import Foundation

final class MemoryPasscodeStore: AppPasscodeSecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private let readGate = NSCondition()
    private var readsBlocked = false
    private var value: Data?
    var failWrites = false
    func read() throws -> Data? {
        readGate.lock()
        while readsBlocked { readGate.wait() }
        readGate.unlock()
        return lock.withLock { value }
    }
    func blockReads() { readGate.lock(); readsBlocked = true; readGate.unlock() }
    func allowReads() { readGate.lock(); readsBlocked = false; readGate.broadcast(); readGate.unlock() }
    func write(_ data: Data) throws {
        try lock.withLock {
            if failWrites { throw AppPasscodeError.storage(-1) }
            value = data
        }
    }
    func corrupt() { lock.withLock { value = Data("not a credential".utf8) } }
}
final class PasscodeTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var date = Date(timeIntervalSince1970: 1_800_000_000)
    func now() -> Date { lock.withLock { date } }
    func advance(_ interval: TimeInterval) { lock.withLock { date.addTimeInterval(interval) } }
}

@main struct AppPasscodeSmoke {
    @MainActor static func main() async throws {
        let store = MemoryPasscodeStore(), clock = PasscodeTestClock()
        let vault = AppPasscodeVault(store: store, now: { clock.now() })
        let initial = try await vault.snapshot()
        precondition(!initial.isConfigured)
        for invalid in ["12345", "1234567", "１２３４５６", "abcdef"] {
            do { try await vault.setInitialPasscode(invalid); fatalError("invalid PIN accepted") } catch {}
        }
        try await vault.setInitialPasscode("803719")
        let bytes = try store.read()!
        precondition(!String(decoding: bytes, as: UTF8.self).contains("803719"), "plaintext PIN persisted")
        let other = MemoryPasscodeStore()
        try await AppPasscodeVault(store: other).setInitialPasscode("803719")
        let otherBytes = try other.read()!
        precondition(bytes != otherBytes, "PIN derivation must use independent random salts")
        do { try await vault.setInitialPasscode("111111"); fatalError("initial setup overwrote an existing PIN") } catch {}
        for _ in 0..<4 {
            let result = try await vault.verify("000000")
            precondition(result == .incorrect)
        }
        let throttled = try await vault.verify("000000")
        guard case .cooldown(let retryAt) = throttled else { fatalError("missing rate limit") }
        precondition(retryAt == clock.now().addingTimeInterval(30))
        let restarted = AppPasscodeVault(store: store, now: { clock.now() })
        let blockedCorrect = try await restarted.verify("803719")
        precondition(blockedCorrect == .cooldown(retryAt), "restarting bypassed throttling")
        clock.advance(31)
        let accepted = try await restarted.verify("803719")
        precondition(accepted == .accepted)
        do { try await restarted.changePasscode(current: "000000", replacement: "246810"); fatalError("password changed without current PIN") } catch {}
        try await restarted.enableBiometrics(state: Data([1,2,3,4]), current: "803719")
        try await restarted.changePasscode(current: "803719", replacement: "246810")
        let oldResult = try await restarted.verify("803719")
        let newResult = try await restarted.verify("246810")
        precondition(oldResult == .incorrect && newResult == .accepted)
        let changed = try await restarted.snapshot()
        precondition(changed.biometricState == Data([1,2,3,4]))
        try await restarted.disableBiometrics()
        let disabled = try await restarted.snapshot()
        precondition(disabled.biometricState == nil)
        store.failWrites = true
        do { _ = try await restarted.verify("246810"); fatalError("storage failure allowed authentication") } catch {}
        store.failWrites = false
        store.corrupt()
        do { _ = try await restarted.snapshot(); fatalError("corrupt credential treated as an unlocked app") } catch {}

        let suite = "WiseLife.AppPasscodeSmoke." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let lifecycleStore = MemoryPasscodeStore()
        let lifecycleVault = AppPasscodeVault(store: lifecycleStore)
        let model = AppLockModel(vault: lifecycleVault, defaults: defaults)
        model.didBecomeActive(); await model.load()
        precondition(model.phase == .onboarding)
        model.skipSetup(); precondition(model.phase == .unlocked)
        try await model.createPasscode("135790", useBiometry: false)
        precondition(model.phase == .unlocked && model.isConfigured)
        model.willResignActive(); precondition(model.privacyCovered)
        model.didEnterBackground(); precondition(model.phase == .locked)
        model.didBecomeActive(); precondition(!model.privacyCovered && model.phase == .locked)
        model.skipSetup(); precondition(model.phase == .locked, "skip bypassed an existing credential")
        lifecycleStore.blockReads()
        let unlockTask = Task { await model.unlock(code: "135790") }
        while !model.isBusy { await Task.yield() }
        model.willResignActive(); model.didEnterBackground()
        lifecycleStore.allowReads()
        _ = await unlockTask.value
        model.didBecomeActive()
        precondition(model.phase == .locked, "late authentication unlocked after backgrounding")
        let validUnlock = await model.unlock(code: "135790")
        precondition(validUnlock && model.phase == .unlocked)
        let missingCredential = AppLockModel(vault: AppPasscodeVault(store: MemoryPasscodeStore()), defaults: defaults)
        missingCredential.didBecomeActive(); await missingCredential.load()
        precondition(missingCredential.phase == .unavailable, "lost keychain credential failed open")
        print("App passcode: salted derivation, persisted rate limiting, updates, storage failures and background races passed")
    }
}
