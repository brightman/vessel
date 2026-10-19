import Combine
import Foundation

enum AppLanguage: String, CaseIterable, Identifiable {
    case english = "en"
    case chinese = "zh-Hans"
    case japanese = "ja"

    var id: String { rawValue }
    var title: String {
        switch self { case .english: "English"; case .chinese: "中文"; case .japanese: "日本語" }
    }
    var locale: Locale { Locale(identifier: rawValue) }
}

@MainActor
final class AppSettings: ObservableObject {
    @Published var interfaceLanguage: AppLanguage {
        didSet { defaults.set(interfaceLanguage.rawValue, forKey: "interfaceLanguage") }
    }
    @Published var appearance: AppAppearance {
        didSet { defaults.set(appearance.rawValue, forKey: "appearance") }
    }
    @Published var localeIdentifier: String {
        didSet {
            defaults.set(localeIdentifier, forKey: "transcriptionLocale")
            if transcription.appleLocale != localeIdentifier {
                var updated = transcription
                updated.appleLocale = localeIdentifier
                try? saveTranscription(updated)
            }
        }
    }
    @Published private(set) var transcription: TranscriptionConfiguration
    @Published private(set) var ai: AIConfiguration
    private let defaults: UserDefaults
    private let secrets: any SecretStore

    init(defaults: UserDefaults = .standard, secrets: any SecretStore = KeychainSecretStore()) {
        self.defaults = defaults
        self.secrets = secrets
        interfaceLanguage = AppLanguage(rawValue: defaults.string(forKey: "interfaceLanguage") ?? "") ?? .chinese
        appearance = AppAppearance(rawValue: defaults.string(forKey: "appearance") ?? "") ?? .system
        localeIdentifier = defaults.string(forKey: "transcriptionLocale") ?? "zh-CN"
        transcription = defaults.data(forKey: "transcriptionConfiguration")
            .flatMap { try? JSONDecoder().decode(TranscriptionConfiguration.self, from: $0) }
            ?? TranscriptionConfiguration(appleLocale: defaults.string(forKey: "transcriptionLocale") ?? "zh-CN")
        ai = defaults.data(forKey: "aiConfiguration").flatMap { try? JSONDecoder().decode(AIConfiguration.self, from: $0) } ?? AIConfiguration()
        localeIdentifier = transcription.appleLocale
    }

    var transcriptionLabel: String {
        guard interfaceLanguage != .chinese else { return transcription.label }
        let locale = Locale(identifier: interfaceLanguage.rawValue)
        if transcription.engine == .apple {
            let language = locale.localizedString(forIdentifier: transcription.appleLocale) ?? transcription.appleLocale
            return interfaceLanguage == .japanese ? "iPhone内で文字起こし · \(language)" : "On-device transcription · \(language)"
        }
        let language = transcription.whisperLanguage == "auto" ? (interfaceLanguage == .japanese ? "自動検出" : "Auto detect")
            : (locale.localizedString(forLanguageCode: transcription.whisperLanguage) ?? transcription.whisperLanguage)
        return "Whisper \(transcription.whisperSize.title) · \(language)"
    }
    func saveTranscription(_ configuration: TranscriptionConfiguration) throws {
        guard configuration.validWhisperLanguage, !configuration.appleLocale.isEmpty else { throw TranscriptionResourceError.unsupported }
        let data = try JSONEncoder().encode(configuration)
        defaults.set(data, forKey: "transcriptionConfiguration")
        transcription = configuration
        if localeIdentifier != configuration.appleLocale { localeIdentifier = configuration.appleLocale }
    }
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
