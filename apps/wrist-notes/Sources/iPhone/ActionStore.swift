import Combine
import Foundation
import EventKit
import UIKit

@MainActor final class ActionStore: ObservableObject {
    @Published private(set) var items: [ActionItem] = []
    @Published private(set) var busy = false
    @Published var error: String?
    @Published private(set) var available = false
    private var repository: ActionRepository?
    private let system: any ActionSystemServing
    private var reminders: DaybookReminderStore?
    private var observations = Set<AnyCancellable>()
    private var reminderObservation: AnyCancellable?
    private static var executingIDs = Set<UUID>()
    init(repository: ActionRepository? = nil, system: (any ActionSystemServing)? = nil) {
        self.system = system ?? ActionSystemService()
        do { self.repository = try repository ?? ActionRepository(database:DaybookDatabase()); try reload() }
        catch { self.error = error.localizedDescription }
        NotificationCenter.default.publisher(for:.EKEventStoreChanged)
            .merge(with:NotificationCenter.default.publisher(for:UIApplication.didBecomeActiveNotification))
            .merge(with:NotificationCenter.default.publisher(for:UIApplication.protectedDataDidBecomeAvailableNotification))
            .sink { [weak self] _ in Task { @MainActor in await self?.refresh() } }.store(in:&observations)
    }
    func attach(_ reminders: DaybookReminderStore) {
        guard self.reminders == nil else { return }
        self.reminders = reminders
        reminderObservation = reminders.$items.sink { [weak self] rows in
            Task { @MainActor in if self?.busy == false { self?.adopt(rows) } }
        }
        adopt(reminders.items)
    }
    private func reload() throws {
        if repository == nil { repository = try ActionRepository(database:DaybookDatabase()) }
        guard let repository else { throw ActionFailure.invalid("本机行动存储不可用，请重新打开 App。") }
        items = try repository.load().filter { !$0.deleted }.sorted { $0.createdAt > $1.createdAt }; available = true
    }
    @discardableResult private func persist(_ item: ActionItem) throws -> ActionItem {
        guard let repository else { throw ActionFailure.invalid("本机行动存储不可用。") }
        let saved = try repository.save(item); try reload(); return saved
    }
    func addSuggestions(_ values: [ActionItem]) -> Bool {
        guard !busy, let repository else { return false }
        do { for item in values { _ = try repository.addSuggestion(item) }; try reload(); return true }
        catch { self.error = error.localizedDescription; return false }
    }
    private func adopt(_ rows: [DaybookReminder]) {
        guard let repository else { return }
        do {
            let all = try repository.load()
            for row in rows {
                let old = all.first { $0.id == row.id }
                guard old?.deleted != true, old?.status != .suggested,
                      old?.sync != .pending, !(old?.sync == .failed && old?.syncError != nil && row.updatedAt <= (old?.updatedAt ?? .distantPast)) else { continue }
                var item = old ?? ActionItem(kind:.reminder,title:row.title)
                item.id = row.id; item.legacyReminderID = row.id
                item.title = row.title; item.start = row.scheduledAt
                item.createdAt = row.createdAt
                if item.source == nil, let sourceID = row.sourceID {
                    item.source = ActionSource(id:sourceID,title:"来源记录",quote:"",capturedAt:row.createdAt,timeZoneID:TimeZone.current.identifier)
                }
                item.status = row.status == .completed ? .completed : row.status == .cancelled ? .cancelled : .active
                item.link = row.appleLink.map { .init(listID:$0.list.id,listTitle:$0.list.title,identifier:$0.identifier) }
                item.sync = row.appleLink.map { $0.state == .linked ? .linked : $0.state == .missing ? .missing : $0.state == .pending ? .pending : .failed } ?? .local
                if row.status == .needsAttention { item.sync = .failed; item.syncError = "需要重新安排提醒，请编辑时间。" }
                if old != item { _ = try repository.save(item) }
            }
            try reload()
        } catch { self.error = error.localizedDescription }
    }
    func lists(kind: ActionItem.Kind) async throws -> [ActionSystemList] { try await system.lists(kind:kind,request:true) }
    @discardableResult func save(_ value: ActionItem) async -> Bool {
        guard !busy else { return false }; busy = true; error = nil
        defer { busy = false }
        do {
            var item = value
            let old = items.first { $0.id == item.id }
            if let old, old.kind != item.kind, old.legacyReminderID != nil || old.link != nil { throw ActionFailure.invalid("已关联系统的行动不能更换类型，请另建一项。") }
            item.title = item.title.trimmingCharacters(in:.whitespacesAndNewlines)
            item.status = .active; item.deleted = false
            if item.kind == .event && item.allDay {
                var calendar = Calendar(identifier:.gregorian)
                calendar.timeZone = TimeZone(identifier:item.timeZoneID) ?? .current
                item.start = item.start.map { calendar.startOfDay(for:$0) }
                item.end = item.end.map { calendar.startOfDay(for:$0) }
            }
            try item.validate()
            item.operation = old?.link != nil && item.link == nil ? .unlink : .save
            if item.operation == .unlink { item.link = old?.link }
            item.sync = item.kind == .reminder || item.link != nil ? .pending : .local
            item.syncError = nil
            item = try persist(item)
            return await execute(item)
        } catch { self.error = error.localizedDescription; return false }
    }
    @discardableResult func setStatus(_ item: ActionItem, _ status: ActionItem.Status) async -> Bool {
        guard !busy else { return false }; busy = true; error = nil
        defer { busy = false }
        do {
            var value = item; value.status = status
            if status == .active { try value.validate() }
            value.operation = .save
            value.sync = value.kind == .reminder || value.link != nil ? .pending : .local
            return await execute(try persist(value))
        } catch { self.error = error.localizedDescription; return false }
    }
    @discardableResult func delete(_ item: ActionItem) async -> Bool {
        guard !busy else { return false }; busy = true; error = nil
        defer { busy = false }
        do {
            var value = item; value.operation = .delete
            value.sync = .pending
            return await execute(try persist(value))
        } catch { self.error = error.localizedDescription; return false }
    }
    @discardableResult func retry(_ item: ActionItem) async -> Bool {
        guard !busy else { return false }; busy = true; error = nil
        defer { busy = false }
        return await execute(item)
    }
    private func execute(_ input: ActionItem) async -> Bool {
        guard !Self.executingIDs.contains(input.id) else { error = "该行动正在更新，请稍后重试。"; return false }
        Self.executingIDs.insert(input.id)
        defer { Self.executingIDs.remove(input.id) }
        var item = input
        do {
            guard let current = try repository?.load().first(where:{$0.id == input.id}), current.revision == input.revision, !current.deleted else { throw ActionFailure.changed }
            if item.operation == .refresh {
                if let current = try await system.read(item) { item = current }
                else { item.sync = .missing }
            } else if item.status == .suggested {
                if item.operation == .delete { item.deleted = true }
                item.sync = .local
            } else if item.kind == .reminder {
                guard let reminders else { throw ActionFailure.invalid("提醒服务尚未准备好，请重试。") }
                let exists = reminders.items.contains { $0.id == item.id }
                var okay = true
                if item.operation == .delete { if exists { okay = await reminders.delete(item.id) }; item.deleted = okay }
                else if item.status == .completed { if exists { okay = await reminders.complete(item.id) } }
                else if item.status == .cancelled { if exists { okay = await reminders.cancel(item.id) } }
                else {
                    guard let time = item.start else { throw ActionFailure.invalid("请补充提醒时间。") }
                    let list = item.operation == .unlink ? nil : item.link.map { AppleReminderList(id:$0.listID,title:$0.listTitle,accountTitle:"") }
                    okay = await reminders.confirm(title:item.title,scheduledAt:time,sourceID:item.source?.id,editingID:exists ? item.id : nil,appleList:list,newID:item.id)
                }
                guard okay else { throw ActionFailure.invalid(reminders.errorMessage ?? "提醒操作失败，已保留行动供重试。") }
                item.legacyReminderID = item.id
                if let row = reminders.items.first(where:{$0.id == item.id}) {
                    item.link = row.appleLink.map { .init(listID:$0.list.id,listTitle:$0.list.title,identifier:$0.identifier) }
                    item.sync = row.appleLink == nil ? .local : row.appleLink?.state == .linked ? .linked : .failed
                    if item.sync == .failed { throw ActionFailure.invalid(row.appleLink?.lastError ?? "Apple 更新待重试") }
                } else { item.sync = .local }
            } else if item.operation == .delete || item.operation == .unlink || item.status == .cancelled {
                if item.link != nil { try await system.remove(item) }
                item.link = nil; item.sync = .local
                if item.operation == .delete { item.deleted = true }
            } else if item.link != nil { item = try await system.save(item) }
            else { item.sync = .local }
            item.operation = .save; item.syncError = nil
            _ = try persist(item)
            return true
        } catch {
            if case ActionFailure.missing = error { item.sync = .missing } else { item.sync = .failed }
            item.syncError = error.localizedDescription
            self.error = error.localizedDescription
            // Retain desired operation durably; marker lookup makes retry idempotent.
            do { _ = try persist(item) } catch { self.error = error.localizedDescription }
            return false
        }
    }
    func refresh() async {
        guard !busy else { return }; busy = true
        defer { busy = false }
        if let reminders { await reminders.refreshAuthorization(); adopt(reminders.items) }
        do {
            try reload()
            for item in items where item.kind != .reminder && item.status != .suggested && item.link != nil && item.sync == .linked {
                do {
                    if let current = try await system.read(item) { if current != item { _ = try persist(current) } }
                    else { var missing = item; missing.sync = .missing; _ = try persist(missing) }
                } catch { var failed = item; failed.sync = .failed; failed.operation = .refresh; failed.syncError = error.localizedDescription; _ = try? persist(failed) }
            }
        } catch { self.error = error.localizedDescription }
    }
}
