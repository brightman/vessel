import Foundation

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else { fatalError(message) }
}

private actor Inventory {
    let maximum: Int
    let storedAliases: [String: String]
    var locales: Set<String>
    var reserveCalls: [String] = []
    var released: [String] = []
    var mutations = 0
    var maximumConcurrentMutations = 0
    var readsDuringMutation = 0
    var pauseNextReservation = false
    var failAfterNextReservation = false
    var reservationPaused = false
    var continuation: CheckedContinuation<Void, Never>?

    init(maximum: Int, locales: Set<String> = [], storedAliases: [String: String] = [:]) {
        self.maximum = maximum; self.locales = locales; self.storedAliases = storedAliases
    }
    func reserved() -> [String] {
        if mutations > 0 { readsDuringMutation += 1 }
        return Array(locales)
    }
    func reserve(_ locale: String) async throws {
        mutations += 1
        maximumConcurrentMutations = max(maximumConcurrentMutations, mutations)
        defer { mutations -= 1 }
        reserveCalls.append(locale)
        if pauseNextReservation {
            pauseNextReservation = false
            reservationPaused = true
            await withCheckedContinuation { continuation = $0 }
        }
        let stored = storedAliases[locale] ?? locale
        guard locales.count < maximum || locales.contains(stored) else { throw TranscriptionResourceError.reservationLimit }
        locales.insert(stored)
        if failAfterNextReservation {
            failAfterNextReservation = false
            throw TranscriptionResourceError.downloadFailed
        }
    }
    func release(_ locale: String) -> Bool {
        mutations += 1
        maximumConcurrentMutations = max(maximumConcurrentMutations, mutations)
        defer { mutations -= 1 }
        released.append(locale)
        return locales.remove(locale) != nil
    }
    func pauseNext() { pauseNextReservation = true }
    func failNext() { failAfterNextReservation = true }
    func resumeReservation() { continuation?.resume(); continuation = nil }
    func coordinator(preferred: String? = nil, aliases: [String: String] = [:]) -> AppleSpeechReservationCoordinator {
        AppleSpeechReservationCoordinator(backend: .init(maximumReservations: maximum,
            reservedLocales: { await self.reserved() }, reserve: { try await self.reserve($0) },
            release: { await self.release($0) }, preferredLocale: { preferred }, resolveLocale: { aliases[$0] ?? $0 }))
    }
}

private actor OperationGate {
    var started = false
    var continuation: CheckedContinuation<Void, Never>?
    func wait() async {
        started = true
        await withCheckedContinuation { continuation = $0 }
    }
    func resume() { continuation?.resume(); continuation = nil }
}

@main struct AppleSpeechReservationsSmoke {
    static func main() async throws {
        // A cancelled download must not release the reservation held by a second
        // download or transcriber, even when the locale spelling differs.
        let inventory = Inventory(maximum: 1)
        let coordinator = await inventory.coordinator()
        let cancelled = try await coordinator.acquire(locale: "en_US")
        let active = try await coordinator.acquire(locale: "EN-us")
        await coordinator.finish(cancelled, succeeded: false)
        let afterCancellation = await inventory.reserved()
        expect(afterCancellation == ["en-US"], "cancelled lease released another active lease's reservation")
        do {
            _ = try await coordinator.acquire(locale: "fr-FR")
            fatalError("evicted an active language")
        } catch TranscriptionResourceError.reservationLimit {}
        await coordinator.finish(active, succeeded: true)
        let reused = try await coordinator.acquire(locale: "en-US")
        await coordinator.finish(reused, succeeded: false)
        let retained = await inventory.reserved()
        let calls = await inventory.reserveCalls
        expect(retained == ["en-US"] && calls == ["en-US"], "successful or reused reservation was lost")

        let failedInventory = Inventory(maximum: 1)
        let failedCoordinator = await failedInventory.coordinator()
        let firstFailure = try await failedCoordinator.acquire(locale: "en-US")
        let secondFailure = try await failedCoordinator.acquire(locale: "en_US")
        await failedCoordinator.finish(firstFailure, succeeded: false)
        await failedCoordinator.finish(secondFailure, succeeded: false)
        await failedCoordinator.finish(secondFailure, succeeded: false)
        let failedRemaining = await failedInventory.reserved()
        let failedReleases = await failedInventory.released
        expect(failedRemaining.isEmpty && failedReleases == ["en-US"], "last failed lease must release a newly added reservation exactly once")

        let existingInventory = Inventory(maximum: 1, locales: ["en_US"])
        let existingCoordinator = await existingInventory.coordinator()
        let existing = try await existingCoordinator.acquire(locale: "en-US")
        await existingCoordinator.finish(existing, succeeded: false)
        let existingReleases = await existingInventory.released
        let existingReserveCalls = await existingInventory.reserveCalls
        expect(existingReleases.isEmpty && existingReserveCalls.isEmpty, "failed reuse released or re-reserved a preexisting locale")

        let aliasInventory = Inventory(maximum: 1, locales: ["en"])
        let aliasCoordinator = await aliasInventory.coordinator(aliases: ["en": "en-US"])
        let alias = try await aliasCoordinator.acquire(locale: "en-US")
        await aliasCoordinator.finish(alias, succeeded: false)
        let aliasCalls = await aliasInventory.reserveCalls
        let aliasReleases = await aliasInventory.released
        expect(aliasCalls.isEmpty && aliasReleases.isEmpty, "equivalent reserved locale was not reused")
        let returnedAliasInventory = Inventory(maximum: 1, storedAliases: ["en-US": "en"])
        let returnedAlias = await returnedAliasInventory.coordinator(aliases: ["en": "en-US"])
        let aliasedAddition = try await returnedAlias.acquire(locale: "en-US")
        await returnedAlias.finish(aliasedAddition, succeeded: false)
        let rawReleases = await returnedAliasInventory.released
        expect(rawReleases == ["en"], "reservation returned under an equivalent alias must release its actual identifier")

        let throwingInventory = Inventory(maximum: 1)
        let throwing = await throwingInventory.coordinator()
        await throwingInventory.failNext()
        do { _ = try await throwing.acquire(locale: "en-US"); fatalError("ignored reserve failure") }
        catch TranscriptionResourceError.downloadFailed {}
        let afterBackendFailure = await throwingInventory.reserved()
        expect(afterBackendFailure.isEmpty, "backend error after adding a reservation leaked it")

        // Exercise the exact scoped operation API used by the live download and
        // transcriber. The cancelled body deliberately does not observe cancel.
        let operationInventory = Inventory(maximum: 1)
        let operations = await operationInventory.coordinator()
        let cancelledGate = OperationGate(), successfulGate = OperationGate()
        let cancelledOperation = Task {
            try await operations.withReservation(locale: "en_US") { await cancelledGate.wait() }
        }
        while await !cancelledGate.started { await Task.yield() }
        let successfulOperation = Task {
            try await operations.withReservation(locale: "en-US") { await successfulGate.wait() }
        }
        while await !successfulGate.started { await Task.yield() }
        cancelledOperation.cancel()
        await cancelledGate.resume()
        do { try await cancelledOperation.value; fatalError("ignored operation cancellation") } catch is CancellationError {}
        let whileOtherOperationActive = await operationInventory.reserved()
        expect(whileOtherOperationActive == ["en-US"], "cancelled operation released a concurrent transcriber's reservation")
        await successfulGate.resume()
        try await successfulOperation.value
        let afterSuccessfulOperation = await operationInventory.reserved()
        expect(afterSuccessfulOperation == ["en-US"], "successful operation did not retain its reservation")

        // Switching repeatedly must reuse finite capacity, preferring to retain
        // the saved locale while inactive alternatives exist.
        let switchingInventory = Inventory(maximum: 2)
        let switching = await switchingInventory.coordinator(preferred: "en_US")
        for locale in ["en-US", "fr-FR", "de-DE", "ja-JP", "es-ES"] {
            let lease = try await switching.acquire(locale: locale)
            await switching.finish(lease, succeeded: true)
        }
        let switched = Set(await switchingInventory.reserved())
        let evictions = await switchingInventory.released
        expect(switched == ["en-US", "es-ES"], "switching past capacity failed or evicted the preferred saved locale")
        expect(evictions == ["fr-FR", "de-DE", "ja-JP"], "inactive reservations were not evicted safely")

        // Force a backend suspension, then queue competing acquisitions. Actor
        // isolation alone is insufficient while reserve() is suspended.
        let reentrantInventory = Inventory(maximum: 1)
        let reentrant = await reentrantInventory.coordinator()
        await reentrantInventory.pauseNext()
        let pending = Task { try await reentrant.acquire(locale: "en-US") }
        while await !reentrantInventory.reservationPaused { await Task.yield() }
        let sameLocale = Task { try await reentrant.acquire(locale: "en_US") }
        let otherLocale = Task { () throws -> AppleSpeechReservationCoordinator.Lease in
            try await reentrant.acquire(locale: "fr-FR")
        }
        // Let both queued tasks reach the suspended mutation. No wall-clock
        // sleeps or device services are involved.
        for _ in 0..<100 { await Task.yield() }
        pending.cancel()
        await reentrantInventory.resumeReservation()
        do { _ = try await pending.value; fatalError("cancelled acquisition returned a lease") } catch is CancellationError {}
        // Either waiter may win after the cancelled reservation is cleaned up;
        // one can hold the only slot, the other must fail without evicting it.
        var acquired: [AppleSpeechReservationCoordinator.Lease] = []
        for task in [sameLocale, otherLocale] {
            do { acquired.append(try await task.value) }
            catch TranscriptionResourceError.reservationLimit {}
        }
        expect(acquired.count == 1, "competing languages both acquired a single active slot")
        for lease in acquired { await reentrant.finish(lease, succeeded: false) }
        let concurrentMutations = await reentrantInventory.maximumConcurrentMutations
        let concurrentReads = await reentrantInventory.readsDuringMutation
        let reentrantRemaining = await reentrantInventory.reserved()
        expect(concurrentMutations == 1 && concurrentReads == 0 && reentrantRemaining.isEmpty, "inventory mutation reentered or cancellation leaked its reservation")
        print("Apple speech reservations: cancellation, shared leases, normalization, reuse, capacity eviction and serialization passed")
    }
}
