import Foundation
import CryptoKit
import SQLite3
import WristNotesVector

struct DaybookEmbeddingSpace: Equatable, Sendable {
    let model: String
    let revision: Int
    let dimension: Int
    let language: String
    let pooling: String
    var key: String { "\(model)|\(revision)|\(dimension)|\(language)|\(pooling)" }
}
/// Implementations are owned exclusively by the index worker. No generated text is embedded.
protocol DaybookEmbedding: Sendable {
    var space: DaybookEmbeddingSpace { get }
    var partialCoverage: Bool { get }
    func vector(_ text: String) throws -> [Float]?
}

extension DaybookEmbedding { var partialCoverage: Bool { false } }

private final class SemanticGeneration: @unchecked Sendable {
    private let lock = NSLock()
    private var generation: UInt64 = 0
    private var resources: UInt64 = 0
    private var scope: String?
    func begin(scope: String) -> UInt64 {
        lock.lock(); defer { lock.unlock() }
        if self.scope != scope { self.scope = scope; generation &+= 1 }
        return generation
    }
    func resourceRevision() -> UInt64 { lock.lock(); defer { lock.unlock() }; return resources }
    func invalidateResources() { lock.lock(); defer { lock.unlock() }; resources &+= 1; generation &+= 1 }
    func current() -> UInt64 { lock.lock(); defer { lock.unlock() }; return generation }
    @discardableResult func invalidate() -> UInt64 { lock.lock(); defer { lock.unlock() }; generation &+= 1; return generation }
    func check(_ expected: UInt64) throws {
        try Task.checkCancellation()
        guard current() == expected else { throw CancellationError() }
    }
    /// Makes the validity check and a durable mutation atomic with invalidate/clear.
    func write<T>(_ expected: UInt64, _ body: () throws -> T) throws -> T {
        lock.lock(); defer { lock.unlock() }
        try Task.checkCancellation()
        guard generation == expected else { throw CancellationError() }
        return try body()
    }
}

/// Exact scans are serialized process-wide: upstream initializes global SIMD dispatch per connection.
private let semanticExtensionLock = NSLock()

final class DaybookSemanticIndex: DaybookSemanticSearching, @unchecked Sendable {
    static let shared = DaybookSemanticIndex()
    private let generation = SemanticGeneration()
    private let worker: Worker
    private var deletionObservation: NSObjectProtocol?
    init(database: DaybookDatabase? = nil, embedding: (any DaybookEmbedding)? = nil) {
        worker = Worker(database: database, embedding: embedding)
        _ = LegacyAudioDeletionLedger.shared
        deletionObservation = NotificationCenter.default.addObserver(forName:LegacyAudioDeletionLedger.notification,object:nil,queue:nil) { [weak self] note in
            if let id = note.userInfo?["legacyNoteID"] as? UUID { LegacyAudioDeletionLedger.shared.record(id) }
            // Synchronously fence in-flight writes, then clear both vector and fulltext projections.
            self?.invalidate(records:[],allowedKinds:[])
        }
    }
    deinit { if let deletionObservation { NotificationCenter.default.removeObserver(deletionObservation) } }
    func search(query: String, records: [DayRecord], dayStart: Date, dayEnd: Date,
                allowedKinds: Set<DayRecord.Kind>, limit: Int = 20) async -> DaybookSemanticMatches {
        let records = LegacyAudioDeletionLedger.shared.filter(records)
        let evidence = DaybookEvidenceSnapshot(records: records, dayStart: dayStart, dayEnd: dayEnd, allowedKinds: allowedKinds)
        let token = generation.begin(scope:"\(dayStart.timeIntervalSinceReferenceDate)|\(dayEnd.timeIntervalSinceReferenceDate)|\(evidence.fingerprint)")
        do {
            let result = try await worker.search(query: query, records: records, dayStart: dayStart, dayEnd: dayEnd,
                                                 allowedKinds: allowedKinds, limit: limit, gate: generation, token: token)
            try generation.check(token)
            return DaybookSemanticMatches(hits: result.hits, status: result.status, evidence: evidence, generation: token, keywords: result.keywords, coverage: result.coverage, query: query.trimmingCharacters(in: .whitespacesAndNewlines))
        } catch {
            return DaybookSemanticMatches(hits: [], status: error is CancellationError ? "检索已取消；使用关键词" : "本地语义检索不可用；使用关键词", evidence: evidence, generation: token, query: query.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }
    func invalidateResources() { generation.invalidateResources() }
    func isCurrent(_ result: DaybookSemanticMatches) -> Bool { result.generation == generation.current() }
    /// Call synchronously when source/date/permissions change, before enqueueing reconciliation.
    func invalidate(records: [DayRecord], allowedKinds: Set<DayRecord.Kind>) {
        let records = LegacyAudioDeletionLedger.shared.filter(records)
        let token = generation.invalidate()
        Task { try? await worker.reconcile(records: records, allowedKinds: allowedKinds, gate: generation, token: token) }
    }
    func clear() async throws {
        let token = generation.invalidate()
        try await worker.clear(gate: generation, token: token)
    }

    private actor Worker {
        private var database: DaybookDatabase?
        private let injected: (any DaybookEmbedding)?
        init(database: DaybookDatabase?, embedding: (any DaybookEmbedding)?) { self.database = database; injected = embedding }
        private func db() throws -> DaybookDatabase {
            if let database { return database }
            let database = try DaybookDatabase(); self.database = database; return database
        }
        private var resourceRevision: UInt64 = 0
        private func schema(_ db: DaybookDatabase) throws {
            try db.migrate("semantic-index-v2-complete-chunks") {
                // v1 is disposable derived data; no business table participates in this upgrade.
                try db.execute("DROP TABLE IF EXISTS semantic_chunks")
                try db.execute("DROP TABLE IF EXISTS semantic_records")
                try db.execute("CREATE TABLE semantic_records(id TEXT PRIMARY KEY, captured_at REAL NOT NULL, kind TEXT NOT NULL, fingerprint TEXT NOT NULL, model_key TEXT NOT NULL, title TEXT NOT NULL, total INTEGER NOT NULL, indexed_at REAL NOT NULL)")
                try db.execute("CREATE TABLE semantic_chunks(id INTEGER PRIMARY KEY, record_id TEXT NOT NULL REFERENCES semantic_records(id) ON DELETE CASCADE, ordinal INTEGER NOT NULL, model_key TEXT NOT NULL, start_offset INTEGER NOT NULL, end_offset INTEGER NOT NULL, snippet TEXT NOT NULL, state TEXT NOT NULL CHECK(state IN ('pending','ready','unavailable')), vector BLOB, UNIQUE(record_id,ordinal), CHECK((state='ready' AND vector IS NOT NULL) OR (state<>'ready' AND vector IS NULL)))")
                try db.execute("CREATE INDEX semantic_scope ON semantic_records(model_key,kind,captured_at,id)")
                try db.execute("CREATE INDEX semantic_pending ON semantic_chunks(state,record_id,ordinal)")
            }
        }
        private func fingerprint(_ record: DayRecord) -> String {
            let data = try! JSONEncoder().encode([DaybookTextChunks.version, record.id.uuidString, String(record.capturedAt.timeIntervalSinceReferenceDate), record.kind.rawValue, record.title, record.text, record.indexScopeIdentity])
            return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        }
        func reconcile(records: [DayRecord], allowedKinds: Set<DayRecord.Kind>, gate: SemanticGeneration, token: UInt64) throws {
            let db = try db()
            try gate.write(token) { try schema(db) }
            try gate.write(token) { try db.transaction { try DaybookFullTextIndex(database:db).synchronize(records) } }
            let current = Dictionary(records.map { ($0.id.uuidString, $0) }, uniquingKeysWith: { first, _ in first })
            var removed: [String] = []
            for row in try db.query("SELECT id,fingerprint FROM semantic_records") {
                try gate.check(token)
                let id = try row.requiredString("id")
                guard let record = current[id], allowedKinds.contains(record.kind) else { removed.append(id); continue }
                if fingerprint(record) != row["fingerprint"]?.string { removed.append(id) }
            }
            try gate.write(token) {
                try db.transaction {
                    for id in removed { try db.execute("DELETE FROM semantic_records WHERE id=?", [.text(id)]) }
                    try Task.checkCancellation()
                }
            }
        }
        func clear(gate: SemanticGeneration, token: UInt64) throws {
            let db = try db()
            try gate.write(token) {
                try db.transaction {
                    try schema(db)
                    try db.execute("DELETE FROM semantic_records")
                    try DaybookFullTextIndex(database: db).clear()
                    try Task.checkCancellation()
                }
            }
        }
        struct Result {
            var hits: [DaybookSemanticMatches.Hit] = []
            var status = ""
            var keywords: DaybookSemanticMatches.Keywords?
            var coverage: DaybookSemanticMatches.Coverage?
        }
        func search(query: String, records: [DayRecord], dayStart: Date, dayEnd: Date, allowedKinds: Set<DayRecord.Kind>,
                    limit: Int, gate: SemanticGeneration, token: UInt64) throws -> Result {
            try gate.check(token)
            let db = try db()
            var result = Result()
            let records = DayRecord.evidenceRecords(records, scope: DateInterval(start:dayStart,end:dayEnd))
            let fulltext = try gate.write(token) { try DaybookFullTextIndex(database: db) }
            try gate.write(token) { try db.transaction { try fulltext.synchronize(records); try Task.checkCancellation() } }
            result.keywords = try fulltext.search(query: query, records: records, start: dayStart, end: dayEnd, allowed: allowedKinds)
            let lexicalStatus = fulltext.usesFTS ? "SQL 全文关键词" : "SQL 全文关键词（子串模式）"
            result.status = lexicalStatus
            do {
                try reconcile(records: records, allowedKinds: allowedKinds, gate: gate, token: token)
                guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return result }
                let embedding = injected ?? AppleDaybookEmbedding.make()
                guard let embedding else { result.status += "；本机语言资源未就绪"; return result }
                let space = embedding.space
                guard space.dimension > 0 && space.dimension <= 4096 else { throw SemanticFailure.invalidVector }
                let revision = gate.resourceRevision()
                try gate.write(token) {
                    try db.transaction {
                        try db.execute("DELETE FROM semantic_records WHERE model_key<>?", [.text(space.key)])
                        if resourceRevision != revision {
                            try db.execute("UPDATE semantic_chunks SET state='pending' WHERE state='unavailable'")
                        }
                        try Task.checkCancellation()
                    }
                }
                resourceRevision = revision
                let kinds = DaybookRetrieval.requestedKind(for: query).map { allowedKinds.intersection([$0]) } ?? allowedKinds
                guard !kinds.isEmpty else { result.status += "；没有允许 AI 读取的来源"; return result }
                let eligible = records.filter { kinds.contains($0.kind) && $0.capturedAt >= dayStart && $0.capturedAt < dayEnd }
                    .sorted { $0.id.uuidString < $1.id.uuidString }
                let indexed = Set(try db.query("SELECT id FROM semantic_records").compactMap { $0["id"]?.string })
                for record in eligible where !indexed.contains(record.id.uuidString) {
                    try gate.check(token)
                    let plan = DaybookTextChunks.plan(record.text)
                    let fp = fingerprint(record)
                    try gate.write(token) {
                        try db.transaction {
                            try db.execute("INSERT INTO semantic_records VALUES(?,?,?,?,?,?,?,?)", [.text(record.id.uuidString), .real(record.capturedAt.timeIntervalSinceReferenceDate), .text(record.kind.rawValue), .text(fp), .text(space.key), .text(record.title), .integer(Int64(plan.count)), .real(Date.now.timeIntervalSinceReferenceDate)])
                            for (ordinal, chunk) in plan.enumerated() {
                                try Task.checkCancellation()
                                try db.execute("INSERT INTO semantic_chunks(record_id,ordinal,model_key,start_offset,end_offset,snippet,state) VALUES(?,?,?,?,?,?,'pending')", [.text(record.id.uuidString), .integer(Int64(ordinal)), .text(space.key), .integer(Int64(chunk.start)), .integer(Int64(chunk.end)), .text(chunk.snippet)])
                            }
                            try Task.checkCancellation()
                        }
                    }
                }
                let placeholders = kinds.map { _ in "?" }.joined(separator: ",")
                let scope = "r.model_key=? AND r.captured_at>=? AND r.captured_at<? AND r.kind IN (\(placeholders))"
                let values: [DaybookDatabase.Value] = [.text(space.key), .real(dayStart.timeIntervalSinceReferenceDate), .real(dayEnd.timeIntervalSinceReferenceDate)] + kinds.map(\.rawValue).sorted().map { .text($0) }
                func coverage(attempted: Int, resources: Bool) throws -> DaybookSemanticMatches.Coverage {
                    let row = try db.query("SELECT count(*) AS total,coalesce(sum(c.state='ready'),0) AS finished,coalesce(sum(c.state='unavailable'),0) AS unavailable FROM semantic_chunks c JOIN semantic_records r ON r.id=c.record_id WHERE " + scope, values)[0]
                    return .init(total: try row.requiredInt("total"), finished: try row.requiredInt("finished"), unavailable: try row.requiredInt("unavailable"), attempted: attempted, resourcesAvailable: resources, modelWindowLimited: embedding.partialCoverage)
                }
                result.coverage = try coverage(attempted: 0, resources: false)
                try gate.check(token)
                guard let rawQuery = try embedding.vector(String(query.prefix(300))) else {
                    try gate.check(token)
                    result.coverage = try coverage(attempted: 0, resources: false)
                    result.status += "；查询语言或资源不可用；" + coverageStatus(result.coverage!)
                    return result
                }
                try gate.check(token)
                let queryData = try normalized(rawQuery, dimension: space.dimension)
                // Fair persisted schedule: the least attempted record first, then one chunk per record
                // per round. The completed count survives reopen and prevents large records starving peers.
                let pending = try db.query("SELECT * FROM (SELECT c.id,c.snippet,r.title,c.record_id,c.ordinal,ROW_NUMBER() OVER(PARTITION BY c.record_id ORDER BY c.ordinal) AS turn,(SELECT count(*) FROM semantic_chunks done WHERE done.record_id=r.id AND done.state<>'pending') AS attempted FROM semantic_chunks c JOIN semantic_records r ON r.id=c.record_id WHERE " + scope + " AND c.state='pending') ORDER BY turn,attempted,record_id,ordinal LIMIT 64", values)
                for chunk in pending {
                    try gate.check(token)
                    var vector: Data?
                    do {
                        if let raw = try embedding.vector(String(try chunk.requiredString("title").prefix(128)) + "\n" + (try chunk.requiredString("snippet"))) {
                            vector = try normalized(raw, dimension: space.dimension)
                        }
                    } catch is CancellationError { throw CancellationError() }
                    catch { vector = nil }
                    try gate.check(token)
                    try gate.write(token) {
                        try db.transaction {
                            try db.execute("UPDATE semantic_chunks SET state=?,vector=? WHERE id=? AND state='pending'", [.text(vector == nil ? "unavailable" : "ready"), vector.map { .blob($0) } ?? .null, chunk["id"]!])
                            try Task.checkCancellation()
                        }
                    }
                }
                result.coverage = try coverage(attempted: pending.count, resources: true)
                // Keyset paging bounds memory, not total corpus size. Every scoped candidate is scanned.
                var cursor: Int64 = 0
                var best: [UUID: RankedHit] = [:]
                let requestedLimit = max(0, min(40, limit))
                while true {
                    try gate.check(token)
                    let rows = try db.query("SELECT c.id,c.record_id,c.ordinal,c.snippet,c.vector FROM semantic_chunks c JOIN semantic_records r ON r.id=c.record_id WHERE " + scope + " AND c.model_key=r.model_key AND c.state='ready' AND c.id>? ORDER BY c.id LIMIT 4095", values + [.integer(cursor)])
                    guard !rows.isEmpty else { break }
                    cursor = Int64(try rows.last!.requiredInt("id"))
                    for hit in try scan(rows, dimension: space.dimension, query: queryData, limit: requestedLimit, gate: gate, token: token) {
                        if let previous = best[hit.hit.id], !hit.precedes(previous) { continue }
                        best[hit.hit.id] = hit
                    }
                    // Only top-k record minima need survive a batch; later minima can re-enter.
                    best = Dictionary(uniqueKeysWithValues: best.values.sorted { $0.precedes($1) }.prefix(requestedLimit).map { ($0.hit.id, $0) })
                }
                result.hits = best.values.sorted { $0.precedes($1) }.map(\.hit)
                result.status += "；" + coverageStatus(result.coverage!)
                return result
            } catch is CancellationError { throw CancellationError() }
            catch { result.status += "；本地语义检索不可用"; return result }
        }
        private func coverageStatus(_ coverage: DaybookSemanticMatches.Coverage) -> String {
            "向量已完成 \(coverage.finished)/\(coverage.total) 段，待处理 \(coverage.pending) 段，不可用 \(coverage.unavailable) 段" + (coverage.modelWindowLimited ? "（模型窗口可能仅覆盖段内部分文本）" : "")
        }
        private func normalized(_ vector: [Float], dimension: Int) throws -> Data {
            guard vector.count == dimension, vector.allSatisfy(\.isFinite) else { throw SemanticFailure.invalidVector }
            let norm = sqrt(vector.reduce(0.0) { $0 + Double($1) * Double($1) })
            guard norm.isFinite && norm > 0 else { throw SemanticFailure.invalidVector }
            var values = vector.map { Float(Double($0) / norm) }
            return values.withUnsafeMutableBytes { Data($0) }
        }
        private struct RankedHit {
            let hit: DaybookSemanticMatches.Hit
            let distance: Double
            let ordinal: Int
            func precedes(_ other: RankedHit) -> Bool {
                if distance != other.distance { return distance < other.distance }
                if hit.id != other.hit.id { return hit.id.uuidString < other.hit.id.uuidString }
                return ordinal < other.ordinal
            }
        }
        private func scan(_ rows: [DaybookDatabase.Row], dimension: Int, query: Data, limit: Int, gate: SemanticGeneration, token: UInt64) throws -> [RankedHit] {
            semanticExtensionLock.lock(); defer { semanticExtensionLock.unlock() }
            let candidateDB = try DaybookDatabase(inMemory: true)
            try candidateDB.withConnection { handle in
                var message: UnsafeMutablePointer<CChar>?
                let status = wristnotes_vector_init(handle, &message)
                defer { sqlite3_free(message) }
                guard status == SQLITE_OK else { throw SemanticFailure.extensionFailure }
            }
            try candidateDB.execute("CREATE TABLE candidates(id INTEGER PRIMARY KEY, record_id TEXT NOT NULL, snippet TEXT NOT NULL, ordinal INTEGER NOT NULL, embedding BLOB NOT NULL)")
            try candidateDB.transaction {
                for (ordinal, row) in rows.enumerated() {
                    try gate.check(token)
                    guard let data = row["vector"]?.data, data.count == dimension * 4 else { throw SemanticFailure.invalidVector }
                    try candidateDB.execute("INSERT INTO candidates VALUES(?,?,?,?,?)", [.integer(Int64(ordinal + 1)), .text(try row.requiredString("record_id")), .text(try row.requiredString("snippet")), row["ordinal"]!, .blob(data)])
                }
            }
            _ = try candidateDB.query("SELECT vector_init('candidates','embedding',?)", [.text("dimension=\(dimension),type=FLOAT32,distance=COSINE,normalized=1")])
            let ranked = try candidateDB.query("SELECT record_id,snippet,ordinal,distance FROM (SELECT c.record_id,c.snippet,c.ordinal,v.distance,ROW_NUMBER() OVER(PARTITION BY c.record_id ORDER BY v.distance,c.ordinal) AS rank FROM vector_full_scan('candidates','embedding',?) v JOIN candidates c ON c.id=v.rowid) WHERE rank=1 ORDER BY distance,record_id,ordinal LIMIT ?", [.blob(query), .integer(Int64(limit))])
            try gate.check(token)
            return try ranked.compactMap { row in
                guard let id = UUID(uuidString: try row.requiredString("record_id")) else { return nil }
                return RankedHit(hit: .init(id: id, snippet: try row.requiredString("snippet")), distance: try row.requiredDouble("distance"), ordinal: try row.requiredInt("ordinal"))
            }
        }
    }
    private enum SemanticFailure: Error { case unavailable, invalidVector, extensionFailure }
}
