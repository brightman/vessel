import Foundation

@MainActor private final class Geocoder: CaptureAddressResolving {
    var calls: [(CaptureLocation, String)] = []
    var pending: [CheckedContinuation<CaptureAddress, Error>] = []
    func resolve(_ point: CaptureLocation, localeIdentifier: String) async throws -> CaptureAddress {
        calls.append((point, localeIdentifier))
        return try await withCheckedThrowingContinuation { pending.append($0) }
    }
    func cancel() {} // Allow a late response to verify the production generation guard.
    func finish(_ result: Result<CaptureAddress, Error>) { pending.removeFirst().resume(with: result) }
}
@main struct CaptureAddressModelSmoke {
    @MainActor static func spin() async { for _ in 0..<200 { await Task.yield() } }
    @MainActor static func additionalOwnerScope() async {
        let geo = Geocoder()
        let scoped = CaptureAddressModel(resolver: geo, requestSpacing: .zero)
        let day = Date.now, yesterday = Calendar.current.date(byAdding: .day, value: -1, to: Date.now)!
        let evidence = CaptureAddressRequest(owner: .voice(UUID()), date: yesterday,
            point: CaptureLocation(latitude: 31.23, longitude: 121.54, source: .watchRecording)!)
        let unrelated = CaptureAddressRequest(owner: .photo(UUID()), date: yesterday,
            point: CaptureLocation(latitude: 31.30, longitude: 120.59, source: .photoMetadata)!)
        let requests = [evidence, unrelated]
        var saved: [CaptureAddressRequest.Owner: CaptureAddress] = [:]
        func sync(_ owners: Set<CaptureAddressRequest.Owner> = [], enabled: Bool = true, foreground: Bool = true) {
            scoped.synchronize(requests: requests, day: day, localeIdentifier: "zh-Hans", enabled: enabled,
                               foreground: foreground, additionalOwners: owners) { request, address in
                saved[request.owner] = address; return true
            }
        }
        sync(); await spin()
        precondition(geo.calls.isEmpty && saved.isEmpty, "prior-day records are excluded by default")
        sync([evidence.owner], enabled: false); await spin()
        sync([evidence.owner], foreground: false); await spin()
        precondition(geo.calls.isEmpty, "explicit evidence still requires enabled foreground resolution")
        sync([evidence.owner]); await spin()
        precondition(geo.calls.count == 1 && geo.calls[0].0.matchesCapture(evidence.point), "explicit prior-day evidence resolves")
        let address = CaptureAddress(text: "上海市", localeIdentifier: "zh-Hans", city: "上海")!
        geo.finish(.success(address)); await spin()
        precondition(saved[evidence.owner] == address && saved[unrelated.owner] == nil && geo.calls.count == 1,
                     "unrelated prior-day owners remain untouched")
        sync([unrelated.owner]); await spin()
        precondition(geo.calls.count == 2)
        sync(); geo.finish(.success(address)); await spin()
        precondition(saved[unrelated.owner] == nil, "removing an explicit owner rejects its late result")
    }
    @MainActor static func main() async throws {
        let geo = Geocoder()
        let model = CaptureAddressModel(resolver: geo, requestSpacing: .zero)
        let day = Date.now
        let point = CaptureLocation(latitude: 31.2345, longitude: 121.5432, source: .watchRecording)!
        let address = CaptureAddress(text: "上海市浦东新区世纪大道 1 号", localeIdentifier: "zh-Hans")!
        let first = CaptureAddressRequest(owner: .voice(UUID()), date: day, point: point)
        let second = CaptureAddressRequest(owner: .photo(UUID()), date: day, point: point)
        var saved: [CaptureAddressRequest.Owner: CaptureAddress] = [:]
        func sync(_ requests: [CaptureAddressRequest], enabled: Bool = true, foreground: Bool = true, locale: String = "zh-Hans") {
            model.synchronize(requests: requests, day: day, localeIdentifier: locale, enabled: enabled, foreground: foreground) { request, result in
                saved[request.owner] = result; return true
            }
        }
        sync([first, second], enabled: false); await spin()
        precondition(geo.calls.isEmpty && saved.isEmpty)
        sync([first, second]); await spin()
        precondition(geo.calls.count == 1 && geo.pending.count == 1, "same coordinate resolves once across voice/photo")
        geo.finish(.success(address)); await spin()
        precondition(saved[first.owner] == address && saved[second.owner] == address)
        let third = CaptureAddressRequest(owner: .voice(UUID()), date: day, point: point)
        sync([first, second, third]); await spin()
        precondition(saved[third.owner] == address && geo.calls.count == 1, "new capture reuses coordinate cache")
        var cached = point; cached.address = address
        let cachedGeo = Geocoder()
        let restored = CaptureAddressModel(resolver: cachedGeo, requestSpacing: .zero)
        restored.synchronize(requests: [.init(owner: .voice(UUID()), date: day, point: cached), third], day: day,
                             localeIdentifier: "zh-Hans", enabled: true, foreground: true) { request, result in saved[request.owner] = result; return true }
        await spin()
        precondition(cachedGeo.calls.isEmpty && saved[third.owner] == address, "persisted addresses work offline after restart")

        let otherPoint = CaptureLocation(latitude: 31.235, longitude: 121.544, source: .phoneRecording)!
        let other = CaptureAddressRequest(owner: .voice(UUID()), date: day, point: otherPoint)
        sync([other]); await spin()
        sync([], enabled: false)
        geo.finish(.success(address)); await spin()
        precondition(saved[other.owner] == nil, "pause/deletion rejects a late geocoder result")
        sync([other]); await spin()
        geo.finish(.failure(URLError(.notConnectedToInternet))); await spin()
        let count = geo.calls.count
        sync([other]); await spin()
        precondition(geo.calls.count == count && saved[other.owner] == nil, "failed reads must not retry on every render")
        sync([other], foreground: false); sync([other]); await spin()
        precondition(geo.calls.count == count + 1, "foreground re-entry retries")
        geo.finish(.success(address)); await spin()
        precondition(saved[other.owner] == address)
        sync([other], locale: "en"); await spin()
        precondition(geo.calls.last?.1 == "en", "cache is locale-specific")
        sync([other], foreground: false, locale: "en")
        geo.finish(.success(CaptureAddress(text: "Shanghai", localeIdentifier: "en")!)); await spin()
        precondition(saved[other.owner] == address, "background cancellation cannot overwrite a saved address")
        await additionalOwnerScope()
        print("Capture address resolution: consent, deduplication, persistent-cache reuse, cancellation, offline retry, language isolation and explicit prior-day evidence passed")
    }
}
