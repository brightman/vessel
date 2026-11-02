import Foundation
import CryptoKit
import Translation

private struct Fixture: Decodable {
    let id: String
    let queryZh: String, queryEn: String, queryMixed: String
}
private struct TranslationSample: Codable {
    let queryID: String
    let queryLanguage: String
    let expansion: DaybookExpandedQuery
    let seconds: Double
}
private struct TranslationReport: Codable {
    let provider: String
    let os: String
    let fixtureSHA256: String
    let startedAt: String
    let resourceStatus: [String: String]
    var records: [TranslationSample]
}

@main enum AppleQueryTranslationExperiment {
    static func main() async throws {
        guard CommandLine.arguments.count == 3 else {
            throw NSError(domain: "TranslationExperiment", code: 1, userInfo: [NSLocalizedDescriptionKey: "Expected fixture and output JSON paths"])
        }
        let input = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
        let fixtures = try JSONDecoder().decode([Fixture].self, from: input)
        let output = URL(fileURLWithPath: CommandLine.arguments[2])
        let translator = AppleQueryTranslator()
        let availability = LanguageAvailability()
        var statuses: [String: String] = [:]
        var ready = true
        for (source, target) in [("en", "zh-Hans"), ("zh-Hans", "en")] {
            let status = await availability.status(from: Locale.Language(identifier: source), to: Locale.Language(identifier: target))
            statuses["\(source)->\(target)"] = String(describing: status)
            if status != .installed { ready = false }
        }
        var report = TranslationReport(provider: "Apple Translation / installedSource / on-device",
                                       os: ProcessInfo.processInfo.operatingSystemVersionString,
                                       fixtureSHA256: SHA256.hash(data: input).map { String(format: "%02x", $0) }.joined(),
                                       startedAt: ISO8601DateFormatter().string(from: Date()),
                                       resourceStatus: statuses, records: [])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        func save() throws { try encoder.encode(report).write(to: output, options: .atomic) }
        try save()
        guard ready else {
            throw NSError(domain: "TranslationExperiment", code: 2, userInfo: [NSLocalizedDescriptionKey: "Apple translation resources are not installed. Run prepare_translation_resources.sh and confirm the system download first."])
        }
        for fixture in fixtures {
            for (language, query) in zip(["zh", "en", "mixed"], [fixture.queryZh, fixture.queryEn, fixture.queryMixed]) {
                for target in [QueryTranslationLanguage.chinese, .english] {
                    let start = Date()
                    let expansion = try await DaybookQueryExpansion.expand(query, to: target, using: translator)
                    let sample = TranslationSample(queryID: "\(fixture.id)/\(language)", queryLanguage: language,
                                                   expansion: expansion, seconds: Date().timeIntervalSince(start))
                    report.records.append(sample)
                    try save()
                    FileHandle.standardError.write(Data("\(sample.queryID) -> \(target.rawValue): \(expansion.status.rawValue) (\(String(format: "%.3f", sample.seconds)) s)\n".utf8))
                }
            }
        }
        guard report.records.contains(where: { $0.expansion.status == .translated }) else {
            throw NSError(domain: "TranslationExperiment", code: 3, userInfo: [NSLocalizedDescriptionKey: "No real translation completed; refusing to label this a translation benchmark."])
        }
    }
}
