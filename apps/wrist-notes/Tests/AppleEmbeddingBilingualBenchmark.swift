import Foundation
import NaturalLanguage
import SQLite3
import WristNotesVector
import CryptoKit

// This is a standalone diagnostic, never an application entry point. It uses synthetic
// text, an in-memory database, the shipped SQLite Vector sources, and the real wrapper.
// The runner extracts only the wrapper's protocol/type declarations from the index.
private struct Fixture: Decodable {
    let id: String
    let docZh: String, docEn: String, docMixed: String
    let queryZh: String, queryEn: String, queryMixed: String
    var documents: [Sample] {
        zip(["zh", "en", "mixed"], [docZh, docEn, docMixed]).map {
            Sample(id: "\(id)/\($0.0)", topic: id, language: $0.0, text: $0.1)
        }
    }
    var queries: [Sample] {
        zip(["zh", "en", "mixed"], [queryZh, queryEn, queryMixed]).map {
            Sample(id: "\(id)/\($0.0)", topic: id, language: $0.0, text: $0.1)
        }
    }
}

private struct Sample: Encodable {
    let id: String, topic: String, language: String, text: String
    var detected: String { NLLanguageRecognizer.dominantLanguage(for: text)?.rawValue ?? "unknown" }
}

private struct Engine {
    let id: String
    let dimension: Int
    let metadata: [String: String]
    let vector: (String) throws -> [Float]?
}

private enum BenchmarkError: Error { case invalidArguments, invalidVector, database(String), mismatch(String) }

private final class VectorDatabase {
    private var handle: OpaquePointer?
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    init(dimension: Int) throws {
        guard sqlite3_open(":memory:", &handle) == SQLITE_OK, let handle else {
            throw BenchmarkError.database("Cannot open isolated in-memory SQLite")
        }
        var error: UnsafeMutablePointer<CChar>?
        let status = wristnotes_vector_init(handle, &error)
        let detail = error.map { String(cString: $0) }
        sqlite3_free(error)
        guard status == SQLITE_OK else { throw BenchmarkError.database(detail ?? "extension init") }
        try sql("CREATE TABLE candidates(id INTEGER PRIMARY KEY, sample_id TEXT NOT NULL, topic TEXT NOT NULL, language TEXT NOT NULL, original TEXT NOT NULL, embedding BLOB NOT NULL)")
        try sql("SELECT vector_init('candidates','embedding','dimension=\(dimension),type=FLOAT32,distance=COSINE,normalized=1')")
    }
    deinit { sqlite3_close(handle) }
    private func sql(_ sql: String) throws {
        guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else { throw error() }
    }
    private func error() -> BenchmarkError {
        .database(handle.map { String(cString: sqlite3_errmsg($0)) } ?? "closed")
    }
    private func prepare(_ sql: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw error() }
        return statement
    }
    func insert(_ sample: Sample, vector: [Float]) throws {
        let statement = try prepare("INSERT INTO candidates(sample_id,topic,language,original,embedding) VALUES(?,?,?,?,?)")
        defer { sqlite3_finalize(statement) }
        for (index, value) in [sample.id, sample.topic, sample.language, sample.text].enumerated() {
            guard sqlite3_bind_text(statement, Int32(index + 1), value, -1, transient) == SQLITE_OK else { throw error() }
        }
        let status = vector.withUnsafeBytes { sqlite3_bind_blob(statement, 5, $0.baseAddress, Int32($0.count), transient) }
        guard status == SQLITE_OK, sqlite3_step(statement) == SQLITE_DONE else { throw error() }
    }
    func rank(_ query: [Float]) throws -> [Hit] {
        let statement = try prepare("SELECT c.sample_id,c.topic,c.language,v.distance FROM vector_full_scan('candidates','embedding',?) v JOIN candidates c ON c.id=v.rowid ORDER BY v.distance,c.sample_id")
        defer { sqlite3_finalize(statement) }
        let status = query.withUnsafeBytes { sqlite3_bind_blob(statement, 1, $0.baseAddress, Int32($0.count), transient) }
        guard status == SQLITE_OK else { throw error() }
        var hits: [Hit] = []
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { return hits }
            guard step == SQLITE_ROW else { throw error() }
            func string(_ column: Int32) -> String { String(cString: sqlite3_column_text(statement, column)) }
            hits.append(Hit(id: string(0), topic: string(1), language: string(2), distance: sqlite3_column_double(statement, 3)))
        }
    }
    func verifyTextRoundTrip(_ samples: [Sample]) throws -> Int {
        let statement = try prepare("SELECT sample_id,original FROM candidates")
        defer { sqlite3_finalize(statement) }
        let expected = Dictionary(uniqueKeysWithValues: samples.map { ($0.id, $0.text) })
        var count = 0
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { return count }
            guard step == SQLITE_ROW else { throw error() }
            let id = String(cString: sqlite3_column_text(statement, 0))
            let actual = String(cString: sqlite3_column_text(statement, 1))
            guard expected[id] == actual else { throw BenchmarkError.mismatch("Unicode round trip: \(id)") }
            count += 1
        }
    }
    func verifyMixedFullText() throws -> [String: String] {
        do { try sql("CREATE VIRTUAL TABLE bilingual_fts_probe USING fts5(original,tokenize='trigram')") }
        catch { return ["available": "false", "detail": String(describing: error)] }
        try sql("INSERT INTO bilingual_fts_probe VALUES('Kate Bell 建议削减项目预算，停止 paid advertising。')")
        try sql("INSERT INTO bilingual_fts_probe VALUES('Kate Bell 建议早点休息，避免晚上喝 coffee。')")
        var output = ["available": "true"]
        for term in ["\"项目预算\"", "\"paid advertising\"", "\"Kate Bell\" AND \"项目预算\""] {
            let statement = try prepare("SELECT rowid FROM bilingual_fts_probe WHERE bilingual_fts_probe MATCH ? ORDER BY rowid")
            defer { sqlite3_finalize(statement) }
            guard sqlite3_bind_text(statement, 1, term, -1, transient) == SQLITE_OK,
                  sqlite3_step(statement) == SQLITE_ROW, sqlite3_column_int64(statement, 0) == 1,
                  sqlite3_step(statement) == SQLITE_DONE else {
                throw BenchmarkError.mismatch("Mixed-language full text: \(term)")
            }
            output[term] = "correct unique row"
        }
        return output
    }
}

private struct Hit: Codable {
    let id: String, topic: String, language: String
    let distance: Double
}

private struct CaseResult: Encodable {
    let queryID: String, query: String, detected: String, queryLanguage: String, corpusLanguage: String
    let queryAvailable: Bool
    let goldAvailable: Bool
    let candidateCount: Int
    let rank: Int?
    let top: [Hit]
}

private struct Metrics: Encodable {
    let scenario: String
    let queries: Int, queryVectors: Int, goldAvailable: Int, top1: Int, top3: Int
    let mrr: Double
}

private struct TranslationInput: Decodable {
    struct Record: Decodable {
        let queryID: String
        let queryLanguage: String
        let expansion: DaybookExpandedQuery
        let seconds: Double
    }
    let provider: String
    let os: String
    let fixtureSHA256: String
    let resourceStatus: [String: String]
    let records: [Record]
}
private struct ExpansionCase: Encodable {
    let queryID: String, queryLanguage: String, corpusLanguage: String, method: String
    let original: String, translation: String?, translationStatus: String
    let translationSeconds: Double
    let translationVectorAvailable: Bool
    let candidateCount: Int
    let rank: Int?
    let topIDs: [String]
}
private struct ExpansionMetric: Encodable {
    let scenario: String, method: String
    let queries: Int, translations: Int, translationVectors: Int, top1: Int, top3: Int
    let mrr: Double
}

private struct IdentityResult: Encodable {
    let id: String
    let rank: Int
    let closestID: String
    let ownDistance: Double
    let closestDistance: Double
    let recomputedDistance: Double
}

private struct EngineResult: Encodable {
    let id: String
    let dimension: Int
    let metadata: [String: String]
    let vectorCount: Int
    let rejectedDocuments: [Sample]
    let errors: [String]
    let documentIndexSeconds: Double
    let queryAndSearchSeconds: Double
    let unicodeRoundTrips: Int
    let mixedFullText: [String: String]
    let identitySelfHits: Int
    let identityQueries: Int
    let identityNearestIncludingTies: Int
    let identityCollisions: [IdentityResult]
    let cosineDistanceChecks: Int
    let maxCosineDistanceError: Double
    let metrics: [Metrics]
    let cases: [CaseResult]
    let alignedTranslationMetrics: [Metrics]
    let alignedTranslationCases: [CaseResult]
    let queryExpansionMetrics: [ExpansionMetric]?
    let queryExpansionCases: [ExpansionCase]?
}

private struct Report: Encodable {
    let startedAt: String
    let os: String
    let platform: String
    let sqlite: String
    let topics: Int
    let documents: [Sample]
    let queries: [Sample]
    let resources: [[String: String]]
    let results: [EngineResult]
    let queryTranslationProvider: String?
    let queryTranslationOS: String?
}

private func normalized(_ raw: [Float]?, dimension: Int) throws -> [Float]? {
    guard let raw else { return nil }
    guard raw.count == dimension, raw.allSatisfy(\.isFinite) else { throw BenchmarkError.invalidVector }
    let norm = sqrt(raw.reduce(0.0) { $0 + Double($1) * Double($1) })
    guard norm.isFinite, norm > 0 else { throw BenchmarkError.invalidVector }
    return raw.map { Float(Double($0) / norm) }
}

private func cosineDistance(_ a: [Float], _ b: [Float]) -> Double {
    let dot = zip(a, b).reduce(0.0) { $0 + Double($1.0) * Double($1.1) }
    let aa = a.reduce(0.0) { $0 + Double($1) * Double($1) }
    let bb = b.reduce(0.0) { $0 + Double($1) * Double($1) }
    return 1 - max(-1, min(1, dot / sqrt(aa * bb)))
}

private func progress(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
}

private func engines() -> ([Engine], [[String: String]]) {
    var output: [Engine] = []
    var resources: [[String: String]] = []
    for language in [NLLanguage.simplifiedChinese, .english] {
        let key = language.rawValue
        if let model = NLEmbedding.sentenceEmbedding(for: language) {
            let metadata = ["api": "NLEmbedding.sentenceEmbedding", "language": key,
                            "revision": String(model.revision), "dimension": String(model.dimension), "available": "true"]
            resources.append(metadata)
            output.append(Engine(id: "sentence-raw-\(key)", dimension: model.dimension, metadata: metadata) {
                model.vector(for: $0)?.map(Float.init)
            })
        } else { resources.append(["api": "NLEmbedding.sentenceEmbedding", "language": key, "available": "false"]) }
        if let wrapper = AppleDaybookEmbedding.make(language: key) {
            output.append(Engine(id: "app-current-\(key)", dimension: wrapper.space.dimension,
                                 metadata: ["api": "AppleDaybookEmbedding", "spaceKey": wrapper.space.key,
                                            "languageGate": "unchanged production implementation"], vector: wrapper.vector))
        }
        if let model = NLContextualEmbedding(language: language) {
            let metadata = ["api": "NLContextualEmbedding", "language": key, "identifier": model.modelIdentifier,
                            "revision": String(model.revision), "dimension": String(model.dimension),
                            "languages": model.languages.map(\.rawValue).joined(separator: ","),
                            "available": String(model.hasAvailableAssets), "pooling": "mean-token-l2-v1"]
            resources.append(metadata)
            if model.hasAvailableAssets {
                output.append(Engine(id: "contextual-mean-\(key)", dimension: model.dimension, metadata: metadata) { text in
                    // Same mean pooling as the current app fallback. Query and corpus always
                    // use this one model; Chinese and English model vectors are never mixed.
                    let result = try model.embeddingResult(for: text, language: language)
                    var sum = [Double](repeating: 0, count: model.dimension)
                    var count = 0
                    result.enumerateTokenVectors(in: text.startIndex..<text.endIndex) { vector, _ in
                        guard vector.count == sum.count else { return false }
                        for index in sum.indices { sum[index] += vector[index] }
                        count += 1
                        return true
                    }
                    return count == 0 ? nil : sum.map { Float($0 / Double(count)) }
                })
            }
        }
    }
    return (output, resources)
}

private func run(_ engine: Engine, documents: [Sample], queries: [Sample], translations: TranslationInput?) throws -> EngineResult {
    let database = try VectorDatabase(dimension: engine.dimension)
    var vectors: [String: [Float]] = [:]
    var errors: [String] = []
    let start = Date()
    for document in documents {
        do {
            if let vector = try normalized(engine.vector(document.text), dimension: engine.dimension) {
                vectors[document.id] = vector
                try database.insert(document, vector: vector)
            }
        } catch let error as BenchmarkError { throw error }
        catch { errors.append("document \(document.id): \(error.localizedDescription)") }
    }
    let indexSeconds = Date().timeIntervalSince(start)
    let roundTrips = try database.verifyTextRoundTrip(documents)
    let mixedFullText = try database.verifyMixedFullText()
    var cases: [CaseResult] = []
    var expansionCases: [ExpansionCase] = []
    var maxError = 0.0
    var checks = 0
    let queryStart = Date()
    for query in queries {
        var queryVector: [Float]?
        do { queryVector = try normalized(engine.vector(query.text), dimension: engine.dimension) }
        catch let error as BenchmarkError { throw error }
        catch { errors.append("query \(query.id): \(error.localizedDescription)") }
        let hits = try queryVector.map { try database.rank($0) } ?? []
        let target: QueryTranslationLanguage = engine.id.hasSuffix("zh-Hans") ? .chinese : .english
        let expansion = translations?.records.first { $0.queryID == query.id && $0.expansion.target == target }
        var translatedVector: [Float]?
        var translatedHits: [Hit] = []
        if let translation = expansion?.expansion.translation {
            translatedVector = try normalized(engine.vector(translation), dimension: engine.dimension)
            translatedHits = try translatedVector.map { try database.rank($0) } ?? []
            for hit in translatedHits {
                guard let translatedVector, let candidate = vectors[hit.id] else { throw BenchmarkError.mismatch("Missing translated-query vector") }
                maxError = max(maxError, abs(hit.distance - cosineDistance(translatedVector, candidate)))
                checks += 1
            }
        }
        for hit in hits {
            guard let queryVector, let candidate = vectors[hit.id] else { throw BenchmarkError.mismatch("Missing vector") }
            maxError = max(maxError, abs(hit.distance - cosineDistance(queryVector, candidate)))
            checks += 1
        }
        for language in ["zh", "en", "mixed", "all"] {
            let filtered = hits.filter { language == "all" || $0.language == language }
            let eligible = documents.filter { language == "all" || $0.language == language }
            cases.append(CaseResult(queryID: query.id, query: query.text, detected: query.detected,
                                    queryLanguage: query.language, corpusLanguage: language,
                                    queryAvailable: queryVector != nil,
                                    goldAvailable: eligible.contains { $0.topic == query.topic && vectors[$0.id] != nil },
                                    candidateCount: eligible.filter { vectors[$0.id] != nil }.count,
                                    rank: filtered.firstIndex { $0.topic == query.topic }.map { $0 + 1 },
                                    top: Array(filtered.prefix(5))))
            if let expansion {
                let translated = translatedHits.filter { language == "all" || $0.language == language }
                let originalIDs = filtered.map(\.id)
                // Missing/same-language translations retain original retrieval. A real
                // translated vector rejected by a model remains visible as a failure.
                let translatedIDs = expansion.expansion.translation == nil ? originalIDs : translated.map(\.id)
                let fusionLists = expansion.expansion.translation == nil ? [originalIDs] : [originalIDs, translatedIDs]
                let methods = [("direct", originalIDs), ("translated", translatedIDs), ("fused-rrf60", QueryRankFusion.fuse(fusionLists))]
                let goldIDs = Set(eligible.filter { $0.topic == query.topic }.map(\.id))
                for (method, ids) in methods {
                    expansionCases.append(ExpansionCase(queryID: query.id, queryLanguage: query.language,
                        corpusLanguage: language, method: method, original: query.text,
                        translation: expansion.expansion.translation, translationStatus: expansion.expansion.status.rawValue,
                        translationSeconds: expansion.seconds, translationVectorAvailable: translatedVector != nil,
                        candidateCount: eligible.filter { vectors[$0.id] != nil }.count,
                        rank: ids.firstIndex { goldIDs.contains($0) }.map { $0 + 1 }, topIDs: Array(ids.prefix(5))))
                }
            }
        }
    }
    guard maxError < 0.0001 else { throw BenchmarkError.mismatch("SQLite cosine differs from independent calculation: \(maxError)") }
    func metrics(_ cases: [CaseResult]) -> [Metrics] {
        let groups = Dictionary(grouping: cases) { "\($0.queryLanguage)->\($0.corpusLanguage)" }
        return groups.keys.sorted().map { key -> Metrics in
            let group = groups[key]!
            return Metrics(scenario: key, queries: group.count, queryVectors: group.filter(\.queryAvailable).count,
                           goldAvailable: group.filter(\.goldAvailable).count,
                           top1: group.filter { $0.rank == 1 }.count,
                           top3: group.filter { ($0.rank ?? Int.max) <= 3 }.count,
                           mrr: group.reduce(0.0) { $0 + ($1.rank.map { 1.0 / Double($0) } ?? 0) } / Double(group.count))
        }
    }
    var identityHits = 0, identityQueries = 0, identityNearest = 0
    var identityCollisions: [IdentityResult] = []
    var alignedCases: [CaseResult] = []
    for document in documents {
        // Recompute the embedding for the exact original, catching input corruption,
        // unstable vectors, row-ID mixups, or a reversed ranking direction.
        var queryVector: [Float]?
        do { queryVector = try normalized(engine.vector(document.text), dimension: engine.dimension) }
        catch let error as BenchmarkError { throw error }
        catch { errors.append("identity \(document.id): \(error.localizedDescription)") }
        let hits = try queryVector.map { try database.rank($0) } ?? []
        if let queryVector, let original = vectors[document.id] {
            identityQueries += 1
            if hits.first?.id == document.id { identityHits += 1 }
            guard let ownIndex = hits.firstIndex(where: { $0.id == document.id }), let closest = hits.first else {
                throw BenchmarkError.mismatch("Original-text row disappeared")
            }
            let own = hits[ownIndex]
            let repeatedDistance = cosineDistance(queryVector, original)
            // Unsupported inputs may collapse to the same vector. Count and report ties
            // rather than treating the arbitrary row-ID tie-break as a harness failure.
            if abs(own.distance - closest.distance) < 0.00001, abs(repeatedDistance) < 0.00001 { identityNearest += 1 }
            if ownIndex != 0 {
                identityCollisions.append(IdentityResult(id: document.id, rank: ownIndex + 1,
                                                         closestID: closest.id, ownDistance: own.distance,
                                                         closestDistance: closest.distance,
                                                         recomputedDistance: repeatedDistance))
            }
        }
        if document.language == "mixed" { continue }
        let language = document.language == "zh" ? "en" : "zh"
        let filtered = hits.filter { $0.language == language }
        let eligible = documents.filter { $0.language == language }
        alignedCases.append(CaseResult(queryID: document.id, query: document.text, detected: document.detected,
                                       queryLanguage: document.language, corpusLanguage: language,
                                       queryAvailable: queryVector != nil,
                                       goldAvailable: eligible.contains { $0.topic == document.topic && vectors[$0.id] != nil },
                                       candidateCount: eligible.filter { vectors[$0.id] != nil }.count,
                                       rank: filtered.firstIndex { $0.topic == document.topic }.map { $0 + 1 },
                                       top: Array(filtered.prefix(5))))
    }
    guard identityNearest == identityQueries else { throw BenchmarkError.mismatch("Original-text cosine validation: \(identityNearest)/\(identityQueries)") }
    let expansionGroups = Dictionary(grouping: expansionCases) { "\($0.queryLanguage)->\($0.corpusLanguage)|\($0.method)" }
    let expansionMetrics = expansionGroups.keys.sorted().map { key -> ExpansionMetric in
        let group = expansionGroups[key]!, first = expansionGroups[key]![0]
        return ExpansionMetric(scenario: "\(first.queryLanguage)->\(first.corpusLanguage)", method: first.method,
            queries: group.count, translations: group.filter { $0.translation != nil }.count,
            translationVectors: group.filter(\.translationVectorAvailable).count,
            top1: group.filter { $0.rank == 1 }.count, top3: group.filter { ($0.rank ?? Int.max) <= 3 }.count,
            mrr: group.reduce(0.0) { $0 + ($1.rank.map { 1.0 / Double($0) } ?? 0) } / Double(group.count))
    }
    return EngineResult(id: engine.id, dimension: engine.dimension, metadata: engine.metadata, vectorCount: vectors.count,
                        rejectedDocuments: documents.filter { vectors[$0.id] == nil }, errors: errors,
                        documentIndexSeconds: indexSeconds, queryAndSearchSeconds: Date().timeIntervalSince(queryStart),
                        unicodeRoundTrips: roundTrips, mixedFullText: mixedFullText,
                        identitySelfHits: identityHits, identityQueries: identityQueries,
                        identityNearestIncludingTies: identityNearest, identityCollisions: identityCollisions,
                        cosineDistanceChecks: checks, maxCosineDistanceError: maxError,
                        metrics: metrics(cases), cases: cases,
                        alignedTranslationMetrics: metrics(alignedCases), alignedTranslationCases: alignedCases,
                        queryExpansionMetrics: translations == nil ? nil : expansionMetrics,
                        queryExpansionCases: translations == nil ? nil : expansionCases)
}

@main
enum AppleEmbeddingBilingualBenchmark {
    static func main() throws {
        guard (3...4).contains(CommandLine.arguments.count) else { throw BenchmarkError.invalidArguments }
        let fixtureData = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
        let fixtures = try JSONDecoder().decode([Fixture].self, from: fixtureData)
        guard fixtures.count >= 20, Set(fixtures.map(\.id)).count == fixtures.count else {
            throw BenchmarkError.mismatch("Fixture needs unique topics and enough distractors")
        }
        let documents = fixtures.flatMap(\.documents), queries = fixtures.flatMap(\.queries)
        let translations = try CommandLine.arguments.count == 4
            ? JSONDecoder().decode(TranslationInput.self, from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[3]))) : nil
        if let translations {
            let hash = SHA256.hash(data: fixtureData).map { String(format: "%02x", $0) }.joined()
            guard hash == translations.fixtureSHA256, translations.records.count == queries.count * 2 else {
                throw BenchmarkError.mismatch("Translation results must cover this exact fixed fixture")
            }
            for query in queries {
                for target in [QueryTranslationLanguage.chinese, .english] {
                    let matching = translations.records.filter { $0.queryID == query.id && $0.expansion.target == target }
                    guard matching.count == 1, matching[0].expansion.original == query.text else {
                        throw BenchmarkError.mismatch("Missing, duplicated or changed translation input")
                    }
                }
            }
        }
        let (models, resources) = engines()
        let started = ISO8601DateFormatter().string(from: Date())
        var results: [EngineResult] = []
        for model in models {
            progress("Running \(model.id), dimension \(model.dimension)")
            let result = try run(model, documents: documents, queries: queries, translations: translations)
            results.append(result)
            for metric in result.metrics {
                progress("  \(metric.scenario): top1 \(metric.top1)/\(metric.queries), top3 \(metric.top3)/\(metric.queries), query vectors \(metric.queryVectors)")
            }
            if let expansion = result.queryExpansionMetrics {
                let corpus = model.id.hasSuffix("zh-Hans") ? "zh" : "en"
                for metric in expansion where metric.scenario.hasSuffix("->" + corpus) {
                    progress("  translation \(metric.scenario) \(metric.method): top1 \(metric.top1)/\(metric.queries), top3 \(metric.top3)/\(metric.queries)")
                }
            }
        }
        #if targetEnvironment(simulator)
        let platform = "iOS Simulator"
        #elseif os(macOS)
        let platform = "macOS"
        #else
        let platform = "other"
        #endif
        let report = Report(startedAt: started, os: ProcessInfo.processInfo.operatingSystemVersionString,
                            platform: platform, sqlite: String(cString: sqlite3_libversion()), topics: fixtures.count,
                            documents: documents, queries: queries, resources: resources, results: results,
                            queryTranslationProvider: translations?.provider, queryTranslationOS: translations?.os)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(report).write(to: URL(fileURLWithPath: CommandLine.arguments[2]), options: .atomic)
        progress("Saved benchmark: \(CommandLine.arguments[2])")
    }
}
