import Foundation
import HealthKit

/// HealthKit's OS boundary is replaced; preparation and observation/read lifecycle are production.
private final class HealthStoreProbe: HKHealthStore, @unchecked Sendable {
    private let lock = NSLock()
    private var executedQueries: [HKQuery] = []
    private var stoppedQueries: [HKQuery] = []
    private var delivery: [Bool] = []
    private var delayedEnable: (@Sendable (Bool, (any Error)?) -> Void)?
    var holdNextEnable = false
    var queries: [HKQuery] { lock.withLock { executedQueries } }
    var stopped: [HKQuery] { lock.withLock { stoppedQueries } }
    var deliveryChanges: [Bool] { lock.withLock { delivery } }
    var hasDelayedEnable: Bool { lock.withLock { delayedEnable != nil } }
    override func execute(_ query: HKQuery) { lock.withLock { executedQueries.append(query) } }
    override func stop(_ query: HKQuery) { lock.withLock { stoppedQueries.append(query) } }
    override func enableBackgroundDelivery(for type: HKObjectType, frequency: HKUpdateFrequency,
                                          withCompletion completion: @escaping @Sendable (Bool, (any Error)?) -> Void) {
        let delayed = lock.withLock {
            delivery.append(true)
            if holdNextEnable { holdNextEnable = false; delayedEnable = completion; return true }
            return false
        }
        if !delayed { completion(true, nil) }
    }
    override func disableBackgroundDelivery(for type: HKObjectType,
                                           withCompletion completion: @escaping @Sendable (Bool, (any Error)?) -> Void) {
        lock.withLock { delivery.append(false) }; completion(true, nil)
    }
    func finishEnable() {
        let completion = lock.withLock { let value = delayedEnable; delayedEnable = nil; return value }
        completion?(true, nil)
    }
}

private final class PreparationGate: @unchecked Sendable {
    private let lock = NSLock()
    private let release = DispatchSemaphore(value: 0)
    private let entered = DispatchSemaphore(value: 0)
    private var calls = 0
    private var prepared: HealthStoreProbe?
    var callCount: Int { lock.withLock { calls } }
    var store: HealthStoreProbe? { lock.withLock { prepared } }
    func prepare() -> HKHealthStore? {
        precondition(!Thread.isMainThread, "HealthKit store initialization must not perform main-thread I/O")
        lock.withLock { calls += 1 }
        entered.signal()
        release.wait()
        let store = HealthStoreProbe()
        lock.withLock { prepared = store }
        return store
    }
    func finish() { release.signal() }
    func finishWhenFactoryStarts() {
        DispatchQueue.global(qos: .userInitiated).async {
            self.entered.wait()
            self.release.signal()
        }
    }
}

@main struct HealthStorePreparationSmoke {
    @MainActor static func until(_ condition: () -> Bool) async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !condition(), ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(1)) }
        precondition(condition(), "async condition did not become true")
    }
    @MainActor static func main() async throws {
        let disabledGate = PreparationGate()
        let disabled = LifeSourceReader(healthFactory: { disabledGate.prepare() })
        disabled.stopHealthObservation()
        disabled.finishHealthObservationForBackgroundLaunch()
        for _ in 0..<30 { await Task.yield() }
        precondition(disabledGate.callCount == 0 && disabledGate.store == nil,
                     "disabled source/background launch must not prepare HealthKit or wait for it")

        let backgroundGate = PreparationGate()
        let background = LifeSourceReader(healthFactory: { backgroundGate.prepare() })
        background.startHealthObservation(onChange: { $0() }, onError: { _ in preconditionFailure("background preparation failed") })
        backgroundGate.finishWhenFactoryStarts()
        background.finishHealthObservationForBackgroundLaunch()
        precondition(backgroundGate.store?.queries.count == 3 && backgroundGate.callCount == 1,
                     "background launch hook must not return before its requested observers are installed")
        background.finishHealthObservationForBackgroundLaunch()
        precondition(backgroundGate.store?.queries.count == 3 && backgroundGate.callCount == 1,
                     "repeating background launch completion must not duplicate observers or the factory")
        await until { backgroundGate.store?.deliveryChanges.count == 3 }
        background.stopHealthObservation()
        await until { backgroundGate.store?.deliveryChanges.count == 6 }

        let gate = PreparationGate()
        let reader = LifeSourceReader(healthFactory: { gate.prepare() })
        var staleErrors = 0, currentErrors = 0
        reader.startHealthObservation(onChange: { $0() }, onError: { _ in staleErrors += 1 })
        reader.stopHealthObservation()
        reader.startHealthObservation(onChange: { $0() }, onError: { _ in currentErrors += 1 })
        reader.startHealthObservation(onChange: { _ in preconditionFailure("duplicate observer installed") }, onError: { _ in })
        await until { gate.callCount == 1 }
        precondition(gate.store == nil, "normal launch must return while HealthKit is still preparing")
        gate.finish()
        await until { gate.store?.deliveryChanges.count == 3 }
        let store = gate.store!
        precondition(store.queries.count == 3 && store.queries.allSatisfy { $0 is HKObserverQuery },
                     "only the latest enabled generation may install one set of launch observers")
        precondition(store.deliveryChanges == [true, true, true] && gate.callCount == 1)
        precondition(staleErrors == 0 && currentErrors == 0)
        reader.stopHealthObservation()
        await until { store.deliveryChanges.count == 6 }
        precondition(store.stopped.count == 3 && store.deliveryChanges.suffix(3).allSatisfy { !$0 })

        store.holdNextEnable = true
        reader.startHealthObservation(onChange: { $0() }, onError: { _ in currentErrors += 1 })
        await until { store.hasDelayedEnable }
        reader.stopHealthObservation()
        reader.startHealthObservation(onChange: { $0() }, onError: { _ in currentErrors += 1 })
        precondition(store.queries.count == 9 && store.stopped.count == 6,
                     "re-enable must install current observers even while stale background enable is pending")
        store.finishEnable()
        await until { store.deliveryChanges.count == 12 }
        precondition(gate.callCount == 1 && store.queries.count == 9, "ready store reuse must not duplicate observers or initialize again")
        reader.stopHealthObservation()
        await until { store.deliveryChanges.count == 15 }

        let activeRead = Task { try await reader.read(.health, day: .now) }
        await until { store.queries.count == 10 }
        reader.stop(.health)
        activeRead.cancel()
        do { _ = try await activeRead.value; preconditionFailure("active read was not cancelled") }
        catch is CancellationError {}
        precondition(store.stopped.count == 10, "stopped query and task cancellation must settle the read once")

        // A read can be stopped while store preparation is pending, before there is an HKQuery.
        let readGate = PreparationGate()
        let reading = LifeSourceReader(healthFactory: { readGate.prepare() })
        let read = Task { try await reading.read(.health, day: .now) }
        await until { readGate.callCount == 1 }
        for _ in 0..<30 { await Task.yield() }
        reading.stop(.health)
        readGate.finish()
        do { _ = try await read.value; preconditionFailure("stopped read resumed after preparation") }
        catch is CancellationError {}
        precondition(readGate.store?.queries.isEmpty == true, "late store readiness must not query after stop")
        let unavailable = LifeSourceReader(healthFactory: { nil })
        var unavailableErrors = 0
        unavailable.startHealthObservation(onChange: { _ in preconditionFailure("unavailable HealthKit produced a change") },
                                           onError: { if ($0 as? LifeSourceReadFailure)?.status == .unavailable { unavailableErrors += 1 } })
        await until { unavailableErrors == 1 }
        do { _ = try await unavailable.read(.health, day: .now); preconditionFailure("unavailable HealthKit read succeeded") }
        catch let error as LifeSourceReadFailure { precondition(error.status == .unavailable) }
        print("Health store preparation: passed (off-main single initialization, nonblocking normal launch, background before-return observer barrier, disabled/unavailable source, pause/re-enable during preparation/delivery, duplicate start, pending/active read cancellation)")
    }
}
