import Foundation
import Translation

/// Installed Apple translation assets only. Foreground resource preparation is
/// separate so asking a question never initiates a download or a consent sheet.
@available(iOS 26.0, macOS 26.0, *)
actor AppleQueryTranslator: LocalQueryTranslating {
    enum ResourceState: Sendable {
        case installed, downloadable, unsupported, simulator
        var message: String {
            switch self {
            case .installed: "中英翻译语言包已就绪"
            case .downloadable: "中英翻译语言包尚未下载；暂用原问题检索"
            case .unsupported: "当前系统不支持此翻译方向；使用原问题检索"
            case .simulator: "模拟器无法运行 Apple 端上翻译，请在 iPhone 上准备语言包并测试"
            }
        }
    }
    static func resourceState(to target: QueryTranslationLanguage) async -> ResourceState {
        #if targetEnvironment(simulator)
        return .simulator
        #else
        switch await LanguageAvailability().status(
            from: Locale.Language(identifier: target.counterpart.rawValue),
            to: Locale.Language(identifier: target.rawValue)) {
        case .installed: return .installed
        case .supported: return .downloadable
        case .unsupported: return .unsupported
        @unknown default: return .unsupported
        }
        #endif
    }
    func translate(_ text: String, from source: QueryTranslationLanguage,
                   to target: QueryTranslationLanguage) async throws -> String {
        try Task.checkCancellation()
        guard source != target else { return text }
        #if targetEnvironment(simulator)
        throw LocalQueryTranslationFailure.runtimeUnavailable
        #else
        let from = Locale.Language(identifier: source.rawValue)
        let to = Locale.Language(identifier: target.rawValue)
        let status = await LanguageAvailability().status(from: from, to: to)
        try Task.checkCancellation()
        switch status {
        case .installed: break
        case .supported: throw LocalQueryTranslationFailure.resourcesNotInstalled
        case .unsupported: throw LocalQueryTranslationFailure.unsupported
        @unknown default: throw LocalQueryTranslationFailure.runtimeUnavailable
        }
        let session = TranslationSession(installedSource: from, target: to)
        // This initializer cannot request downloads. No network translation client
        // is used; inference is owned by the system's local Translation framework.
        let response = try await session.translate(text)
        try Task.checkCancellation()
        return response.targetText
        #endif
    }
}
