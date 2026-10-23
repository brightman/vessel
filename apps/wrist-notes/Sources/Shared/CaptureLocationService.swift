import CoreLocation
import Foundation

/// iPhone mirrors its SQLite setting here for recording intents; Watch receives the same preference.
/// Authorization is always checked independently on the capturing device.
enum CaptureLocationSettings {
    static let key = "WiseLife.captureLocationEnabled"
    static let changed = Notification.Name("WiseLife.captureLocationChanged")
    private static let revisionLock = NSLock()
    private static var policyRevision: UInt64 = 0
    /// In-process generation also invalidates work queued across a quick off/on toggle.
    static var revision: UInt64 { revisionLock.withLock { policyRevision } }
    static var enabled: Bool { UserDefaults.standard.bool(forKey: key) }
    static func setEnabled(_ value: Bool) {
        revisionLock.withLock {
            if UserDefaults.standard.bool(forKey: key) != value { policyRevision &+= 1 }
            UserDefaults.standard.set(value, forKey: key)
        }
        NotificationCenter.default.post(name: changed, object: value)
    }
}

/// Used only during capture. Never blocks audio, requests background permission, or geocodes.
final class CaptureLocationService: NSObject, CLLocationManagerDelegate {
    private let manager: CLLocationManager
    private var captureDate: Date?
    private var source: CaptureLocation.Source = .phoneRecording
    private var completion: ((CaptureLocation) -> Void)?
    private var timeout: Timer?
    private var observation: NSObjectProtocol?
    private var cameraPreview = false
    private var samples: [CLLocation] = []

    init(manager: CLLocationManager = CLLocationManager()) {
        self.manager = manager
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        observation = NotificationCenter.default.addObserver(forName: CaptureLocationSettings.changed, object: nil, queue: .main) { [weak self] _ in
            if !CaptureLocationSettings.enabled { self?.cancel() }
        }
    }
    deinit {
        if let observation { NotificationCenter.default.removeObserver(observation) }
        timeout?.invalidate()
    }
    func begin(at date: Date, source: CaptureLocation.Source, onFix: @escaping (CaptureLocation) -> Void) {
        cancel()
        guard CaptureLocationSettings.enabled else { return }
        captureDate = date; self.source = source; completion = onFix
        timeout = Timer.scheduledTimer(withTimeInterval: 20, repeats: false) { [weak self] _ in self?.cancel() }
        startIfAuthorized()
    }
    // Keep only a short memory of fixes while the camera UI is visible. This lets the
    // original shutter timestamp, rather than the later "Use Photo" tap, select a fix.
    func beginCameraPreview() {
        cancel()
        guard CaptureLocationSettings.enabled else { return }
        cameraPreview = true; startIfAuthorized()
    }
    func finishCamera(at date: Date?) -> CaptureLocation? {
        defer { cancel() }
        guard CaptureLocationSettings.enabled, let date,
              let sample = samples.min(by: { abs($0.timestamp.timeIntervalSince(date)) < abs($1.timestamp.timeIntervalSince(date)) }),
              abs(sample.timestamp.timeIntervalSince(date)) <= 15 else { return nil }
        return point(sample, source: .phoneCamera)
    }
    func cancel() {
        timeout?.invalidate(); timeout = nil; captureDate = nil; completion = nil
        cameraPreview = false; samples = []; manager.stopUpdatingLocation()
    }
    private func startIfAuthorized() {
        guard CaptureLocationSettings.enabled, captureDate != nil || cameraPreview else { return }
        switch manager.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse: manager.startUpdatingLocation()
        case .notDetermined: manager.requestWhenInUseAuthorization()
        default: cancel()
        }
    }
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) { startIfAuthorized() }
    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard CaptureLocationSettings.enabled else { cancel(); return }
        let recent = locations.filter { $0.horizontalAccuracy >= 0 && abs($0.timestamp.timeIntervalSinceNow) <= 30 }
        if cameraPreview {
            samples.append(contentsOf: recent)
            samples.removeAll { $0.timestamp.timeIntervalSinceNow < -180 }
            return
        }
        guard let captureDate,
              let value = recent.reversed().compactMap({ point($0, source: source) }).first(where: { $0.isNearCapture(captureDate) }) else { return }
        let callback = completion; cancel(); callback?(value)
    }
    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        if (error as? CLError)?.code != .locationUnknown { cancel() }
    }
    private func point(_ location: CLLocation, source: CaptureLocation.Source) -> CaptureLocation? {
        CaptureLocation(latitude: location.coordinate.latitude, longitude: location.coordinate.longitude,
                        accuracy: location.horizontalAccuracy, measuredAt: location.timestamp, source: source)
    }
}
