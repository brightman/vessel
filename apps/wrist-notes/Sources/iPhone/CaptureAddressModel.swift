import Combine
import Foundation

struct CaptureAddressRequest: Equatable, Sendable {
    enum Owner: Hashable, Sendable { case voice(UUID), photo(UUID) }
    let owner: Owner
    let date: Date
    var point: CaptureLocation
}

@MainActor protocol CaptureAddressResolving {
    func resolve(_ point: CaptureLocation, localeIdentifier: String) async throws -> CaptureAddress
    func cancel()
}

/// The durable cache lives on original media records, so deleting media also deletes its address.
/// This queue only enriches existing coordinates; it never acquires a fresh location.
@MainActor final class CaptureAddressModel: ObservableObject {
    @Published private(set) var isResolving = false
    private let resolver: any CaptureAddressResolving
    private let requestSpacing: Duration
    private var requests: [CaptureAddressRequest] = []
    private var cache: [String: CaptureAddress] = [:]
    private var attempted: Set<String> = []
    private var worker: Task<Void, Never>?
    private var generation = UUID()
    private var scope = ""
    private var activeKey: String?
    private var day = Date.now
    private var additionalOwners: Set<CaptureAddressRequest.Owner> = []
    private var localeIdentifier = ""
    private var canResolve = false
    private var apply: ((CaptureAddressRequest, CaptureAddress) -> Bool)?

    #if os(iOS)
    convenience init() { self.init(resolver: AppleCaptureAddressResolver()) }
    #endif
    init(resolver: any CaptureAddressResolving, requestSpacing: Duration = .seconds(1)) {
        self.resolver = resolver; self.requestSpacing = requestSpacing
    }

    func synchronize(requests: [CaptureAddressRequest], day: Date, localeIdentifier: String,
                     enabled: Bool, foreground: Bool,
                     additionalOwners: Set<CaptureAddressRequest.Owner> = [],
                     apply: @escaping (CaptureAddressRequest, CaptureAddress) -> Bool) {
        let day = Calendar.current.startOfDay(for: day)
        let nextScope = "\(enabled)|\(foreground)|\(day.timeIntervalSince1970)|\(localeIdentifier)"
        if scope != nextScope { cancel(); attempted.removeAll(); scope = nextScope }
        let previous = Dictionary(self.requests.map { ($0.owner, $0.point.coordinateKey) }, uniquingKeysWith: { a, _ in a })
        for request in requests where previous[request.owner] != request.point.coordinateKey {
            attempted.remove(request.point.coordinateKey)
        }
        self.requests = requests; self.day = day; self.localeIdentifier = localeIdentifier
        self.additionalOwners = additionalOwners
        self.canResolve = enabled && foreground; self.apply = apply
        let retainedKeys = Set(requests.map { $0.point.coordinateKey })
        cache = cache.filter { retainedKeys.contains($0.key) && $0.value.isCurrent(for: localeIdentifier) }
        for request in requests {
            if let address = request.point.address, address.isCurrent(for: localeIdentifier) {
                cache[request.point.coordinateKey] = address
            }
        }
        if let activeKey, !candidates.contains(where: { $0.point.coordinateKey == activeKey }) { cancel() }
        guard canResolve, worker == nil, nextRequest != nil else { return }
        let token = UUID(); generation = token; isResolving = true
        worker = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.generation == token { self.worker = nil; self.activeKey = nil; self.isResolving = false }
            }
            while self.generation == token, let request = self.nextRequest {
                let key = request.point.coordinateKey
                self.attempted.insert(key); self.activeKey = key
                let wasCached = self.cache[key] != nil
                do {
                    let address: CaptureAddress
                    if let cached = self.cache[key] { address = cached }
                    else { address = try await self.resolver.resolve(request.point, localeIdentifier: self.localeIdentifier) }
                    try Task.checkCancellation()
                    guard self.generation == token, self.canResolve, address.isCurrent(for: self.localeIdentifier) else { return }
                    self.cache[key] = address
                    // Use current requests, not the list from before an asynchronous lookup.
                    for target in self.requests where target.point.coordinateKey == key && target.point.address != address {
                        if self.apply?(target, address) == true,
                           let index = self.requests.firstIndex(where: { $0.owner == target.owner && $0.point.matchesCapture(target.point) }) {
                            self.requests[index].point.address = address
                        }
                    }
                } catch {
                    guard self.generation == token, !Task.isCancelled else { return }
                    // No invented address or destructive empty update. A new foreground/date
                    // session retries; re-rendering the same failed session does not hammer Maps.
                }
                self.activeKey = nil
                if !wasCached, self.nextRequest != nil {
                    do { try await Task.sleep(for: self.requestSpacing) } catch { return }
                }
            }
        }
    }
    private var candidates: [CaptureAddressRequest] {
        requests.filter {
            (Calendar.current.isDate($0.date, inSameDayAs: day) || additionalOwners.contains($0.owner))
                && $0.point.address?.isCurrent(for: localeIdentifier) != true
        }
    }
    private var nextRequest: CaptureAddressRequest? { candidates.first { !attempted.contains($0.point.coordinateKey) } }
    private func cancel() {
        generation = UUID(); worker?.cancel(); worker = nil
        resolver.cancel(); activeKey = nil; isResolving = false
    }
}
