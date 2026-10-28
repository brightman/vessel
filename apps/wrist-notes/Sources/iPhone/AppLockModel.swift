import Combine
import LocalAuthentication
import SwiftUI

@MainActor
final class AppLockModel: ObservableObject {
    enum Phase { case loading, onboarding, locked, unlocked, unavailable }
    @Published private(set) var phase: Phase = .loading
    @Published private(set) var isConfigured = false
    @Published private(set) var biometricEnabled = false
    @Published private(set) var biometricAvailable = false
    @Published private(set) var biometricName = "Face ID"
    @Published private(set) var isBusy = false
    @Published private(set) var retryAt: Date? { didSet { scheduleCooldownExpiry() } }
    @Published private(set) var privacyCovered = true
    @Published private(set) var lockCycle = 0
    @Published var message: String?
    @Published var feedback: String?
    private let vault: AppPasscodeVault
    private let defaults: UserDefaults
    private var context: LAContext?
    private var active = false
    private var backgrounded = false
    private var pendingUnlock: Int?
    private var attemptedAutomaticBiometry = false
    private var cooldownTimer: Timer?
    private let onboardingKey = "WiseLife.AppPasscode.onboarding.v1"
    private let expectedKey = "WiseLife.AppPasscode.configured.v1"

    init(vault: AppPasscodeVault = AppPasscodeVault(), defaults: UserDefaults = .standard) {
        self.vault = vault; self.defaults = defaults
        refreshBiometricAvailability()
    }

    func load() async {
        do {
            let value = try await vault.snapshot()
            isConfigured = value.isConfigured
            biometricEnabled = value.biometricState != nil
            retryAt = value.retryAt
            if !value.isConfigured && defaults.bool(forKey: expectedKey) {
                throw AppPasscodeError.invalidConfiguration
            }
            phase = value.isConfigured ? .locked :
                (defaults.bool(forKey: onboardingKey) ? .unlocked : .onboarding)
            message = nil
            automaticallyUnlockIfNeeded()
        } catch { phase = .unavailable; message = error.localizedDescription }
    }

    func willResignActive() { active = false; privacyCovered = true }
    func didEnterBackground() {
        backgrounded = true
        lockCycle += 1
        context?.invalidate(); context = nil
        pendingUnlock = nil; isBusy = false
        attemptedAutomaticBiometry = false
        message = nil
        if isConfigured { phase = .locked }
    }
    func didBecomeActive() {
        active = true; backgrounded = false; privacyCovered = false
        refreshBiometricAvailability()
        if let retryAt, retryAt <= .now { self.retryAt = nil }
        if pendingUnlock == lockCycle { pendingUnlock = nil; phase = .unlocked }
        if phase == .unavailable { Task { await load() } }
        else { automaticallyUnlockIfNeeded() }
    }
    func skipSetup() {
        guard phase == .onboarding, !isConfigured, !isBusy else { return }
        defaults.set(true, forKey: onboardingKey)
        phase = .unlocked
    }

    func unlock(code: String) async -> Bool {
        guard phase == .locked, !isBusy else { return false }
        isBusy = true; message = nil
        let cycle = lockCycle
        defer { if cycle == lockCycle { isBusy = false } }
        do {
            let result = try await vault.verify(code)
            guard cycle == lockCycle else { return false }
            switch result {
            case .accepted: finishUnlock(cycle: cycle); retryAt = nil; return true
            case .incorrect: message = "密码不正确，请重试。"
            case .cooldown(let until): retryAt = until; message = "尝试次数过多，请稍后重试。"
            }
        } catch { if cycle == lockCycle { message = error.localizedDescription } }
        return false
    }

    func createPasscode(_ code: String, useBiometry: Bool) async throws {
        guard !isBusy else { throw CancellationError() }
        isBusy = true
        let cycle = lockCycle
        defer { if cycle == lockCycle { isBusy = false } }
        var state: Data?
        if useBiometry {
            do { state = try await authenticateBiometry(reason: "启用 WiseLife 的快捷解锁") }
            catch {
                if cycle == lockCycle { feedback = "密码将正常启用。\(biometricName) 尚未开启，可稍后在设置中开启。" }
            }
        }
        guard cycle == lockCycle, !backgrounded else { throw CancellationError() }
        try await vault.setInitialPasscode(code, biometricState: state)
        isConfigured = true; biometricEnabled = state != nil
        defaults.set(true, forKey: onboardingKey); defaults.set(true, forKey: expectedKey)
        if cycle == lockCycle { finishUnlock(cycle: cycle) }
        else { phase = .locked }
    }

    func validateCurrent(_ code: String) async throws {
        let result = try await vault.verify(code)
        switch result {
        case .accepted: retryAt = nil
        case .incorrect: throw AppPasscodeError.incorrectCode
        case .cooldown(let date): retryAt = date; throw AppPasscodeError.cooldown(date)
        }
    }
    func changePasscode(current: String, replacement: String) async throws {
        guard phase == .unlocked else { throw CancellationError() }
        let cycle = lockCycle
        try await vault.changePasscode(current: current, replacement: replacement)
        guard cycle == lockCycle else { throw CancellationError() }
        retryAt = nil
    }
    func enableBiometry(current: String) async throws {
        try await validateCurrent(current)
        let cycle = lockCycle
        let state = try await authenticateBiometry(reason: "启用 WiseLife 的快捷解锁")
        guard cycle == lockCycle, !backgrounded else { throw CancellationError() }
        try await vault.enableBiometrics(state: state, current: current)
        biometricEnabled = true
    }
    func disableBiometry() async {
        do { try await vault.disableBiometrics(); biometricEnabled = false }
        catch { feedback = error.localizedDescription }
    }

    func unlockWithBiometry() async {
        guard phase == .locked, biometricEnabled, !isBusy else { return }
        let cycle = lockCycle
        isBusy = true; message = nil
        defer { if cycle == lockCycle { isBusy = false } }
        do {
            let before = try await vault.snapshot()
            let current = LAContext()
            var error: NSError?
            guard current.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error),
                  let enrollment = current.domainState.biometry.stateHash else {
                throw error ?? AppPasscodeError.invalidConfiguration as NSError
            }
            guard before.isConfigured, before.biometricState == enrollment else {
                try await vault.disableBiometrics()
                biometricEnabled = false
                message = "生物识别设置已变化，请输入 App 密码后重新开启。"
                return
            }
            let after = try await authenticateBiometry(reason: "解锁 WiseLife 中的个人记录", using: current)
            guard cycle == lockCycle, after == before.biometricState else { return }
            finishUnlock(cycle: cycle)
        } catch {
            if cycle == lockCycle { message = "请使用 App 密码解锁，或再次尝试 \(biometricName)。" }
        }
    }

    private func authenticateBiometry(reason: String, using supplied: LAContext? = nil) async throws -> Data {
        let value = supplied ?? LAContext()
        context = value
        defer { if context === value { context = nil } }
        value.localizedCancelTitle = "使用 App 密码"
        value.localizedFallbackTitle = ""
        let accepted = try await value.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, localizedReason: reason)
        guard accepted, let state = value.domainState.biometry.stateHash else {
            throw AppPasscodeError.invalidConfiguration
        }
        return state
    }
    private func finishUnlock(cycle: Int) {
        guard cycle == lockCycle, !backgrounded else { return }
        message = nil
        if active { phase = .unlocked }
        else { pendingUnlock = cycle }
    }
    private func refreshBiometricAvailability() {
        let value = LAContext()
        biometricAvailable = value.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
        biometricName = value.biometryType == .touchID ? "Touch ID" : "Face ID"
    }
    private func automaticallyUnlockIfNeeded() {
        guard active, phase == .locked, biometricEnabled, !attemptedAutomaticBiometry else { return }
        attemptedAutomaticBiometry = true
        Task { await unlockWithBiometry() }
    }
    private func scheduleCooldownExpiry() {
        cooldownTimer?.invalidate(); cooldownTimer = nil
        guard let retryAt else { return }
        cooldownTimer = Timer.scheduledTimer(withTimeInterval: max(0.1, retryAt.timeIntervalSinceNow), repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.retryAt = nil; self?.message = nil }
        }
    }
}
