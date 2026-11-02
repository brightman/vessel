import Foundation

enum QueryTranslationLanguage: String, Codable, Sendable {
    case chinese = "zh-Hans", english = "en"
    var counterpart: Self { self == .chinese ? .english : .chinese }
    var displayName: String { self == .chinese ? "中文" : "English" }
}
enum LocalQueryTranslationFailure: Error { case resourcesNotInstalled, unsupported, runtimeUnavailable }
protocol LocalQueryTranslating: Sendable {
    func translate(_ text: String, from: QueryTranslationLanguage, to: QueryTranslationLanguage) async throws -> String
}
struct DaybookExpandedQuery: Codable, Sendable {
    enum Status: String, Codable, Sendable {
        case translated, sameLanguage, resourcesUnavailable, unsupported, failed, invalidInput, invalidOutput, unchanged
    }
    let original: String
    let translation: String?
    let target: QueryTranslationLanguage
    let status: Status

    // The original remains authoritative for fulltext, names, dates, filters,
    // history and the answer prompt. Translated text is only a vector input.
    var semanticText: String { translation ?? original }
    var retrievalStatus: String? {
        switch status {
        case .translated: "已端上翻译检索问题（\(target.displayName)）"
        case .sameLanguage: nil
        case .resourcesUnavailable: "端上翻译资源不可用，请在设置 → AI 检索准备语言包；使用原问题检索"
        case .unsupported: "此语言暂不支持端上翻译；使用原问题检索"
        case .failed, .invalidInput, .invalidOutput, .unchanged: "端上翻译未产生可用结果；使用原问题检索"
        }
    }
}
enum DaybookQueryExpansion {
    static func expand(_ original: String, to target: QueryTranslationLanguage,
                       using translator: any LocalQueryTranslating) async throws -> DaybookExpandedQuery {
        try Task.checkCancellation()
        func result(_ status: DaybookExpandedQuery.Status, _ translation: String? = nil) -> DaybookExpandedQuery {
            .init(original: original, translation: translation, target: target, status: status)
        }
        let text = original.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.count <= 300 else { return result(.invalidInput) }
        let containsChinese = text.unicodeScalars.contains { scalar in
            (0x3400...0x4DBF).contains(scalar.value) || (0x4E00...0x9FFF).contains(scalar.value)
                || (0x20000...0x3134F).contains(scalar.value)
        }
        let containsLatin = text.unicodeScalars.contains { scalar in
            (0x41...0x5A).contains(scalar.value) || (0x61...0x7A).contains(scalar.value)
        }
        // An English-dominant mixed question can still contain Chinese that needs
        // translation to English. Do not use dominant language as a hard veto.
        let needsTranslation = target == .chinese ? containsLatin : containsChinese
        guard needsTranslation else { return result(.sameLanguage) }
        let source = target.counterpart
        do {
            let output = try await translator.translate(text, from: source, to: target)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            try Task.checkCancellation()
            guard !output.isEmpty, output.count <= 1200 else { return result(.invalidOutput) }
            guard output != text else { return result(.unchanged) }
            let hasTargetScript = output.unicodeScalars.contains { scalar in
                target == .chinese ? (0x3400...0x9FFF).contains(scalar.value)
                    : (0x41...0x5A).contains(scalar.value) || (0x61...0x7A).contains(scalar.value)
            }
            guard hasTargetScript else { return result(.invalidOutput) }
            return result(.translated, output)
        } catch is CancellationError { throw CancellationError() }
        catch {
            try Task.checkCancellation()
            switch error {
            case LocalQueryTranslationFailure.resourcesNotInstalled: return result(.resourcesUnavailable)
            case LocalQueryTranslationFailure.unsupported: return result(.unsupported)
            case LocalQueryTranslationFailure.runtimeUnavailable: return result(.resourcesUnavailable)
            default: return result(.failed)
            }
        }
    }
}
enum QueryRankFusion {
    /// Reciprocal rank fusion. Keep model similarity scores inside their own spaces.
    static func fuse(_ lists: [[String]]) -> [String] {
        var scores: [String: Double] = [:]
        for list in lists {
            var seen: Set<String> = []
            var rank = 0
            for id in list where seen.insert(id).inserted {
                rank += 1
                scores[id, default: 0] += 1.0 / (60.0 + Double(rank))
            }
        }
        return scores.keys.sorted {
            if scores[$0] != scores[$1] { return scores[$0]! > scores[$1]! }
            return $0 < $1
        }
    }
}
