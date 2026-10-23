import Foundation
import EventKit

/// EventKit boundary. Access is requested only from the explicit connect action.
/// The opaque URL identifies tasks owned by this local reminder; no recording content is exported.
@MainActor
final class AppleReminderService: AppleReminderServing {
    private let store: EKEventStore

    init(store: EKEventStore = EKEventStore()) { self.store = store }

    func authorization() -> AppleReminderAccess {
        switch EKEventStore.authorizationStatus(for: .reminder) {
        case .notDetermined: return .notDetermined
        case .restricted: return .restricted
        case .fullAccess: return .authorized
        case .denied, .writeOnly: return .denied
        // Legacy authorized values can still be returned after an OS upgrade.
        case .authorized: return .authorized
        @unknown default: return .denied
        }
    }

    func requestAccess() async throws -> Bool {
        do { return try await store.requestFullAccessToReminders() }
        catch { throw AppleReminderFailure.accessDenied }
    }

    func lists() throws -> [AppleReminderList] {
        try requireAccess()
        return store.calendars(for: .reminder).filter(\.allowsContentModifications)
            .map(Self.list).sorted {
                if $0.accountTitle != $1.accountTitle { return $0.accountTitle.localizedStandardCompare($1.accountTitle) == .orderedAscending }
                return $0.title.localizedStandardCompare($1.title) == .orderedAscending
            }
    }

    func upsert(_ reminder: DaybookReminder) async throws -> AppleReminderSnapshot {
        try requireAccess()
        guard let link = reminder.appleLink else { throw AppleReminderFailure.noList }
        let title = try DaybookReminder.validatedTitle(reminder.title)
        guard reminder.scheduledAt.timeIntervalSince1970.isFinite else { throw DaybookReminderError.invalidDate }
        let existing = try await ownedTask(reminder)
        // A settled association must never silently recreate an externally deleted task.
        guard existing != nil || (link.identifier == nil && link.lastSynced == nil) else { throw AppleReminderFailure.missing }
        let destination = try writableCalendar(link.list.id)
        if let existing { _ = try writableCalendar(existing.calendar.calendarIdentifier) }
        try Task.checkCancellation()
        try requireAccess()
        let task = existing ?? EKReminder(eventStore: store)
        task.calendar = destination
        task.title = title
        task.url = marker(reminder.id)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        var due = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: reminder.scheduledAt)
        due.calendar = calendar
        due.timeZone = calendar.timeZone
        task.startDateComponents = due
        task.dueDateComponents = due
        task.alarms = [EKAlarm(absoluteDate: reminder.scheduledAt)]
        task.isCompleted = reminder.status == .completed
        do { try store.save(task, commit: true) }
        catch { throw AppleReminderFailure.writeFailed }
        return try snapshot(task)
    }

    func remove(_ reminder: DaybookReminder) async throws {
        try requireAccess()
        guard let task = try await ownedTask(reminder) else { return }
        _ = try writableCalendar(task.calendar.calendarIdentifier)
        try Task.checkCancellation()
        try requireAccess()
        do { try store.remove(task, commit: true) }
        catch { throw AppleReminderFailure.writeFailed }
    }

    func read(_ reminder: DaybookReminder) async throws -> AppleReminderSnapshot? {
        try requireAccess()
        guard let task = try await ownedTask(reminder) else { return nil }
        _ = try writableCalendar(task.calendar.calendarIdentifier)
        return try snapshot(task)
    }

    private func requireAccess() throws {
        guard authorization() == .authorized else { throw AppleReminderFailure.accessDenied }
    }

    private func writableCalendar(_ id: String) throws -> EKCalendar {
        guard let calendar = store.calendars(for: .reminder).first(where: { $0.calendarIdentifier == id }),
              calendar.allowsContentModifications else { throw AppleReminderFailure.noList }
        return calendar
    }

    private func marker(_ id: UUID) -> URL {
        // UUID is generated locally; it contains no user text or source recording identifier.
        URL(string: "wiselife://reminder/" + id.uuidString)!
    }

    private func ownedTask(_ reminder: DaybookReminder) async throws -> EKReminder? {
        guard let link = reminder.appleLink else { throw AppleReminderFailure.missing }
        let expected = marker(reminder.id)
        // An identifier pointing at another item is not absence and must never be overwritten.
        if let id = link.identifier, let cached = store.calendarItem(withIdentifier: id) {
            guard let cached = cached as? EKReminder, cached.url == expected else { throw AppleReminderFailure.ownershipChanged }
        }
        let predicate = store.predicateForReminders(in: nil)
        let fetched: [EKReminder] = try await withCheckedThrowingContinuation { continuation in
            store.fetchReminders(matching: predicate) { reminders in
                guard let reminders else {
                    continuation.resume(throwing: AppleReminderFailure.unavailable)
                    return
                }
                continuation.resume(returning: reminders)
            }
        }
        try Task.checkCancellation()
        try requireAccess()
        let matches = fetched.filter { $0.url == expected }
        guard matches.count <= 1 else { throw AppleReminderFailure.ownershipChanged }
        // A full marker scan also catches a successful EventKit save whose local acknowledgement
        // was interrupted, or an identifier changed by a move between reminder lists.
        return matches.first
    }

    private static func list(_ calendar: EKCalendar) -> AppleReminderList {
        AppleReminderList(id: calendar.calendarIdentifier, title: calendar.title, accountTitle: calendar.source.title)
    }

    private func snapshot(_ task: EKReminder) throws -> AppleReminderSnapshot {
        let title = try DaybookReminder.validatedTitle(task.title ?? "")
        guard let components = task.dueDateComponents,
              components.year != nil, components.month != nil, components.day != nil else {
            throw AppleReminderFailure.writeFailed
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = components.timeZone ?? .current
        var normalized = components
        normalized.calendar = calendar
        normalized.timeZone = calendar.timeZone
        guard normalized.isValidDate(in: calendar), let date = calendar.date(from: normalized),
              date.timeIntervalSince1970.isFinite else { throw AppleReminderFailure.writeFailed }
        return AppleReminderSnapshot(identifier: task.calendarItemIdentifier, title: title,
            scheduledAt: date, completed: task.isCompleted, list: Self.list(task.calendar))
    }
}
