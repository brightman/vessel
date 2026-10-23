import Foundation

struct DesktopLibraryItem: Identifiable, Sendable {
    let deviceID: String
    let deviceName: String
    let transcript: DesktopTranscript
    let summary: DesktopSummary?
    var id: String { deviceID + "|" + transcript.id }
}
struct DesktopDevice: Identifiable, Sendable { let id: String; let name: String; let recordCount: Int }

final class DesktopStore: @unchecked Sendable {
    private let db: SyncSQLite
    init(url: URL) throws {
        db = try SyncSQLite(url: url)
        try db.execute("CREATE TABLE IF NOT EXISTS devices (id TEXT PRIMARY KEY, name TEXT NOT NULL, token_hash TEXT NOT NULL, last_sequence INTEGER NOT NULL DEFAULT 0)")
        try db.execute("CREATE TABLE IF NOT EXISTS revoked_devices (id TEXT PRIMARY KEY, token_hash TEXT NOT NULL)")
        try db.execute("CREATE TABLE IF NOT EXISTS transcripts (device_id TEXT NOT NULL REFERENCES devices(id) ON DELETE CASCADE, id TEXT NOT NULL, content_hash TEXT NOT NULL, payload BLOB NOT NULL, PRIMARY KEY(device_id,id))")
        try db.execute("CREATE TABLE IF NOT EXISTS summaries (sequence INTEGER PRIMARY KEY AUTOINCREMENT, device_id TEXT NOT NULL, record_id TEXT NOT NULL, input_hash TEXT NOT NULL, payload BLOB NOT NULL, UNIQUE(device_id,record_id), FOREIGN KEY(device_id,record_id) REFERENCES transcripts(device_id,id) ON DELETE CASCADE)")
        try db.execute("CREATE TABLE IF NOT EXISTS summary_checkpoints (cache_key TEXT NOT NULL, part INTEGER NOT NULL, text TEXT NOT NULL, PRIMARY KEY(cache_key,part))")
    }
    func pair(deviceID: String, name: String) throws -> String {
        guard UUID(uuidString: deviceID) != nil, !name.isEmpty, name.count <= 128 else { throw DesktopSyncError.invalid("设备身份无效。") }
        let token = DesktopSyncCodec.secret(), hash = DesktopSyncCodec.hash(Data(token.utf8))
        try db.transaction {
            try db.execute("INSERT INTO devices(id,name,token_hash) VALUES (?,?,?) ON CONFLICT(id) DO UPDATE SET name=excluded.name,token_hash=excluded.token_hash", [.text(deviceID), .text(name), .text(hash)])
            try db.execute("DELETE FROM revoked_devices WHERE id=?", [.text(deviceID)])
        }
        return token
    }
    func exchange(_ request: DesktopSyncRequest, serverID: String) throws -> DesktopSyncResponse {
        try db.transaction {
            if request.operation == "unpair", let revoked = try db.query("SELECT token_hash FROM revoked_devices WHERE id=?", [.text(request.deviceID)]).first?["token_hash"]?.string,
               DesktopSyncCodec.tokenMatches(revoked, DesktopSyncCodec.hash(Data(request.credential.utf8))) {
                return DesktopSyncResponse(serverID: serverID)
            }
            let device = try authorized(request)
            if request.operation == "unpair" {
                try rememberRevocation(request.deviceID)
                try db.execute("DELETE FROM devices WHERE id=?", [.text(request.deviceID)])
                try clearCheckpoints(deviceID: request.deviceID)
                return DesktopSyncResponse(serverID: serverID)
            }
            guard request.operation == "exchange", request.events.count <= 50, request.summaryCursor >= 0 else { throw DesktopSyncError.invalid("同步请求无效。") }
            var acknowledged = device["last_sequence"]?.integer ?? 0, previous: Int64 = 0
            for event in request.events {
                guard event.sequence > previous, event.recordID.count <= 160 else { throw DesktopSyncError.invalid("同步顺序无效。") }
                previous = event.sequence
                if let record = event.record { try record.validate(); guard record.id == event.recordID else { throw DesktopSyncError.invalid("录音来源不匹配。") } }
                guard event.sequence > acknowledged else { continue }
                if let record = event.record {
                    let old = try db.query("SELECT content_hash FROM transcripts WHERE device_id=? AND id=?", [.text(request.deviceID), .text(record.id)]).first?["content_hash"]?.string
                    if old != record.contentHash {
                        try db.execute("DELETE FROM summaries WHERE device_id=? AND record_id=?", [.text(request.deviceID), .text(record.id)])
                        try clearCheckpoints(deviceID: request.deviceID, recordID: record.id)
                    }
                    try db.execute("INSERT INTO transcripts(device_id,id,content_hash,payload) VALUES (?,?,?,?) ON CONFLICT(device_id,id) DO UPDATE SET content_hash=excluded.content_hash,payload=excluded.payload", [.text(request.deviceID), .text(record.id), .text(record.contentHash), .blob(try DesktopSyncCodec.encode(record))])
                } else {
                    try db.execute("DELETE FROM transcripts WHERE device_id=? AND id=?", [.text(request.deviceID), .text(event.recordID)])
                    try clearCheckpoints(deviceID: request.deviceID, recordID: event.recordID)
                }
                acknowledged = event.sequence
            }
            try db.execute("UPDATE devices SET last_sequence=? WHERE id=?", [.integer(acknowledged), .text(request.deviceID)])
            let rows = try db.query("SELECT sequence,payload FROM summaries WHERE device_id=? AND sequence>? ORDER BY sequence LIMIT 11", [.text(request.deviceID), .integer(request.summaryCursor)])
            let changes = try rows.prefix(10).map { row -> DesktopSummaryChange in
                guard let data = row["payload"]?.data, let sequence = row["sequence"]?.integer else { throw DesktopSyncError.storage }
                return .init(sequence: sequence, summary: try DesktopSyncCodec.decode(DesktopSummary.self, data))
            }
            return DesktopSyncResponse(serverID: serverID, acknowledged: acknowledged, summaries: changes, hasMoreSummaries: rows.count > 10)
        }
    }
    private func authorized(_ request: DesktopSyncRequest) throws -> SyncSQLite.Row {
        guard let row = try db.query("SELECT * FROM devices WHERE id=?", [.text(request.deviceID)]).first,
              let hash = row["token_hash"]?.string,
              DesktopSyncCodec.tokenMatches(hash, DesktopSyncCodec.hash(Data(request.credential.utf8))) else { throw DesktopSyncError.unauthorized }
        return row
    }
    func items() throws -> [DesktopLibraryItem] {
        let rows = try db.query("SELECT t.*,d.name,s.payload AS summary FROM transcripts t JOIN devices d ON d.id=t.device_id LEFT JOIN summaries s ON s.device_id=t.device_id AND s.record_id=t.id")
        return try rows.map { row in
            guard let data = row["payload"]?.data, let deviceID = row["device_id"]?.string else { throw DesktopSyncError.storage }
            let record = try DesktopSyncCodec.decode(DesktopTranscript.self, data)
            let summary = try row["summary"]?.data.map { try DesktopSyncCodec.decode(DesktopSummary.self, $0) }
            return DesktopLibraryItem(deviceID: deviceID, deviceName: row["name"]?.string ?? "iPhone", transcript: record,
                summary: summary?.inputHash == record.contentHash ? summary : nil)
        }.sorted { $0.transcript.capturedAt > $1.transcript.capturedAt }
    }
    func isCurrent(_ item: DesktopLibraryItem) throws -> Bool {
        try db.query("SELECT content_hash FROM transcripts WHERE device_id=? AND id=?", [.text(item.deviceID), .text(item.transcript.id)]).first?["content_hash"]?.string == item.transcript.contentHash
    }
    func save(_ summary: DesktopSummary, item: DesktopLibraryItem) throws {
        try summary.validate()
        try db.transaction {
            guard summary.recordID == item.transcript.id, summary.inputHash == item.transcript.contentHash, try isCurrent(item) else { throw CancellationError() }
            try db.execute("DELETE FROM summaries WHERE device_id=? AND record_id=?", [.text(item.deviceID), .text(summary.recordID)])
            try db.execute("INSERT INTO summaries(device_id,record_id,input_hash,payload) VALUES (?,?,?,?)", [.text(item.deviceID), .text(summary.recordID), .text(summary.inputHash), .blob(try DesktopSyncCodec.encode(summary))])
        }
    }
    func devices() throws -> [DesktopDevice] {
        try db.query("SELECT d.id,d.name,count(t.id) AS count FROM devices d LEFT JOIN transcripts t ON t.device_id=d.id GROUP BY d.id ORDER BY d.name").map {
            DesktopDevice(id: $0["id"]?.string ?? "", name: $0["name"]?.string ?? "iPhone", recordCount: Int($0["count"]?.integer ?? 0))
        }
    }
    func revoke(_ id: String) throws {
        try db.transaction { try rememberRevocation(id); try db.execute("DELETE FROM devices WHERE id=?", [.text(id)]); try clearCheckpoints(deviceID: id) }
    }
    private func rememberRevocation(_ id: String) throws {
        try db.execute("INSERT OR REPLACE INTO revoked_devices(id,token_hash) SELECT id,token_hash FROM devices WHERE id=?", [.text(id)])
    }
    private func clearCheckpoints(deviceID: String, recordID: String? = nil) throws {
        let prefix = deviceID + "|" + (recordID.map { $0 + "|" } ?? "")
        try db.execute("DELETE FROM summary_checkpoints WHERE substr(cache_key,1,length(?))=?", [.text(prefix), .text(prefix)])
    }
    func checkpoint(key: String, part: Int) throws -> String? {
        try db.query("SELECT text FROM summary_checkpoints WHERE cache_key=? AND part=?", [.text(key), .integer(Int64(part))]).first?["text"]?.string
    }
    func checkpoint(key: String, part: Int, text: String, item: DesktopLibraryItem) throws {
        try db.transaction {
            guard try isCurrent(item) else { throw CancellationError() }
            try db.execute("INSERT OR REPLACE INTO summary_checkpoints(cache_key,part,text) VALUES (?,?,?)", [.text(key), .integer(Int64(part)), .text(text)])
        }
    }
}
