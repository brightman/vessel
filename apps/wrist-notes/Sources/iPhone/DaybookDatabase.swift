import Foundation
import SQLite3

/// Synchronous, serialized SQLite access. Safe from any thread; run expensive work on a worker.
/// A transaction holds the recursive lock until COMMIT/ROLLBACK. Never suspend/await in its body.
/// Values and rows own their bytes; no SQLite statement or pointer escapes this API.
final class DaybookDatabase: @unchecked Sendable {
    enum Value: Equatable, Sendable {
        case null, integer(Int64), real(Double), text(String), blob(Data)
        var string: String? { if case let .text(value) = self { value } else { nil } }
        var double: Double? { switch self { case let .real(value): value; case let .integer(value): Double(value); default: nil } }
        var data: Data? { if case let .blob(value) = self { value } else { nil } }
    }
    struct Failure: LocalizedError {
        let code: Int32
        let detail: String
        var errorDescription: String? { "本机数据库错误（\(code)）：\(detail)" }
    }
    // Every SQL date column uses seconds since 2001-01-01 (Swift reference date).
    // This preserves the exact Double stored by legacy JSON Date archives.
    typealias Row = [String: Value]
    let url: URL
    private let lock = NSRecursiveLock()
    private var handle: OpaquePointer?
    private var transactionDepth = 0
    static var applicationSupportRoot: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("WristNotes", isDirectory: true)
    }
    static var applicationURL: URL {
        applicationSupportRoot.appendingPathComponent("Database/daybook.sqlite3")
    }
    /// Actual app legacy locations share one database. Arbitrary test/archive URLs stay isolated.
    static func url(forLegacy url: URL) -> URL {
        let parent = url.deletingLastPathComponent()
        if ["LifeSources", "Conversations"].contains(parent.lastPathComponent), parent.deletingLastPathComponent().lastPathComponent == "WristNotes" {
            return parent.deletingLastPathComponent().appendingPathComponent("Database/daybook.sqlite3")
        }
        return url.appendingPathExtension("sqlite3")
    }
    static func metadataURL(forRoot root: URL) -> URL {
        let standardized = root.standardizedFileURL
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        if ["VoiceNotes", "PhotoMoments", "DaybookReminders"].contains(where: {
            documents.appendingPathComponent($0, isDirectory: true).standardizedFileURL.path == standardized.path
        }) { return applicationURL }
        return standardized.appendingPathComponent("metadata.sqlite3")
    }
    init(url: URL = DaybookDatabase.applicationURL, inMemory: Bool = false) throws {
        self.url = url
        if !inMemory { try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true) }
        #if os(iOS)
        if !inMemory {
            // HealthKit snapshots share this Application Support tree with conversations and
            // insights. Exclude the whole tree so neither current rows nor legacy JSON migration
            // copies can enter an iCloud device backup. The user's recordings remain in Documents.
            let backupRoot = url.standardizedFileURL == Self.applicationURL.standardizedFileURL
                ? Self.applicationSupportRoot : url.deletingLastPathComponent()
            try Self.excludeFromBackup(backupRoot)
            if backupRoot.standardizedFileURL != url.deletingLastPathComponent().standardizedFileURL {
                try Self.excludeFromBackup(url.deletingLastPathComponent())
            }
        }
        // WatchConnectivity may launch the app after the phone has been locked.
        // Keep the database unavailable before the first unlock after reboot, but
        // allow background receipt to use it after the user has unlocked once.
        if !inMemory { try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: url.deletingLastPathComponent().path) }
        #endif
        let status = sqlite3_open_v2(inMemory ? ":memory:" : url.path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil)
        guard status == SQLITE_OK else { let error = failure(status); sqlite3_close(handle); handle = nil; throw error }
        do {
            sqlite3_extended_result_codes(handle, 1)
            sqlite3_busy_timeout(handle, 5_000)
            try execute("PRAGMA foreign_keys = ON")
            _ = try query("PRAGMA journal_mode = WAL")
            try execute("PRAGMA synchronous = FULL")
            try transaction { try installSchema() }
            #if os(iOS)
            for suffix in ["", "-wal", "-shm", "-journal"] where !inMemory && FileManager.default.fileExists(atPath: url.path + suffix) {
                try Self.excludeFromBackup(URL(fileURLWithPath: url.path + suffix))
                try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: url.path + suffix)
            }
            #endif
        } catch { sqlite3_close(handle); handle = nil; throw error }
    }
    deinit { sqlite3_close(handle) }
    #if os(iOS)
    private static func excludeFromBackup(_ url: URL) throws {
        var target = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try target.setResourceValues(values)
    }
    #endif
    private func failure(_ code: Int32) -> Failure {
        // Do not include bound record content in errors.
        Failure(code: code, detail: handle.map { String(cString: sqlite3_errmsg($0)) } ?? "无法打开数据库")
    }
    /// For extension registration only. Pointer valid during the synchronous locked closure.
    /// Do not retain/close it, dispatch work, or issue transaction control statements here.
    func withConnection<T>(_ body: (OpaquePointer) throws -> T) throws -> T {
        lock.lock(); defer { lock.unlock() }
        guard let handle else { throw Failure(code: SQLITE_MISUSE, detail: "数据库已关闭") }
        return try body(handle)
    }
    private func statement(_ sql: String, _ values: [Value]) throws -> OpaquePointer {
        var statement: OpaquePointer?
        let status = sqlite3_prepare_v2(handle, sql, -1, &statement, nil)
        guard status == SQLITE_OK, let statement else { throw failure(status) }
        do {
            guard sqlite3_bind_parameter_count(statement) == values.count else { throw Failure(code: SQLITE_MISUSE, detail: "绑定参数数量不匹配") }
            let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            for (offset, value) in values.enumerated() {
                let index = Int32(offset + 1), status: Int32
                switch value {
                case .null: status = sqlite3_bind_null(statement, index)
                case let .integer(value): status = sqlite3_bind_int64(statement, index, value)
                case let .real(value):
                    guard value.isFinite else { throw Failure(code: SQLITE_MISMATCH, detail: "日期或数值不是有限值") }
                    status = sqlite3_bind_double(statement, index, value)
                case let .text(value): status = value.withCString { sqlite3_bind_text(statement, index, $0, Int32(value.utf8.count), transient) }
                case let .blob(value): status = value.withUnsafeBytes { bytes in
                    if value.isEmpty { return sqlite3_bind_zeroblob(statement, index, 0) }
                    return sqlite3_bind_blob(statement, index, bytes.baseAddress, Int32(value.count), transient)
                }
                }
                guard status == SQLITE_OK else { throw failure(status) }
            }
            return statement
        } catch { sqlite3_finalize(statement); throw error }
    }
    func execute(_ sql: String, _ values: [Value] = []) throws {
        lock.lock(); defer { lock.unlock() }
        let statement = try statement(sql, values); defer { sqlite3_finalize(statement) }
        let status = sqlite3_step(statement)
        guard status == SQLITE_DONE else { throw failure(status) }
    }
    func query(_ sql: String, _ values: [Value] = []) throws -> [Row] {
        lock.lock(); defer { lock.unlock() }
        let statement = try statement(sql, values); defer { sqlite3_finalize(statement) }
        var rows: [Row] = []
        while true {
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { return rows }
            guard status == SQLITE_ROW else { throw failure(status) }
            var row: Row = [:]
            for index in 0..<sqlite3_column_count(statement) {
                let name = String(cString: sqlite3_column_name(statement, index))
                switch sqlite3_column_type(statement, index) {
                case SQLITE_INTEGER: row[name] = .integer(sqlite3_column_int64(statement, index))
                case SQLITE_FLOAT: row[name] = .real(sqlite3_column_double(statement, index))
                case SQLITE_TEXT:
                    let bytes = sqlite3_column_text(statement, index)!
                    row[name] = .text(String(decoding: UnsafeBufferPointer(start: bytes, count: Int(sqlite3_column_bytes(statement, index))), as: UTF8.self))
                case SQLITE_BLOB:
                    let count = Int(sqlite3_column_bytes(statement, index))
                    row[name] = .blob(count == 0 ? Data() : Data(bytes: sqlite3_column_blob(statement, index)!, count: count))
                default: row[name] = .null
                }
            }
            rows.append(row)
        }
    }
    func transaction<T>(_ body: () throws -> T) throws -> T {
        try transaction(immediate: true, body)
    }
    /// A consistent WAL snapshot for expensive derivation. Other connections may
    /// write while this reads; release it before validating and publishing results.
    func readTransaction<T>(_ body: () throws -> T) throws -> T {
        try transaction(immediate: false, body)
    }
    private func transaction<T>(immediate: Bool, _ body: () throws -> T) throws -> T {
        lock.lock(); defer { lock.unlock() }
        let depth = transactionDepth, savepoint = "daybook_\(depth)"
        try execute(depth == 0 ? (immediate ? "BEGIN IMMEDIATE" : "BEGIN DEFERRED") : "SAVEPOINT \(savepoint)")
        transactionDepth += 1
        defer { transactionDepth -= 1 }
        do {
            let result = try body()
            try execute(depth == 0 ? "COMMIT" : "RELEASE SAVEPOINT \(savepoint)")
            return result
        } catch {
            if depth == 0 { try? execute("ROLLBACK") }
            else { try? execute("ROLLBACK TO SAVEPOINT \(savepoint)"); try? execute("RELEASE SAVEPOINT \(savepoint)") }
            throw error
        }
    }
    func migrate(_ domain: String, importRows: () throws -> Void) throws {
        try transaction {
            guard try query("SELECT domain FROM storage_migrations WHERE domain = ?", [.text(domain)]).isEmpty else { return }
            try importRows()
            try markMigrated(domain)
        }
    }
    func markMigrated(_ domain: String) throws {
        try execute("INSERT OR REPLACE INTO storage_migrations(domain, imported_at) VALUES (?, ?)", [.text(domain), .real(Date.now.timeIntervalSinceReferenceDate)])
    }
    static func json<T: Encodable>(_ value: T) throws -> Value { .blob(try JSONEncoder().encode(value)) }
    static func decode<T: Decodable>(_ type: T.Type, _ value: Value?) throws -> T {
        guard let data = value?.data else { throw Failure(code: SQLITE_CORRUPT, detail: "缺少结构化数据") }
        return try JSONDecoder().decode(type, from: data)
    }
    private func installSchema() throws {
        let version = try query("PRAGMA user_version")[0]["user_version"]?.double ?? -1
        guard version <= 16 else { throw Failure(code: SQLITE_SCHEMA, detail: "数据库版本高于此应用支持的版本") }
        if version < 1 {
            let statements = [
                "CREATE TABLE storage_migrations (domain TEXT PRIMARY KEY, imported_at REAL NOT NULL)",
                "CREATE TABLE life_settings (source TEXT PRIMARY KEY, enabled INTEGER NOT NULL CHECK(enabled IN (0,1)))",
                "CREATE TABLE life_snapshots (source TEXT NOT NULL, day REAL NOT NULL, status TEXT NOT NULL, refreshed_at REAL, message TEXT, stale INTEGER NOT NULL CHECK(stale IN (0,1)), PRIMARY KEY(source,day))",
                "CREATE TABLE life_records (id TEXT PRIMARY KEY, source TEXT NOT NULL, day REAL NOT NULL, captured_at REAL NOT NULL, kind TEXT NOT NULL, title TEXT NOT NULL, text TEXT NOT NULL, summary TEXT NOT NULL, duration REAL NOT NULL, metric REAL, intervals BLOB, FOREIGN KEY(source,day) REFERENCES life_snapshots(source,day) ON DELETE CASCADE)",
                "CREATE INDEX life_records_date_source ON life_records(captured_at,source)",
                "CREATE INDEX life_records_source_day ON life_records(source,day,captured_at,id)",
                "CREATE INDEX life_snapshots_date ON life_snapshots(day,source)",
                "CREATE TABLE life_suppression (id TEXT PRIMARY KEY)",
                "CREATE TABLE conversations (day REAL PRIMARY KEY, updated_at REAL NOT NULL)",
                "CREATE TABLE conversation_turns (id TEXT PRIMARY KEY, day REAL NOT NULL REFERENCES conversations(day) ON DELETE CASCADE, position INTEGER NOT NULL, question TEXT NOT NULL, text TEXT NOT NULL, generated INTEGER NOT NULL CHECK(generated IN (0,1)), provider TEXT NOT NULL, evidence BLOB NOT NULL, sources BLOB NOT NULL, scope TEXT NOT NULL, question_references BLOB, UNIQUE(day,position))",
                "CREATE INDEX conversation_turns_day ON conversation_turns(day,position)",
                "CREATE INDEX conversations_updated ON conversations(updated_at)",
                "CREATE TABLE insight_entries (id TEXT PRIMARY KEY, position INTEGER NOT NULL UNIQUE, day REAL NOT NULL, language TEXT NOT NULL, generation_version INTEGER NOT NULL, evidence BLOB NOT NULL, updated_at REAL NOT NULL, result BLOB, message TEXT, dismissed INTEGER NOT NULL CHECK(dismissed IN (0,1)))",
                "CREATE INDEX insight_entries_day ON insight_entries(day,updated_at)",
                "CREATE TABLE insight_budgets (day REAL PRIMARY KEY, attempts INTEGER NOT NULL CHECK(attempts >= 0), position INTEGER NOT NULL UNIQUE)",
                "PRAGMA user_version = 1"
            ]
            for sql in statements { try execute(sql) }
        }
        // Repair this additive v1 index on every supported version as before.
        try execute("CREATE INDEX IF NOT EXISTS life_records_source_day ON life_records(source,day,captured_at,id)")
        if version < 2 {
            let metadata = [
                "CREATE TABLE IF NOT EXISTS voice_notes (id TEXT PRIMARY KEY, captured_at REAL NOT NULL, kind TEXT NOT NULL, title TEXT NOT NULL, transcript TEXT NOT NULL, summary TEXT NOT NULL, duration REAL NOT NULL CHECK(duration >= 0), audio_filename TEXT NOT NULL UNIQUE, payload BLOB NOT NULL)",
                "CREATE INDEX IF NOT EXISTS voice_notes_date ON voice_notes(captured_at,id)",
                "CREATE TABLE IF NOT EXISTS photo_moments (id TEXT PRIMARY KEY, captured_at REAL NOT NULL, caption TEXT NOT NULL, recognized_text TEXT NOT NULL)",
                "CREATE INDEX IF NOT EXISTS photo_moments_date ON photo_moments(captured_at,id)",
                "CREATE TABLE IF NOT EXISTS photo_attachments (id TEXT PRIMARY KEY, moment_id TEXT NOT NULL REFERENCES photo_moments(id) ON DELETE CASCADE, position INTEGER NOT NULL CHECK(position >= 0 AND position < 6), filename TEXT NOT NULL UNIQUE, recognized_text TEXT NOT NULL, recognition_error TEXT, UNIQUE(moment_id,position))",
                "CREATE TABLE IF NOT EXISTS daybook_reminders (id TEXT PRIMARY KEY, title TEXT NOT NULL, scheduled_at REAL NOT NULL, source_id TEXT, status TEXT NOT NULL, notification_id TEXT NOT NULL UNIQUE, created_at REAL NOT NULL, updated_at REAL NOT NULL)",
                "CREATE INDEX IF NOT EXISTS daybook_reminders_date ON daybook_reminders(scheduled_at,id)",
                "CREATE TABLE IF NOT EXISTS media_tombstones (kind TEXT NOT NULL, id TEXT NOT NULL, filename TEXT NOT NULL, deleted_at REAL NOT NULL, PRIMARY KEY(kind,id))",
                "PRAGMA user_version = 2"
            ]
            for sql in metadata { try execute(sql) }
        }
        if version < 3 {
            try execute("ALTER TABLE photo_moments ADD COLUMN imported_at REAL")
            try execute("ALTER TABLE photo_attachments ADD COLUMN capture BLOB")
            try execute("PRAGMA user_version = 3")
        }
        if version < 4 {
            try execute("CREATE TABLE reminder_apple_links (reminder_id TEXT PRIMARY KEY REFERENCES daybook_reminders(id) ON DELETE CASCADE, payload BLOB NOT NULL)")
            try execute("PRAGMA user_version = 4")
        }
        if version < 5 {
            let recording = [
                "CREATE TABLE IF NOT EXISTS recording_sessions (id TEXT PRIMARY KEY, started_at REAL, time_zone_identifier TEXT, origin BLOB, ended_at REAL, interrupted INTEGER NOT NULL DEFAULT 0 CHECK(interrupted IN (0,1)), final_ordinal INTEGER CHECK(final_ordinal BETWEEN 0 AND 100000), end_revision INTEGER CHECK(end_revision >= 0), end_payload BLOB, legacy_note_id TEXT UNIQUE, created_at REAL NOT NULL)",
                "CREATE INDEX IF NOT EXISTS recording_sessions_date ON recording_sessions(started_at,id)",
                "CREATE TABLE IF NOT EXISTS recording_chunks (id TEXT PRIMARY KEY, session_id TEXT NOT NULL REFERENCES recording_sessions(id) ON DELETE CASCADE, ordinal INTEGER NOT NULL CHECK(ordinal BETWEEN 0 AND 100000), filename TEXT NOT NULL UNIQUE, captured_at REAL NOT NULL, session_start_offset REAL NOT NULL CHECK(session_start_offset >= 0), frame_count INTEGER NOT NULL CHECK(frame_count > 0), sample_rate REAL NOT NULL CHECK(sample_rate > 0), byte_count INTEGER NOT NULL CHECK(byte_count > 0), sha256 TEXT NOT NULL CHECK(length(sha256)=64), payload BLOB NOT NULL, UNIQUE(session_id,ordinal))",
                "CREATE INDEX IF NOT EXISTS recording_chunks_date ON recording_chunks(captured_at,session_id)",
                "CREATE TABLE IF NOT EXISTS recording_gaps (session_id TEXT NOT NULL REFERENCES recording_sessions(id) ON DELETE CASCADE, gap_key TEXT NOT NULL, kind TEXT NOT NULL, first_ordinal INTEGER, last_ordinal INTEGER, start_offset REAL, end_offset REAL, PRIMARY KEY(session_id,gap_key))",
                "CREATE TABLE IF NOT EXISTS recording_session_tombstones (session_id TEXT PRIMARY KEY, deleted_at REAL NOT NULL)",
                "CREATE TABLE IF NOT EXISTS recording_file_cleanup (filename TEXT PRIMARY KEY, session_id TEXT NOT NULL, deleted_at REAL NOT NULL)",
                "PRAGMA user_version = 5"
            ]
            for sql in recording { try execute(sql) }
        }
        if version < 6 {
            let audio = [
                "CREATE TABLE IF NOT EXISTS audio_source_tombstones (source_key TEXT PRIMARY KEY, deleted_at REAL NOT NULL)",
                "CREATE TABLE IF NOT EXISTS audio_processing_sources (source_key TEXT PRIMARY KEY, kind TEXT NOT NULL CHECK(kind IN ('session','legacyNote')), source_id TEXT NOT NULL, session_id TEXT REFERENCES recording_sessions(id) ON DELETE CASCADE, note_id TEXT REFERENCES voice_notes(id) ON DELETE CASCADE, descriptor BLOB NOT NULL, fingerprint TEXT NOT NULL, configuration_key TEXT NOT NULL, revision INTEGER NOT NULL DEFAULT 0, cancelled INTEGER NOT NULL DEFAULT 0 CHECK(cancelled IN (0,1)), CHECK((kind='session' AND session_id=source_id AND note_id IS NULL) OR (kind='legacyNote' AND note_id=source_id AND session_id IS NULL)))",
                "CREATE TABLE IF NOT EXISTS audio_processing_jobs (id TEXT PRIMARY KEY, source_key TEXT NOT NULL REFERENCES audio_processing_sources(source_key) ON DELETE CASCADE, configuration_key TEXT NOT NULL, core_start REAL NOT NULL, core_end REAL NOT NULL, window BLOB NOT NULL, state TEXT NOT NULL CHECK(state IN ('pending','running','completed','missingResource','cancelled','failed')), active INTEGER NOT NULL DEFAULT 1 CHECK(active IN (0,1)), lease TEXT, message TEXT, result BLOB, result_hash TEXT)",
                "CREATE INDEX IF NOT EXISTS audio_jobs_queue ON audio_processing_jobs(state,active,source_key,core_start)",
                "CREATE INDEX IF NOT EXISTS audio_jobs_source_version ON audio_processing_jobs(source_key,configuration_key,active,core_start)",
                "CREATE TABLE IF NOT EXISTS audio_transcript_spans (job_id TEXT NOT NULL REFERENCES audio_processing_jobs(id) ON DELETE CASCADE, position INTEGER NOT NULL, start REAL NOT NULL, end REAL NOT NULL, text TEXT NOT NULL, speaker_id TEXT, PRIMARY KEY(job_id,position))",
                "CREATE INDEX IF NOT EXISTS audio_spans_time ON audio_transcript_spans(job_id,start,end)",
                "CREATE TABLE IF NOT EXISTS audio_activity_intervals (job_id TEXT NOT NULL REFERENCES audio_processing_jobs(id) ON DELETE CASCADE, position INTEGER NOT NULL, start REAL NOT NULL, end REAL NOT NULL, kind TEXT NOT NULL CHECK(kind IN ('speech','noSpeech','uncertain')), PRIMARY KEY(job_id,position))",
                "CREATE INDEX IF NOT EXISTS audio_activity_time ON audio_activity_intervals(job_id,start,end)",
                "CREATE TRIGGER IF NOT EXISTS audio_source_delete BEFORE DELETE ON audio_processing_sources BEGIN INSERT OR IGNORE INTO audio_source_tombstones(source_key,deleted_at) VALUES (OLD.source_key,0); END",
                "CREATE TRIGGER IF NOT EXISTS audio_source_insert BEFORE INSERT ON audio_processing_sources WHEN EXISTS(SELECT 1 FROM audio_source_tombstones WHERE source_key=NEW.source_key) BEGIN SELECT RAISE(ABORT,'audio_source_deleted'); END",
                "CREATE TRIGGER IF NOT EXISTS audio_session_delete BEFORE DELETE ON recording_sessions BEGIN INSERT OR IGNORE INTO audio_source_tombstones(source_key,deleted_at) VALUES ('session:' || OLD.id,0); END",
                "CREATE TRIGGER IF NOT EXISTS audio_note_delete BEFORE DELETE ON voice_notes BEGIN INSERT OR IGNORE INTO audio_source_tombstones(source_key,deleted_at) VALUES ('legacyNote:' || OLD.id,0); END",
                "PRAGMA user_version = 6"
            ]
            for sql in audio { try execute(sql) }
        }
        if version < 7 {
            try execute("CREATE TABLE IF NOT EXISTS audio_speaker_mappings (job_id TEXT NOT NULL REFERENCES audio_processing_jobs(id) ON DELETE CASCADE, local_id TEXT NOT NULL, canonical_id TEXT, feature BLOB NOT NULL, PRIMARY KEY(job_id,local_id))")
            try execute("CREATE TABLE IF NOT EXISTS audio_processing_stage_requests (job_id TEXT PRIMARY KEY REFERENCES audio_processing_jobs(id) ON DELETE CASCADE, stages INTEGER NOT NULL)")
            try execute("PRAGMA user_version = 7")
        }

        if version < 8 {
            let segments = [
                "CREATE TABLE IF NOT EXISTS content_segment_sources (source_key TEXT PRIMARY KEY REFERENCES audio_processing_sources(source_key) ON DELETE CASCADE, signature TEXT NOT NULL, state TEXT NOT NULL, epoch INTEGER NOT NULL DEFAULT 0)",
                "CREATE TABLE IF NOT EXISTS content_segments (id TEXT PRIMARY KEY, source_key TEXT NOT NULL REFERENCES audio_processing_sources(source_key) ON DELETE CASCADE, start REAL NOT NULL, revision INTEGER NOT NULL, deleted INTEGER NOT NULL DEFAULT 0 CHECK(deleted IN (0,1)), payload BLOB NOT NULL)",
                "CREATE INDEX IF NOT EXISTS content_segments_source ON content_segments(source_key,deleted,start,id)",
                "CREATE TABLE IF NOT EXISTS content_segment_ranges (segment_id TEXT NOT NULL REFERENCES content_segments(id) ON DELETE CASCADE, position INTEGER NOT NULL, start REAL NOT NULL, end REAL NOT NULL, payload BLOB NOT NULL, PRIMARY KEY(segment_id,position))",
                "CREATE INDEX IF NOT EXISTS content_segment_range_time ON content_segment_ranges(segment_id,start,end)",
                "CREATE TABLE IF NOT EXISTS content_segment_suppression (id INTEGER PRIMARY KEY, source_key TEXT NOT NULL REFERENCES audio_processing_sources(source_key) ON DELETE CASCADE, start REAL NOT NULL, end REAL NOT NULL)",
                "CREATE INDEX IF NOT EXISTS content_segment_suppression_source ON content_segment_suppression(source_key,start,end)",
                "CREATE TABLE IF NOT EXISTS content_segment_tombstones (id TEXT PRIMARY KEY, source_key TEXT NOT NULL, revision INTEGER NOT NULL)",
                "CREATE TABLE IF NOT EXISTS content_segment_edits (sequence INTEGER PRIMARY KEY AUTOINCREMENT, source_key TEXT NOT NULL REFERENCES audio_processing_sources(source_key) ON DELETE CASCADE, kind TEXT NOT NULL, before_payload BLOB NOT NULL, after_epoch INTEGER NOT NULL, undone INTEGER NOT NULL DEFAULT 0 CHECK(undone IN (0,1)))",
                "CREATE INDEX IF NOT EXISTS content_segment_edits_source ON content_segment_edits(source_key,sequence)",
                "CREATE TRIGGER IF NOT EXISTS content_segments_source_delete BEFORE DELETE ON content_segments BEGIN INSERT OR REPLACE INTO content_segment_tombstones(id,source_key,revision) VALUES (OLD.id,OLD.source_key,OLD.revision); END",
                "PRAGMA user_version = 8"
            ]
            for sql in segments { try execute(sql) }
        }

        if version < 9 {
            try execute("CREATE TABLE IF NOT EXISTS content_enrichment_checkpoints (cache_key TEXT NOT NULL, unit TEXT NOT NULL, source_key TEXT NOT NULL REFERENCES audio_processing_sources(source_key) ON DELETE CASCADE, segment_id TEXT, text TEXT NOT NULL, accepted_revision INTEGER, PRIMARY KEY(cache_key,unit))")
            try execute("CREATE TABLE IF NOT EXISTS content_topic_decisions (source_key TEXT NOT NULL REFERENCES audio_processing_sources(source_key) ON DELETE CASCADE, signature TEXT NOT NULL, position REAL NOT NULL, decision TEXT NOT NULL, model_key TEXT NOT NULL, PRIMARY KEY(source_key,signature,position))")
            try execute("PRAGMA user_version = 9")
        }

        if version < 10 {
            // Keep the existing signature as an enrichment/topic cache key when only locators
            // change. This nullable digest allows exact semantic comparison for older snapshots.
            if try !query("PRAGMA table_info(content_segment_sources)").contains(where: { $0["name"]?.string == "semantic_signature" }) {
                try execute("ALTER TABLE content_segment_sources ADD COLUMN semantic_signature TEXT")
            }
            try execute("PRAGMA user_version = 10")
        }

        if version < 11 {
            try execute("CREATE TABLE IF NOT EXISTS recording_location_samples (id TEXT PRIMARY KEY, session_id TEXT NOT NULL REFERENCES recording_sessions(id) ON DELETE CASCADE, session_offset REAL NOT NULL CHECK(session_offset >= 0), requested_at REAL NOT NULL, payload BLOB NOT NULL)")
            try execute("CREATE INDEX IF NOT EXISTS recording_location_samples_session_time ON recording_location_samples(session_id,session_offset,requested_at,id)")
            try execute("PRAGMA user_version = 11")
        }

        if version < 12 {
            try execute("CREATE TABLE IF NOT EXISTS recording_location_addresses (sample_id TEXT PRIMARY KEY REFERENCES recording_location_samples(id) ON DELETE CASCADE, payload BLOB NOT NULL)")
            try execute("PRAGMA user_version = 12")
        }

        if version < 13 {
            // Rebuildable processed content, separate from immutable original ASR rows.
            // A semantic signature prevents an old artifact representing edited ranges.
            try execute("CREATE TABLE IF NOT EXISTS content_segment_presentations (segment_id TEXT PRIMARY KEY REFERENCES content_segments(id) ON DELETE CASCADE, content_signature TEXT NOT NULL, transcript BLOB NOT NULL)")
            try execute("PRAGMA user_version = 13")
        }

        if version < 14 {
            if try !query("PRAGMA table_info(audio_processing_jobs)").contains(where: { $0["name"]?.string == "retry_count" }) {
                try execute("ALTER TABLE audio_processing_jobs ADD COLUMN retry_count INTEGER NOT NULL DEFAULT 0 CHECK(retry_count >= 0)")
            }
            try execute("PRAGMA user_version = 14")
        }

        if version < 15 {
            // Contact links belong to one processed recording source, not to a
            // transient segment or a global speaker identity.
            try execute("CREATE TABLE IF NOT EXISTS content_speaker_contacts (source_key TEXT NOT NULL REFERENCES audio_processing_sources(source_key) ON DELETE CASCADE, speaker_id TEXT NOT NULL, payload BLOB NOT NULL, PRIMARY KEY(source_key,speaker_id))")
            try execute("PRAGMA user_version = 15")
        }

        if version < 16 {
            try execute("CREATE TABLE IF NOT EXISTS contacts (id TEXT PRIMARY KEY, origin_type TEXT NOT NULL CHECK(origin_type IN ('ios','manual')), system_contact_identifier TEXT, display_name TEXT NOT NULL, organization TEXT, emails_json TEXT NOT NULL DEFAULT '[]', phone_numbers_json TEXT NOT NULL DEFAULT '[]', avatar_thumbnail BLOB, sync_state TEXT NOT NULL CHECK(sync_state IN ('manual','current','needs_refresh','unavailable','missing')), created_at REAL NOT NULL, updated_at REAL NOT NULL, last_synced_at REAL, CHECK((origin_type='ios' AND system_contact_identifier IS NOT NULL AND sync_state IN ('current','needs_refresh','unavailable','missing')) OR (origin_type='manual' AND system_contact_identifier IS NULL AND sync_state='manual')))")
            try execute("CREATE UNIQUE INDEX IF NOT EXISTS contacts_system_identifier ON contacts(system_contact_identifier) WHERE system_contact_identifier IS NOT NULL")
            try execute("CREATE TABLE IF NOT EXISTS recording_speaker_contacts (source_key TEXT NOT NULL REFERENCES audio_processing_sources(source_key) ON DELETE CASCADE, speaker_id TEXT NOT NULL, contact_id TEXT NOT NULL REFERENCES contacts(id) ON DELETE CASCADE, linked_at REAL NOT NULL, speaker_revision TEXT NOT NULL, PRIMARY KEY(source_key,speaker_id))")
            try execute("CREATE INDEX IF NOT EXISTS speaker_contacts_by_contact ON recording_speaker_contacts(contact_id,source_key)")
            try execute("CREATE INDEX IF NOT EXISTS audio_spans_speaker_time ON audio_transcript_spans(speaker_id,start,end)")

            let now = Date.now.timeIntervalSinceReferenceDate
            func contactID(_ snapshot: SpeakerContactSnapshot) -> String {
                snapshot.origin == .ios ? "ios:\(snapshot.identifier)" : snapshot.identifier
            }
            func store(_ snapshot: SpeakerContactSnapshot, sourceKey: String?, speakerID: String?, revision: String) throws {
                let origin = snapshot.origin.rawValue
                let id = contactID(snapshot)
                let name = snapshot.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !id.isEmpty, !name.isEmpty else { return }
                let emails = String(data: try JSONEncoder().encode(snapshot.emails), encoding: .utf8) ?? "[]"
                let phones = String(data: try JSONEncoder().encode(snapshot.phoneNumbers), encoding: .utf8) ?? "[]"
                let state = snapshot.origin == .ios ? SpeakerContactSyncState.current.rawValue : SpeakerContactSyncState.manual.rawValue
                try execute("INSERT INTO contacts(id,origin_type,system_contact_identifier,display_name,organization,emails_json,phone_numbers_json,avatar_thumbnail,sync_state,created_at,updated_at,last_synced_at) VALUES(?,?,?,?,?,?,?,?,?,?,?,?) ON CONFLICT(id) DO UPDATE SET display_name=excluded.display_name,organization=excluded.organization,emails_json=excluded.emails_json,phone_numbers_json=excluded.phone_numbers_json,avatar_thumbnail=excluded.avatar_thumbnail,sync_state=excluded.sync_state,updated_at=excluded.updated_at,last_synced_at=excluded.last_synced_at", [
                    .text(id), .text(origin), snapshot.origin == .ios ? .text(snapshot.identifier) : .null, .text(name), snapshot.organization.map(Value.text) ?? .null,
                    .text(emails), .text(phones), snapshot.thumbnailData.map(Value.blob) ?? .null, .text(state), .real(now), .real(now), snapshot.origin == .ios ? .real(now) : .null
                ])
                guard let sourceKey, let speakerID,
                      try !query("SELECT 1 FROM audio_processing_sources WHERE source_key=?", [.text(sourceKey)]).isEmpty else { return }
                let spans=try query("SELECT j.id,j.result_hash,t.position,t.start,t.end,t.text FROM audio_transcript_spans t JOIN audio_processing_jobs j ON j.id=t.job_id JOIN audio_processing_sources s ON s.source_key=j.source_key WHERE j.source_key=? AND j.active=1 AND j.configuration_key=s.configuration_key AND j.result IS NOT NULL AND t.speaker_id=? ORDER BY t.start,t.end,j.id,t.position",[.text(sourceKey),.text(speakerID)])
                var revisionParts: [String] = []
                revisionParts.reserveCapacity(spans.count * 6)
                for row in spans {
                    revisionParts.append(row["id"]?.string ?? "")
                    revisionParts.append(row["result_hash"]?.string ?? "")
                    revisionParts.append(String(row["position"]?.double ?? 0))
                    revisionParts.append(String(row["start"]?.double ?? 0))
                    revisionParts.append(String(row["end"]?.double ?? 0))
                    revisionParts.append(row["text"]?.string ?? "")
                }
                let currentRevision = spans.isEmpty ? revision : AudioStableID.make(revisionParts)
                try execute("INSERT INTO recording_speaker_contacts(source_key,speaker_id,contact_id,linked_at,speaker_revision) VALUES(?,?,?,?,?) ON CONFLICT(source_key,speaker_id) DO UPDATE SET contact_id=excluded.contact_id,speaker_revision=excluded.speaker_revision", [.text(sourceKey), .text(speakerID), .text(id), .real(now), .text(currentRevision)])
            }

            // Convert the source-scoped snapshot table first. It is retained as a rollback
            // artifact, but the normalized contact/link tables become authoritative.
            for row in try query("SELECT source_key,speaker_id,payload FROM content_speaker_contacts") {
                guard let sourceKey = row["source_key"]?.string, let speakerID = row["speaker_id"]?.string else { continue }
                let snapshot = try DaybookDatabase.decode(SpeakerContactSnapshot.self, row["payload"])
                try store(snapshot, sourceKey: sourceKey, speakerID: speakerID, revision: "legacy")
            }
            // VoiceNote payloads are an older persistence path. Import snapshots and only
            // create a recording relation when the processed source exists; thoughts never
            // become speaker/contact records.
            for row in try query("SELECT payload FROM voice_notes") {
                let note = try DaybookDatabase.decode(VoiceNote.self, row["payload"])
                guard note.kind != .thought, let contacts = note.speakerContacts, !contacts.isEmpty else { continue }
                let sourceKey = AudioSourceID(kind: .legacyNote, id: note.id).key
                for (speakerID, snapshot) in contacts {
                    try store(snapshot, sourceKey: sourceKey, speakerID: speakerID, revision: note.transcriptRevision?.uuidString ?? "legacy")
                }
            }
            try execute("PRAGMA user_version = 16")
        }

    }
}

// Typed reads fail closed when a damaged or incompatible row has unexpected SQLite types.
extension Dictionary where Key == String, Value == DaybookDatabase.Value {
    func requiredString(_ name: String) throws -> String {
        guard let value = self[name]?.string else { throw DaybookDatabase.Failure(code: 11, detail: "数据库文本字段无效：\(name)") }
        return value
    }
    func requiredDouble(_ name: String) throws -> Double {
        guard let value = self[name]?.double, value.isFinite else { throw DaybookDatabase.Failure(code: 11, detail: "数据库数字字段无效：\(name)") }
        return value
    }
    func requiredInt(_ name: String) throws -> Int {
        guard case let .integer(value) = self[name], let number = Int(exactly: value) else { throw DaybookDatabase.Failure(code: 11, detail: "数据库整数字段无效：\(name)") }
        return number
    }
}
