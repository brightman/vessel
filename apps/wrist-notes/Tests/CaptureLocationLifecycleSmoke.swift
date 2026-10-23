import Foundation
import CoreLocation

private final class LocationManagerStub: CLLocationManager {
    var starts = 0
    var stops = 0
    var permissionRequests = 0
    var permission: CLAuthorizationStatus = .authorizedAlways
    override var authorizationStatus: CLAuthorizationStatus { permission }
    override func startUpdatingLocation() { starts += 1 }
    override func stopUpdatingLocation() { stops += 1 }
    override func requestWhenInUseAuthorization() { permissionRequests += 1 }
}

@main struct CaptureLocationLifecycleSmoke {
    static func main() {
        let prior = CaptureLocationSettings.enabled
        defer { CaptureLocationSettings.setEnabled(prior) }
        let manager = LocationManagerStub()
        let service = CaptureLocationService(manager: manager)
        var received: [CaptureLocation] = []
        let date = Date.now
        func sample(_ seconds: Double, accuracy: Double = 10) -> CLLocation {
            CLLocation(coordinate: .init(latitude: 31.2, longitude: 121.5), altitude: 0,
                       horizontalAccuracy: accuracy, verticalAccuracy: -1, timestamp: date.addingTimeInterval(seconds))
        }
        let initialPolicyRevision = CaptureLocationSettings.revision
        CaptureLocationSettings.setEnabled(false)
        CaptureLocationSettings.setEnabled(true)
        precondition(CaptureLocationSettings.revision != initialPolicyRevision, "Off/on must invalidate already queued location persistence")
        CaptureLocationSettings.setEnabled(false)
        service.begin(at: date, source: .phoneRecording) { received.append($0) }
        precondition(manager.starts == 0)
        CaptureLocationSettings.setEnabled(true)
        service.begin(at: date, source: .phoneRecording) { received.append($0) }
        precondition(manager.starts == 1)
        service.locationManager(manager, didUpdateLocations: [sample(-120), sample(0, accuracy: -1)])
        precondition(received.isEmpty)
        service.locationManager(manager, didUpdateLocations: [sample(0)])
        precondition(received.count == 1)
        service.locationManager(manager, didUpdateLocations: [sample(1)])
        precondition(received.count == 1, "Only one fix per recording")
        service.begin(at: date, source: .watchRecording) { received.append($0) }
        service.cancel()
        service.locationManager(manager, didUpdateLocations: [sample(1)])
        precondition(received.count == 1, "Cancelled capture cannot acquire late metadata")
        service.begin(at: date, source: .phoneRecording) { received.append($0) }
        CaptureLocationSettings.setEnabled(false)
        service.locationManager(manager, didUpdateLocations: [sample(1)])
        precondition(received.count == 1, "Pause invalidates outstanding request")
        CaptureLocationSettings.setEnabled(true)
        manager.permission = .denied
        let count = manager.starts
        service.begin(at: date, source: .watchRecording) { received.append($0) }
        precondition(manager.starts == count)
        manager.permission = .notDetermined
        service.begin(at: date, source: .watchRecording) { received.append($0) }
        precondition(manager.permissionRequests == 1)
        manager.permission = .authorizedAlways
        service.locationManagerDidChangeAuthorization(manager)
        precondition(manager.starts == count + 1)
        service.cancel()
        service.beginCameraPreview()
        service.locationManager(manager, didUpdateLocations: [sample(-2), sample(2)])
        let camera = service.finishCamera(at: date.addingTimeInterval(-2))
        precondition(camera?.measuredAt == date.addingTimeInterval(-2))
        precondition(camera?.source == .phoneCamera)
        precondition(service.finishCamera(at: date) == nil)
        service.beginCameraPreview()
        service.locationManager(manager, didUpdateLocations: [sample(0)])
        precondition(service.finishCamera(at: date.addingTimeInterval(-120)) == nil, "Never use later import position for shutter")
        print("Capture lifecycle: opt-in, denial, authorization, stale fixes, one-shot, cancel, pause, camera timestamp passed")
    }
}
