import Combine
import Foundation

@MainActor
final class AppSettings: ObservableObject {
    @Published var speakerDiarizationEnabled: Bool {
        didSet { defaults.set(speakerDiarizationEnabled, forKey: "speakerDiarizationEnabled") }
    }
    @Published var stateOfMindEnabled: Bool {
        didSet { defaults.set(stateOfMindEnabled, forKey: "stateOfMindEnabled") }
    }
    @Published var hrvEnabled: Bool {
        didSet { defaults.set(hrvEnabled, forKey: "hrvEnabled") }
    }
    @Published var heartRateEnabled: Bool {
        didSet { defaults.set(heartRateEnabled, forKey: "heartRateEnabled") }
    }
    @Published var appearance: AppAppearance {
        didSet { defaults.set(appearance.rawValue, forKey: "appearance") }
    }
    @Published var localeIdentifier: String {
        didSet { defaults.set(localeIdentifier, forKey: "transcriptionLocale") }
    }
    @Published private(set) var ai: AIConfiguration
    private let defaults: UserDefaults
    private let secrets: any SecretStore

    init(defaults: UserDefaults = .standard, secrets: any SecretStore = KeychainSecretStore()) {
        self.defaults = defaults
        self.secrets = secrets
        speakerDiarizationEnabled = defaults.bool(forKey: "speakerDiarizationEnabled")
        stateOfMindEnabled = defaults.bool(forKey: "stateOfMindEnabled")
        hrvEnabled = defaults.bool(forKey: "hrvEnabled")
        heartRateEnabled = defaults.bool(forKey: "heartRateEnabled")
        appearance = AppAppearance(rawValue: defaults.string(forKey: "appearance") ?? "") ?? .dark
        localeIdentifier = defaults.string(forKey: "transcriptionLocale") ?? "zh-CN"
        ai = defaults.data(forKey: "aiConfiguration").flatMap { try? JSONDecoder().decode(AIConfiguration.self, from: $0) } ?? AIConfiguration()
    }

    var transcriptionLabel: String { "Apple 端上转写 · " + (localeIdentifier == "en-US" ? "English" : "普通话") }
    func apiKey() throws -> String { try secrets.read() }

    func saveAI(_ configuration: AIConfiguration, apiKey: String) throws {
        let saved: AIConfiguration
        if configuration.mode == .custom {
            saved = try configuration.validated(apiKey: apiKey)
            // Store the secret first; a Keychain failure must not enable a broken configuration.
            try secrets.write(apiKey.trimmingCharacters(in: .whitespacesAndNewlines))
        } else {
            // Returning to local mode discards unsaved edits to the remote settings.
            var local = ai
            local.mode = .local
            saved = local
        }
        let data = try JSONEncoder().encode(saved)
        defaults.set(data, forKey: "aiConfiguration")
        ai = saved
    }
}
