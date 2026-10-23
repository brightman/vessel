import Foundation

struct DaybookReminder: Codable, Equatable, Identifiable, Sendable {
    enum Status: String, Codable, Sendable {
        case scheduled, completed, cancelled, needsAttention
    }

    static let notificationPrefix = "wisenote.daybook.reminder."
    var id: UUID
    var title: String
    var scheduledAt: Date
    var sourceID: UUID?
    var status: Status
    var notificationID: String
    var createdAt: Date
    var updatedAt: Date
    var appleLink: AppleReminderLink? = nil

    var statusTitle: String {
        switch status {
        case .scheduled: scheduledAt <= .now ? "已到提醒时间" : "已安排"
        case .completed: "已完成"
        case .cancelled: "已取消"
        case .needsAttention: "需要重新安排"
        }
    }

    static func validatedTitle(_ title: String) throws -> String {
        let value = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.count <= 200 else { throw DaybookReminderError.invalidTitle }
        return value
    }

    static func validateDate(_ date: Date, now: Date = .now) throws {
        guard date.timeIntervalSince1970.isFinite, date > now.addingTimeInterval(1) else {
            throw DaybookReminderError.invalidDate
        }
    }
}

enum DaybookNotificationAuthorization: Equatable, Sendable {
    case notDetermined, denied, authorized, provisional, unavailable

    var canSchedule: Bool { self == .authorized || self == .provisional }

    var title: String {
        switch self {
        case .notDetermined: "确认首条提醒时申请通知权限"
        case .denied: "系统通知已关闭"
        case .authorized: "系统通知已允许"
        case .provisional: "系统通知以安静方式送达"
        case .unavailable: "此设备无法安排通知"
        }
    }
}

enum DaybookReminderError: Error, LocalizedError, Equatable {
    case invalidTitle, invalidDate, permissionDenied, notificationFailure, notFound, busy
    case tooManyReminders, invalidStorage, storageUnavailable

    var errorDescription: String? {
        switch self {
        case .invalidTitle: "请输入 1–200 字的提醒内容。"
        case .invalidDate: "请选择未来的提醒时间。"
        case .permissionDenied: "尚未允许通知，提醒没有安排。请在系统设置中开启 WiseLife 通知，再重新确认。"
        case .notificationFailure: "系统未能安排通知，原有提醒已保留。请重试。"
        case .notFound: "这条提醒已不存在，请返回列表刷新。"
        case .busy: "正在保存上一项操作，请稍后再试。"
        case .tooManyReminders: "待提醒事项已达 50 条。请先完成或取消部分提醒。"
        case .invalidStorage: "无法读取提醒文件，原文件已保留。请检查存储后重新打开应用。"
        case .storageUnavailable: "无法保存提醒，原有内容已保留。请检查设备存储空间后重试。"
        }
    }
}

enum AppleReminderAccess: Equatable, Sendable { case notDetermined, denied, restricted, authorized }

struct AppleReminderList: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let title: String
    let accountTitle: String
}

struct AppleReminderSnapshot: Codable, Equatable, Sendable {
    var identifier: String
    var title: String
    var scheduledAt: Date
    var completed: Bool
    var list: AppleReminderList
}

struct AppleReminderLink: Codable, Equatable, Sendable {
    enum State: String, Codable, Sendable { case pending, linked, failed, missing }
    enum Operation: String, Codable, Sendable { case upsert, unlink, delete, cancel, refresh }
    var list: AppleReminderList
    var identifier: String?
    var state: State = .pending
    var operation: Operation = .upsert
    var lastError: String?
    var lastSynced: AppleReminderSnapshot?

    var statusTitle: String {
        switch state {
        case .linked: "已添加到 Apple 提醒事项"
        case .pending: "正在更新 Apple 提醒事项"
        case .missing: "Apple 中的任务已移除"
        case .failed: operation == .refresh ? "Apple 状态待刷新" : (lastSynced == nil ? "Apple 添加状态待确认" : "Apple 更新待重试")
        }
    }
}

enum AppleReminderFailure: Error, LocalizedError, Equatable {
    case accessDenied, noList, writeFailed, missing, ownershipChanged, unavailable
    var errorDescription: String? {
        switch self {
        case .accessDenied: "未获提醒事项完整访问权限。待办已保留，请在系统设置中允许后重试。"
        case .noList: "所选提醒事项列表不可写。请重新选择列表，或关闭 Apple 关联。"
        case .writeFailed: "未能确认 Apple 提醒事项的更新结果。待办已保留，请重试。"
        case .missing: "Apple 中的任务已移除。为避免重复创建，请先关闭关联，再按需重新添加。"
        case .ownershipChanged: "系统任务的关联标识已变化。为保护其他任务，本次没有修改。"
        case .unavailable: "Apple 提醒事项暂不可用，待办已保留。"
        }
    }
}

@MainActor protocol AppleReminderServing {
    func authorization() -> AppleReminderAccess
    func requestAccess() async throws -> Bool
    func lists() throws -> [AppleReminderList]
    func upsert(_ reminder: DaybookReminder) async throws -> AppleReminderSnapshot
    func remove(_ reminder: DaybookReminder) async throws
    func read(_ reminder: DaybookReminder) async throws -> AppleReminderSnapshot?
}

/// SQLite persistence. Published items change only after the transaction commits.
final class DaybookReminderRepository {
    private let db: DaybookDatabase
    private(set) var items: [DaybookReminder] = []

    init(root: URL, database: DaybookDatabase? = nil) throws {
        db = try database ?? DaybookDatabase(url: DaybookDatabase.metadataURL(forRoot: root))
        let indexURL = root.appendingPathComponent("reminders.json")
        do {
            try db.migrate("daybook_reminders") {
                if (try? FileManager.default.attributesOfItem(atPath: indexURL.path)[.type] as? FileAttributeType) == .typeSymbolicLink { throw DaybookReminderError.invalidStorage }
                let imported = FileManager.default.fileExists(atPath: indexURL.path)
                    ? try JSONDecoder().decode([DaybookReminder].self, from: Data(contentsOf: indexURL)) : []
                try Self.validate(imported)
                for item in imported { try insert(item) }
                _ = try load()
            }
            items = try db.transaction { try load() }
        } catch { throw DaybookReminderError.invalidStorage }
    }

    func reload() throws {
        do {
            let current = try db.transaction { try load() }
            items = current
        } catch { throw DaybookReminderError.invalidStorage }
    }

    func replace(with revised: [DaybookReminder]) throws {
        try Self.validate(revised)
        let baseline = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
        let proposed = Dictionary(uniqueKeysWithValues: revised.map { ($0.id, $0) })
        do {
            let committed = try db.transaction {
                let current = Dictionary(uniqueKeysWithValues: try load().map { ($0.id, $0) })
                // Compare only touched rows. An older repository cannot overwrite newer edits,
                // and records created elsewhere are outside this replacement's baseline.
                for id in Set(baseline.keys).union(proposed.keys) where baseline[id] != proposed[id] {
                    guard current[id] == baseline[id] else { throw DaybookReminderError.storageUnavailable }
                    if let item = proposed[id] {
                        if baseline[id] == nil { try insert(item) }
                        else {
                            try db.execute("UPDATE daybook_reminders SET title=?,scheduled_at=?,source_id=?,status=?,notification_id=?,created_at=?,updated_at=? WHERE id=?", Array(values(item).dropFirst()) + [.text(id.uuidString)])
                            try saveAppleLink(item)
                        }
                    } else { try db.execute("DELETE FROM daybook_reminders WHERE id=?", [.text(id.uuidString)]) }
                }
                return try load()
            }
            items = committed
        } catch { throw DaybookReminderError.storageUnavailable }
    }
    private func values(_ item: DaybookReminder) -> [DaybookDatabase.Value] {
        [.text(item.id.uuidString), .text(item.title), .real(item.scheduledAt.timeIntervalSinceReferenceDate), item.sourceID.map { .text($0.uuidString) } ?? .null, .text(item.status.rawValue), .text(item.notificationID), .real(item.createdAt.timeIntervalSinceReferenceDate), .real(item.updatedAt.timeIntervalSinceReferenceDate)]
    }
    private func insert(_ item: DaybookReminder) throws {
        try db.execute("INSERT INTO daybook_reminders(id,title,scheduled_at,source_id,status,notification_id,created_at,updated_at) VALUES (?,?,?,?,?,?,?,?)", values(item))
        try saveAppleLink(item)
    }
    private func saveAppleLink(_ item: DaybookReminder) throws {
        if let link = item.appleLink {
            try db.execute("INSERT OR REPLACE INTO reminder_apple_links(reminder_id,payload) VALUES (?,?)", [.text(item.id.uuidString), try DaybookDatabase.json(link)])
        } else {
            try db.execute("DELETE FROM reminder_apple_links WHERE reminder_id=?", [.text(item.id.uuidString)])
        }
    }
    private func load() throws -> [DaybookReminder] {
        let result = try db.query("SELECT * FROM daybook_reminders ORDER BY scheduled_at,id").map { row in
            guard let id = UUID(uuidString: try row.requiredString("id")),
                  let status = DaybookReminder.Status(rawValue: try row.requiredString("status")) else { throw DaybookReminderError.invalidStorage }
            let sourceID: UUID?
            switch row["source_id"] {
            case .null: sourceID = nil
            case .text(let value):
                guard let id = UUID(uuidString: value) else { throw DaybookReminderError.invalidStorage }
                sourceID = id
            default: throw DaybookReminderError.invalidStorage
            }
            var item = DaybookReminder(id: id, title: try row.requiredString("title"), scheduledAt: Date(timeIntervalSinceReferenceDate: try row.requiredDouble("scheduled_at")), sourceID: sourceID, status: status, notificationID: try row.requiredString("notification_id"), createdAt: Date(timeIntervalSinceReferenceDate: try row.requiredDouble("created_at")), updatedAt: Date(timeIntervalSinceReferenceDate: try row.requiredDouble("updated_at")))
            if let link = try db.query("SELECT payload FROM reminder_apple_links WHERE reminder_id=?", [.text(id.uuidString)]).first {
                item.appleLink = try DaybookDatabase.decode(AppleReminderLink.self, link["payload"])
            }
            return item
        }
        try Self.validate(result)
        return result
    }

    private static func validate(_ items: [DaybookReminder]) throws {
        guard Set(items.map(\.id)).count == items.count,
              Set(items.map(\.notificationID)).count == items.count else {
            throw DaybookReminderError.invalidStorage
        }
        for item in items {
            if let link = item.appleLink {
                guard !link.list.id.isEmpty, link.list.id.count <= 4096,
                      link.list.title.count <= 4096, link.list.accountTitle.count <= 4096,
                      link.identifier.map({ !$0.isEmpty && $0.count <= 4096 }) ?? true,
                      link.lastError.map({ $0.count <= 8192 }) ?? true else { throw DaybookReminderError.invalidStorage }
                if let snapshot = link.lastSynced {
                    guard !snapshot.identifier.isEmpty, snapshot.identifier.count <= 4096,
                          (try? DaybookReminder.validatedTitle(snapshot.title)) == snapshot.title,
                          snapshot.scheduledAt.timeIntervalSince1970.isFinite else { throw DaybookReminderError.invalidStorage }
                }
            }
            guard (try? DaybookReminder.validatedTitle(item.title)) == item.title,
                  item.notificationID.hasPrefix(DaybookReminder.notificationPrefix),
                  item.notificationID.count <= 150,
                  [item.scheduledAt, item.createdAt, item.updatedAt].allSatisfy({ $0.timeIntervalSince1970.isFinite }) else {
                throw DaybookReminderError.invalidStorage
            }
        }
    }
}

@MainActor
protocol DaybookReminderScheduling {
    func authorization() async -> DaybookNotificationAuthorization
    func requestAuthorization() async throws -> DaybookNotificationAuthorization
    func schedule(_ reminder: DaybookReminder) async throws
    func remove(ids: [String]) async
    func pendingIDs() async -> Set<String>
}

/// Coordinates durable metadata with the system queue. Each edit has a distinct notification ID,
/// so a failed replacement can remove only its candidate and preserve the old reminder.
@MainActor
final class DaybookReminderCoordinator {
    private let repository: DaybookReminderRepository
    private let scheduler: any DaybookReminderScheduling
    private let apple: (any AppleReminderServing)?
    private var busy = false
    // Scheduling precedes the SQLite commit. Other coordinators must preserve those candidates.
    private static var confirmingNotificationIDs = Set<String>()
    private static var appleInFlightIDs = Set<UUID>()
    var items: [DaybookReminder] { repository.items }

    init(repository: DaybookReminderRepository, scheduler: any DaybookReminderScheduling, apple: (any AppleReminderServing)? = nil) {
        self.repository = repository
        self.scheduler = scheduler
        self.apple = apple
    }

    @discardableResult
    func confirm(title: String, scheduledAt: Date, sourceID: UUID? = nil, editingID: UUID? = nil, appleList: AppleReminderList? = nil, newID: UUID? = nil) async throws -> DaybookReminder {
        guard !busy else { throw DaybookReminderError.busy }
        busy = true
        defer { busy = false }
        try repository.reload()
        let title = try DaybookReminder.validatedTitle(title)
        try DaybookReminder.validateDate(scheduledAt)
        let previous = (editingID ?? newID).flatMap { id in items.first { $0.id == id } }
        if editingID != nil && previous == nil { throw DaybookReminderError.notFound }
        if let candidateID = editingID ?? newID, Self.appleInFlightIDs.contains(candidateID) { throw DaybookReminderError.busy }
        let activeCount = items.filter { $0.status == .scheduled && $0.scheduledAt > .now && $0.id != previous?.id }.count
        guard activeCount < 50 else { throw DaybookReminderError.tooManyReminders }
        if appleList != nil || previous?.appleLink != nil {
            return try await confirmApple(title: title, scheduledAt: scheduledAt, sourceID: sourceID,
                                          previous: previous, list: appleList, newID: newID)
        }
        var permission = await scheduler.authorization()
        if permission == .notDetermined { permission = try await scheduler.requestAuthorization() }
        guard permission.canSchedule else { throw DaybookReminderError.permissionDenied }
        try Task.checkCancellation()
        try DaybookReminder.validateDate(scheduledAt)
        let now = Date.now
        let candidate = DaybookReminder(
            id: previous?.id ?? newID ?? UUID(), title: title, scheduledAt: scheduledAt,
            sourceID: sourceID ?? previous?.sourceID, status: .scheduled,
            notificationID: DaybookReminder.notificationPrefix + UUID().uuidString,
            createdAt: previous?.createdAt ?? now, updatedAt: now
        )
        Self.confirmingNotificationIDs.insert(candidate.notificationID)
        defer { Self.confirmingNotificationIDs.remove(candidate.notificationID) }
        do {
            try await scheduler.schedule(candidate)
            try Task.checkCancellation()
            guard await scheduler.authorization().canSchedule else { throw DaybookReminderError.permissionDenied }
            try Task.checkCancellation()
            var revised = items.filter { $0.id != candidate.id }
            revised.append(candidate)
            try repository.replace(with: revised)
        } catch {
            await scheduler.remove(ids: [candidate.notificationID])
            throw error
        }
        if let previous { await scheduler.remove(ids: [previous.notificationID]) }
        return candidate
    }

    func cancel(_ id: UUID) async throws { try await changeStatus(id, to: .cancelled) }
    func complete(_ id: UUID) async throws { try await changeStatus(id, to: .completed) }

    func delete(_ id: UUID) async throws {
        guard !busy else { throw DaybookReminderError.busy }
        busy = true
        defer { busy = false }
        try repository.reload()
        guard let item = items.first(where: { $0.id == id }) else { throw DaybookReminderError.notFound }
        guard !Self.appleInFlightIDs.contains(id) else { throw DaybookReminderError.busy }
        if item.appleLink != nil {
            var desired = item
            desired.appleLink?.operation = .delete
            desired.appleLink?.state = .pending
            desired.updatedAt = .now
            try replace(desired)
            try await processApple(id)
            return
        }
        try repository.replace(with: items.filter { $0.id != id })
        await scheduler.remove(ids: [item.notificationID])
    }

    func reconcile() async throws {
        guard !busy else { throw DaybookReminderError.busy }
        busy = true
        defer { busy = false }
        try repository.reload()
        for item in items where item.appleLink != nil && !Self.appleInFlightIDs.contains(item.id) {
            if item.appleLink?.state == .pending { try await processApple(item.id) }
            else if item.appleLink?.state == .linked { try await refreshApple(item) }
        }
        try repository.reload()
        let observed = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
        let pending = await scheduler.pendingIDs()
        let permission = await scheduler.authorization()
        try repository.reload()
        var revised = items
        for index in revised.indices where revised[index].appleLink == nil && revised[index].status == .scheduled && revised[index].scheduledAt > .now {
            // The async queue snapshot cannot establish absence for a new or changed row.
            guard observed[revised[index].id] == revised[index] else { continue }
            if !pending.contains(revised[index].notificationID) || !permission.canSchedule {
                revised[index].status = .needsAttention
                revised[index].updatedAt = .now
            }
        }
        if revised != items { try repository.replace(with: revised) }
        // Refresh even on a no-op and use durable IDs at the cleanup boundary.
        try repository.reload()
        let activeIDs = Set(items.filter { $0.appleLink == nil && $0.status == .scheduled }.map(\.notificationID))
        let obsolete = pending.filter {
            $0.hasPrefix(DaybookReminder.notificationPrefix) && !activeIDs.contains($0)
                && !Self.confirmingNotificationIDs.contains($0)
        }
        await scheduler.remove(ids: Array(obsolete))
    }

    private func changeStatus(_ id: UUID, to status: DaybookReminder.Status) async throws {
        guard !busy else { throw DaybookReminderError.busy }
        busy = true
        defer { busy = false }
        try repository.reload()
        guard let index = items.firstIndex(where: { $0.id == id }) else { throw DaybookReminderError.notFound }
        guard !Self.appleInFlightIDs.contains(id) else { throw DaybookReminderError.busy }
        var revised = items
        revised[index].status = status
        revised[index].updatedAt = .now
        if revised[index].appleLink != nil {
            revised[index].appleLink?.operation = status == .cancelled ? .cancel : .upsert
            revised[index].appleLink?.state = .pending
        }
        try repository.replace(with: revised)
        await scheduler.remove(ids: [revised[index].notificationID])
        if revised[index].appleLink != nil { try await processApple(id) }
    }
}

extension DaybookReminderCoordinator {
    func retryApple(_ id: UUID) async throws {
        guard !busy, !Self.appleInFlightIDs.contains(id) else { throw DaybookReminderError.busy }
        busy = true
        defer { busy = false }
        try repository.reload()
        guard var item = items.first(where: { $0.id == id }), item.appleLink != nil else { throw DaybookReminderError.notFound }
        item.appleLink?.state = .pending
        item.appleLink?.lastError = nil
        item.updatedAt = .now
        try replace(item)
        try await processApple(id, requestLocalPermission: true)
    }

    private func replace(_ item: DaybookReminder) throws {
        try repository.replace(with: items.filter { $0.id != item.id } + [item])
    }

    private func confirmApple(title: String, scheduledAt: Date, sourceID: UUID?, previous: DaybookReminder?, list: AppleReminderList?, newID: UUID?) async throws -> DaybookReminder {
        var candidate = DaybookReminder(id: previous?.id ?? newID ?? UUID(), title: title, scheduledAt: scheduledAt,
            sourceID: sourceID ?? previous?.sourceID, status: .scheduled,
            notificationID: DaybookReminder.notificationPrefix + UUID().uuidString,
            createdAt: previous?.createdAt ?? .now, updatedAt: .now)
        if let list {
            candidate.appleLink = previous?.appleLink ?? AppleReminderLink(list: list)
            candidate.appleLink?.list = list
            candidate.appleLink?.operation = .upsert
        } else {
            candidate.appleLink = previous?.appleLink
            candidate.appleLink?.operation = .unlink
        }
        candidate.appleLink?.state = .pending
        candidate.appleLink?.lastError = nil
        // Write the intent before any external effect. On restart the same UUID marker is reused.
        try replace(candidate)
        if let previous { await scheduler.remove(ids: [previous.notificationID]) }
        try await processApple(candidate.id, requestLocalPermission: true)
        return items.first { $0.id == candidate.id } ?? candidate
    }

    private func processApple(_ id: UUID, requestLocalPermission: Bool = false) async throws {
        guard !Self.appleInFlightIDs.contains(id) else { return }
        Self.appleInFlightIDs.insert(id)
        defer { Self.appleInFlightIDs.remove(id) }
        try repository.reload()
        guard let item = items.first(where: { $0.id == id }), let link = item.appleLink else { return }
        await scheduler.remove(ids: [item.notificationID])
        var candidate = item
        var deleteLocal = false
        var scheduledLocalID: String?
        defer { if let scheduledLocalID { Self.confirmingNotificationIDs.remove(scheduledLocalID) } }
        do {
            guard let apple else { throw AppleReminderFailure.unavailable }
            guard apple.authorization() == .authorized else { throw AppleReminderFailure.accessDenied }
            switch link.operation {
            case .refresh:
                try await refreshApple(item)
                return
            case .upsert:
                let snapshot = try await apple.upsert(item)
                candidate.appleLink?.identifier = snapshot.identifier
                candidate.appleLink?.lastSynced = snapshot
                candidate.appleLink?.list = snapshot.list
                candidate.appleLink?.state = .linked
                candidate.appleLink?.lastError = nil
                if candidate.status == .needsAttention { candidate.status = .scheduled }
            case .unlink:
                try await apple.remove(item)
                var access = await scheduler.authorization()
                if access == .notDetermined && requestLocalPermission { access = try await scheduler.requestAuthorization() }
                guard access.canSchedule else { throw DaybookReminderError.permissionDenied }
                try DaybookReminder.validateDate(candidate.scheduledAt)
                candidate.appleLink = nil
                candidate.status = .scheduled
                Self.confirmingNotificationIDs.insert(candidate.notificationID)
                scheduledLocalID = candidate.notificationID
                try await scheduler.schedule(candidate)
                guard await scheduler.authorization().canSchedule else { throw DaybookReminderError.permissionDenied }
            case .cancel:
                try await apple.remove(item)
                candidate.appleLink = nil
                candidate.status = .cancelled
            case .delete:
                try await apple.remove(item)
                deleteLocal = true
            }
        } catch {
            await scheduler.remove(ids: [item.notificationID])
            candidate = item
            candidate.appleLink?.state = (error as? AppleReminderFailure) == .missing ? .missing : .failed
            candidate.appleLink?.lastError = error.localizedDescription
            if candidate.status == .scheduled { candidate.status = .needsAttention }
        }
        candidate.updatedAt = .now
        // Do not roll back a successful Apple operation if local persistence fails: the durable
        // pending operation is recovered using the stable marker on the next foreground refresh.
        try repository.reload()
        guard items.first(where: { $0.id == id }) == item else { throw DaybookReminderError.storageUnavailable }
        do {
            if deleteLocal { try repository.replace(with: items.filter { $0.id != id }) }
            else { try replace(candidate) }
        } catch {
            if candidate.appleLink == nil { await scheduler.remove(ids: [candidate.notificationID]) }
            throw error
        }
    }

    private func refreshApple(_ observed: DaybookReminder) async throws {
        guard let apple else { return }
        var updated = observed
        do {
            let snapshot = try await apple.read(observed)
            if let snapshot {
                // Only linked, settled tasks are read back; pending local edits always win.
                guard (try? DaybookReminder.validatedTitle(snapshot.title)) != nil,
                      snapshot.scheduledAt.timeIntervalSince1970.isFinite else { throw AppleReminderFailure.writeFailed }
                updated.appleLink?.state = .linked
                updated.appleLink?.operation = .refresh
                updated.appleLink?.lastError = nil
                updated.title = snapshot.title
                updated.scheduledAt = snapshot.scheduledAt
                updated.status = snapshot.completed ? .completed : .scheduled
                updated.appleLink?.identifier = snapshot.identifier
                updated.appleLink?.lastSynced = snapshot
                updated.appleLink?.list = snapshot.list
            } else {
                updated.appleLink?.operation = .refresh
                updated.appleLink?.state = .missing
                updated.appleLink?.lastError = AppleReminderFailure.missing.localizedDescription
                if updated.status == .scheduled { updated.status = .needsAttention }
            }
        } catch {
            updated.appleLink?.operation = .refresh
            updated.appleLink?.state = .failed
            updated.appleLink?.lastError = error.localizedDescription
        }
        guard updated != observed else { return }
        updated.updatedAt = .now
        try repository.reload()
        guard items.first(where: { $0.id == observed.id }) == observed else { return }
        try replace(updated)
    }
}
