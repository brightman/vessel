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
    @Published var requiresRemoteAIConfirmation: Bool {
        didSet { defaults.set(requiresRemoteAIConfirmation, forKey: "requiresRemoteAIConfirmation") }
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
    @Published private(set) var aiRevision = 0
    @Published private(set) var ai: AIConfiguration
    private var aiProfiles: [String: AIConfiguration] = [:]
    private let defaults: UserDefaults
    private let secrets: any SecretStore
    let chatGPT: ChatGPTAccountModel
    private var chatGPTObservation: AnyCancellable?

    init(defaults: UserDefaults = .standard, secrets: any SecretStore = KeychainSecretStore(), chatGPT: ChatGPTAccountModel? = nil) {
        self.defaults = defaults
        self.secrets = secrets
        self.chatGPT = chatGPT ?? .shared
        interfaceLanguage = AppLanguage(rawValue: defaults.string(forKey: "interfaceLanguage") ?? "") ?? .chinese
        appearance = AppAppearance(rawValue: defaults.string(forKey: "appearance") ?? "") ?? .system
        requiresRemoteAIConfirmation = defaults.object(forKey: "requiresRemoteAIConfirmation") as? Bool ?? true
        localeIdentifier = defaults.string(forKey: "transcriptionLocale") ?? "zh-CN"
        transcription = defaults.data(forKey: "transcriptionConfiguration")
            .flatMap { try? JSONDecoder().decode(TranscriptionConfiguration.self, from: $0) }
            ?? TranscriptionConfiguration(appleLocale: defaults.string(forKey: "transcriptionLocale") ?? "zh-CN")
        ai = defaults.data(forKey: "aiConfiguration").flatMap { try? JSONDecoder().decode(AIConfiguration.self, from: $0) } ?? AIConfiguration()
        aiProfiles = defaults.data(forKey: "aiProviderConfigurations")
            .flatMap { try? JSONDecoder().decode([String: AIConfiguration].self, from: $0) } ?? [:]
        // Older versions kept all providers in one record. Preserve every recoverable field.
        if aiProfiles.isEmpty {
            for mode in [AIConfiguration.Mode.local, .chatgpt, .nearbyMac] {
                var profile = ai; profile.mode = mode
                aiProfiles[mode.rawValue] = profile
            }
            if ai.mode != .nearbyMac {
                var custom = ai; custom.mode = .custom
                aiProfiles[AIConfiguration.Mode.custom.rawValue] = custom
            }
        }
        aiProfiles[ai.mode.rawValue] = ai
        localeIdentifier = transcription.appleLocale
        chatGPTObservation = self.chatGPT.$revision.dropFirst().sink { [weak self] _ in
            if self?.ai.mode == .chatgpt { self?.aiRevision += 1 }
        }
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

    /// nil means no confirmation was presented; false means a displayed request became stale.
    /// A stale request never inherits the saved opt-out, and only a valid confirmation saves it.
    func authorizeRemoteAISend(confirmationIsCurrent: Bool?, rememberChoice: Bool = false) -> Bool {
        if let confirmationIsCurrent {
            guard confirmationIsCurrent else { return false }
            if rememberChoice { requiresRemoteAIConfirmation = false }
            return true
        }
        return !requiresRemoteAIConfirmation
    }

    func configuration(for mode: AIConfiguration.Mode) -> AIConfiguration {
        var profile = aiProfiles[mode.rawValue] ?? AIConfiguration()
        profile.mode = mode
        return profile
    }

    func saveAI(_ configuration: AIConfiguration, apiKey: String) throws {
        let saved: AIConfiguration
        if configuration.mode == .custom {
            saved = try configuration.validated(apiKey: apiKey)
            // Store the secret first; a Keychain failure must not enable a broken configuration.
            try secrets.write(apiKey.trimmingCharacters(in: .whitespacesAndNewlines))
        } else if configuration.mode == .nearbyMac {
            saved = try configuration.validated(apiKey: "")
        } else if configuration.mode == .chatgpt {
            guard chatGPT.canSave(modelID: configuration.chatGPTModel, accountID: configuration.chatGPTAccountID) else {
                throw AIServiceError.invalidConfiguration("请先连接 ChatGPT、确认套餐提示并选择可用模型。")
            }
            var connected = configuration
            connected.mode = .chatgpt
            connected.chatGPTModel = configuration.chatGPTModel
            connected.chatGPTAccountID = configuration.chatGPTAccountID
            saved = connected
        } else {
            // Returning to local mode discards unsaved edits to the remote settings.
            var local = ai
            local.mode = .local
            saved = local
        }
        var profiles = aiProfiles
        profiles[saved.mode.rawValue] = saved
        let profileData = try JSONEncoder().encode(profiles)
        let data = try JSONEncoder().encode(saved)
        defaults.set(profileData, forKey: "aiProviderConfigurations")
        defaults.set(data, forKey: "aiConfiguration")
        aiProfiles = profiles
        ai = saved
        aiRevision += 1
    }
}
