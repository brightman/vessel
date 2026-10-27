import Foundation

enum AppleTranscriptionEngine: String, Codable, Sendable {
    case speechTranscriber
    case dictationTranscriber

    var displayName: String {
        switch self {
        case .speechTranscriber: "Apple SpeechTranscriber"
        case .dictationTranscriber: "Apple DictationTranscriber"
        }
    }
}

enum AppleTranscriptionEnginePolicy {
    static func preferred(speechAvailable: Bool, speechLocaleSupported: Bool,
                          dictationLocaleSupported: Bool) -> AppleTranscriptionEngine? {
        if speechAvailable && speechLocaleSupported { return .speechTranscriber }
        if dictationLocaleSupported { return .dictationTranscriber }
        return nil
    }

    static func run<Value: Sendable>(preferred: AppleTranscriptionEngine, fallback: AppleTranscriptionEngine?,
                                     shouldFallback: (Error) -> Bool,
                                     operation: (AppleTranscriptionEngine) async throws -> Value) async throws
        -> (engine: AppleTranscriptionEngine, value: Value) {
        do {
            return (preferred, try await operation(preferred))
        } catch {
            guard let fallback, !Task.isCancelled, !(error is CancellationError), shouldFallback(error) else {
                throw error
            }
            return (fallback, try await operation(fallback))
        }
    }
}

struct SpeechLanguage: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
}

struct TranscriptionConfiguration: Codable, Equatable, Sendable {
    enum Engine: String, Codable, CaseIterable { case apple, whisper }
    enum WhisperSize: String, Codable, CaseIterable {
        case tiny, base, small
        var title: String { rawValue.capitalized }
        var detail: String {
            switch self { case .tiny: "Tiny · 更轻量"; case .base: "Base · 均衡"; case .small: "Small · 更高精度" }
        }
    }
    var engine: Engine = .apple
    var appleLocale = "zh-CN"
    var whisperSize: WhisperSize = .base
    var whisperLanguage = "auto"
    var resourceID: String { engine == .apple ? "apple:\(appleLocale)" : "whisper:\(whisperSize.rawValue)" }
    var resourceName: String {
        engine == .apple ? "\(Self.appleLanguageName(appleLocale))语言包" : "Whisper \(whisperSize.title) 多语言模型"
    }
    var label: String {
        engine == .apple ? "\(AppleTranscriptionEngine.speechTranscriber.displayName) 优先 · \(AppleTranscriptionEngine.dictationTranscriber.displayName) 回退 · \(Self.appleLanguageName(appleLocale))" : "Whisper \(whisperSize.title) · \(Self.whisperLanguageName(whisperLanguage))"
    }
    static func appleLanguageName(_ code: String) -> String {
        Locale(identifier: "zh-Hans").localizedString(forIdentifier: code) ?? code
    }
    static func whisperLanguageName(_ code: String) -> String {
        code == "auto" ? "自动检测" : (Locale(identifier: "zh-Hans").localizedString(forLanguageCode: code) ?? code)
    }
    // Original Tiny / Base / Small multilingual tokenizer. The later yue token is not in these models.
    static let whisperLanguageCodes = "zh en de es ru ko fr ja pt tr pl ca nl ar sv it id hi fi vi he uk el ms cs ro da hu ta no th ur hr bg lt la mi ml cy sk te fa lv bn sr az sl kn et mk br eu is hy ne mn bs kk sq sw gl mr pa si km sn yo so af oc ka be tg sd gu am yi lo uz fo ht ps tk nn mt sa lb my bo tl mg as tt haw ln ha ba jw su".split(separator: " ").map(String.init)
    var validWhisperLanguage: Bool { whisperLanguage == "auto" || Self.whisperLanguageCodes.contains(whisperLanguage) }
}

enum WhisperTranscriptValidity {
    static func containsSpeechCharacters(_ text: String) -> Bool {
        text.unicodeScalars.contains { CharacterSet.alphanumerics.contains($0) }
    }
}

struct SpeechDownloadProgress: Equatable, Sendable {
    var fraction: Double?
    var completedBytes: Int64? = nil
    var totalBytes: Int64? = nil
}

enum SpeechResourceState: Equatable {
    case checking, missing, downloading(SpeechDownloadProgress), ready, unavailable(String), failed(String)
}

enum TranscriptionResourceError: LocalizedError {
    case missing, downloadFailed, invalidFiles, unsupported, reservationLimit, emptyTranscript
    case http(Int)
    static var appleUnavailableMessage: String {
        #if targetEnvironment(simulator)
        "当前模拟器无法使用 Apple 端上转写。请在 iPhone 真机测试，或到设置 → 语音转写模型选择 Whisper。"
        #else
        "这台设备暂不支持 Apple 端上转写，可到设置 → 语音转写模型选择 Whisper。"
        #endif
    }
    var errorDescription: String? {
        switch self {
        case .missing: "请先到设置 → 语音转文本，下载所选模型的语言资源。"
        case .downloadFailed: "下载失败，请检查网络和可用存储空间后重试。"
        case .invalidFiles: "模型文件不完整或校验失败，请重新下载。"
        case .unsupported: "此设备暂不支持所选系统转写语言，可尝试 Whisper。"
        case .reservationLimit: "系统语言资源预留已达上限，暂时无法下载此语言。请稍后重试或使用 Whisper。"
        case .emptyTranscript: "未识别到有效语音，请检查录音和转写语言。"
        case .http(let code): "模型下载服务返回 HTTP \(code)，请稍后重试。"
        }
    }
}
