import Foundation

/// Source projections and the outbound journal share the phone's existing SQLite transaction.
final class PhoneDesktopSyncRepository {
    let db: DaybookDatabase
    init(database: DaybookDatabase) { db = database }
    func deviceID() throws -> String {
        try db.transaction {
            if let id = try db.query("SELECT id FROM desktop_sync_identity LIMIT 1").first?["id"]?.string { return id }
            let id = UUID().uuidString
            try db.execute("INSERT INTO desktop_sync_identity(id) VALUES (?)", [.text(id)])
            return id
        }
    }
    func reconcile() throws {
        try db.transaction {
            for row in try db.query("SELECT source_key FROM desktop_sync_dirty ORDER BY source_key") {
                let key = try row.requiredString("source_key"), record = try project(key)
                let old = try db.query("SELECT content_hash FROM desktop_sync_projection WHERE record_id=?", [.text(key)]).first?["content_hash"]?.string
                if let record {
                    try record.validate()
                    if old != record.contentHash {
                        let payload = try DesktopSyncCodec.encode(record)
                        try db.execute("INSERT OR REPLACE INTO desktop_sync_projection(record_id,content_hash,payload) VALUES (?,?,?)", [.text(key), .text(record.contentHash), .blob(payload)])
                        // Coalesce intermediate revisions without retaining deleted transcript text.
                        try db.execute("DELETE FROM desktop_sync_events WHERE record_id=?", [.text(key)])
                        try db.execute("INSERT INTO desktop_sync_events(record_id,payload) VALUES (?,?)", [.text(key), .blob(payload)])
                        try db.execute("DELETE FROM desktop_summaries WHERE record_id=? AND input_hash<>?", [.text(key), .text(record.contentHash)])
                    }
                } else if old != nil {
                    try db.execute("DELETE FROM desktop_sync_projection WHERE record_id=?", [.text(key)])
                    try db.execute("DELETE FROM desktop_summaries WHERE record_id=?", [.text(key)])
                    try db.execute("DELETE FROM desktop_sync_events WHERE record_id=?", [.text(key)])
                    try db.execute("INSERT INTO desktop_sync_events(record_id,payload) VALUES (?,NULL)", [.text(key)])
                }
                try db.execute("DELETE FROM desktop_sync_dirty WHERE source_key=?", [.text(key)])
            }
        }
    }
    func project(_ key: String) throws -> DesktopTranscript? {
        let pieces = key.split(separator: ":", maxSplits: 1)
        guard pieces.count == 2, let uuid = UUID(uuidString: String(pieces[1])) else { return nil }
        let processing = AudioProcessingRepository(database: db)
        if pieces[0] == "legacyNote" {
            guard let row = try db.query("SELECT payload FROM voice_notes WHERE id=?", [.text(uuid.uuidString)]).first else { return nil }
            let note = try DaybookDatabase.decode(VoiceNote.self, row["payload"])
            if !note.transcript.isEmpty || note.transcriptRevision != nil || note.transcriptionState == .ready {
                let spans = (note.transcriptSegments ?? []).map { span in
                    DesktopTranscriptSpan(id: span.id.uuidString, start: span.start, end: span.end,
                        speaker: span.speakerID.map { "说话人 " + $0.replacingOccurrences(of: "speaker-", with: "") }, text: span.text)
                }
                return .init(id: key, title: note.displayTitle, capturedAt: note.capturedAt, duration: note.duration,
                    captureDevice: note.origin?.device ?? "未知设备", kind: note.kind.rawValue, text: note.transcript, spans: spans,
                    isFinal: note.transcriptionState == .ready && note.diarizationState != .running)
            }
            if let source = try processing.currentSource(.init(kind: .legacyNote, id: uuid)) { return try project(source, processing: processing) }
            return .init(id: key, title: note.displayTitle, capturedAt: note.capturedAt, duration: note.duration,
                captureDevice: note.origin?.device ?? "未知设备", kind: note.kind.rawValue, text: "", spans: [], isFinal: false)
        }
        guard pieces[0] == "session", try !db.query("SELECT id FROM recording_sessions WHERE id=?", [.text(uuid.uuidString)]).isEmpty,
              let source = try processing.currentSource(.init(kind: .session, id: uuid)) else { return nil }
        return try project(source, processing: processing)
    }
    private func project(_ source: AudioSourceSnapshot, processing: AudioProcessingRepository) throws -> DesktopTranscript {
        var spans: [DesktopTranscriptSpan] = [], offset = 0
        while true {
            let page = try processing.spans(sourceID: source.id, limit: 500, offset: offset)
            for (index, span) in page.enumerated() {
                spans.append(.init(id: "span-\(offset + index)", start: span.start, end: span.end,
                    speaker: span.speakerID.map { "说话人 " + $0.replacingOccurrences(of: "speaker-", with: "") }, text: span.text))
            }
            offset += page.count; if page.count < 500 { break }
        }
        let progress = try processing.progress(sourceID: source.id), results = try processing.results(sourceID: source.id)
        let count = progress.states.values.reduce(0, +)
        let final = source.complete && count > 0 && results.count == count && results.allSatisfy { $0.asr == .success }
        return .init(id: source.id.key, title: source.title.isEmpty ? "完整录音" : source.title, capturedAt: source.capturedAt,
            duration: source.ranges.last?.end ?? 0, captureDevice: source.origin?.device ?? "Apple Watch", kind: "long",
            text: spans.map(\.text).joined(separator: "\n"), spans: spans, isFinal: final)
    }
    struct State { let acknowledged: Int64; let cursor: Int64; let lastSynced: Date?; let pending: Int }
    func state(serverID: String) throws -> State {
        try db.execute("INSERT OR IGNORE INTO desktop_sync_peers(server_id) VALUES (?)", [.text(serverID)])
        let row = try db.query("SELECT * FROM desktop_sync_peers WHERE server_id=?", [.text(serverID)]).first!
        let acknowledged = Int64(try row.requiredInt("acknowledged"))
        let pending = try db.query("SELECT count(*) AS count FROM desktop_sync_events WHERE sequence>?", [.integer(acknowledged)]).first!.requiredInt("count")
        return State(acknowledged: acknowledged, cursor: Int64(try row.requiredInt("summary_cursor")), lastSynced: row["last_synced"]?.double.map(Date.init(timeIntervalSinceReferenceDate:)), pending: pending)
    }
    func events(after sequence: Int64) throws -> [DesktopSyncEvent] {
        let rows = try db.query("SELECT * FROM desktop_sync_events WHERE sequence>? ORDER BY sequence LIMIT 20", [.integer(sequence)])
        var events: [DesktopSyncEvent] = [], bytes = 0
        for row in rows {
            let payload = row["payload"]?.data
            if !events.isEmpty && bytes + (payload?.count ?? 0) > 6_000_000 { break }
            events.append(.init(sequence: Int64(try row.requiredInt("sequence")), recordID: try row.requiredString("record_id"),
                record: try payload.map { try DesktopSyncCodec.decode(DesktopTranscript.self, $0) }))
            bytes += payload?.count ?? 0
        }
        return events
    }
    func accept(_ response: DesktopSyncResponse, serverID: String, maximumSent: Int64) throws {
        try db.transaction {
            let state = try state(serverID: serverID)
            guard response.acknowledged >= state.acknowledged, response.acknowledged <= maximumSent else { throw DesktopSyncError.invalid("同步确认版本不匹配，请重新配对。") }
            var cursor = state.cursor
            for change in response.summaries {
                guard change.sequence > cursor else { continue }
                try change.summary.validate()
                if let record = try project(change.summary.recordID), record.isFinal, record.contentHash == change.summary.inputHash {
                    try db.execute("INSERT OR REPLACE INTO desktop_summaries(record_id,input_hash,payload) VALUES (?,?,?)", [.text(record.id), .text(record.contentHash), .blob(try DesktopSyncCodec.encode(change.summary))])
                }
                cursor = change.sequence
            }
            try db.execute("UPDATE desktop_sync_peers SET acknowledged=?,summary_cursor=?,last_synced=? WHERE server_id=?", [.integer(response.acknowledged), .integer(cursor), .real(Date.now.timeIntervalSinceReferenceDate), .text(serverID)])
        }
    }
    func summaries() throws -> [String: DesktopSummary] {
        try db.transaction {
            try reconcile()
            var values: [String: DesktopSummary] = [:]
            for row in try db.query("SELECT record_id,payload FROM desktop_summaries") {
                let summary = try DesktopSyncCodec.decode(DesktopSummary.self, row["payload"]?.data ?? Data())
                if let record = try project(summary.recordID), record.isFinal, record.contentHash == summary.inputHash { values[summary.recordID] = summary }
            }
            return values
        }
    }
    func resetPeer(_ serverID: String) throws {
        try db.transaction {
            try db.execute("DELETE FROM desktop_sync_peers WHERE server_id=?", [.text(serverID)])
            try db.execute("DELETE FROM desktop_summaries")
        }
    }
}
