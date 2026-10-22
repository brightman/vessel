import CryptoKit
import Foundation

/// Only a digest of the complete allowed scope is retained, never a duplicate of raw record bodies.
struct DaybookEvidenceSnapshot: Codable, Equatable, Sendable {
    let dayStart: Date
    let dayEnd: Date
    let allowedKinds: Set<DayRecord.Kind>
    let fingerprint: String

    init(records: [DayRecord], dayStart: Date, dayEnd: Date, allowedKinds: Set<DayRecord.Kind>) {
        self.dayStart = dayStart; self.dayEnd = dayEnd; self.allowedKinds = allowedKinds
        let scoped = records.compactMap { $0.recordingProjection(from: dayStart, to: dayEnd) }.filter { allowedKinds.contains($0.kind) }
            .sorted { $0.id.uuidString < $1.id.uuidString }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.nonConformingFloatEncodingStrategy = .convertToString(positiveInfinity: "+Infinity", negativeInfinity: "-Infinity", nan: "NaN")
        // DayRecord is an entirely Codable value; nonfinite numbers have an explicit stable encoding.
        let data = try! encoder.encode(scoped)
        fingerprint = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    func isCurrent(records: [DayRecord], allowedKinds: Set<DayRecord.Kind>) -> Bool {
        self.allowedKinds == allowedKinds && self == Self(records: records, dayStart: dayStart, dayEnd: dayEnd, allowedKinds: allowedKinds)
    }
}

struct DaybookConversationTurn: Codable, Equatable, Identifiable, Sendable {
    enum State: String, Codable, Sendable { case pending, completed, cancelled, failed, redacted }
    let id: UUID
    let question: String
    let text: String
    let generated: Bool
    let provider: String
    let evidence: DaybookEvidenceSnapshot
    let sources: [DaybookRetrieval.Source]
    let scopeDescription: String
    // Original user references are scoped to the preceding displayed answer, not this turn's new labels.
    // Optional for decoding version-1 archives written before identity-aware user references.
    var questionReferenceIDs: [Int: UUID]? = nil
    var state: State? = nil
    var createdAt: Date? = nil
    var completionState: State { state ?? .completed }

    func replacing(text: String, state: State) -> Self {
        Self(id: id, question: question, text: text, generated: false, provider: "", evidence: evidence,
             sources: [], scopeDescription: "", questionReferenceIDs: nil, state: state, createdAt: createdAt)
    }

    func redacted() -> Self {
        replacing(text: "相关资料的读取权限已关闭，回答和引用已移除。你的问题仍保留在历史中。", state: .redacted)
    }

    var referencedSourceIDs: Set<UUID> {
        Set(sources.filter { text.contains("[\($0.number)]") }.map(\.id))
    }
}

struct DaybookConversation: Codable, Equatable, Sendable {
    let day: Date
    var updatedAt: Date
    var turns: [DaybookConversationTurn]
}

enum DaybookConversationFailure: LocalizedError {
    case load, save
    var errorDescription: String? {
        switch self {
        case .load: "无法读取本机对话，原文件已保留。可重试读取，或明确重置本机对话存储。"
        case .save: "本机对话保存失败，此次更改尚未保存。请检查存储空间后重试保存。"
        }
    }
}

/// Atomic, versioned, local storage. Corruption is never replaced without an explicit reset.
final class DaybookConversationStore {
    private struct Archive: Codable { let version: Int; let conversations: [DaybookConversation] }
    private let url: URL
    private var database: DaybookDatabase?
    private var blocked = false
    static let pageSize = 10
    struct Cursor: Equatable { let createdAt: Double; let id: String }
    struct Page { let turns: [DaybookConversationTurn]; let cursor: Cursor?; let hasMore: Bool }

    static func local() -> DaybookConversationStore {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return DaybookConversationStore(url: root.appendingPathComponent("WristNotes/Conversations/history.json"))
    }

    init(url: URL, database: DaybookDatabase? = nil) { self.url = url; self.database = database }
    private func connection() throws -> DaybookDatabase {
        if let database { return database }
        let db = try DaybookDatabase(url: DaybookDatabase.url(forLegacy: url)); database = db; return db
    }

    private func preparedConnection() throws -> DaybookDatabase {
        let db = try connection()
        try db.migrate("conversation-history-v2") {
            try db.execute("ALTER TABLE conversation_turns ADD COLUMN state TEXT")
            try db.execute("ALTER TABLE conversation_turns ADD COLUMN created_at REAL")
            // Old rows have no individual send time. Preserve their thread/order deterministically.
            try db.execute("UPDATE conversation_turns SET created_at = (SELECT updated_at FROM conversations WHERE day = conversation_turns.day) - ((SELECT COUNT(*) FROM conversation_turns AS sibling WHERE sibling.day = conversation_turns.day) - 1 - position) * 0.000001")
            try db.execute("CREATE INDEX conversation_turns_history ON conversation_turns(created_at DESC, id DESC)")
        }
        try db.migrate("conversations") {
            guard FileManager.default.fileExists(atPath: url.path) else { return }
            let data = try Data(contentsOf: url)
            guard data.count <= 12_000_000 else { throw DaybookConversationFailure.load }
            let archive = try JSONDecoder().decode(Archive.self, from: data)
            try Self.validate(archive)
            try Self.write(archive.conversations, db: db)
        }
        return db
    }

    func load() throws -> [DaybookConversation] {
        do {
            let db = try preparedConnection()
            let archive = Archive(version: 1, conversations: try Self.read(db))
            try Self.validate(archive)
            blocked = false
            return archive.conversations
        } catch { blocked = true; throw DaybookConversationFailure.load }
    }

    @discardableResult
    func save(_ conversations: [DaybookConversation]) throws -> [DaybookConversation] {
        guard !blocked else { throw DaybookConversationFailure.load }
        do {
            let db = try preparedConnection()
            try Self.validate(Archive(version: 1, conversations: conversations))
            try db.transaction { try Self.write(conversations, db: db) }
            return conversations
        } catch { throw DaybookConversationFailure.save }
    }

    func loadPage(before cursor: Cursor? = nil, limit: Int = pageSize) throws -> Page {
        do {
            let db = try preparedConnection()
            let count = max(1, min(limit, 100))
            var values: [DaybookDatabase.Value] = []
            var query = "SELECT * FROM conversation_turns"
            if let cursor {
                query += " WHERE (created_at, id) < (?, ?)"
                values += [.real(cursor.createdAt), .text(cursor.id)]
            }
            query += " ORDER BY created_at DESC, id DESC LIMIT ?"
            values.append(.integer(Int64(count + 1)))
            let rows = try db.query(query, values)
            let page = Array(rows.prefix(count))
            let turns = try page.map(Self.turn).reversed()
            let next = try page.last.map { Cursor(createdAt: try $0.requiredDouble("created_at"), id: try $0.requiredString("id")) }
            blocked = false
            return Page(turns: Array(turns), cursor: next, hasMore: rows.count > count)
        } catch { blocked = true; throw DaybookConversationFailure.load }
    }

    func latestEvidenceDay(selectedDay: Date, allowedKinds: Set<DayRecord.Kind>) throws -> Date? {
        let db = try preparedConnection()
        guard let row = try db.query("SELECT evidence FROM conversation_turns WHERE day = ? AND COALESCE(state,'completed') = 'completed' ORDER BY position DESC LIMIT 1", [.real(selectedDay.timeIntervalSinceReferenceDate)]).first else { return nil }
        let evidence = try DaybookDatabase.decode(DaybookEvidenceSnapshot.self, row["evidence"])
        return evidence.allowedKinds.isSubset(of: allowedKinds) ? evidence.dayStart : nil
    }

    /// The request and every subsequent state are committed by UUID, never by replacing the archive.
    func saveTurn(_ turn: DaybookConversationTurn, day: Date) throws {
        guard !blocked else { throw DaybookConversationFailure.load }
        do {
            try Self.validate(Archive(version: 1, conversations: [.init(day: day, updatedAt: .now, turns: [turn])]))
            let db = try preparedConnection()
            try db.transaction {
                let dayValue = DaybookDatabase.Value.real(day.timeIntervalSinceReferenceDate)
                try db.execute("INSERT INTO conversations(day,updated_at) VALUES (?,?) ON CONFLICT(day) DO UPDATE SET updated_at = excluded.updated_at", [dayValue, .real(Date.now.timeIntervalSinceReferenceDate)])
                let existing = try db.query("SELECT position,day FROM conversation_turns WHERE id = ?", [.text(turn.id.uuidString)]).first
                if let existing, existing["day"] != dayValue { throw DaybookConversationFailure.save }
                let position = try existing?["position"] ?? db.query("SELECT COALESCE(MAX(position),-1)+1 AS next FROM conversation_turns WHERE day = ?", [dayValue])[0]["next"]!
                try Self.writeTurn(turn, day: dayValue, position: position, fallbackDate: .now, db: db)
            }
        } catch { throw DaybookConversationFailure.save }
    }

    func interruptPending() throws {
        let db = try preparedConnection()
        try db.execute("UPDATE conversation_turns SET state = 'cancelled', text = ?, sources = ?, question_references = NULL WHERE state = 'pending'", [.text("上次回答已中断，可重新提问。"), try DaybookDatabase.json([DaybookRetrieval.Source]())])
    }

    /// Read only bounded batches of permission metadata; unrelated rows and their content are untouched.
    func redactDisallowed(_ allowedKinds: Set<DayRecord.Kind>) throws {
        let db = try preparedConnection()
        try db.transaction {
            var cursor = ""
            while true {
                let rows = try db.query("SELECT id,evidence FROM conversation_turns WHERE id > ? AND COALESCE(state,'completed') != 'redacted' ORDER BY id LIMIT 128", [.text(cursor)])
                guard !rows.isEmpty else { break }
                for row in rows {
                    cursor = try row.requiredString("id")
                    let evidence = try DaybookDatabase.decode(DaybookEvidenceSnapshot.self, row["evidence"])
                    if !evidence.allowedKinds.isSubset(of: allowedKinds) {
                        try db.execute("UPDATE conversation_turns SET state = 'redacted', text = ?, generated = 0, provider = '', sources = ?, scope = '', question_references = NULL WHERE id = ?", [.text("相关资料的读取权限已关闭，回答和引用已移除。你的问题仍保留在历史中。"), try DaybookDatabase.json([DaybookRetrieval.Source]()), .text(cursor)])
                    }
                }
            }
        }
    }

    func reset() throws {
        // Explicit reset clears this domain only and keeps legacy bytes for recovery.
        do {
            let db = try connection()
            try db.transaction {
                try db.execute("DELETE FROM conversations")
                try db.markMigrated("conversations")
            }
            blocked = false
        } catch { throw DaybookConversationFailure.save }
    }
    private static func validate(_ archive: Archive) throws {
            guard archive.version == 1,
                  Set(archive.conversations.map(\.day)).count == archive.conversations.count,
                  Set(archive.conversations.flatMap { $0.turns.map(\.id) }).count == archive.conversations.reduce(0, { $0 + $1.turns.count }) else { throw DaybookConversationFailure.load }
            for thread in archive.conversations {
                guard thread.day.timeIntervalSinceReferenceDate.isFinite, thread.updatedAt.timeIntervalSinceReferenceDate.isFinite,
                      Set(thread.turns.map(\.id)).count == thread.turns.count else { throw DaybookConversationFailure.load }
                for turn in thread.turns {
                    guard turn.question.count <= 300, turn.text.count <= 8_000, turn.provider.count <= 300,
                          turn.sources.count <= 5, turn.sources.allSatisfy({ $0.snippet.count <= 200 && $0.title.count <= 48 }),
                          turn.evidence.dayStart < turn.evidence.dayEnd,
                          turn.evidence.fingerprint.count == 64,
                          turn.createdAt?.timeIntervalSinceReferenceDate.isFinite != false else { throw DaybookConversationFailure.load }
                }
            }
    }
    private static func write(_ conversations: [DaybookConversation], db: DaybookDatabase) throws {
        try db.execute("DELETE FROM conversations")
        for thread in conversations {
            let day = DaybookDatabase.Value.real(thread.day.timeIntervalSinceReferenceDate)
            try db.execute("INSERT INTO conversations VALUES (?, ?)", [day, .real(thread.updatedAt.timeIntervalSinceReferenceDate)])
            for (index, turn) in thread.turns.enumerated() {
                try writeTurn(turn, day: day, position: .integer(Int64(index)), fallbackDate: thread.updatedAt.addingTimeInterval(-Double(thread.turns.count - 1 - index) * 0.000001), db: db)
            }
        }
    }
    private static func writeTurn(_ turn: DaybookConversationTurn, day: DaybookDatabase.Value, position: DaybookDatabase.Value, fallbackDate: Date, db: DaybookDatabase) throws {
        try db.execute("""
            INSERT INTO conversation_turns(id,day,position,question,text,generated,provider,evidence,sources,scope,question_references,state,created_at)
            VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?) ON CONFLICT(id) DO UPDATE SET
            question=excluded.question,text=excluded.text,generated=excluded.generated,provider=excluded.provider,
            evidence=excluded.evidence,sources=excluded.sources,scope=excluded.scope,question_references=excluded.question_references,state=excluded.state
            """, [.text(turn.id.uuidString), day, position, .text(turn.question), .text(turn.text), .integer(turn.generated ? 1 : 0), .text(turn.provider), try DaybookDatabase.json(turn.evidence), try DaybookDatabase.json(turn.sources), .text(turn.scopeDescription), try turn.questionReferenceIDs.map { try DaybookDatabase.json($0) } ?? .null, turn.state.map { .text($0.rawValue) } ?? .null, .real((turn.createdAt ?? fallbackDate).timeIntervalSinceReferenceDate)])
    }

    private static func turn(_ value: DaybookDatabase.Row) throws -> DaybookConversationTurn {
        guard let id = UUID(uuidString: try value.requiredString("id")) else { throw DaybookConversationFailure.load }
        let state = value["state"]?.string.flatMap(DaybookConversationTurn.State.init(rawValue:))
        guard value["state"] == .null || state != nil else { throw DaybookConversationFailure.load }
        let turn = DaybookConversationTurn(id: id, question: try value.requiredString("question"), text: try value.requiredString("text"), generated: value["generated"] == .integer(1), provider: try value.requiredString("provider"), evidence: try DaybookDatabase.decode(DaybookEvidenceSnapshot.self, value["evidence"]), sources: try DaybookDatabase.decode([DaybookRetrieval.Source].self, value["sources"]), scopeDescription: try value.requiredString("scope"), questionReferenceIDs: value["question_references"] == .null ? nil : try DaybookDatabase.decode([Int: UUID].self, value["question_references"]), state: state, createdAt: Date(timeIntervalSinceReferenceDate: try value.requiredDouble("created_at")))
        try validate(Archive(version: 1, conversations: [.init(day: turn.evidence.dayStart, updatedAt: turn.createdAt!, turns: [turn])]))
        return turn
    }
    private static func read(_ db: DaybookDatabase) throws -> [DaybookConversation] {
        try db.transaction {
            try db.query("SELECT * FROM conversations ORDER BY updated_at DESC").map { row in
                let turns = try db.query("SELECT * FROM conversation_turns WHERE day = ? ORDER BY position", [row["day"]!]).map { value -> DaybookConversationTurn in
                    try turn(value)
                }
                return DaybookConversation(day: Date(timeIntervalSinceReferenceDate: try row.requiredDouble("day")), updatedAt: Date(timeIntervalSinceReferenceDate: try row.requiredDouble("updated_at")), turns: turns)
            }
        }
    }
}
