import Foundation
import SQLite3

/// Small, independent desktop database; the phone uses its existing database for the sync journal.
final class SyncSQLite: @unchecked Sendable {
    enum Value { case text(String), integer(Int64), blob(Data), null }
    typealias Row = [String: Value]
    private var handle: OpaquePointer?
    private let lock = NSRecursiveLock()
    init(url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        guard sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else { throw DesktopSyncError.storage }
        sqlite3_busy_timeout(handle, 5000)
        try execute("PRAGMA journal_mode=WAL"); try execute("PRAGMA synchronous=FULL"); try execute("PRAGMA foreign_keys=ON")
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    deinit { sqlite3_close(handle) }
    func transaction<T>(_ body: () throws -> T) throws -> T {
        lock.lock(); defer { lock.unlock() }
        try execute("BEGIN IMMEDIATE")
        do { let value = try body(); try execute("COMMIT"); return value }
        catch { try? execute("ROLLBACK"); throw error }
    }
    func execute(_ sql: String, _ values: [Value] = []) throws { _ = try query(sql, values) }
    func query(_ sql: String, _ values: [Value] = []) throws -> [Row] {
        lock.lock(); defer { lock.unlock() }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw DesktopSyncError.storage }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_bind_parameter_count(statement) == values.count else { throw DesktopSyncError.storage }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (offset, value) in values.enumerated() {
            let i = Int32(offset + 1), status: Int32
            switch value {
            case .text(let text): status = text.withCString { sqlite3_bind_text(statement, i, $0, Int32(text.utf8.count), transient) }
            case .integer(let number): status = sqlite3_bind_int64(statement, i, number)
            case .blob(let data): status = data.withUnsafeBytes { sqlite3_bind_blob(statement, i, $0.baseAddress, Int32(data.count), transient) }
            case .null: status = sqlite3_bind_null(statement, i)
            }
            guard status == SQLITE_OK else { throw DesktopSyncError.storage }
        }
        var rows: [Row] = []
        while true {
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { return rows }
            guard status == SQLITE_ROW else { throw DesktopSyncError.storage }
            var row: Row = [:]
            for i in 0..<sqlite3_column_count(statement) {
                let name = String(cString: sqlite3_column_name(statement, i))
                switch sqlite3_column_type(statement, i) {
                case SQLITE_INTEGER: row[name] = .integer(sqlite3_column_int64(statement, i))
                case SQLITE_TEXT:
                    let count = Int(sqlite3_column_bytes(statement, i))
                    if let bytes = sqlite3_column_text(statement, i) { row[name] = .text(String(decoding: UnsafeBufferPointer(start: bytes, count: count), as: UTF8.self)) }
                case SQLITE_BLOB:
                    let count = Int(sqlite3_column_bytes(statement, i))
                    row[name] = .blob(sqlite3_column_blob(statement, i).map { Data(bytes: $0, count: count) } ?? Data())
                default: row[name] = .null
                }
            }
            rows.append(row)
        }
    }
}
extension SyncSQLite.Value {
    var string: String? { if case .text(let value) = self { return value }; return nil }
    var integer: Int64? { if case .integer(let value) = self { return value }; return nil }
    var data: Data? { if case .blob(let value) = self { return value }; return nil }
}
