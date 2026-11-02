import Foundation

/// Results survive source deletion. The batch and action outbox are committed together.
final class FlashCaptureRepository {
    private let db: DaybookDatabase
    private let actions: ActionRepository
    init(database: DaybookDatabase) throws {
        db = database; actions = try ActionRepository(database: database)
        try db.migrate("flash-notebook-v1") {
            try db.execute("CREATE TABLE flash_batches(source_id TEXT PRIMARY KEY,payload BLOB NOT NULL)")
            try db.execute("CREATE TABLE flash_assets(id TEXT PRIMARY KEY,source_id TEXT NOT NULL,kind TEXT NOT NULL,captured_at REAL NOT NULL,revision INTEGER NOT NULL,revoked INTEGER NOT NULL,ready INTEGER NOT NULL,currency TEXT,direction TEXT,amount_minor INTEGER,payload BLOB NOT NULL)")
            try db.execute("CREATE INDEX flash_assets_library ON flash_assets(kind,captured_at DESC)")
            try db.execute("CREATE INDEX flash_assets_source ON flash_assets(source_id)")
        }
    }
    func seedHistory(_ ids: [UUID]) throws {
        try db.migrate("flash-notebook-history-v1") {
            for id in ids where try batch(id) == nil { try setBatch(.init(sourceID: id, state: .historical)) }
        }
    }
    func isHistorical(_ capturedAt: Date) throws -> Bool {
        guard let row = try db.query("SELECT imported_at FROM storage_migrations WHERE domain='flash-notebook-v1'").first else { return true }
        return capturedAt.timeIntervalSinceReferenceDate < (try row.requiredDouble("imported_at"))
    }
    func batch(_ id: UUID) throws -> FlashBatch? {
        try db.query("SELECT payload FROM flash_batches WHERE source_id=?", [.text(id.uuidString)]).first.map { try DaybookDatabase.decode(FlashBatch.self, $0["payload"]) }
    }
    func setBatch(_ batch: FlashBatch) throws {
        try db.execute("INSERT INTO flash_batches(source_id,payload) VALUES(?,?) ON CONFLICT(source_id) DO UPDATE SET payload=excluded.payload", [.text(batch.sourceID.uuidString), try DaybookDatabase.json(batch)])
    }
    func batches() throws -> [FlashBatch] { try db.query("SELECT payload FROM flash_batches").map { try DaybookDatabase.decode(FlashBatch.self, $0["payload"]) } }
    func assets() throws -> [FlashAsset] {
        try db.query("SELECT payload FROM flash_assets ORDER BY captured_at DESC,id").map { try DaybookDatabase.decode(FlashAsset.self, $0["payload"]) }
    }
    func commit(_ value: FlashExtraction, source: ActionSource, allowsActions: Bool = true) throws {
        try db.transaction {
            guard try batch(source.id)?.state != .complete else { return }
            for asset in value.assets { _ = try save(asset) }
            for var action in value.actions {
                if !allowsActions { action.sync = .failed; action.syncError = "历史闪念：尚未执行，请编辑后保存以安排。" }
                _ = try actions.save(action)
            }
            try setBatch(.init(sourceID: source.id, state: .complete, allowsAutomaticActions: allowsActions))
        }
    }
    @discardableResult func save(_ asset: FlashAsset) throws -> FlashAsset {
        try asset.validate()
        return try db.transaction {
            let revision = try db.query("SELECT revision FROM flash_assets WHERE id=?", [.text(asset.id.uuidString)]).first?["revision"]?.double ?? 0
            guard Int(revision) == asset.revision else { throw ActionFailure.changed }
            var next = asset; next.revision += 1
            try db.execute("INSERT INTO flash_assets(id,source_id,kind,captured_at,revision,revoked,ready,currency,direction,amount_minor,payload) VALUES(?,?,?,?,?,?,?,?,?,?,?) ON CONFLICT(id) DO UPDATE SET revision=excluded.revision,revoked=excluded.revoked,ready=excluded.ready,currency=excluded.currency,direction=excluded.direction,amount_minor=excluded.amount_minor,payload=excluded.payload", [
                .text(next.id.uuidString), .text(next.source.id.uuidString), .text(next.kind.rawValue), .real(next.source.capturedAt.timeIntervalSinceReferenceDate), .integer(Int64(next.revision)), .integer(next.revoked ? 1 : 0), .integer(next.ready ? 1 : 0), next.currency.map(DaybookDatabase.Value.text) ?? .null, next.direction.map { .text($0.rawValue) } ?? .null, next.amountMinor.map(DaybookDatabase.Value.integer) ?? .null, try DaybookDatabase.json(next)])
            return next
        }
    }
    func totals() throws -> [FlashCurrencyTotal] {
        try db.query("SELECT currency,SUM(CASE WHEN direction='income' THEN amount_minor ELSE 0 END) AS income,SUM(CASE WHEN direction='expense' THEN amount_minor ELSE 0 END) AS expense FROM flash_assets WHERE kind='expense' AND revoked=0 AND ready=1 GROUP BY currency ORDER BY currency").map {
            FlashCurrencyTotal(currency: try $0.requiredString("currency"), income: Int64(try $0.requiredInt("income")), expense: Int64(try $0.requiredInt("expense")))
        }
    }
}
