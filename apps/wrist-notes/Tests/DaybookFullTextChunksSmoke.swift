import Foundation
import SQLite3

func fullTextChunksSmoke(directory: URL, day: Date, space: DaybookEmbeddingSpace) async throws {
    let end = day.addingTimeInterval(86400)
    let db = try DaybookDatabase(url: directory.appendingPathComponent("fulltext.sqlite3"))
    let index = DaybookSemanticIndex(database: db, embedding: FixtureEmbedding(space: space, available: false))
    let body = "预算审核 汉字。 A\" OR B* café CAFÉ 中文逗号，结束 " + String(repeating: "普通。", count: 900) + "尾部合同"
    let visible = DayRecord(id: UUID(), capturedAt: day, kind: .voice, title: "会议", text: body, summary: "生成专属摘要")
    let denied = DayRecord(id: UUID(), capturedAt: day, kind: .image, title: "预算审核", text: "预算审核")
    let old = DayRecord(id: UUID(), capturedAt: day.addingTimeInterval(-1), kind: .voice, title: "预算审核", text: "预算审核")
    let records = [visible, denied, old]
    for query in ["预", "预算", "预算审核", "A\" OR B*", "CAFE\u{301}", "中文逗号，", "尾部合同", "生成专属摘要"] {
        let result = await index.search(query: query, records: records, dayStart: day, dayEnd: end, allowedKinds: [.voice], limit: 10)
        precondition(result.keywords != nil, "SQL keywords survive missing embedding resources")
        let library = DaybookRetrieval.libraryRecords(query: query, records: records, dayStart: day, dayEnd: end, allowedKinds: [.voice], semantic: result)
        precondition(library.contains { $0.id == visible.id }, "literal SQL full text supports short/long/quoted/normalized/tail terms: \(query)")
        precondition(!library.contains { $0.id == old.id })
        if query == "预算审核" {
            precondition(library.contains { $0.id == denied.id })
            let prepared = try DaybookRetrieval().prepare(question: query, records: records, selectedDate: day, allowedKinds: [.voice], semantic: result)
            precondition(prepared.sources.map(\.id) == [visible.id])
        }
        if query == "生成专属摘要" {
            let prepared = try DaybookRetrieval().prepare(question: query, records: records, selectedDate: day, allowedKinds: [.voice], semantic: result)
            precondition(prepared.sources.isEmpty, "AI SQL excludes generated summary")
        }
        let stale = DaybookRetrieval.libraryRecords(query: "不存在词", records: records, dayStart: day, dayEnd: end, allowedKinds: [.voice], semantic: result)
        precondition(stale.isEmpty, "query mismatch rejects SQL payload")
    }
    let imageOnly = await index.search(query: "预算审核图片", records: records, dayStart: day, dayEnd: end, allowedKinds: [.voice, .image], limit: 10)
    let preparedImage = try DaybookRetrieval().prepare(question: "预算审核图片", records: records, selectedDate: day, allowedKinds: [.voice, .image], semantic: imageOnly)
    precondition(preparedImage.sources.map(\.id) == [denied.id] && imageOnly.keywords?.aiScores[visible.id] == nil, "requested type constrains AI SQL candidates")
    // A prior substring-only platform has populated projections without any FTS table.
    try db.execute("DROP TABLE IF EXISTS fulltext_fts")
    let promoted = await index.search(query: "预算审核", records: records, dayStart: day, dayEnd: end, allowedKinds: [.voice], limit: 10)
    precondition(promoted.keywords?.libraryIDs.contains(visible.id) == true, "enabling FTS must backfill unchanged projections atomically")
    let before = try db.query("SELECT * FROM fulltext_records ORDER BY id")
    let beforeFTS = try db.query("SELECT rowid,title,original,summary FROM fulltext_fts ORDER BY rowid")
    try db.execute("CREATE TRIGGER fail_fulltext BEFORE INSERT ON fulltext_records BEGIN SELECT RAISE(ABORT, 'fixture'); END")
    let edited = DayRecord(id: visible.id, capturedAt: day, kind: .voice, title: "新词", text: "当前原文")
    let failed = await index.search(query: "当前原文", records: [edited], dayStart: day, dayEnd: end, allowedKinds: [.voice], limit: 10)
    precondition(failed.keywords == nil)
    let after = try db.query("SELECT * FROM fulltext_records ORDER BY id")
    let afterFTS = try db.query("SELECT rowid,title,original,summary FROM fulltext_fts ORDER BY rowid")
    precondition(before == after && beforeFTS == afterFTS, "projection and FTS synchronization rolls back on write failure")
    precondition(DaybookRetrieval.libraryRecords(query: "当前原文", records: [edited], dayStart: day, dayEnd: end, allowedKinds: [.voice], semantic: failed).map(\.id) == [edited.id])
    try db.execute("DROP TRIGGER fail_fulltext")
    let plan = try db.query("EXPLAIN QUERY PLAN SELECT id FROM fulltext_records WHERE kind=? AND captured_at>=? AND captured_at<?", [.text("voice"), .real(day.timeIntervalSinceReferenceDate), .real(end.timeIntervalSinceReferenceDate)])
    precondition(plan.contains { $0["detail"]?.string?.contains("fulltext_scope") == true })
    if !(try db.query("SELECT name FROM sqlite_master WHERE name='fulltext_fts'")).isEmpty {
        let ftsPlan = try db.query("EXPLAIN QUERY PLAN SELECT rowid FROM fulltext_fts WHERE fulltext_fts MATCH ?", [.text("\"预算审核\"")])
        precondition(ftsPlan.contains { $0["detail"]?.string?.contains("VIRTUAL TABLE INDEX") == true })
    }

    for text in ["", "   \n", String(repeating: "无", count: 1700), String(repeating: "👨‍👩‍👧‍👦e\u{301}。", count: 500), String(repeating: "甲", count: 597) + "合同预算" + String(repeating: "乙", count: 700)] {
        let chunks = DaybookTextChunks.plan(text)
        if text.isEmpty { precondition(chunks.isEmpty); continue }
        precondition(chunks.first?.start == 0 && chunks.last?.end == text.count)
        var covered = 0
        let chars = Array(text)
        for chunk in chunks {
            precondition(chunk.start <= covered && chunk.end > covered && chunk.end - chunk.start <= 600 && covered - chunk.start <= 80)
            precondition(chunk.snippet == String(chars[chunk.start..<chunk.end]))
            covered = chunk.end
        }
        if text.contains("合同预算") { precondition(chunks.contains { $0.snippet.contains("合同预算") }) }
    }

    let resumeURL = directory.appendingPathComponent("resume.sqlite3")
    let resumeDB = try DaybookDatabase(url: resumeURL)
    let good = DayRecord(id: UUID(uuidString: "FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF")!, capturedAt: day, kind: .voice, title: "good", text: "合同预算")
    let huge = DayRecord(id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, capturedAt: day, kind: .voice, title: "huge", text: String(repeating: "普通记录。", count: 9000) + "合同预算")
    let broken = DayRecord(id: UUID(uuidString: "00000000-0000-0000-0000-000000000000")!, capturedAt: day, kind: .voice, title: "badvector", text: "badvector")
    let corpus = [huge, broken, good]
    let firstIndex = DaybookSemanticIndex(database: resumeDB, embedding: FixtureEmbedding(space: space, available: true))
    let first = await firstIndex.search(query: "合同预算", records: corpus, dayStart: day, dayEnd: end, allowedKinds: [.voice], limit: 10)
    precondition(first.coverage?.pending ?? 0 > 0 && first.coverage?.unavailable == 1)
    precondition(first.hits.contains { $0.id == good.id }, "failed and huge records cannot starve later valid records")
    let completed = try resumeDB.query("SELECT id FROM semantic_chunks WHERE state='ready'")
    precondition(completed.count <= 64)
    try resumeDB.execute("CREATE TRIGGER no_completed_update BEFORE UPDATE ON semantic_chunks WHEN OLD.state='ready' BEGIN SELECT RAISE(ABORT, 'rewrote completed'); END")
    let reopened = DaybookSemanticIndex(database: try DaybookDatabase(url: resumeURL), embedding: FixtureEmbedding(space: space, available: true))
    let second = await reopened.search(query: "合同预算", records: corpus, dayStart: day, dayEnd: end, allowedKinds: [.voice], limit: 10)
    precondition(second.coverage?.pending == 0 && second.coverage?.unavailable == 1)
    precondition(second.hits.contains { $0.id == huge.id && $0.snippet.contains("合同预算") })
    precondition((second.coverage?.finished ?? 0) > completed.count, "DB reopen resumes unfinished chunks")
    print("Daybook full text and resumable chunks: passed")
}

func fullRangeVectorSmoke(directory: URL, day: Date, space: DaybookEmbeddingSpace) async throws {
    let db = try DaybookDatabase(url: directory.appendingPathComponent("fullrange.sqlite3"))
    let records = (0..<4097).map { number in
        DayRecord(id: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012x", number))!, capturedAt: day, kind: .voice, title: "ordinary", text: number == 4096 ? "合同预算" : "ordinary")
    }
    // Real public search creates complete plans; fixture vectors bypass 65 inference passes solely
    // to exercise the production extension scan across more than its per-table candidate capacity.
    let planning = DaybookSemanticIndex(database: db, embedding: FixtureEmbedding(space: space, available: false))
    _ = await planning.search(query: "合同预算", records: records, dayStart: day, dayEnd: day.addingTimeInterval(86400), allowedKinds: [.voice], limit: 1)
    let ordinary: [Float] = [0, 0, 1], best: [Float] = [1, 0, 0]
    try db.transaction {
        try db.execute("UPDATE semantic_chunks SET state='ready',vector=?", [.blob(ordinary.withUnsafeBytes { Data($0) })])
        try db.execute("UPDATE semantic_chunks SET vector=? WHERE record_id=?", [.blob(best.withUnsafeBytes { Data($0) }), .text(records.last!.id.uuidString)])
    }
    let index = DaybookSemanticIndex(database: db, embedding: FixtureEmbedding(space: space, available: true))
    let result = await index.search(query: "合同预算", records: records, dayStart: day, dayEnd: day.addingTimeInterval(86400), allowedKinds: [.voice], limit: 1)
    precondition(result.hits.first?.id == records.last?.id, "the best candidate beyond 4095 must win by actual global distance")
    precondition(result.coverage?.finished == 4097, "complete records must not be evicted at the old 1365-record cap")
    print("Daybook full range vector scan: passed (4097 candidates)")
}

private final class RecoveringEmbedding: DaybookEmbedding, @unchecked Sendable {
    let space: DaybookEmbeddingSpace
    private let lock = NSLock()
    private var ready = false
    init(space: DaybookEmbeddingSpace) { self.space = space }
    func recover() { lock.lock(); ready = true; lock.unlock() }
    func vector(_ text: String) throws -> [Float]? {
        lock.lock(); defer { lock.unlock() }
        if text.contains("unsupported") && !ready { return nil }
        return [1, 0, 0]
    }
}
func unavailableAndMigrationSmoke(directory: URL, day: Date, space: DaybookEmbeddingSpace) async throws {
    let db = try DaybookDatabase(url: directory.appendingPathComponent("upgrade.sqlite3"))
    try db.execute("INSERT INTO life_settings VALUES('fixture',1)")
    try db.migrate("semantic-index-v1") {
        try db.execute("CREATE TABLE semantic_records(id TEXT PRIMARY KEY)")
        try db.execute("CREATE TABLE semantic_chunks(id INTEGER PRIMARY KEY,record_id TEXT REFERENCES semantic_records(id) ON DELETE CASCADE)")
        try db.execute("INSERT INTO semantic_records VALUES('old-derived-only')")
        try db.execute("INSERT INTO semantic_chunks VALUES(1,'old-derived-only')")
    }
    let broken = DayRecord(id: UUID(), capturedAt: day, kind: .voice, title: "content", text: "unsupported")
    let good = DayRecord(id: UUID(), capturedAt: day, kind: .voice, title: "content", text: "valid")
    let embedding = RecoveringEmbedding(space: space)
    let index = DaybookSemanticIndex(database: db, embedding: embedding)
    let first = await index.search(query: "query", records: [broken, good], dayStart: day, dayEnd: day.addingTimeInterval(86400), allowedKinds: [.voice], limit: 10)
    precondition(first.coverage?.finished == 1 && first.coverage?.unavailable == 1 && first.coverage?.pending == 0 && first.coverage?.canContinue == false)
    precondition(first.hits.map(\.id) == [good.id])
    let business = try db.query("SELECT enabled FROM life_settings WHERE source='fixture'")
    precondition(business.first?["enabled"] == .integer(1), "v1 upgrade preserves business tables")
    let migrations = try db.query("SELECT domain FROM storage_migrations WHERE domain='semantic-index-v2-complete-chunks'")
    precondition(migrations.count == 1)
    try db.execute("CREATE TRIGGER no_retry BEFORE UPDATE ON semantic_chunks BEGIN SELECT RAISE(ABORT, 'retry spin'); END")
    let again = await index.search(query: "query", records: [broken, good], dayStart: day, dayEnd: day.addingTimeInterval(86400), allowedKinds: [.voice], limit: 10)
    precondition(again.coverage?.attempted == 0 && again.hits.map(\.id) == [good.id], "unsupported content persists without retries on ordinary searches")
    try db.execute("DROP TRIGGER no_retry")
    embedding.recover(); index.invalidateResources()
    let recovered = await index.search(query: "query", records: [broken, good], dayStart: day, dayEnd: day.addingTimeInterval(86400), allowedKinds: [.voice], limit: 10)
    precondition(recovered.coverage?.finished == 2 && recovered.coverage?.unavailable == 0 && recovered.coverage?.attempted == 1)
    let tail = DayRecord(id: good.id, capturedAt: day, kind: .voice, title: "content", text: String(repeating: "原文。", count: 1000) + "尾部甲")
    _ = await index.search(query: "query", records: [tail], dayStart: day, dayEnd: day.addingTimeInterval(86400), allowedKinds: [.voice], limit: 10)
    let changedTail = DayRecord(id: good.id, capturedAt: day, kind: .voice, title: "content", text: String(repeating: "原文。", count: 1000) + "尾部乙")
    _ = await index.search(query: "query", records: [changedTail], dayStart: day, dayEnd: day.addingTimeInterval(86400), allowedKinds: [.voice], limit: 10)
    let chunks = try db.query("SELECT snippet FROM semantic_chunks")
    precondition(chunks.contains { $0["snippet"]?.string?.contains("尾部乙") == true } && !chunks.contains { $0["snippet"]?.string?.contains("尾部甲") == true }, "tail edits invalidate the complete cache")
    try await index.clear()
    let projection = try db.query("SELECT * FROM fulltext_records")
    let vectors = try db.query("SELECT * FROM semantic_chunks")
    precondition(projection.isEmpty && vectors.isEmpty)
    print("Daybook unavailable state, resource retry, and v1 migration: passed")
}

// Replace only this synthetic connection's tokenizer constructor with an unavailable one.
// This drives the real capability probe and scoped SQL fallback without production test switches.
func tokenizerFallbackSmoke(directory: URL, day: Date, space: DaybookEmbeddingSpace) async throws {
    let db = try DaybookDatabase(url: directory.appendingPathComponent("tokenizer.sqlite3"))
    let restore: () -> Void = try db.withConnection { handle in
        var api: UnsafeMutablePointer<fts5_api>?
        var statement: OpaquePointer?
        precondition(sqlite3_prepare_v2(handle, "SELECT fts5(?1)", -1, &statement, nil) == SQLITE_OK)
        defer { sqlite3_finalize(statement) }
        withUnsafeMutablePointer(to: &api) { pointer in
            "fts5_api_ptr".withCString { type in
                precondition(sqlite3_bind_pointer(statement, 1, pointer, type, nil) == SQLITE_OK)
                precondition(sqlite3_step(statement) == SQLITE_ROW)
            }
        }
        guard let api else { preconditionFailure("system FTS5 API unavailable") }
        var original = fts5_tokenizer()
        var context: UnsafeMutableRawPointer?
        precondition(api.pointee.xFindTokenizer(api, "trigram", &context, &original) == SQLITE_OK)
        var unavailable = fts5_tokenizer(xCreate: { _, _, _, _ in SQLITE_ERROR }, xDelete: { _ in }, xTokenize: { _, _, _, _, _, _ in SQLITE_ERROR })
        precondition(api.pointee.xCreateTokenizer(api, "trigram", nil, &unavailable, nil) == SQLITE_OK)
        return {
            var tokenizer = original
            precondition(api.pointee.xCreateTokenizer(api, "trigram", context, &tokenizer, nil) == SQLITE_OK)
        }
    }
    let record = DayRecord(id: UUID(), capturedAt: day, kind: .voice, title: "记录", text: "预算审核 A\" OR B* CAFE\u{301}")
    let index = DaybookSemanticIndex(database: db, embedding: FixtureEmbedding(space: space, available: false))
    for query in ["预算审核", "A\" OR B*", "café"] {
        let result = await index.search(query: query, records: [record], dayStart: day, dayEnd: day.addingTimeInterval(86400), allowedKinds: [.voice], limit: 1)
        precondition(result.keywords?.usesFTS == false && result.keywords?.libraryIDs == [record.id], "unavailable trigram falls back to scoped SQL substring matching")
    }
    restore()
    let promoted = await index.search(query: "预算审核", records: [record], dayStart: day, dayEnd: day.addingTimeInterval(86400), allowedKinds: [.voice], limit: 1)
    precondition(promoted.keywords?.usesFTS == true && promoted.keywords?.libraryIDs == [record.id], "restored tokenizer atomically backfills unchanged projections")
    print("Daybook real tokenizer failure and capability recovery: passed")
}
