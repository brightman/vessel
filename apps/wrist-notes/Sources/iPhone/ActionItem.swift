import Foundation

struct ActionSource: Codable, Equatable, Hashable, Sendable {
    var id: UUID
    var title: String
    var quote: String
    var capturedAt: Date
    var timeZoneID: String
    var recordingKind: String? = nil
    var timeZoneKnown = false
    var offset: TimeInterval? = nil
}

struct ActionItem: Codable, Equatable, Identifiable, Sendable {
    enum Kind: String, Codable, CaseIterable, Sendable {
        case todo, reminder, event
        var title: String { switch self { case .todo: "待办"; case .reminder: "提醒"; case .event: "日程" } }
        var icon: String { switch self { case .todo: "CheckCheck"; case .reminder: "Bell"; case .event: "CalendarDays" } }
    }
    enum Status: String, Codable, Sendable { case suggested, active, completed, cancelled }
    enum Sync: String, Codable, Sendable { case local, pending, linked, failed, missing }
    enum Operation: String, Codable, Sendable { case save, delete, unlink, refresh }
    struct Link: Codable, Equatable, Sendable {
        var listID: String
        var listTitle: String
        var identifier: String?
    }
    var id = UUID()
    var kind: Kind
    var title: String
    var notes = ""
    var status: Status = .active
    var start: Date? = nil // task deadline / reminder time / event start
    var end: Date? = nil
    var allDay = false
    var timeZoneID = TimeZone.current.identifier
    var source: ActionSource? = nil
    var legacyReminderID: UUID? = nil
    var link: Link? = nil
    var sync: Sync = .local
    var operation: Operation = .save
    var syncError: String? = nil
    var deleted = false
    var createdAt = Date.now
    var updatedAt = Date.now
    var revision = 0
    var dedupKey: String? = nil

    func timeLabel(_ date: Date) -> String {
        let formatter = DateFormatter(); formatter.locale = .current
        formatter.timeZone = TimeZone(identifier:timeZoneID) ?? .current
        formatter.dateStyle = .medium; formatter.timeStyle = allDay ? .none : .short
        return formatter.string(from:date)
    }
    var statusTitle: String {
        if status == .suggested { return "待确认" }
        if status == .cancelled { return "已取消" }
        if status == .completed { return "已完成" }
        if kind == .event, let end, end < .now { return "已结束" }
        if kind == .todo, let start, start < .now { return "已逾期" }
        return "已加入"
    }
    var syncTitle: String {
        switch sync {
        case .local: return kind == .reminder ? "WiseLife 本地提醒" : "仅保存在本机"
        case .pending: return "系统操作待完成"
        case .linked: return "已关联 Apple \(kind == .event ? "日历" : "提醒事项")"
        case .failed: return syncError ?? "系统更新失败，可重试"
        case .missing: return "系统中的项目已移除，不会自动重建"
        }
    }
    func validate(now: Date = .now, activating: Bool = true) throws {
        guard !title.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty, title.count <= 200, notes.count <= 4000,
              TimeZone(identifier:timeZoneID) != nil,
              [start,end].compactMap({$0}).allSatisfy({$0.timeIntervalSince1970.isFinite}) else { throw ActionFailure.invalid("请填写有效的标题、时间和时区。") }
        guard activating && status != .suggested else { return }
        if kind == .event {
            guard let start, let end, end > start else { throw ActionFailure.invalid("请填写日程开始和结束时间，结束时间必须晚于开始时间。") }
        }
        if kind == .reminder && status == .active {
            guard let start, start > now.addingTimeInterval(1) else { throw ActionFailure.invalid("请选择未来的提醒时间。") }
        }
    }
}

enum ActionFailure: LocalizedError {
    case invalid(String), changed, missing
    var errorDescription: String? {
        switch self { case .invalid(let text): text; case .changed: "行动已变化，请刷新后重试。"; case .missing: "关联项目已不存在，请先取消关联再按需添加。" }
    }
}

final class ActionRepository {
    private let db: DaybookDatabase
    init(database: DaybookDatabase) throws {
        db = database
        try db.execute("CREATE TABLE IF NOT EXISTS daybook_actions (id TEXT PRIMARY KEY, revision INTEGER NOT NULL, dedup_key TEXT UNIQUE, payload BLOB NOT NULL)")
    }
    func load() throws -> [ActionItem] {
        try db.query("SELECT payload FROM daybook_actions").map { try DaybookDatabase.decode(ActionItem.self,$0["payload"]) }
    }
    @discardableResult func save(_ item: ActionItem) throws -> ActionItem {
        try item.validate(activating:false)
        return try db.transaction {
            let current = try db.query("SELECT revision FROM daybook_actions WHERE id=?",[.text(item.id.uuidString)]).first
            guard (current?["revision"].flatMap { value -> Int? in if case let .integer(v) = value { return Int(v) }; return nil } ?? 0) == item.revision else { throw ActionFailure.changed }
            var next = item; next.revision += 1; next.updatedAt = .now
            try db.execute("INSERT INTO daybook_actions(id,revision,dedup_key,payload) VALUES(?,?,?,?) ON CONFLICT(id) DO UPDATE SET revision=excluded.revision,dedup_key=excluded.dedup_key,payload=excluded.payload",[.text(next.id.uuidString),.integer(Int64(next.revision)),next.dedupKey.map(DaybookDatabase.Value.text) ?? .null,try DaybookDatabase.json(next)])
            return next
        }
    }
    func addSuggestion(_ value: ActionItem) throws -> ActionItem {
        try db.transaction {
            var item = value
            let key = item.source.map { "\($0.id.uuidString)|\(item.kind.rawValue)|\($0.quote.trimmingCharacters(in:.whitespacesAndNewlines))" }
            guard let key else { throw ActionFailure.invalid("建议缺少原话依据。") }
            if let existing = try load().first(where:{$0.dedupKey == key}) { return existing }
            item.status = .suggested; item.dedupKey = key
            return try save(item)
        }
    }
}
