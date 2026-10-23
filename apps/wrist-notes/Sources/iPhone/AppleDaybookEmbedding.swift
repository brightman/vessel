import Foundation
import NaturalLanguage

/// Local Apple embeddings only. Asset requests exist solely on the explicit settings action.
final class AppleDaybookEmbedding: DaybookEmbedding, @unchecked Sendable {
    static let languageKey = "daybook.semantic.language.v1"
    static let languages = ["zh-Hans", "en", "zh-Hant", "ja"]
    static var selectedLanguage: String { UserDefaults.standard.string(forKey: languageKey) ?? "zh-Hans" }
    let space: DaybookEmbeddingSpace
    private let sentence: NLEmbedding?
    private let contextual: NLContextualEmbedding?
    private let language: NLLanguage
    // Contextual models can have a smaller token window than our original-text chunk.
    var partialCoverage: Bool { contextual != nil }

    private init(sentence: NLEmbedding?, contextual: NLContextualEmbedding?, language: NLLanguage) {
        self.sentence = sentence; self.contextual = contextual; self.language = language
        if let sentence {
            space = DaybookEmbeddingSpace(model: "apple-sentence", revision: sentence.revision,
                dimension: sentence.dimension, language: language.rawValue, pooling: "sentence-v1")
        } else {
            let model = contextual!
            space = DaybookEmbeddingSpace(model: model.modelIdentifier, revision: model.revision,
                dimension: model.dimension, language: language.rawValue, pooling: "mean-token-l2-v1")
        }
    }
    static func make(language raw: String = selectedLanguage) -> AppleDaybookEmbedding? {
        guard languages.contains(raw) else { return nil }
        let language = NLLanguage(rawValue: raw)
        if let sentence = NLEmbedding.sentenceEmbedding(for: language) {
            return AppleDaybookEmbedding(sentence: sentence, contextual: nil, language: language)
        }
        if let model = NLContextualEmbedding(language: language), model.hasAvailableAssets {
            return AppleDaybookEmbedding(sentence: nil, contextual: model, language: language)
        }
        return nil
    }
    func vector(_ text: String) throws -> [Float]? {
        // Spaces are language-specific; an unsupported query/chunk falls back rather than promising translation.
        if let detected = NLLanguageRecognizer.dominantLanguage(for: text), detected != language {
            return nil
        }
        if let sentence { return sentence.vector(for: text)?.map(Float.init) }
        guard let contextual, contextual.hasAvailableAssets else { return nil }
        let result = try contextual.embeddingResult(for: text, language: language)
        var sum = [Double](repeating: 0, count: space.dimension)
        var count = 0
        result.enumerateTokenVectors(in: text.startIndex..<text.endIndex) { vector, _ in
            guard vector.count == sum.count else { return false }
            for index in sum.indices { sum[index] += vector[index] }
            count += 1
            return true
        }
        guard count > 0 else { return nil }
        return sum.map { Float($0 / Double(count)) }
    }
    static func resourceStatus(language raw: String) -> (message: String, canDownload: Bool) {
        let language = NLLanguage(rawValue: raw)
        if NLEmbedding.sentenceEmbedding(for: language) != nil { return ("本地句向量已就绪", false) }
        guard let model = NLContextualEmbedding(language: language) else { return ("此语言不支持本地语义检索；使用关键词", false) }
        return model.hasAvailableAssets ? ("本地上下文向量已就绪（按模型窗口覆盖部分原文）", false) : ("Apple 语言资源尚未下载；使用关键词", true)
    }
    static func download(language raw: String) async -> String {
        guard let model = NLContextualEmbedding(language: NLLanguage(rawValue: raw)) else { return "此语言没有可下载资源。" }
        return await withCheckedContinuation { continuation in
            model.requestAssets { result, error in
                if error != nil { continuation.resume(returning: "Apple 资源下载失败，请稍后重试。") }
                else {
                    switch result {
                    case .available: continuation.resume(returning: "Apple 资源已就绪。")
                    case .notAvailable: continuation.resume(returning: "Apple 目前未提供此资源；继续使用关键词。")
                    default: continuation.resume(returning: "Apple 资源尚未就绪；继续使用关键词。")
                    }
                }
            }
        }
    }
}
