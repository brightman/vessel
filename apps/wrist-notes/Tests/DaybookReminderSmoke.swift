import Foundation

private func expect(_ condition: Bool, _ message: String) {
    if !condition { fatalError(message) }
}

@MainActor
private final class TestNotificationScheduler: DaybookReminderScheduling {
    var permission: DaybookNotificationAuthorization = .authorized
    var permissionAfterRequest: DaybookNotificationAuthorization = .authorized
    var requests = 0
    var scheduled: [String: DaybookReminder] = [:]
    var failSchedule = false
    var afterSchedule: (() -> Void)?
    var scheduleContinuation: CheckedContinuation<Void, Never>?
    var pauseSchedule = false

    func authorization() async -> DaybookNotificationAuthorization { permission }
    func requestAuthorization() async throws -> DaybookNotificationAuthorization {
        requests += 1
        permission = permissionAfterRequest
        return permission
    }
    func schedule(_ reminder: DaybookReminder) async throws {
        scheduled[reminder.notificationID] = reminder
        if pauseSchedule {
            await withCheckedContinuation { scheduleContinuation = $0 }
        }
        afterSchedule?()
        if failSchedule { throw DaybookReminderError.notificationFailure }
    }
    func remove(ids: [String]) async { ids.forEach { scheduled[$0] = nil } }
    func pendingIDs() async -> Set<String> { Set(scheduled.keys) }
}

@main
struct DaybookReminderSmoke {
    @MainActor
    static func main() async throws {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("daybook-reminders-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let root = temporary.appendingPathComponent("Reminders", isDirectory: true)
        let repository = try DaybookReminderRepository(root: root)
        let scheduler = TestNotificationScheduler()
        let coordinator = DaybookReminderCoordinator(repository: repository, scheduler: scheduler)
        let future = Date.now.addingTimeInterval(7200)

        // Removing validation would turn invalid proposals into persisted notifications.
        for (title, date) in [("  \n", future), ("Past", Date.now.addingTimeInterval(-60)), (String(repeating: "长", count: 201), future)] {
            do { _ = try await coordinator.confirm(title: title, scheduledAt: date); fatalError("accepted invalid reminder") }
            catch is DaybookReminderError {}
        }
        expect(coordinator.items.isEmpty && scheduler.scheduled.isEmpty && scheduler.requests == 0, "invalid proposals have no side effects")

        scheduler.permission = .denied
        do { _ = try await coordinator.confirm(title: "权限拒绝", scheduledAt: future); fatalError("ignored denied permission") }
        catch let error as DaybookReminderError { expect(error == .permissionDenied, "denial remains explicit") }
        expect(coordinator.items.isEmpty && scheduler.scheduled.isEmpty, "denial cannot create a scheduled item")

        scheduler.permission = .notDetermined
        scheduler.permissionAfterRequest = .denied
        do { _ = try await coordinator.confirm(title: "首次拒绝", scheduledAt: future); fatalError("ignored first denial") }
        catch let error as DaybookReminderError { expect(error == .permissionDenied, "first request denial") }
        expect(scheduler.requests == 1 && coordinator.items.isEmpty, "permission requested only on confirmation")

        scheduler.permission = .authorized
        let sourceID = UUID()
        let first = try await coordinator.confirm(title: "  发送方案  ", scheduledAt: future, sourceID: sourceID)
        expect(first.title == "发送方案" && first.sourceID == sourceID && first.status == .scheduled, "confirmed reminder is normalized and linked")
        expect(scheduler.scheduled[first.notificationID]?.title == "发送方案", "notification receives confirmed title")
        let reopened = try DaybookReminderRepository(root: root)
        expect(reopened.items == [first], "confirmed reminder survives reopening")

        scheduler.failSchedule = true
        do { _ = try await coordinator.confirm(title: "失败的编辑", scheduledAt: future, editingID: first.id); fatalError("ignored scheduling failure") }
        catch let error as DaybookReminderError { expect(error == .notificationFailure, "surface scheduling failure") }
        expect(coordinator.items == [first] && scheduler.scheduled == [first.notificationID: first], "failed scheduling preserves original and removes candidate")
        expect(try DaybookReminderRepository(root: root).items == [first], "failed scheduling does not alter durable state")
        scheduler.failSchedule = false

        scheduler.afterSchedule = { scheduler.permission = .denied }
        do { _ = try await coordinator.confirm(title: "保存前撤回权限", scheduledAt: future, editingID: first.id); fatalError("committed after permission revoked") }
        catch let error as DaybookReminderError { expect(error == .permissionDenied, "recheck permission before commit") }
        expect(coordinator.items == [first] && scheduler.scheduled == [first.notificationID: first], "permission revoked during scheduling rolls back candidate")
        scheduler.afterSchedule = nil
        scheduler.permission = .authorized

        // A real filesystem obstruction makes atomic persistence fail after scheduling.
        let backup = temporary.appendingPathComponent("RemindersBackup", isDirectory: true)
        scheduler.afterSchedule = {
            try! FileManager.default.moveItem(at: root, to: backup)
            try! Data("blocked".utf8).write(to: root)
        }
        do { _ = try await coordinator.confirm(title: "磁盘失败", scheduledAt: future, editingID: first.id); fatalError("ignored storage failure") }
        catch {}
        expect(coordinator.items == [first] && scheduler.scheduled == [first.notificationID: first], "failed persistence rolls back candidate notification and memory")
        try FileManager.default.removeItem(at: root)
        try FileManager.default.moveItem(at: backup, to: root)
        scheduler.afterSchedule = nil
        expect(try DaybookReminderRepository(root: root).items == [first], "failed persistence leaves old index intact")

        let edited = try await coordinator.confirm(title: "更新方案", scheduledAt: future.addingTimeInterval(600), editingID: first.id)
        expect(edited.id == first.id && edited.sourceID == sourceID && edited.notificationID != first.notificationID, "edit preserves identity and renews notification")
        expect(scheduler.scheduled == [edited.notificationID: edited], "successful edit removes old notification")

        try FileManager.default.moveItem(at: root, to: backup)
        try Data("blocked".utf8).write(to: root)
        do { try await coordinator.cancel(edited.id); fatalError("ignored cancellation persistence failure") } catch {}
        expect(coordinator.items == [edited] && scheduler.scheduled == [edited.notificationID: edited], "failed cancellation keeps active reminder")
        try FileManager.default.removeItem(at: root)
        try FileManager.default.moveItem(at: backup, to: root)
        try await coordinator.cancel(edited.id)
        expect(coordinator.items[0].status == .cancelled && scheduler.scheduled.isEmpty, "cancel persists and removes notification")
        expect(try DaybookReminderRepository(root: root).items[0].status == .cancelled, "cancel survives restart")

        let resumed = try await coordinator.confirm(title: "再次安排", scheduledAt: future, editingID: first.id)
        try await coordinator.complete(resumed.id)
        expect(coordinator.items[0].status == .completed && scheduler.scheduled.isEmpty, "completion persists and removes notification")
        try await coordinator.delete(resumed.id)
        expect(try coordinator.items.isEmpty && DaybookReminderRepository(root: root).items.isEmpty, "delete persists")
        do { try await coordinator.complete(UUID()); fatalError("accepted unknown ID") }
        catch let error as DaybookReminderError { expect(error == .notFound, "unknown ID is explicit") }

        let pending = try await coordinator.confirm(title: "重启检查", scheduledAt: future)
        var orphan = pending
        orphan.id = UUID()
        orphan.notificationID = DaybookReminder.notificationPrefix + UUID().uuidString
        scheduler.scheduled[orphan.notificationID] = orphan
        scheduler.scheduled["some-other-feature"] = orphan
        try await coordinator.reconcile()
        expect(scheduler.scheduled[orphan.notificationID] == nil && scheduler.scheduled["some-other-feature"] != nil, "reconcile removes only orphaned owned notifications")
        scheduler.scheduled[pending.notificationID] = nil
        try await coordinator.reconcile()
        expect(coordinator.items[0].status == .needsAttention, "missing future notification is not reported as scheduled")
        expect(try DaybookReminderRepository(root: root).items[0].status == .needsAttention, "attention state is durable")

        // Overlapping edits must not overwrite the first transaction's snapshot.
        scheduler.pauseSchedule = true
        let inFlight = Task { try await coordinator.confirm(title: "稍后提交", scheduledAt: future) }
        while scheduler.scheduleContinuation == nil { await Task.yield() }
        do { try await coordinator.delete(pending.id); fatalError("accepted overlapping mutation") }
        catch let error as DaybookReminderError { expect(error == .busy, "concurrent mutation is rejected") }
        scheduler.scheduleContinuation?.resume()
        scheduler.scheduleContinuation = nil
        _ = try await inFlight.value
        scheduler.pauseSchedule = false

        let beforeCancellation = coordinator.items
        let notificationsBeforeCancellation = scheduler.scheduled
        scheduler.pauseSchedule = true
        let cancelled = Task { try await coordinator.confirm(title: "取消中的安排", scheduledAt: future) }
        while scheduler.scheduleContinuation == nil { await Task.yield() }
        cancelled.cancel()
        scheduler.scheduleContinuation?.resume()
        scheduler.scheduleContinuation = nil
        do { _ = try await cancelled.value; fatalError("committed cancelled operation") }
        catch is CancellationError {}
        scheduler.pauseSchedule = false
        expect(coordinator.items == beforeCancellation && scheduler.scheduled == notificationsBeforeCancellation, "cancelled scheduling removes its candidate and preserves existing reminders")

        let corruptRoot = temporary.appendingPathComponent("Corrupt", isDirectory: true)
        try FileManager.default.createDirectory(at: corruptRoot, withIntermediateDirectories: true)
        let corruptURL = corruptRoot.appendingPathComponent("reminders.json")
        let corruptData = Data("existing unreadable data".utf8)
        try corruptData.write(to: corruptURL)
        do { _ = try DaybookReminderRepository(root: corruptRoot); fatalError("silently reset corrupt reminders") } catch {}
        expect(try Data(contentsOf: corruptURL) == corruptData, "opening corrupt data must not replace it")

        let suite = "daybook-preferences-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = DaybookPreferences(defaults: defaults)
        preferences.proactiveEnabled = true
        preferences.allowAudio = false
        preferences.allowPhotos = false
        preferences.quietEnabled = true
        preferences.quietStartMinutes = 22 * 60
        preferences.quietEndMinutes = 8 * 60
        preferences.dailySuggestionLimit = 4
        let reloadedPreferences = DaybookPreferences(defaults: defaults)
        expect(reloadedPreferences.proactiveEnabled && !reloadedPreferences.allowAudio && !reloadedPreferences.allowPhotos && reloadedPreferences.dailySuggestionLimit == 4, "source permissions and frequency survive reopening")
        func time(_ hour: Int, _ minute: Int = 0) -> Date {
            Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 19, hour: hour, minute: minute))!
        }
        expect(reloadedPreferences.isQuiet(at: time(22)) && reloadedPreferences.isQuiet(at: time(7, 59)), "overnight quiet interval includes start and early morning")
        expect(!reloadedPreferences.isQuiet(at: time(8)) && !reloadedPreferences.isQuiet(at: time(21, 59)), "quiet end is exclusive")
        preferences.quietStartMinutes = 9 * 60
        preferences.quietEndMinutes = 17 * 60
        expect(preferences.isQuiet(at: time(12)) && !preferences.isQuiet(at: time(18)), "same-day quiet interval")
        preferences.quietEndMinutes = preferences.quietStartMinutes
        expect(preferences.isQuiet(at: time(3)), "equal times mean all-day quiet")
        preferences.quietEnabled = false
        expect(!preferences.isQuiet(at: time(3)), "disabled quiet mode permits suggestions")
        preferences.quietStartMinutes = -5
        preferences.quietEndMinutes = 2000
        preferences.dailySuggestionLimit = 0
        expect(preferences.quietStartMinutes == 0 && preferences.quietEndMinutes == 1439 && preferences.dailySuggestionLimit == 1, "invalid preferences are bounded")

        print("Daybook reminders: validation, permission denial, durable create/edit/cancel/complete/delete, scheduling and disk rollback, reconciliation, concurrency, corrupt storage and preferences passed")
    }
}
