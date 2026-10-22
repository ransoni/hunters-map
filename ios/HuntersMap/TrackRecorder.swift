import Foundation
import CoreLocation

// Records the walked track while recording is on, also with the screen locked (background
// location mode; iOS shows the blue location indicator). Only the last `window` is kept:
// the map draws it as a trail that fades with age. The track is saved to disk, so it
// survives the app being closed, and recording resumes on the next launch.
//
// It is also the app's background GPS engine for location sharing: GPS runs while recording
// or sharing is on, and every accurate fix goes to `onLocation` (SharingModel uploads it).

struct TrackPoint: Codable, Equatable {
    let latitude: Double
    let longitude: Double
    let time: Date

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}

final class TrackRecorder: NSObject, ObservableObject, CLLocationManagerDelegate {
    /// How much of the track is shown.
    static let window: TimeInterval = 60 * 60
    /// Fixes less accurate than this (metres) are skipped, so the trail doesn't zigzag.
    private static let maxAccuracy: CLLocationAccuracy = 30

    @Published private(set) var points: [TrackPoint] = []
    @Published private(set) var isRecording = false
    @Published private(set) var permissionDenied = false

    /// Called with every accurate fix while GPS runs (recording or sharing).
    var onLocation: ((CLLocation) -> Void)?
    /// Latest accurate fix, for sending a position as soon as sharing starts.
    private(set) var lastLocation: CLLocation?

    private let manager = CLLocationManager()
    private var sharingActive = false
    private var backgroundSession: CLBackgroundActivitySession?
    private static let recordingKey = "trackRecording"
    private static let fileURL = URL.applicationSupportDirectory.appending(path: "track.json")

    override init() {
        super.init()
        manager.delegate = self
        manager.activityType = .fitness
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.distanceFilter = 5
        manager.pausesLocationUpdatesAutomatically = false
        manager.showsBackgroundLocationIndicator = true
        load()
        if UserDefaults.standard.bool(forKey: Self.recordingKey) { start() }
    }

    func toggle() {
        isRecording ? stop() : start()
    }

    func start() {
        switch manager.authorizationStatus {
        case .denied, .restricted:
            permissionDenied = true
            return
        case .notDetermined:
            manager.requestWhenInUseAuthorization() // starts in locationManagerDidChangeAuthorization
        default:
            break
        }
        isRecording = true
        UserDefaults.standard.set(true, forKey: Self.recordingKey)
        updateEngine()
    }

    func stop() {
        isRecording = false
        UserDefaults.standard.set(false, forKey: Self.recordingKey)
        updateEngine()
        save()
    }

    /// Keeps GPS running for location sharing, also when the track isn't recorded.
    func setSharingActive(_ active: Bool) {
        guard active != sharingActive else { return }
        sharingActive = active
        if active && manager.authorizationStatus == .notDetermined {
            manager.requestWhenInUseAuthorization()
        }
        updateEngine()
    }

    private var gpsNeeded: Bool { isRecording || sharingActive }

    private func updateEngine() {
        if gpsNeeded {
            beginUpdates()
        } else {
            manager.stopUpdatingLocation()
            manager.allowsBackgroundLocationUpdates = false
            backgroundSession?.invalidate()
            backgroundSession = nil
        }
    }

    /// Points within the window, oldest first.
    func recentPoints(now: Date = .now) -> [TrackPoint] {
        points.filter { now.timeIntervalSince($0.time) <= Self.window }
    }

    private func beginUpdates() {
        let status = manager.authorizationStatus
        guard status == .authorizedWhenInUse || status == .authorizedAlways else { return }
        // Keeps updates coming with the screen locked, under "While Using the App" permission.
        manager.allowsBackgroundLocationUpdates = true
        if backgroundSession == nil { backgroundSession = CLBackgroundActivitySession() }
        manager.startUpdatingLocation()
    }

    // MARK: CLLocationManagerDelegate

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        switch manager.authorizationStatus {
        case .denied, .restricted:
            if isRecording { stop() }
            permissionDenied = true
        case .authorizedWhenInUse, .authorizedAlways:
            permissionDenied = false
            if gpsNeeded { beginUpdates() }
        default:
            break
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        let accepted = locations.filter {
            $0.horizontalAccuracy >= 0 && $0.horizontalAccuracy <= Self.maxAccuracy
        }
        guard let latest = accepted.last else { return }
        lastLocation = latest
        onLocation?(latest)
        guard isRecording else { return }
        let now = Date.now
        var updated = points.filter { now.timeIntervalSince($0.time) <= Self.window }
        for location in accepted {
            updated.append(TrackPoint(latitude: location.coordinate.latitude,
                                      longitude: location.coordinate.longitude,
                                      time: location.timestamp))
        }
        points = updated
        save()
    }

    // MARK: Persistence

    private func load() {
        guard let data = try? Data(contentsOf: Self.fileURL),
              let saved = try? JSONDecoder().decode([TrackPoint].self, from: data) else { return }
        points = saved.filter { Date.now.timeIntervalSince($0.time) <= Self.window }
    }

    private func save() {
        do {
            try FileManager.default.createDirectory(at: URL.applicationSupportDirectory,
                                                    withIntermediateDirectories: true)
            try JSONEncoder().encode(points).write(to: Self.fileURL, options: .atomic)
        } catch {
            print("track save failed: \(error)")
        }
    }
}
