import Foundation
import CoreLocation
import SwiftUI
import FirebaseFirestore

// Hunting groups and live location sharing.
//
// - Groups, invites and sharing on/off go through the backend API (APIClient).
// - Own position: while sharing with any group, every GPS fix from TrackRecorder is uploaded,
//   at most every `uploadInterval` unless moved `uploadDistance`. GPS keeps running with the
//   screen locked (background location mode).
// - Others' positions: read live from Firestore (groups/{id}/locations), which the security
//   rules allow for members only.

struct HunterPosition: Identifiable, Equatable {
    let id: String // user id
    let name: String
    let latitude: Double
    let longitude: Double
    let accuracy: Double
    let updatedAt: Date
    let sharingUntil: Date

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    /// Positions older than this are shown greyed out ("last seen").
    static let staleAfter: TimeInterval = 5 * 60

    func isStale(now: Date = .now) -> Bool { now.timeIntervalSince(updatedAt) > Self.staleAfter }
}

@MainActor
final class SharingModel: ObservableObject {
    static let uploadInterval: TimeInterval = 20
    static let uploadDistance: CLLocationDistance = 25
    /// GPS reports nothing while standing still (e.g. at a hunting post), so the last position
    /// is re-sent this often to show others the hunter is still there.
    static let heartbeatInterval: TimeInterval = 60
    static let durations: [TimeInterval] = [2, 4, 8, 12, 24].map { $0 * 3600 }

    /// The caller's groups; `sharingUntil` is the caller's own sharing in that group.
    @Published private(set) var groups: [HuntingGroup] = []
    /// Other hunters currently sharing in any of the caller's groups (one entry per person).
    @Published private(set) var hunters: [HunterPosition] = []
    @Published private(set) var positionsByGroup: [String: [String: HunterPosition]] = [:]
    /// Each hunter's positions from the last TrackRecorder.window, collected from the live
    /// updates while the app is open (the server keeps only the latest position).
    @Published private(set) var trails: [String: [TrackPoint]] = [:]
    @Published private(set) var lastUpload: Date?
    @Published var errorMessage: String?

    private let api: APIClient
    private let recorder: TrackRecorder
    private lazy var db = Firestore.firestore(database: "hunters-map")
    private var uid: String?
    private var listeners: [String: ListenerRegistration] = [:]
    private var lastSent: CLLocation?
    private var uploading = false
    private var timer: Timer?

    init(api: APIClient = .shared, recorder: TrackRecorder) {
        self.api = api
        self.recorder = recorder
        recorder.onLocation = { [weak self] location in
            Task { @MainActor in self?.handle(location) }
        }
        // Sharing ends on its own; also drops others' expired positions and sends the heartbeat.
        timer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.updateEngine()
                self?.recomputeHunters()
                self?.heartbeat()
            }
        }
    }

    var isSharing: Bool { groups.contains { isSharing(in: $0.id) } }

    func isSharing(in groupID: String) -> Bool {
        guard let until = groups.first(where: { $0.id == groupID })?.sharingUntil else { return false }
        return until > .now
    }

    func sharingUntil(in groupID: String) -> Date? {
        isSharing(in: groupID) ? groups.first { $0.id == groupID }?.sharingUntil : nil
    }

    // MARK: Session

    /// Follows sign-in: loads the groups for a user, clears everything on sign-out.
    func userChanged(_ uid: String?) {
        guard uid != self.uid else { return }
        self.uid = uid
        if uid == nil {
            groups = []
            syncListeners()
            updateEngine()
        } else {
            Task { await reload() }
        }
    }

    func reload() async {
        guard uid != nil else { return }
        await run {
            self.groups = try await self.api.groups()
                .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        }
        syncListeners()
        updateEngine()
    }

    // MARK: Groups

    func createGroup(name: String) async -> HuntingGroup? {
        var created: HuntingGroup?
        await run { created = try await self.api.createGroup(name: name) }
        await reload()
        return created
    }

    func join(code: String) async -> HuntingGroup? {
        var joined: HuntingGroup?
        await run { joined = try await self.api.join(code: code) }
        await reload()
        return joined
    }

    func detail(groupID: String) async -> HuntingGroup? {
        var group: HuntingGroup?
        await run { group = try await self.api.group(id: groupID) }
        return group
    }

    func invite(groupID: String) async -> GroupInvite? {
        var invite: GroupInvite?
        await run { invite = try await self.api.createInvite(groupID: groupID) }
        return invite
    }

    /// Leaves the group (an owner hands it over to the longest-standing member).
    func leave(groupID: String) async -> Bool {
        guard let uid else { return false }
        let ok = await run { try await self.api.removeMember(groupID: groupID, userID: uid) }
        await reload()
        return ok
    }

    func deleteGroup(groupID: String) async -> Bool {
        let ok = await run { try await self.api.deleteGroup(id: groupID) }
        await reload()
        return ok
    }

    // MARK: Sharing

    /// Starts sharing in a group for `duration`, or stops with nil.
    func setSharing(groupID: String, duration: TimeInterval?) async {
        let until = duration.map { Date.now.addingTimeInterval($0) }
        await run { _ = try await self.api.setSharing(groupID: groupID, until: until) }
        await reload()
        if until != nil, let location = recorder.lastLocation {
            lastSent = nil // send right away, others shouldn't wait for the next fix
            handle(location)
        }
    }

    private func updateEngine() {
        recorder.setSharingActive(isSharing)
    }

    private func handle(_ location: CLLocation) {
        guard isSharing, !uploading else { return }
        if let lastSent,
           location.timestamp.timeIntervalSince(lastSent.timestamp) < Self.uploadInterval,
           location.distance(from: lastSent) < Self.uploadDistance {
            return
        }
        upload(location, recordedAt: location.timestamp)
    }

    /// Re-sends the last fix when GPS has been quiet (not moving) for `heartbeatInterval`.
    private func heartbeat() {
        guard isSharing, !uploading, let location = recorder.lastLocation else { return }
        if let lastUpload, Date.now.timeIntervalSince(lastUpload) < Self.heartbeatInterval { return }
        // No new fix means the phone hasn't moved more than the GPS distance filter.
        upload(location, recordedAt: .now)
    }

    private func upload(_ location: CLLocation, recordedAt: Date) {
        uploading = true
        let body = SharedLocation(
            lat: location.coordinate.latitude,
            lon: location.coordinate.longitude,
            accuracy: max(0, location.horizontalAccuracy),
            heading: location.course >= 0 && location.course < 360 ? location.course : nil,
            speed: location.speed >= 0 && location.speed <= 100 ? location.speed : nil,
            recordedAt: recordedAt)
        Task {
            defer { uploading = false }
            do {
                _ = try await api.postLocation(body)
                lastSent = location
                lastUpload = .now
            } catch {
                // Weak coverage in the forest: skip this one, the next fix is sent instead.
                print("location upload failed: \(error.localizedDescription)")
            }
        }
    }

    // MARK: Others' positions (Firestore)

    private func syncListeners() {
        let wanted = Set(groups.map(\.id))
        for (id, listener) in listeners where !wanted.contains(id) {
            listener.remove()
            listeners[id] = nil
            positionsByGroup[id] = nil
        }
        for id in wanted where listeners[id] == nil {
            listeners[id] = db.collection("groups").document(id).collection("locations")
                .addSnapshotListener { [weak self] snapshot, error in
                    guard let snapshot else {
                        print("locations listener \(id): \(error?.localizedDescription ?? "?")")
                        return
                    }
                    let positions = snapshot.documents.compactMap(Self.position)
                    Task { @MainActor in
                        guard let self, self.listeners[id] != nil else { return }
                        self.positionsByGroup[id] = Dictionary(positions.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
                        self.recomputeHunters()
                    }
                }
        }
        recomputeHunters()
    }

    private func recomputeHunters() {
        let now = Date.now
        var latest: [String: HunterPosition] = [:]
        for positions in positionsByGroup.values {
            for p in positions.values where p.id != uid && p.sharingUntil > now {
                if let seen = latest[p.id], seen.updatedAt >= p.updatedAt { continue }
                latest[p.id] = p
            }
        }
        let sorted = latest.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        if sorted != hunters { hunters = sorted }

        var newTrails: [String: [TrackPoint]] = [:]
        for h in sorted {
            var track = (trails[h.id] ?? []).filter { now.timeIntervalSince($0.time) <= TrackRecorder.window }
            if h.updatedAt > track.last?.time ?? .distantPast {
                track.append(TrackPoint(latitude: h.latitude, longitude: h.longitude, time: h.updatedAt))
            }
            newTrails[h.id] = track
        }
        if newTrails != trails { trails = newTrails }
    }

    private nonisolated static func position(_ doc: QueryDocumentSnapshot) -> HunterPosition? {
        let d = doc.data()
        guard let lat = d["lat"] as? Double, let lon = d["lon"] as? Double,
              let updated = (d["updatedAt"] as? Timestamp)?.dateValue(),
              let until = (d["sharingUntil"] as? Timestamp)?.dateValue() else { return nil }
        return HunterPosition(
            id: doc.documentID,
            name: d["displayName"] as? String ?? "?",
            latitude: lat, longitude: lon,
            accuracy: d["accuracy"] as? Double ?? 0,
            updatedAt: updated, sharingUntil: until)
    }

    // MARK: Helpers

    @discardableResult
    private func run(_ work: @escaping () async throws -> Void) async -> Bool {
        do {
            try await work()
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }
}

/// Stable colour and initials for a hunter, used on the map and in member lists.
enum HunterStyle {
    static let palette: [UIColor] = [
        UIColor(red: 0.12, green: 0.47, blue: 0.85, alpha: 1), // blue
        UIColor(red: 0.80, green: 0.20, blue: 0.55, alpha: 1), // magenta
        UIColor(red: 0.10, green: 0.60, blue: 0.45, alpha: 1), // teal
        UIColor(red: 0.55, green: 0.30, blue: 0.80, alpha: 1), // purple
        UIColor(red: 0.85, green: 0.55, blue: 0.05, alpha: 1), // amber
        UIColor(red: 0.20, green: 0.45, blue: 0.20, alpha: 1), // forest
        UIColor(red: 0.75, green: 0.25, blue: 0.20, alpha: 1), // brick
        UIColor(red: 0.25, green: 0.30, blue: 0.40, alpha: 1), // slate
    ]
    static let stale = UIColor(red: 0.61, green: 0.60, blue: 0.57, alpha: 1)

    /// Same colour for a person on every launch (String.hashValue is randomised per run).
    static func color(for userID: String) -> UIColor {
        let sum = userID.unicodeScalars.reduce(0) { $0 &+ Int($1.value) }
        return palette[sum % palette.count]
    }

    static func initials(_ name: String) -> String {
        let parts = name.split(separator: " ").prefix(2)
        let letters = parts.compactMap(\.first).map(String.init).joined()
        return letters.isEmpty ? "?" : letters.uppercased()
    }

    static func hex(_ color: UIColor) -> String {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        color.getRed(&r, green: &g, blue: &b, alpha: &a)
        return String(format: "#%02X%02X%02X", Int(r * 255), Int(g * 255), Int(b * 255))
    }
}
