import Foundation

@MainActor private final class LocationAddressGeocoder: CaptureAddressResolving {
    var calls = 0
    var pending: CheckedContinuation<CaptureAddress, Error>?
    func resolve(_ point: CaptureLocation, localeIdentifier: String) async throws -> CaptureAddress {
        calls += 1
        return try await withCheckedThrowingContinuation { pending = $0 }
    }
    func cancel() {} // Deliberately deliver late completion to exercise the production generation guard.
    func finish(_ result: Result<CaptureAddress, Error>) { let value = pending; pending = nil; value?.resume(with: result) }
}

@main struct RecordingLocationAddressesSmoke {
    @MainActor static func waitUntil(_ condition: () throws -> Bool) async throws {
        let deadline = Date.now.addingTimeInterval(3)
        while try !condition(), Date.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        let completed = try condition()
        precondition(completed, "Timed out waiting for production address worker")
    }
    @MainActor static func main() async throws {
        let root = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("recording-addresses-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let db = try DaybookDatabase(url: root.appendingPathComponent("metadata.sqlite3"))
        let repo = try RecordingSessionRepository(root: root.appendingPathComponent("media"), database: db)
        let date = Date.now, sid = UUID()
        let point = CaptureLocation(latitude: 1, longitude: 2, accuracy: 20, measuredAt: date, source: .watchRecording)!
        let sample = RecordingLocationSample(sessionID: sid, sessionOffset: 0, requestedAt: date, location: point, sourceDevice: "Watch")
        try repo.importLocationSample(sample, pairingID: "pair")
        let geo = LocationAddressGeocoder()
        let consumer = RecordingLocationAddressModel(resolver: geo, requestSpacing: .zero, openRepository: { repo })
        func sync(enabled: Bool = true, foreground: Bool = true) {
            consumer.synchronize(sessionIDs: [sid], day: date, localeIdentifier: "en_US", enabled: enabled, foreground: foreground)
        }
        sync(enabled: false)
        sync(foreground: false)
        precondition(geo.calls == 0, "Foreground and location permission gate address lookup")
        sync()
        try await waitUntil { geo.calls == 1 }
        sync(foreground: false)
        let address = CaptureAddress(text: "Example road", localeIdentifier: "en_US", city: "Example")!
        geo.finish(.success(address))
        try await Task.sleep(for: .milliseconds(30))
        let cancelledAddress = try repo.locationSamples(sessionID: sid).first?.location.address
        precondition(cancelledAddress == nil, "Cancelled geocoder result must not persist")
        sync()
        try await waitUntil { geo.calls == 2 }
        geo.finish(.failure(URLError(.notConnectedToInternet)))
        try await Task.sleep(for: .milliseconds(30))
        sync()
        try await Task.sleep(for: .milliseconds(30))
        let offlineAddress = try repo.locationSamples(sessionID: sid).first?.location.address
        precondition(geo.calls == 2 && offlineAddress == nil, "Offline keeps raw coordinate and avoids retry on every render")
        sync(foreground: false); sync()
        try await waitUntil { geo.calls == 3 }
        geo.finish(.success(address))
        try await waitUntil { try repo.locationSamples(sessionID: sid).first?.location.address == address }
        let restoredGeo = LocationAddressGeocoder()
        let restored = RecordingLocationAddressModel(resolver: restoredGeo, requestSpacing: .zero, openRepository: { repo })
        restored.synchronize(sessionIDs: [sid], day: date, localeIdentifier: "en_US", enabled: true, foreground: true)
        try await Task.sleep(for: .milliseconds(30))
        precondition(restoredGeo.calls == 0, "Durable address cache is available offline after foreground consumer restart")
        print("Recording location addresses: foreground consent, cancellation, offline retry and durable cache passed")
    }
}
