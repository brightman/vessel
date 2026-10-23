import Foundation
import EventKit

struct ActionSystemList: Identifiable, Equatable {
    let id: String
    let title: String
}
@MainActor protocol ActionSystemServing {
    func lists(kind: ActionItem.Kind, request: Bool) async throws -> [ActionSystemList]
    func save(_ item: ActionItem) async throws -> ActionItem
    func remove(_ item: ActionItem) async throws
    func read(_ item: ActionItem) async throws -> ActionItem?
}

/// Operates exclusively on items carrying this action's stable ownership URL.
@MainActor final class ActionSystemService: ActionSystemServing {
    private let store = EKEventStore()
    private func entity(_ kind: ActionItem.Kind) -> EKEntityType { kind == .event ? .event : .reminder }
    private func access(_ kind: ActionItem.Kind) throws {
        guard EKEventStore.authorizationStatus(for:entity(kind)) == .fullAccess else {
            throw ActionFailure.invalid("未获系统完整访问权限，行动已保留在本机。请在设置中允许后重试。")
        }
    }
    func lists(kind: ActionItem.Kind, request: Bool) async throws -> [ActionSystemList] {
        if request && EKEventStore.authorizationStatus(for:entity(kind)) == .notDetermined {
            if kind == .event { _ = try await store.requestFullAccessToEvents() }
            else { _ = try await store.requestFullAccessToReminders() }
        }
        try access(kind)
        return store.calendars(for:entity(kind)).filter(\.allowsContentModifications).map { ActionSystemList(id:$0.calendarIdentifier,title:"\($0.title) · \($0.source.title)") }
    }
    private func calendar(_ item: ActionItem) throws -> EKCalendar {
        try access(item.kind)
        guard let id = item.link?.listID, let calendar = store.calendars(for:entity(item.kind)).first(where:{$0.calendarIdentifier == id}), calendar.allowsContentModifications else { throw ActionFailure.invalid("所选系统列表不可写，请重新选择。") }
        return calendar
    }
    private func marker(_ item: ActionItem) -> URL { URL(string:"wiselife://action/\(item.id.uuidString)")! }
    private func find(_ item: ActionItem) async throws -> EKCalendarItem? {
        try access(item.kind)
        let url = marker(item)
        if let id = item.link?.identifier, let found = store.calendarItem(withIdentifier:id) {
            guard found.url == url, (item.kind == .event ? found is EKEvent : found is EKReminder) else { throw ActionFailure.invalid("系统项目的关联标记已变化，本次没有修改。") }
            return found
        }
        let found: [EKCalendarItem]
        if item.kind == .event {
            let anchor = item.start ?? item.createdAt
            let predicate = store.predicateForEvents(withStart:anchor.addingTimeInterval(-366*86400),end:(item.end ?? anchor).addingTimeInterval(366*86400),calendars:nil)
            found = store.events(matching:predicate).filter { $0.url == url }
        } else {
            let rows: [EKReminder] = try await withCheckedThrowingContinuation { continuation in
                store.fetchReminders(matching:store.predicateForReminders(in:nil)) { values in
                    if let values { continuation.resume(returning:values) }
                    else { continuation.resume(throwing:ActionFailure.invalid("无法读取系统提醒事项，请重试。")) }
                }
            }
            found = rows.filter { $0.url == url }
        }
        try Task.checkCancellation(); try access(item.kind)
        guard found.count <= 1 else { throw ActionFailure.invalid("发现多个关联项目，请先在系统中核对，未自动修改。") }
        return found.first
    }
    func save(_ item: ActionItem) async throws -> ActionItem {
        let destination = try calendar(item)
        let existing = try await find(item)
        if existing == nil && (item.link?.identifier != nil || item.sync == .missing) { throw ActionFailure.missing }
        let object: EKCalendarItem
        if item.kind == .event {
            let event = (existing as? EKEvent) ?? EKEvent(eventStore:store)
            guard let start = item.start, let end = item.end, end > start else { throw ActionFailure.invalid("请补全日程起止时间。") }
            event.title = item.title; event.calendar = destination; event.url = marker(item)
            event.startDate = start; event.endDate = end; event.isAllDay = item.allDay
            event.timeZone = TimeZone(identifier:item.timeZoneID)
            try store.save(event,span:.thisEvent,commit:true); object = event
        } else {
            let task = (existing as? EKReminder) ?? EKReminder(eventStore:store)
            task.title = item.title; task.calendar = destination; task.url = marker(item)
            task.isCompleted = item.status == .completed
            if let deadline = item.start {
                var calendar = Calendar(identifier:.gregorian); calendar.timeZone = TimeZone(identifier:item.timeZoneID) ?? .current
                var components = calendar.dateComponents([.year,.month,.day,.hour,.minute],from:deadline)
                components.timeZone = calendar.timeZone; components.calendar = calendar
                task.dueDateComponents = components
            } else { task.dueDateComponents = nil }
            // Tasks have a deadline, not an automatic alarm. Reminder notifications use the existing adapter.
            if existing == nil { task.alarms = [] }
            try store.save(task,commit:true); object = task
        }
        var result = item
        result.link?.identifier = object.calendarItemIdentifier
        result.sync = .linked; result.syncError = nil
        return result
    }
    func remove(_ item: ActionItem) async throws {
        guard let found = try await find(item) else { return }
        guard found.calendar.allowsContentModifications else { throw ActionFailure.invalid("系统列表不可写，行动已保留。") }
        if let event = found as? EKEvent { try store.remove(event,span:.thisEvent,commit:true) }
        else if let task = found as? EKReminder { try store.remove(task,commit:true) }
    }
    func read(_ item: ActionItem) async throws -> ActionItem? {
        guard let found = try await find(item) else { return nil }
        var result = item
        result.title = found.title ?? item.title
        result.link = .init(listID:found.calendar.calendarIdentifier,listTitle:found.calendar.title,identifier:found.calendarItemIdentifier)
        if let event = found as? EKEvent {
            result.start = event.startDate; result.end = event.endDate; result.allDay = event.isAllDay
            result.timeZoneID = event.timeZone?.identifier ?? item.timeZoneID
        } else if let task = found as? EKReminder {
            result.status = task.isCompleted ? .completed : .active
            result.start = task.dueDateComponents.flatMap { ($0.calendar ?? Calendar.current).date(from:$0) }
        }
        result.sync = .linked; result.syncError = nil
        return result
    }
}
