import Foundation

@main struct OnboardingSmoke {
    @MainActor static func main() throws {
        let domain = "onboarding.test.\(UUID())"
        let defaults = UserDefaults(suiteName: domain)!
        defer { defaults.removePersistentDomain(forName: domain) }
        var state = OnboardingPersistence.load(defaults: defaults, hasExistingData: false)
        precondition(state.shouldPresent && state.page == .welcome)
        state.page = .data
        state.dataReviewed = true
        OnboardingPersistence.save(state, defaults: defaults)
        // Runtime creates databases after launch; that must not reclassify a pending install.
        let resumed = OnboardingPersistence.load(defaults: defaults, hasExistingData: true)
        precondition(resumed.shouldPresent && resumed.page == .data && resumed.dataReviewed)
        for disposition in [OnboardingProgress.Disposition.completed, .skipped] {
            state.disposition = disposition
            OnboardingPersistence.save(state, defaults: defaults)
            precondition(!OnboardingPersistence.load(defaults: defaults, hasExistingData: false).shouldPresent)
        }
        defaults.removeObject(forKey: OnboardingPersistence.key)
        let upgrade = OnboardingPersistence.load(defaults: defaults, hasExistingData: true)
        precondition(upgrade.disposition == .existingUser && !upgrade.shouldPresent)
        // Corrupt/newer state must not lock an existing user out.
        defaults.set(Data("unknown".utf8), forKey: OnboardingPersistence.key)
        precondition(!OnboardingPersistence.load(defaults: defaults, hasExistingData: false).shouldPresent)
        let json = String(data: try JSONEncoder().encode(state), encoding: .utf8)!
        precondition(!json.contains("apiKey") && !json.contains("ready"))
        precondition(!OnboardingReadiness.aiStep(understanding: true, retrieval: false))
        precondition(!OnboardingReadiness.aiStep(understanding: false, retrieval: true))
        precondition(OnboardingReadiness.aiStep(understanding: true, retrieval: true))
        let store = OnboardingStore(defaults: defaults)
        store.transcriptionDraft = TranscriptionConfiguration(engine: .whisper, whisperSize: .tiny, whisperLanguage: "ja")
        store.aiDraft = AIConfiguration(mode: .custom, model: "example-model", baseURL: "https://example.invalid/v1", apiProtocol: .anthropic)
        let reopened = OnboardingStore(defaults: defaults)
        precondition(reopened.transcriptionDraft?.whisperSize == .tiny && reopened.transcriptionDraft?.whisperLanguage == "ja")
        precondition(reopened.aiDraft?.apiProtocol == .anthropic && reopened.aiDraft?.baseURL == "https://example.invalid/v1")
        store.aiDraft = AIConfiguration(mode: .custom, baseURL: "https://user:fake-password@example.invalid/v1?key=fake")
        precondition(store.aiDraft?.baseURL == "", "a pasted credential-bearing URL cannot enter saved drafts")
        defaults.set("zh-Hans", forKey: "interfaceLanguage")
        precondition(OnboardingPersistence.existingInstallation(defaults: defaults))
        print("Onboarding persistence and readiness smoke passed")
    }
}
