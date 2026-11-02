import Combine
import Foundation

@MainActor final class OnboardingStore: ObservableObject {
    @Published var progress: OnboardingProgress {
        didSet { OnboardingPersistence.save(progress, defaults: defaults) }
    }
    private let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        progress = OnboardingPersistence.load(defaults: defaults, hasExistingData: OnboardingPersistence.existingInstallation(defaults: defaults))
    }
    var transcriptionDraft: TranscriptionConfiguration? {
        get { defaults.data(forKey: "wiselife.onboarding.asrDraft").flatMap { try? JSONDecoder().decode(TranscriptionConfiguration.self, from: $0) } }
        set { defaults.set(newValue.flatMap { try? JSONEncoder().encode($0) }, forKey: "wiselife.onboarding.asrDraft") }
    }
    var aiDraft: AIConfiguration? {
        get { defaults.data(forKey: "wiselife.onboarding.aiDraft").flatMap { try? JSONDecoder().decode(AIConfiguration.self, from: $0) } }
        set {
            var safe = newValue
            // Draft persistence must never store credentials accidentally pasted into a URL.
            if let url = safe?.baseURL, !url.isEmpty {
                if let components = URLComponents(string: url), components.user == nil,
                   components.password == nil, components.query == nil, components.fragment == nil {} else { safe?.baseURL = "" }
            }
            defaults.set(safe.flatMap { try? JSONEncoder().encode($0) }, forKey: "wiselife.onboarding.aiDraft")
        }
    }
    func finish(skipped: Bool) {
        progress.disposition = skipped ? .skipped : .completed
        if !skipped { progress.page = .review }
    }
}
