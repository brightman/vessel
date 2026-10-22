import Foundation

/// Sync evidence survives relaunch and note deletion, scoped to the system pairing directory.
/// Only call recordSaved after the recording has been durably imported.
final class WatchSyncStore {
    struct Summary {
        var pendingCount: Int?
        var lastSyncedAt: Date?
        var reportedAt: Date?
        var transferFailureCount = 0
        var missingFileCount = 0
    }
    private let db: DaybookDatabase

    init(database: DaybookDatabase) throws {
        db = database
        try db.transaction {
            try db.execute("CREATE TABLE IF NOT EXISTS watch_sync_snapshots (pairing_id TEXT PRIMARY KEY, updated_at REAL NOT NULL)")
            try db.execute("CREATE TABLE IF NOT EXISTS watch_sync_pending (pairing_id TEXT NOT NULL REFERENCES watch_sync_snapshots(pairing_id) ON DELETE CASCADE, id TEXT NOT NULL, PRIMARY KEY(pairing_id,id))")
            try db.execute("CREATE TABLE IF NOT EXISTS watch_sync_receipts (pairing_id TEXT NOT NULL, id TEXT NOT NULL, saved_at REAL NOT NULL, PRIMARY KEY(pairing_id,id))")
            try db.execute("CREATE INDEX IF NOT EXISTS watch_sync_receipts_time ON watch_sync_receipts(pairing_id,saved_at DESC)")
            try db.execute("CREATE TABLE IF NOT EXISTS watch_sync_failures (pairing_id TEXT NOT NULL, id TEXT NOT NULL, reason TEXT NOT NULL, PRIMARY KEY(pairing_id,id), FOREIGN KEY(pairing_id,id) REFERENCES watch_sync_pending(pairing_id,id) ON DELETE CASCADE)")
        }
    }

    // V2 tables are projections of committed repository receipts, never generic V1 IDs.
    private func prepareV2() throws {
        try db.execute("CREATE TABLE IF NOT EXISTS watch_session_sync_snapshot (counterpart TEXT PRIMARY KEY, updated_at REAL NOT NULL, payload TEXT NOT NULL)")
        try db.execute("CREATE TABLE IF NOT EXISTS watch_session_sync_chunk (counterpart TEXT NOT NULL, session_id TEXT NOT NULL, chunk_id TEXT NOT NULL, ordinal INTEGER NOT NULL, saved_at REAL NOT NULL, PRIMARY KEY(counterpart,chunk_id), UNIQUE(counterpart,session_id,ordinal))")
        try db.execute("CREATE TABLE IF NOT EXISTS watch_session_sync_end (counterpart TEXT NOT NULL, session_id TEXT NOT NULL, payload TEXT NOT NULL, PRIMARY KEY(counterpart,session_id))")
    }
    func apply(_ snapshot: WatchSessionSyncSnapshot, counterpartID: String) throws {
        try db.transaction {
            try prepareV2()
            let previous = try db.query("SELECT updated_at FROM watch_session_sync_snapshot WHERE counterpart=?", [.text(counterpartID)]).first?["updated_at"]?.double
            guard previous == nil || snapshot.updatedAt.timeIntervalSinceReferenceDate > previous! else { return }
            try db.execute("INSERT INTO watch_session_sync_snapshot(counterpart,updated_at,payload) VALUES (?,?,?) ON CONFLICT(counterpart) DO UPDATE SET updated_at=excluded.updated_at,payload=excluded.payload", [.text(counterpartID), .real(snapshot.updatedAt.timeIntervalSinceReferenceDate), try DaybookDatabase.json(snapshot)])
        }
    }
    func recordSaved(_ saved: RecordingSavedChunk, counterpartID: String) throws {
        try saved.validate()
        try db.transaction {
            try prepareV2()
            let r = saved.receipt
            try db.execute("INSERT OR IGNORE INTO watch_session_sync_chunk(counterpart,session_id,chunk_id,ordinal,saved_at) VALUES (?,?,?,?,?)", [.text(counterpartID), .text(r.sessionID.uuidString), .text(r.chunkID.uuidString), .integer(Int64(r.ordinal)), .real(saved.savedAt.timeIntervalSinceReferenceDate)])
        }
    }
    func recordEnd(_ end: RecordingSessionEnd, counterpartID: String) throws {
        try db.transaction {
            try prepareV2()
            if let row = try db.query("SELECT payload FROM watch_session_sync_end WHERE counterpart=? AND session_id=?", [.text(counterpartID), .text(end.sessionID.uuidString)]).first {
                let old = try DaybookDatabase.decode(RecordingSessionEnd.self, row["payload"])
                if old.revision > end.revision { return }
                guard old.revision != end.revision || old == end else { throw RecordingTransportError.conflict }
            }
            try db.execute("INSERT INTO watch_session_sync_end(counterpart,session_id,payload) VALUES (?,?,?) ON CONFLICT(counterpart,session_id) DO UPDATE SET payload=excluded.payload", [.text(counterpartID), .text(end.sessionID.uuidString), try DaybookDatabase.json(end)])
        }
    }
    func readSessions(counterpartID: String) throws -> Summary {
        try db.transaction {
            try prepareV2()
            let values: [DaybookDatabase.Value] = [.text(counterpartID)]
            let row = try db.query("SELECT updated_at,payload FROM watch_session_sync_snapshot WHERE counterpart=?", values).first
            let snapshot = try row.map { try DaybookDatabase.decode(WatchSessionSyncSnapshot.self, $0["payload"]) }
            var pending = 0
            for item in snapshot?.pending ?? [] {
                guard let end = item.end,
                      let row = try db.query("SELECT payload FROM watch_session_sync_end WHERE counterpart=? AND session_id=?", values + [.text(item.sessionID.uuidString)]).first,
                      try DaybookDatabase.decode(RecordingSessionEnd.self, row["payload"]) == end else { pending += 1; continue }
                let coverage = try db.query("SELECT COUNT(*) AS count, MIN(ordinal) AS first, MAX(ordinal) AS last FROM watch_session_sync_chunk WHERE counterpart=? AND session_id=?", values + [.text(item.sessionID.uuidString)]).first!
                let count = Int(coverage["count"]?.double ?? 0)
                let complete = end.finalOrdinal.map { count == $0 + 1 && coverage["first"]?.double == 0 && coverage["last"]?.double == Double($0) } ?? (count == 0)
                if !complete || item.lastOrdinal != end.finalOrdinal { pending += 1 }
            }
            let last = try db.query("SELECT MAX(saved_at) AS saved FROM watch_session_sync_chunk WHERE counterpart=?", values).first?["saved"]?.double
            return Summary(pendingCount: snapshot == nil ? nil : pending,
                           lastSyncedAt: last.map(Date.init(timeIntervalSinceReferenceDate:)), reportedAt: snapshot?.updatedAt)
        }
    }

    func apply(_ snapshot: WatchSyncSnapshot, pairingID: String) throws {
        guard snapshot.updatedAt.timeIntervalSinceReferenceDate.isFinite else { return }
        try db.transaction {
            let values: [DaybookDatabase.Value] = [.text(pairingID)]
            let previous = try db.query("SELECT updated_at FROM watch_sync_snapshots WHERE pairing_id=?", values).first?["updated_at"]?.double
            guard previous == nil || snapshot.updatedAt.timeIntervalSinceReferenceDate > previous! else { return }
            try db.execute("INSERT INTO watch_sync_snapshots(pairing_id,updated_at) VALUES (?,?) ON CONFLICT(pairing_id) DO UPDATE SET updated_at=excluded.updated_at", values + [.real(snapshot.updatedAt.timeIntervalSinceReferenceDate)])
            try db.execute("DELETE FROM watch_sync_pending WHERE pairing_id=?", values)
            for id in Set(snapshot.pendingIDs) {
                try db.execute("INSERT INTO watch_sync_pending(pairing_id,id) VALUES (?,?)", values + [.text(id.uuidString)])
            }
            let pending = Set(snapshot.pendingIDs)
            for failure in snapshot.failures ?? [] where pending.contains(failure.id) {
                try db.execute("INSERT OR REPLACE INTO watch_sync_failures(pairing_id,id,reason) VALUES (?,?,?)", values + [.text(failure.id.uuidString), .text(failure.reason.rawValue)])
            }
        }
    }

    func recordSaved(_ id: UUID, at date: Date = .now, pairingID: String) throws {
        try db.execute("INSERT OR IGNORE INTO watch_sync_receipts(pairing_id,id,saved_at) VALUES (?,?,?)", [.text(pairingID), .text(id.uuidString), .real(date.timeIntervalSinceReferenceDate)])
    }

    func read(pairingID: String) throws -> Summary {
        try db.transaction {
            let values: [DaybookDatabase.Value] = [.text(pairingID)]
            let reported = try db.query("SELECT updated_at FROM watch_sync_snapshots WHERE pairing_id=?", values).first?["updated_at"]?.double
            let count = try db.query("SELECT COUNT(*) AS count FROM watch_sync_pending p WHERE pairing_id=? AND NOT EXISTS (SELECT 1 FROM watch_sync_receipts r WHERE r.pairing_id=p.pairing_id AND r.id=p.id)", values).first?["count"]?.double
            let last = try db.query("SELECT saved_at FROM watch_sync_receipts WHERE pairing_id=? ORDER BY saved_at DESC LIMIT 1", values).first?["saved_at"]?.double
            let failures = try db.query("SELECT reason,COUNT(*) AS count FROM watch_sync_failures f WHERE pairing_id=? AND NOT EXISTS (SELECT 1 FROM watch_sync_receipts r WHERE r.pairing_id=f.pairing_id AND r.id=f.id) GROUP BY reason", values)
            return Summary(pendingCount: reported == nil ? nil : count.map(Int.init),
                           lastSyncedAt: last.map(Date.init(timeIntervalSinceReferenceDate:)),
                           reportedAt: reported.map(Date.init(timeIntervalSinceReferenceDate:)),
                           transferFailureCount: Int(failures.first { $0["reason"]?.string == "transferFailed" }?["count"]?.double ?? 0),
                           missingFileCount: Int(failures.first { $0["reason"]?.string == "fileMissing" }?["count"]?.double ?? 0))
        }
    }
}
