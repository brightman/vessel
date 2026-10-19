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
        case .permissionDenied: "尚未允许通知，提醒没有安排。请在系统设置中开启 WiseNote 通知，再重新确认。"
        case .notificationFailure: "系统未能安排通知，原有提醒已保留。请重试。"
        case .notFound: "这条提醒已不存在，请返回列表刷新。"
        case .busy: "正在保存上一项操作，请稍后再试。"
        case .tooManyReminders: "待提醒事项已达 50 条。请先完成或取消部分提醒。"
        case .invalidStorage: "无法读取提醒文件，原文件已保留。请检查存储后重新打开应用。"
        case .storageUnavailable: "无法保存提醒，原有内容已保留。请检查设备存储空间后重试。"
        }
    }
}

/// Foundation-only persistence. The previous in-memory and on-disk values survive failed writes.
final class DaybookReminderRepository {
    private let indexURL: URL
    private(set) var items: [DaybookReminder]

    init(root: URL) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        indexURL = root.appendingPathComponent("reminders.json")
        if FileManager.default.fileExists(atPath: indexURL.path) {
            do {
                items = try JSONDecoder().decode([DaybookReminder].self, from: Data(contentsOf: indexURL))
                try Self.validate(items)
            } catch { throw DaybookReminderError.invalidStorage }
        } else { items = [] }
    }

    func replace(with revised: [DaybookReminder]) throws {
        try Self.validate(revised)
        do {
            let data = try JSONEncoder().encode(revised)
            try data.write(to: indexURL, options: .atomic)
        } catch { throw DaybookReminderError.storageUnavailable }
        items = revised
    }

    private static func validate(_ items: [DaybookReminder]) throws {
        guard Set(items.map(\.id)).count == items.count,
              Set(items.map(\.notificationID)).count == items.count else {
            throw DaybookReminderError.invalidStorage
        }
        for item in items {
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

/// Coordinates the durable file with the system queue. Each edit has a distinct notification ID,
/// so a failed replacement can remove only its candidate and preserve the old reminder.
@MainActor
final class DaybookReminderCoordinator {
    private let repository: DaybookReminderRepository
    private let scheduler: any DaybookReminderScheduling
    private var busy = false
    var items: [DaybookReminder] { repository.items }

    init(repository: DaybookReminderRepository, scheduler: any DaybookReminderScheduling) {
        self.repository = repository
        self.scheduler = scheduler
    }

    @discardableResult
    func confirm(title: String, scheduledAt: Date, sourceID: UUID? = nil, editingID: UUID? = nil) async throws -> DaybookReminder {
        guard !busy else { throw DaybookReminderError.busy }
        busy = true
        defer { busy = false }
        let title = try DaybookReminder.validatedTitle(title)
        try DaybookReminder.validateDate(scheduledAt)
        let previous = editingID.flatMap { id in items.first { $0.id == id } }
        if editingID != nil && previous == nil { throw DaybookReminderError.notFound }
        let activeCount = items.filter { $0.status == .scheduled && $0.scheduledAt > .now && $0.id != editingID }.count
        guard activeCount < 50 else { throw DaybookReminderError.tooManyReminders }
        var permission = await scheduler.authorization()
        if permission == .notDetermined { permission = try await scheduler.requestAuthorization() }
        guard permission.canSchedule else { throw DaybookReminderError.permissionDenied }
        try Task.checkCancellation()
        try DaybookReminder.validateDate(scheduledAt)
        let now = Date.now
        let candidate = DaybookReminder(
            id: previous?.id ?? UUID(), title: title, scheduledAt: scheduledAt,
            sourceID: sourceID ?? previous?.sourceID, status: .scheduled,
            notificationID: DaybookReminder.notificationPrefix + UUID().uuidString,
            createdAt: previous?.createdAt ?? now, updatedAt: now
        )
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
        guard let item = items.first(where: { $0.id == id }) else { throw DaybookReminderError.notFound }
        try repository.replace(with: items.filter { $0.id != id })
        await scheduler.remove(ids: [item.notificationID])
    }

    func reconcile() async throws {
        guard !busy else { throw DaybookReminderError.busy }
        busy = true
        defer { busy = false }
        let pending = await scheduler.pendingIDs()
        let permission = await scheduler.authorization()
        var revised = items
        for index in revised.indices where revised[index].status == .scheduled && revised[index].scheduledAt > .now {
            if !pending.contains(revised[index].notificationID) || !permission.canSchedule {
                revised[index].status = .needsAttention
                revised[index].updatedAt = .now
            }
        }
        if revised != items { try repository.replace(with: revised) }
        let activeIDs = Set(items.filter { $0.status == .scheduled }.map(\.notificationID))
        let obsolete = pending.filter { $0.hasPrefix(DaybookReminder.notificationPrefix) && !activeIDs.contains($0) }
        await scheduler.remove(ids: Array(obsolete))
    }

    private func changeStatus(_ id: UUID, to status: DaybookReminder.Status) async throws {
        guard !busy else { throw DaybookReminderError.busy }
        busy = true
        defer { busy = false }
        guard let index = items.firstIndex(where: { $0.id == id }) else { throw DaybookReminderError.notFound }
        var revised = items
        revised[index].status = status
        revised[index].updatedAt = .now
        try repository.replace(with: revised)
        await scheduler.remove(ids: [revised[index].notificationID])
    }
}
