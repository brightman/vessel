import Foundation

/// Leases protect an app-wide AssetInventory reservation while downloads and
/// transcribers use it. Inventory mutation must also be serialized across awaits.
actor AppleSpeechReservationCoordinator {
    struct Backend: Sendable {
        let maximumReservations: Int
        var reservedLocales: @Sendable () async -> [String]
        var reserve: @Sendable (String) async throws -> Void
        var release: @Sendable (String) async -> Bool
        var preferredLocale: @Sendable () async -> String?
        var resolveLocale: @Sendable (String) async -> String = { $0 }
    }
    struct Lease: Sendable {
        fileprivate let id: UUID
        fileprivate let locale: String
    }
    private struct Entry {
        var leases: Set<UUID> = []
        var retained: Bool
        var lastUsed: UInt64 = 0
    }
    private let backend: Backend
    private var entries: [String: Entry] = [:]
    private var clock: UInt64 = 0
    private var mutationLocked = false
    private var mutationWaiters: [CheckedContinuation<Void, Never>] = []

    init(backend: Backend) { self.backend = backend }

    func acquire(locale: String) async throws -> Lease {
        await lockMutations()
        defer { unlockMutations() }
        try Task.checkCancellation()
        guard !locale.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw TranscriptionResourceError.unsupported
        }
        let key = Self.normalized(await backend.resolveLocale(locale))
        var reserved = await inventory()
        var entry = entries[key] ?? Entry(retained: reserved[key] != nil)
        if reserved[key] == nil {
            entry.retained = false
            reserved = try await makeRoom(reserved)
            try Task.checkCancellation()
            do {
                try await backend.reserve(key)
                guard await inventory()[key] != nil else { throw TranscriptionResourceError.reservationLimit }
            } catch {
                // A backend can throw after adding a reservation. Clean up only
                // our unsuccessful addition, never a locale with another lease.
                if entry.leases.isEmpty && !entry.retained, let actual = await inventory()[key] {
                    _ = await backend.release(actual)
                }
                throw error
            }
        }
        clock &+= 1
        entry.lastUsed = clock
        let lease = Lease(id: UUID(), locale: key)
        entry.leases.insert(lease.id)
        entries[key] = entry
        if Task.isCancelled {
            await finishLocked(lease, succeeded: false)
            throw CancellationError()
        }
        return lease
    }

    func withReservation<Value: Sendable>(locale: String, operation: @Sendable () async throws -> Value) async throws -> Value {
        let lease = try await acquire(locale: locale)
        do {
            let value = try await operation()
            try Task.checkCancellation()
            await finish(lease, succeeded: true)
            return value
        } catch {
            await finish(lease, succeeded: false)
            throw error
        }
    }

    func finish(_ lease: Lease, succeeded: Bool) async {
        await lockMutations()
        defer { unlockMutations() }
        await finishLocked(lease, succeeded: succeeded)
    }

    private func finishLocked(_ lease: Lease, succeeded: Bool) async {
        guard var entry = entries[lease.locale], entry.leases.remove(lease.id) != nil else { return }
        entry.retained = entry.retained || succeeded
        entries[lease.locale] = entry
        guard entry.leases.isEmpty && !entry.retained else { return }
        if let actual = await inventory()[lease.locale] {
            _ = await backend.release(actual)
            guard await inventory()[lease.locale] == nil else { return }
        }
        entries.removeValue(forKey: lease.locale)
    }

    private func makeRoom(_ initial: [String: String]) async throws -> [String: String] {
        guard backend.maximumReservations > 0 else { throw TranscriptionResourceError.reservationLimit }
        var reserved = initial
        let preferred: String?
        if let locale = await backend.preferredLocale() { preferred = Self.normalized(await backend.resolveLocale(locale)) }
        else { preferred = nil }
        while reserved.count >= backend.maximumReservations {
            let candidates = reserved.keys.filter { entries[$0]?.leases.isEmpty ?? true }.sorted {
                if ($0 == preferred) != ($1 == preferred) { return $1 == preferred }
                let lhs = entries[$0]?.lastUsed ?? 0, rhs = entries[$1]?.lastUsed ?? 0
                return lhs == rhs ? $0 < $1 : lhs < rhs
            }
            guard let candidate = candidates.first, let actual = reserved[candidate] else {
                throw TranscriptionResourceError.reservationLimit
            }
            _ = await backend.release(actual)
            reserved = await inventory()
            guard reserved[candidate] == nil else { throw TranscriptionResourceError.reservationLimit }
            entries.removeValue(forKey: candidate)
        }
        return reserved
    }

    private func inventory() async -> [String: String] {
        var result: [String: String] = [:]
        for locale in await backend.reservedLocales() {
            let key = Self.normalized(await backend.resolveLocale(locale))
            result[key] = locale
        }
        return result
    }

    private static func normalized(_ locale: String) -> String {
        Locale.canonicalLanguageIdentifier(from: locale.replacingOccurrences(of: "_", with: "-"))
    }

    // An actor may reenter during every backend await. Keep this gate held for
    // the complete read/evict/reserve/lease update (and finish/release) sequence.
    private func lockMutations() async {
        if !mutationLocked { mutationLocked = true; return }
        await withCheckedContinuation { mutationWaiters.append($0) }
    }
    private func unlockMutations() {
        if mutationWaiters.isEmpty { mutationLocked = false }
        else { mutationWaiters.removeFirst().resume() }
    }
}
