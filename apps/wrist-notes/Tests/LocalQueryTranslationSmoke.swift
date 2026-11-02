import Foundation

private enum TestFailure: Error { case expected(String) }
private func check(_ condition: Bool, _ message: String) throws {
    guard condition else { throw TestFailure.expected(message) }
}

// Models missing resources, cancellation, or a returned string at the Apple API
// boundary. Assertions exercise expansion/fusion policy, not this test double.
private struct TranslationFixture: LocalQueryTranslating {
    enum Outcome: Sendable { case text(String), missing, cancelled }
    let expectedText: String
    let expectedSource: QueryTranslationLanguage
    let expectedTarget: QueryTranslationLanguage
    let outcome: Outcome
    func translate(_ text: String, from: QueryTranslationLanguage, to: QueryTranslationLanguage) async throws -> String {
        try check(text == expectedText && from == expectedSource && to == expectedTarget, "incorrect translation direction or source text")
        switch outcome {
        case let .text(value): return value
        case .missing: throw LocalQueryTranslationFailure.resourcesNotInstalled
        case .cancelled: throw CancellationError()
        }
    }
}

@main struct LocalQueryTranslationSmoke {
    static func main() async throws {
        let english = "What did Kate Bell say about the project budget?"
        let expected = "Kate Bell 对项目预算说了什么？"
        let translated = try await DaybookQueryExpansion.expand(english, to: .chinese,
            using: TranslationFixture(expectedText: english, expectedSource: .english, expectedTarget: .chinese, outcome: .text(expected)))
        try check(translated.original == english && translated.translation == expected && translated.status == .translated,
                  "translation must augment the original question")

        let mixed = "Kate Bell 今天对 project budget 有什么建议？"
        let mixedResult = try await DaybookQueryExpansion.expand(mixed, to: .english,
            using: TranslationFixture(expectedText: mixed, expectedSource: .chinese, expectedTarget: .english,
                                      outcome: .text("What does Kate Bell suggest about the project budget today?")))
        try check(mixedResult.status == .translated && mixedResult.original == mixed,
                  "mixed query must translate its Chinese content even if English is dominant")

        let unavailable = try await DaybookQueryExpansion.expand(english, to: .chinese,
            using: TranslationFixture(expectedText: english, expectedSource: .english, expectedTarget: .chinese, outcome: .missing))
        try check(unavailable.original == english && unavailable.translation == nil && unavailable.status == .resourcesUnavailable,
                  "missing resources must preserve original retrieval")
        for output in ["   ", english] {
            let result = try await DaybookQueryExpansion.expand(english, to: .chinese,
                using: TranslationFixture(expectedText: english, expectedSource: .english, expectedTarget: .chinese, outcome: .text(output)))
            try check(result.translation == nil && result.status != .translated, "empty or unchanged output is not a successful translation")
        }
        let wrongLanguage = try await DaybookQueryExpansion.expand(english, to: .chinese,
            using: TranslationFixture(expectedText: english, expectedSource: .english, expectedTarget: .chinese, outcome: .text("An unrelated English-only response")))
        try check(wrongLanguage.translation == nil && wrongLanguage.status == .invalidOutput,
                  "English-only output cannot count as a Chinese translation")

        let same = try await DaybookQueryExpansion.expand("今天的睡眠怎么样？", to: .chinese,
            using: TranslationFixture(expectedText: "must not be called", expectedSource: .english, expectedTarget: .chinese, outcome: .text("wrong")))
        try check(same.status == .sameLanguage && same.translation == nil, "same-language input must not call Translation")
        var cancelled = false
        do {
            _ = try await DaybookQueryExpansion.expand(english, to: .chinese,
                using: TranslationFixture(expectedText: english, expectedSource: .english, expectedTarget: .chinese, outcome: .cancelled))
        } catch is CancellationError { cancelled = true }
        try check(cancelled, "cancelled queries must not return a stale expansion")

        try check(QueryRankFusion.fuse([["A", "B", "C"], ["B", "D", "A"]]) == ["B", "A", "D", "C"],
                  "fusion must combine ranks without comparing raw cross-model scores")
        try check(QueryRankFusion.fuse([["A", "A", "B"], ["B", "C"]]) == ["B", "A", "C"],
                  "duplicate rows must not get extra votes")
        try check(QueryRankFusion.fuse([["A", "B"], []]) == ["A", "B"], "failed translation must preserve original ordering")
        print("Local query translation policy: passed")
    }
}
