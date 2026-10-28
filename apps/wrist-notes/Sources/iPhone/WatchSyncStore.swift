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
