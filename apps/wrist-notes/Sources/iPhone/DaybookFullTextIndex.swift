import Foundation
import CryptoKit

/// Worker-owned derived projection. Call synchronization inside the generation's atomic transaction.
struct DaybookFullTextIndex {
    let db: DaybookDatabase
    let usesFTS: Bool
    init(database: DaybookDatabase) throws {
        self.db = database
        let db = database
        try db.migrate("fulltext-" + DaybookRetrieval.normalizationVersion) {
            try db.execute("CREATE TABLE fulltext_records(id TEXT PRIMARY KEY, captured_at REAL NOT NULL, kind TEXT NOT NULL, fingerprint TEXT NOT NULL, title TEXT NOT NULL, original TEXT NOT NULL, summary TEXT NOT NULL)")
            try db.execute("CREATE INDEX fulltext_scope ON fulltext_records(kind,captured_at,id)")
            try db.execute("CREATE INDEX fulltext_date ON fulltext_records(captured_at,id)")
        }
        // Probe actual SQLite capability; a missing tokenizer must not disable scoped SQL search.
        do {
            try db.transaction {
                let exists = !(try db.query("SELECT name FROM sqlite_master WHERE name='fulltext_fts'")).isEmpty
                if !exists {
                    try db.execute("CREATE VIRTUAL TABLE fulltext_fts USING fts5(title,original,summary, tokenize='trigram')")
                    // A previous tokenizer-unavailable run may already have unchanged projections.
                    try db.execute("INSERT INTO fulltext_fts(rowid,title,original,summary) SELECT rowid,title,original,summary FROM fulltext_records")
                }
                try Task.checkCancellation()
            }
            usesFTS = true
        } catch let error as DaybookDatabase.Failure where error.detail.contains("tokenizer") || error.detail.contains("no such module") {
            usesFTS = false
        }
    }
    func synchronize(_ records: [DayRecord]) throws {
        let records = Dictionary(records.map { ($0.id.uuidString, $0) }, uniquingKeysWith: { first, _ in first })
        var existing = Dictionary(uniqueKeysWithValues: try db.query("SELECT rowid,id,fingerprint FROM fulltext_records").map { (try $0.requiredString("id"), $0) })
        for (id, record) in records {
            let content = [DaybookRetrieval.normalizationVersion, id, String(record.capturedAt.timeIntervalSinceReferenceDate), record.kind.rawValue, record.title, record.text, record.summary, record.indexScopeIdentity]
            let fp = SHA256.hash(data: try JSONEncoder().encode(content)).map { String(format: "%02x", $0) }.joined()
            let old = existing.removeValue(forKey: id)
            if old?["fingerprint"]?.string == fp { continue }
            if let old { try remove(old) }
            try db.execute("INSERT INTO fulltext_records VALUES(?,?,?,?,?,?,?)", [.text(id), .real(record.capturedAt.timeIntervalSinceReferenceDate), .text(record.kind.rawValue), .text(fp), .text(DaybookRetrieval.normalize(record.title)), .text(DaybookRetrieval.normalize(record.text)), .text(DaybookRetrieval.normalize(record.summary))])
            if usesFTS {
                try db.execute("INSERT INTO fulltext_fts(rowid,title,original,summary) SELECT rowid,title,original,summary FROM fulltext_records WHERE id=?", [.text(id)])
            }
        }
        for row in existing.values { try remove(row) }
    }
    private func remove(_ row: DaybookDatabase.Row) throws {
        if usesFTS { try db.execute("DELETE FROM fulltext_fts WHERE rowid=?", [row["rowid"]!]) }
        try db.execute("DELETE FROM fulltext_records WHERE id=?", [row["id"]!])
    }
    func clear() throws {
        if usesFTS { try db.execute("DELETE FROM fulltext_fts") }
        try db.execute("DELETE FROM fulltext_records")
    }
    private func matching(_ term: String, start: Date, end: Date, kinds: Set<DayRecord.Kind>?, summary: Bool) throws -> [DaybookDatabase.Row] {
        var values: [DaybookDatabase.Value] = [.real(start.timeIntervalSinceReferenceDate), .real(end.timeIntervalSinceReferenceDate)]
        var scope = "captured_at>=? AND captured_at<?"
        if let kinds {
            guard !kinds.isEmpty else { return [] }
            scope += " AND kind IN (" + kinds.map { _ in "?" }.joined(separator: ",") + ")"
            values += kinds.map(\.rawValue).sorted().map { .text($0) }
        }
        if !term.isEmpty {
            if usesFTS && term.unicodeScalars.count >= 3 && !term.contains("\0") {
                let quoted = "\"" + term.replacingOccurrences(of: "\"", with: "\"\"") + "\""
                scope += " AND rowid IN (SELECT rowid FROM fulltext_fts WHERE fulltext_fts MATCH ?)"
                values.append(.text((summary ? "" : "{title original} : ") + quoted))
            }
            let columns = summary ? ["title", "original", "summary"] : ["title", "original"]
            scope += " AND (" + columns.map { "instr(\($0),?)>0" }.joined(separator: " OR ") + ")"
            values += columns.map { _ in .text(term) }
        }
        return try db.query("SELECT id,title,original FROM fulltext_records WHERE " + scope + " ORDER BY id", values)
    }
    func search(query: String, records: [DayRecord], start: Date, end: Date, allowed: Set<DayRecord.Kind>) throws -> DaybookSemanticMatches.Keywords {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let library = try matching(DaybookRetrieval.normalize(query), start: start, end: end, kinds: nil, summary: true)
        let terms = try DaybookRetrieval().keywordTerms(question: query, selectedDate: start)
        let kinds = DaybookRetrieval.requestedKind(for: query).map { allowed.intersection([$0]) } ?? allowed
        var scores: [UUID: Int] = [:]
        for term in terms {
            for row in try matching(term, start: start, end: end, kinds: kinds, summary: false) {
                guard let id = UUID(uuidString: try row.requiredString("id")) else { continue }
                let score = (try row.requiredString("title").contains(term) ? 4 * term.count : 0) + (try row.requiredString("original").contains(term) ? term.count : 0)
                scores[id, default: 0] += score
            }
        }
        return .init(query: query, terms: terms, libraryIDs: Set(library.compactMap { $0["id"]?.string.flatMap(UUID.init(uuidString:)) }), aiScores: scores,
                     libraryEvidence: .init(records: records, dayStart: start, dayEnd: end, allowedKinds: DaybookSemanticMatches.Keywords.allKinds), usesFTS: usesFTS)
    }
}
