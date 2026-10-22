import CryptoKit
import Foundation

enum LifeSource: String, Codable, CaseIterable, Identifiable, Sendable {
    case health, calendar, location
    var id: Self { self }
    var title: String { switch self { case .health: "Apple 健康"; case .calendar: "日历"; case .location: "地点" } }
}
enum LifeSourceStatus: String, Codable { case ready, empty, awaitingAuthorization, denied, unavailable, error }
struct LifeSourceSnapshot: Codable, Equatable {
    let source: LifeSource
    let day: Date
    var records: [DayRecord]
    var status: LifeSourceStatus
    var refreshedAt: Date?
    var message: String?
    var isStale: Bool
}

enum LifeAggregation {
    static func dayInterval(_ date: Date, calendar: Calendar = .current) -> DateInterval {
        let start = calendar.startOfDay(for: date)
        return DateInterval(start: start, end: calendar.date(byAdding: .day, value: 1, to: start)!)
    }
    static func sleepDuration(_ samples: [DateInterval], within day: DateInterval) -> TimeInterval {
        mergedSleepIntervals(samples, within: day).reduce(0) { $0 + $1.duration }
    }
    static func mergedSleepIntervals(_ samples: [DateInterval], within day: DateInterval) -> [DateInterval] {
        let clipped = samples.compactMap { sample -> DateInterval? in
            let start = max(day.start, sample.start), end = min(day.end, sample.end)
            return end > start ? DateInterval(start: start, end: end) : nil
        }.sorted { $0.start < $1.start }
        var merged: [DateInterval] = []
        var current: DateInterval?
        for sample in clipped {
            if let previous = current {
                if sample.start <= previous.end { current = DateInterval(start: previous.start, end: max(previous.end, sample.end)) }
                else { merged.append(previous); current = sample }
            } else { current = sample }
        }
        if let current { merged.append(current) }; return merged
    }
    static func recordID(source: LifeSource, key: String, day: Date) -> UUID {
        stableID("life-v1|\(source.rawValue)|\(day.timeIntervalSince1970)|\(key)")
    }
    static func locationID(_ parentID: UUID) -> UUID { stableID("life-v1|location|\(parentID.uuidString)") }
    private static func stableID(_ value: String) -> UUID {
        let bytes = Array(SHA256.hash(data: Data(value.utf8)).prefix(16))
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7], bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }
}

/// Row storage; publish a new snapshot only after the SQLite transaction commits.
final class LifeSourceStore {
    enum Failure: Error { case paused, staleConfirmation }
    private struct State: Codable {
        var enabled: [String: Bool] = [:]
        var snapshots: [LifeSourceSnapshot] = []
        var suppressed: Set<UUID> = []
    }
    private let database: DaybookDatabase
    private var state: State
    init(url: URL, database: DaybookDatabase? = nil) throws {
        let db = try database ?? DaybookDatabase(url: DaybookDatabase.url(forLegacy: url))
        self.database = db
        // Domain-local additive migration, independent of other metadata schemas.
        try db.migrate("life-moments-v1") {
            try db.execute("CREATE TABLE IF NOT EXISTS life_moment_metadata (record_id TEXT PRIMARY KEY REFERENCES life_records(id) ON DELETE CASCADE, payload BLOB NOT NULL)")
        }
        try db.migrate("life") {
            guard FileManager.default.fileExists(atPath: url.path) else { return }
            let data = try Data(contentsOf: url)
            let imported = try JSONDecoder().decode(State.self, from: data)
            try Self.write(imported, to: db)
        }
        state = try Self.read(db)
    }
    var records: [DayRecord] {
        state.snapshots.flatMap { snapshot in
            snapshot.records.filter { !state.suppressed.contains($0.id) }.map { record in
                guard snapshot.isStale else { return record }
                // Keep the freshness warning in the searchable/AI projection as well as visible status.
                var displayed = record
                displayed.title = "【旧快照】" + record.title
                displayed.text = "【旧快照：来源刷新失败，数据可能已过期】\n" + record.text
                return displayed
            }
        }.sorted { $0.capturedAt > $1.capturedAt }
    }
    func isEnabled(_ source: LifeSource) -> Bool { state.enabled[source.rawValue] ?? false }
    func isSuppressed(_ id: UUID) -> Bool { state.suppressed.contains(id) }
    func snapshot(source: LifeSource, day: Date) -> LifeSourceSnapshot? { state.snapshots.first { $0.source == source && $0.day == day } }
    func setEnabled(_ enabled: Bool, source: LifeSource) throws {
        var next = state; next.enabled[source.rawValue] = enabled; try save(next)
    }
    func replace(source: LifeSource, day: Date, records: [DayRecord], refreshedAt: Date) throws {
        guard isEnabled(source) else { throw Failure.paused }
        var next = state
        next.snapshots.removeAll { $0.source == source && $0.day == day }
        let previous = state.snapshots.first { $0.source == source && $0.day == day }?.records ?? []
        let updated = records.map { value -> DayRecord in
            var value = value
            if let old = previous.first(where: { $0.id == value.id })?.lifeMoment?.sleep,
               old.confirmed, let sleep = value.lifeMoment?.sleep, sleep.isMain,
               sleep.startedAt == old.startedAt, sleep.endedAt == old.endedAt {
                value.lifeMoment?.sleep?.confirmed = true
                value.title = "起床 · 本人确认"
                value.text += "\n本人确认此睡眠结束时间为起床时间。"
            }
            return value
        }
        let unique = Dictionary(updated.filter { !next.suppressed.contains($0.id) }.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a }).values.sorted { $0.id.uuidString < $1.id.uuidString }
        let hasData = source == .health ? records.contains { $0.metricValue != nil } : !records.isEmpty
        next.snapshots.append(LifeSourceSnapshot(source: source, day: day, records: unique, status: hasData ? .ready : .empty, refreshedAt: refreshedAt, message: nil, isStale: false))
        try save(next)
    }
    func appendLocation(_ record: DayRecord, day: Date, refreshedAt: Date) throws {
        var records = snapshot(source: .location, day: day)?.records ?? []
        records.removeAll { $0.id == record.id }; records.append(record)
        try replace(source: .location, day: day, records: records, refreshedAt: refreshedAt)
    }
    func markFailure(source: LifeSource, day: Date, status: LifeSourceStatus, message: String) throws {
        var next = state
        if let index = next.snapshots.firstIndex(where: { $0.source == source && $0.day == day }) {
            next.snapshots[index].status = status; next.snapshots[index].message = message
            next.snapshots[index].isStale = next.snapshots[index].refreshedAt != nil
        } else { next.snapshots.append(LifeSourceSnapshot(source: source, day: day, records: [], status: status, message: message, isStale: false)) }
        try save(next)
    }
    func delete(_ id: UUID) throws {
        var next = state; next.suppressed.insert(id)
        for index in next.snapshots.indices { next.snapshots[index].records.removeAll { $0.id == id } }
        try save(next)
    }
    func confirmWake(_ id: UUID, expectedEnd: Date, confirmed: Bool) throws {
        var next = state
        guard let snapshot = next.snapshots.firstIndex(where: { $0.records.contains { $0.id == id } }),
              let index = next.snapshots[snapshot].records.firstIndex(where: { $0.id == id }),
              let detail = next.snapshots[snapshot].records[index].lifeMoment?.sleep,
              detail.isMain, detail.endedAt == expectedEnd else { throw Failure.staleConfirmation }
        next.snapshots[snapshot].records[index].lifeMoment?.sleep?.confirmed = confirmed
        next.snapshots[snapshot].records[index].title = confirmed ? "起床 · 本人确认" : "起床 · 估计"
        let suffix = "\n本人确认此睡眠结束时间为起床时间。"
        next.snapshots[snapshot].records[index].text = next.snapshots[snapshot].records[index].text.replacingOccurrences(of: suffix, with: "") + (confirmed ? suffix : "")
        try save(next)
    }
    private func save(_ next: State) throws {
        try database.transaction { try Self.writeDelta(from: state, to: next, db: database) }
        state = next
    }
    private struct SnapshotKey: Hashable {
        let source: String
        let day: Date
        init(_ snapshot: LifeSourceSnapshot) { source = snapshot.source.rawValue; day = snapshot.day }
        var bindings: [DaybookDatabase.Value] { [.text(source), .real(day.timeIntervalSinceReferenceDate)] }
    }
    /// Life history grows without a day cap. Persist only changed rows, never rewrite prior years.
    private static func writeDelta(from old: State, to next: State, db: DaybookDatabase) throws {
        for source in old.enabled.keys where next.enabled[source] == nil {
            try db.execute("DELETE FROM life_settings WHERE source = ?", [.text(source)])
        }
        for (source, enabled) in next.enabled where old.enabled[source] != enabled {
            try db.execute("INSERT INTO life_settings VALUES (?, ?) ON CONFLICT(source) DO UPDATE SET enabled = excluded.enabled", [.text(source), .integer(enabled ? 1 : 0)])
        }
        let before = Dictionary(uniqueKeysWithValues: old.snapshots.map { (SnapshotKey($0), $0) })
        let after = Dictionary(uniqueKeysWithValues: next.snapshots.map { (SnapshotKey($0), $0) })
        for key in before.keys where after[key] == nil {
            try db.execute("DELETE FROM life_snapshots WHERE source = ? AND day = ?", key.bindings)
        }
        for (key, snapshot) in after where before[key] != snapshot {
            if before[key] == nil {
                try insertSnapshot(snapshot, db: db)
            } else {
                try db.execute("UPDATE life_snapshots SET status = ?, refreshed_at = ?, message = ?, stale = ? WHERE source = ? AND day = ?", [.text(snapshot.status.rawValue), snapshot.refreshedAt.map { .real($0.timeIntervalSinceReferenceDate) } ?? .null, snapshot.message.map { .text($0) } ?? .null, .integer(snapshot.isStale ? 1 : 0)] + key.bindings)
            }
            let previousRecords = Dictionary(uniqueKeysWithValues: (before[key]?.records ?? []).map { ($0.id, $0) })
            let nextRecords = Dictionary(uniqueKeysWithValues: snapshot.records.map { ($0.id, $0) })
            for id in previousRecords.keys where nextRecords[id] == nil {
                try db.execute("DELETE FROM life_records WHERE id = ? AND source = ? AND day = ?", [.text(id.uuidString)] + key.bindings)
            }
            for record in snapshot.records where previousRecords[record.id] != record {
                if previousRecords[record.id] == nil { try insertRecord(record, key: key, db: db) }
                else {
                    try db.execute("UPDATE life_records SET captured_at = ?, kind = ?, title = ?, text = ?, summary = ?, duration = ?, metric = ?, intervals = ? WHERE id = ? AND source = ? AND day = ?", try recordValues(record) + [.text(record.id.uuidString)] + key.bindings)
                    try writeMoment(record, db: db)
                }
            }
        }
        for id in old.suppressed.subtracting(next.suppressed) { try db.execute("DELETE FROM life_suppression WHERE id = ?", [.text(id.uuidString)]) }
        for id in next.suppressed.subtracting(old.suppressed) { try db.execute("INSERT INTO life_suppression VALUES (?)", [.text(id.uuidString)]) }
    }
    private static func recordValues(_ record: DayRecord) throws -> [DaybookDatabase.Value] {
        [.real(record.capturedAt.timeIntervalSinceReferenceDate), .text(record.kind.rawValue), .text(record.title), .text(record.text), .text(record.summary), .real(record.duration), record.metricValue.map { .real($0) } ?? .null, try record.intervals.map { try DaybookDatabase.json($0) } ?? .null]
    }
    private static func insertRecord(_ record: DayRecord, key: SnapshotKey, db: DaybookDatabase) throws {
        try db.execute("INSERT INTO life_records VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)", try [.text(record.id.uuidString)] + key.bindings + recordValues(record))
        try writeMoment(record, db: db)
    }
    private static func writeMoment(_ record: DayRecord, db: DaybookDatabase) throws {
        if let detail = record.lifeMoment {
            try db.execute("INSERT INTO life_moment_metadata VALUES (?, ?) ON CONFLICT(record_id) DO UPDATE SET payload = excluded.payload", [.text(record.id.uuidString), try DaybookDatabase.json(detail)])
        } else { try db.execute("DELETE FROM life_moment_metadata WHERE record_id = ?", [.text(record.id.uuidString)]) }
    }
    private static func insertSnapshot(_ snapshot: LifeSourceSnapshot, db: DaybookDatabase) throws {
        try db.execute("INSERT INTO life_snapshots VALUES (?, ?, ?, ?, ?, ?)", SnapshotKey(snapshot).bindings + [.text(snapshot.status.rawValue), snapshot.refreshedAt.map { .real($0.timeIntervalSinceReferenceDate) } ?? .null, snapshot.message.map { .text($0) } ?? .null, .integer(snapshot.isStale ? 1 : 0)])
    }
    private static func write(_ state: State, to db: DaybookDatabase) throws {
        try db.execute("DELETE FROM life_records")
        try db.execute("DELETE FROM life_snapshots")
        try db.execute("DELETE FROM life_settings")
        try db.execute("DELETE FROM life_suppression")
        for (source, enabled) in state.enabled {
            guard LifeSource(rawValue: source) != nil else { throw DaybookDatabase.Failure(code: 11, detail: "未知生活数据来源") }
            try db.execute("INSERT INTO life_settings VALUES (?, ?)", [.text(source), .integer(enabled ? 1 : 0)])
        }
        for snapshot in state.snapshots {
            try insertSnapshot(snapshot, db: db)
            for record in snapshot.records { try insertRecord(record, key: SnapshotKey(snapshot), db: db) }
        }
        for id in state.suppressed { try db.execute("INSERT INTO life_suppression VALUES (?)", [.text(id.uuidString)]) }
    }
    private static func read(_ db: DaybookDatabase) throws -> State {
        try db.transaction {
            var state = State()
            for row in try db.query("SELECT * FROM life_settings") { state.enabled[try row.requiredString("source")] = row["enabled"] == .integer(1) }
            for row in try db.query("SELECT * FROM life_suppression") {
                guard let id = UUID(uuidString: try row.requiredString("id")) else { throw DaybookDatabase.Failure(code: 11, detail: "无效生活记录 ID") }
                state.suppressed.insert(id)
            }
            for row in try db.query("SELECT * FROM life_snapshots ORDER BY day,source") {
                guard let source = LifeSource(rawValue: try row.requiredString("source")), let status = LifeSourceStatus(rawValue: try row.requiredString("status")) else { throw DaybookDatabase.Failure(code: 11, detail: "无效生活快照") }
                let records = try db.query("SELECT life_records.*, life_moment_metadata.payload AS moment_payload FROM life_records LEFT JOIN life_moment_metadata ON life_records.id = life_moment_metadata.record_id WHERE source = ? AND day = ? ORDER BY captured_at,id", [row["source"]!, row["day"]!]).map { value -> DayRecord in
                    guard let id = UUID(uuidString: try value.requiredString("id")), let kind = DayRecord.Kind(rawValue: try value.requiredString("kind")) else { throw DaybookDatabase.Failure(code: 11, detail: "无效生活记录") }
                    var record = DayRecord(id: id, capturedAt: Date(timeIntervalSinceReferenceDate: try value.requiredDouble("captured_at")), kind: kind, title: try value.requiredString("title"), text: try value.requiredString("text"), summary: try value.requiredString("summary"), duration: try value.requiredDouble("duration"), metricValue: value["metric"]?.double, intervals: value["intervals"] == .null ? nil : try DaybookDatabase.decode([DateInterval].self, value["intervals"]))
                    record.lifeMoment = value["moment_payload"] == .null ? nil : try DaybookDatabase.decode(LifeMomentDetails.self, value["moment_payload"])
                    return record
                }
                state.snapshots.append(LifeSourceSnapshot(source: source, day: Date(timeIntervalSinceReferenceDate: try row.requiredDouble("day")), records: records, status: status, refreshedAt: row["refreshed_at"]?.double.map { Date(timeIntervalSinceReferenceDate: $0) }, message: row["message"]?.string, isStale: row["stale"] == .integer(1)))
            }
            return state
        }
    }
}

struct LifeSourceReadFailure: LocalizedError {
    let status: LifeSourceStatus
    let message: String
    var errorDescription: String? { message }
}
struct LifeCoordinate: Sendable {
    let latitude: Double
    let longitude: Double
    let accuracy: Double
}
@MainActor protocol LifeSourceReading {
    var onLocationAuthorizationChange: (() -> Void)? { get set }
    func authorize(_ source: LifeSource) async throws
    func read(_ source: LifeSource, day: Date, calendar: Calendar) async throws -> [DayRecord]
    func oneShotLocation() async throws -> LifeCoordinate
    func stop(_ source: LifeSource)
    func locationAvailabilityIssue() -> LifeSourceReadFailure?
    func startHealthObservation(onChange: @escaping (@escaping () -> Void) -> Void, onError: @escaping (Error) -> Void)
    func stopHealthObservation()
}
extension LifeSourceReading {
    func locationAvailabilityIssue() -> LifeSourceReadFailure? { nil }
    func startHealthObservation(onChange: @escaping (@escaping () -> Void) -> Void, onError: @escaping (Error) -> Void) {}
    func stopHealthObservation() {}
}
