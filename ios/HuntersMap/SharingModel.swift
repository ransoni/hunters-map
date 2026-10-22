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
    /// Smoothed direction of travel (compass degrees), nil when standing still.
    let heading: Double?
    let updatedAt: Date
    let sharingUntil: Date

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    /// Positions older than this are shown greyed out ("last seen").
    static let staleAfter: TimeInterval = 5 * 60

    func isStale(now: Date = .now) -> Bool { now.timeIntervalSince(updatedAt) > Self.staleAfter }

    /// Since when the hunter has stayed within `stillRadius` of this position, from their
    /// track (nil without a track).
    var stillSince: Date?
    static let stillRadius: CLLocationDistance = 30
    /// Shown as "paikallaan X min" from this long on.
    static let stillAfter: TimeInterval = 5 * 60

    /// Minutes standing still, when that's at least `stillAfter` and the position is fresh.
    func stillMinutes(now: Date = .now) -> Int? {
        guard let stillSince, !isStale(now: now) else { return nil }
        let still = now.timeIntervalSince(stillSince)
        return still >= Self.stillAfter ? Int(still / 60) : nil
    }
}

@MainActor
final class SharingModel: ObservableObject {
    static let uploadInterval: TimeInterval = 20
    static let uploadDistance: CLLocationDistance = 25
    /// GPS reports nothing while standing still (e.g. at a hunting post), so the last position
    /// is re-sent this often to show others the hunter is still there.
    static let heartbeatInterval: TimeInterval = 60
    /// Direction of travel = bearing from where the hunter was this far back to where they are
    /// now: the average of all small steps in between, so GPS jitter doesn't swing the arrow.
    static let headingDistance: CLLocationDistance = 30
    /// No direction (no arrow) unless `headingDistance` was covered within this time.
    static let headingWindow: TimeInterval = 120
    static let durations: [TimeInterval] = [2, 4, 8, 12, 24].map { $0 * 3600 }

    /// The caller's groups; `sharingUntil` is the caller's own sharing in that group.
    @Published private(set) var groups: [HuntingGroup] = []
    /// Other hunters currently sharing in any of the caller's groups (one entry per person).
    @Published private(set) var hunters: [HunterPosition] = []
    @Published private(set) var positionsByGroup: [String: [String: HunterPosition]] = [:]
    /// Each hunter's track from the last TrackRecorder.window (server-side, groups/{id}/tracks).
    @Published private(set) var trails: [String: [TrackPoint]] = [:]
    private var tracksByGroup: [String: [String: [TrackPoint]]] = [:]
    private var trackListeners: [String: ListenerRegistration] = [:]
    @Published private(set) var lastUpload: Date?
    @Published var errorMessage: String?

    private let api: APIClient
    private let recorder: TrackRecorder
    private lazy var db = Firestore.firestore(database: "hunters-map")
    private var uid: String?
    private var listeners: [String: ListenerRegistration] = [:]
    private var lastSent: CLLocation?
    /// Every accurate fix from the last `headingWindow`, for the smoothed direction.
    private var recentFixes: [CLLocation] = []
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
        guard isSharing else { return }
        recentFixes.append(location)
        recentFixes.removeAll { location.timestamp.timeIntervalSince($0.timestamp) > Self.headingWindow }
        guard !uploading else { return }
        if let lastSent,
           location.timestamp.timeIntervalSince(lastSent.timestamp) < Self.uploadInterval,
           location.distance(from: lastSent) < Self.uploadDistance {
            return
        }
        upload(location, recordedAt: location.timestamp, heading: smoothedHeading(at: location))
    }

    /// Compass bearing (0-360) from the most recent fix at least `headingDistance` back to
    /// `location`, or nil when the hunter hasn't moved that far within `headingWindow`.
    private func smoothedHeading(at location: CLLocation) -> Double? {
        guard let from = recentFixes.last(where: { location.distance(from: $0) >= Self.headingDistance }) else {
            return nil
        }
        return Self.bearing(from: from.coordinate, to: location.coordinate)
    }

    static func bearing(from a: CLLocationCoordinate2D, to b: CLLocationCoordinate2D) -> Double {
        let lat1 = a.latitude * .pi / 180, lat2 = b.latitude * .pi / 180
        let dLon = (b.longitude - a.longitude) * .pi / 180
        let y = sin(dLon) * cos(lat2)
        let x = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(dLon)
        let degrees = atan2(y, x) * 180 / .pi
        return (degrees + 360).truncatingRemainder(dividingBy: 360)
    }

    /// Re-sends the last fix when GPS has been quiet (not moving) for `heartbeatInterval`.
    private func heartbeat() {
        guard isSharing, !uploading, let location = recorder.lastLocation else { return }
        if let lastUpload, Date.now.timeIntervalSince(lastUpload) < Self.heartbeatInterval { return }
        // No new fix means the phone hasn't moved more than the GPS distance filter, so there
        // is no direction of travel either.
        upload(location, recordedAt: .now, heading: nil)
    }

    private func upload(_ location: CLLocation, recordedAt: Date, heading: Double?) {
        uploading = true
        let body = SharedLocation(
            lat: location.coordinate.latitude,
            lon: location.coordinate.longitude,
            accuracy: max(0, location.horizontalAccuracy),
            heading: heading,
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
            trackListeners[id]?.remove()
            trackListeners[id] = nil
            tracksByGroup[id] = nil
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
            trackListeners[id] = db.collection("groups").document(id).collection("tracks")
                .addSnapshotListener { [weak self] snapshot, error in
                    guard let snapshot else {
                        print("tracks listener \(id): \(error?.localizedDescription ?? "?")")
                        return
                    }
                    let tracks = snapshot.documents.map { ($0.documentID, Self.trackPoints($0)) }
                    Task { @MainActor in
                        guard let self, self.trackListeners[id] != nil else { return }
                        self.tracksByGroup[id] = Dictionary(tracks, uniquingKeysWith: { a, _ in a })
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
        // Trails: a hunter shares the same track in every group; take the freshest copy.
        var newTrails: [String: [TrackPoint]] = [:]
        for id in latest.keys {
            let copies = tracksByGroup.values.compactMap { $0[id] }
            let track = copies.max { ($0.last?.time ?? .distantPast) < ($1.last?.time ?? .distantPast) } ?? []
            newTrails[id] = track.filter { now.timeIntervalSince($0.time) <= TrackRecorder.window }
        }
        for (id, track) in newTrails {
            guard let position = latest[id] else { continue }
            latest[id]?.stillSince = Self.stillSince(track, at: position)
        }

        let sorted = latest.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        if sorted != hunters { hunters = sorted }
        if newTrails != trails { trails = newTrails }
    }

    /// Start of the track's final stretch that stays within `stillRadius` of the position.
    private static func stillSince(_ track: [TrackPoint], at position: HunterPosition) -> Date? {
        let here = CLLocation(latitude: position.latitude, longitude: position.longitude)
        var since: Date?
        for point in track.reversed() {
            let there = CLLocation(latitude: point.latitude, longitude: point.longitude)
            if there.distance(from: here) > HunterPosition.stillRadius { break }
            since = point.time
        }
        return since
    }

    private nonisolated static func trackPoints(_ doc: QueryDocumentSnapshot) -> [TrackPoint] {
        let points = doc.data()["points"] as? [[String: Any]] ?? []
        return points.compactMap { p in
            guard let lat = p["lat"] as? Double, let lon = p["lon"] as? Double,
                  let t = (p["t"] as? Timestamp)?.dateValue() else { return nil }
            return TrackPoint(latitude: lat, longitude: lon, time: t)
        }
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
            heading: d["heading"] as? Double,
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
