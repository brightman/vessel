import Foundation

/// A date archive, not the capped insights cache. No transcripts or credentials are stored here.
final class DaybookRecapStore {
    private var database: DaybookDatabase?
    init(database: DaybookDatabase? = nil) { self.database = database }
    private func connection() throws -> DaybookDatabase {
        let db = try database ?? DaybookDatabase()
        database = db
        try db.migrate("daily-recaps-v1") {
            try db.execute("CREATE TABLE daily_recaps (day TEXT PRIMARY KEY, payload BLOB NOT NULL)")
        }
        try db.migrate("daily-recap-attempts-v1") {
            try db.execute("CREATE TABLE daily_recap_attempts (day TEXT PRIMARY KEY, started_at REAL NOT NULL)")
            // Existing archives already suppress automatic generation. Preserve that
            // budget independently when evidence validation replaces their payload.
            try db.execute("INSERT INTO daily_recap_attempts(day,started_at) SELECT day,? FROM daily_recaps", [.real(Date.now.timeIntervalSinceReferenceDate)])
        }
        return db
    }
    func load() throws -> [DaybookRecapEntry] {
        try connection().query("SELECT payload FROM daily_recaps ORDER BY day DESC").map {
            let entry = try DaybookDatabase.decode(DaybookRecapEntry.self, $0["payload"])
            try Self.validate(entry); return entry
        }
    }
    func save(_ entry: DaybookRecapEntry) throws {
        try Self.validate(entry)
        let db = try connection()
        try db.transaction {
            try db.execute("INSERT INTO daily_recaps(day,payload) VALUES (?,?) ON CONFLICT(day) DO UPDATE SET payload=excluded.payload",
                [.text(entry.dayKey), try DaybookDatabase.json(entry)])
        }
    }
    /// Claim the date and save the crash/relaunch marker atomically before inference.
    /// Manual attempts always remain available and also suppress later automatic work.
    func beginAttempt(_ entry: DaybookRecapEntry, automatic: Bool) throws -> Bool {
        try Self.validate(entry)
        let db = try connection()
        return try db.transaction {
            if automatic, try !db.query("SELECT day FROM daily_recap_attempts WHERE day=?", [.text(entry.dayKey)]).isEmpty { return false }
            try db.execute("INSERT OR IGNORE INTO daily_recap_attempts(day,started_at) VALUES (?,?)", [.text(entry.dayKey), .real(Date.now.timeIntervalSinceReferenceDate)])
            try db.execute("INSERT INTO daily_recaps(day,payload) VALUES (?,?) ON CONFLICT(day) DO UPDATE SET payload=excluded.payload",
                [.text(entry.dayKey), try DaybookDatabase.json(entry)])
            return true
        }
    }
    func remove(_ day: String) throws { try connection().execute("DELETE FROM daily_recaps WHERE day=?", [.text(day)]) }
    private static func validate(_ entry: DaybookRecapEntry) throws {
        guard entry.dayKey.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil,
              entry.scope.start < entry.scope.end, entry.scope.duration <= 27 * 3600,
              Set(entry.references.map(\.id)).count == entry.references.count else { throw DaybookRecapFailure.storage }
        if let text = entry.text {
            try DaybookRecapInput.validate(text, sourceNumbers: Set(entry.references.compactMap(\.number)))
        }
    }
}
