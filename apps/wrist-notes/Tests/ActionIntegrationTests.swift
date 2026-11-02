import XCTest
@testable import WiseLifeActionVerification

@MainActor final class ActionFakeSystem: ActionSystemServing {
    var values: [UUID:ActionItem] = [:]
    var failAfterSave = false
    var failDelete = false
    var failRead = false
    var saves = 0
    var holdNextSave = false
    var gate: CheckedContinuation<Void, Never>?
    func lists(kind: ActionItem.Kind, request: Bool) async throws -> [ActionSystemList] { [.init(id:"test",title:"Test")] }
    func save(_ item: ActionItem) async throws -> ActionItem {
        if holdNextSave { holdNextSave = false; await withCheckedContinuation { gate = $0 } }
        saves += 1
        var result = item; result.link?.identifier = item.id.uuidString; result.sync = .linked; result.syncError = nil
        values[item.id] = result
        if failAfterSave { failAfterSave = false; throw ActionFailure.invalid("acknowledgment interrupted") }
        return result
    }
    func remove(_ item: ActionItem) async throws { if failDelete { throw ActionFailure.invalid("delete failed") }; values[item.id] = nil }
    func read(_ item: ActionItem) async throws -> ActionItem? { if failRead { throw ActionFailure.invalid("read failed") }; guard var value = values[item.id] else { return nil }; value.revision = item.revision; value.operation = item.operation; return value }
}
final class ActionFakeScheduler: DaybookReminderScheduling {
    var ids = Set<String>(); var schedules = 0
    func authorization() async -> DaybookNotificationAuthorization { .authorized }
    func requestAuthorization() async throws -> DaybookNotificationAuthorization { .authorized }
    func schedule(_ reminder: DaybookReminder) async throws { ids.insert(reminder.notificationID); schedules += 1 }
    func remove(ids: [String]) async { self.ids.subtract(ids) }
    func pendingIDs() async -> Set<String> { ids }
}
@MainActor final class ActionFakeApple: AppleReminderServing {
    func authorization() -> AppleReminderAccess { .denied }
    func requestAccess() async throws -> Bool { false }
    func lists() throws -> [AppleReminderList] { [] }
    func upsert(_ reminder: DaybookReminder) async throws -> AppleReminderSnapshot { throw AppleReminderFailure.accessDenied }
    func remove(_ reminder: DaybookReminder) async throws { throw AppleReminderFailure.accessDenied }
    func read(_ reminder: DaybookReminder) async throws -> AppleReminderSnapshot? { nil }
}

@MainActor final class ActionIntegrationTests: XCTestCase {
    func testFlashEditingCompletedTaskKeepsCompletion() async throws {
        let repo = try ActionRepository(database: DaybookDatabase(inMemory: true))
        var task = ActionItem(kind: .todo, title: "完成的草图")
        task.dedupKey = "flash|completed-edit"; task.status = .completed
        let saved = try repo.save(task)
        let store = ActionStore(repository: repo, system: ActionFakeSystem())
        var edited = saved; edited.title = "草图二版"
        let okay = await store.save(edited)
        XCTAssertTrue(okay)
        XCTAssertEqual(store.flashTimelineItems.first?.title, "草图二版")
        XCTAssertEqual(store.flashTimelineItems.first?.status, .completed, "Editing content must not silently reopen a completed task")
    }

    func testFlashDeletionRemainsInSourceTimelineAfterReopen() async throws {
        let db = try DaybookDatabase(inMemory: true)
        let repo = try ActionRepository(database: db)
        let source = ActionSource(id: UUID(), title: "来源闪念", quote: "安排日程", capturedAt: .now, timeZoneID: "Asia/Shanghai")
        var event = ActionItem(kind: .event, title: "测试日程", source: source)
        event.start = .now.addingTimeInterval(3600); event.end = .now.addingTimeInterval(7200)
        event.dedupKey = "flash|timeline-delete"; event.sync = .pending
        _ = try repo.save(event)
        let system = ActionFakeSystem()
        // Use one system owner across execution, failure, retry and reopen.
        let live = ActionStore(repository: repo, system: system)
        await live.resumeFlashCommands()
        system.failDelete = true
        let failed = await live.delete(try XCTUnwrap(live.items.first))
        XCTAssertFalse(failed)
        XCTAssertEqual(FlashCommandState(item: try XCTUnwrap(live.flashTimelineItems.first)), .deleteFailed)
        XCTAssertEqual(system.values.count, 1)
        system.failDelete = false
        let retried = await live.retry(try XCTUnwrap(live.items.first))
        XCTAssertTrue(retried); XCTAssertTrue(system.values.isEmpty); XCTAssertTrue(live.items.isEmpty)
        let reopened = ActionStore(repository: repo, system: system)
        XCTAssertTrue(reopened.items.isEmpty)
        let tombstone = try XCTUnwrap(reopened.flashTimelineItems.first)
        XCTAssertEqual(tombstone.source?.id, source.id)
        XCTAssertEqual(FlashCommandState(item: tombstone), .revoked)
        await reopened.resumeFlashCommands()
        XCTAssertTrue(system.values.isEmpty, "Opening the timeline must not recreate a deleted command")
    }

    func testFlashOutboxWaitsForBusyStore() async throws {
        let repo = try ActionRepository(database: DaybookDatabase(inMemory: true))
        let system = ActionFakeSystem()
        let busyStore = ActionStore(repository: repo, system: system)
        var regular = ActionItem(kind: .event, title: "正在保存")
        regular.start = .now.addingTimeInterval(3600); regular.end = .now.addingTimeInterval(7200)
        regular.link = .init(listID: "test", listTitle: "Test")
        system.holdNextSave = true
        let saving = Task { await busyStore.save(regular) }
        while system.gate == nil { await Task.yield() }
        var flash = regular; flash.id = UUID(); flash.title = "新闪念"; flash.dedupKey = "flash|busy"; flash.sync = .pending
        _ = try repo.save(flash)
        let resuming = Task { await busyStore.resumeFlashCommands() }
        for _ in 0..<10 { await Task.yield() }
        system.gate?.resume()
        _ = await saving.value; await resuming.value
        XCTAssertEqual(system.values.count, 2, "New commands must not get stranded when another action is saving")
    }

    func testFlashReminderSchedulesOnceAndCancels() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = try ActionRepository(database: DaybookDatabase(url: root.appendingPathComponent("db.sqlite")))
        let scheduler = ActionFakeScheduler()
        let reminders = DaybookReminderStore(root: root.appendingPathComponent("reminders"), scheduler: scheduler, apple: ActionFakeApple())
        await reminders.refreshAuthorization()
        let store = ActionStore(repository: repo, system: ActionFakeSystem()); store.attach(reminders)
        var reminder = ActionItem(kind: .reminder, title: "测试提醒")
        reminder.start = .now.addingTimeInterval(3600); reminder.sync = .pending; reminder.dedupKey = "flash|reminder"
        _ = try repo.save(reminder)
        await store.resumeFlashCommands(); await store.resumeFlashCommands()
        XCTAssertEqual(scheduler.schedules, 1); XCTAssertEqual(scheduler.ids.count, 1)
        let cancelled = await store.setStatus(try XCTUnwrap(store.items.first), .cancelled)
        XCTAssertTrue(cancelled); XCTAssertTrue(scheduler.ids.isEmpty)
        await store.resumeFlashCommands(); XCTAssertEqual(scheduler.schedules, 1)
    }
    func testFlashOutboxRecoveryAndRevocation() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let db = try DaybookDatabase(url: root.appendingPathComponent("flash.sqlite"))
        let repo = try ActionRepository(database: db), assets = try FlashCaptureRepository(database: db)
        let source = ActionSource(id: UUID(), title: "测试闪念", quote: "帮我安排日程", capturedAt: .now, timeZoneID: "Asia/Shanghai", recordingKind: "thought", timeZoneKnown: true)
        var event = ActionItem(kind: .event, title: "测试日程", source: source)
        event.start = Date.now.addingTimeInterval(3600); event.end = event.start!.addingTimeInterval(1800)
        event.dedupKey = "flash|test"; event.sync = .pending
        try assets.commit(.init(actions: [event]), source: source)
        let system = ActionFakeSystem(); system.failAfterSave = true
        let store = ActionStore(repository: repo, system: system)
        await store.resumeFlashCommands()
        XCTAssertEqual(store.items.first?.sync, .failed)
        XCTAssertEqual(system.values.count, 1, "Acknowledge loss still leaves one owned event")
        let reopened = ActionStore(repository: try ActionRepository(database: DaybookDatabase(url: db.url)), system: system)
        let retried = await reopened.retry(try XCTUnwrap(reopened.items.first))
        XCTAssertTrue(retried); XCTAssertEqual(system.values.count, 1)
        await reopened.resumeFlashCommands()
        XCTAssertEqual(system.saves, 2, "Completed outbox items must not execute on reopen")
        let cancelled = await reopened.setStatus(try XCTUnwrap(reopened.items.first), .cancelled)
        XCTAssertTrue(cancelled); XCTAssertTrue(system.values.isEmpty)
        try assets.commit(.init(actions: [event]), source: source)
        await reopened.resumeFlashCommands()
        XCTAssertEqual(system.saves, 2); XCTAssertEqual(try repo.load().first?.status, .cancelled)
    }

    func testIncompleteFlashCommandDoesNotSchedule() async throws {
        let db = try DaybookDatabase(inMemory: true)
        let repo = try ActionRepository(database: db)
        var item = ActionItem(kind: .event, title: "缺时间的日程")
        item.dedupKey = "flash|incomplete"; item.sync = .pending
        _ = try repo.save(item)
        let system = ActionFakeSystem()
        let store = ActionStore(repository: repo, system: system)
        await store.resumeFlashCommands()
        XCTAssertEqual(store.items.first?.sync, .failed)
        XCTAssertEqual(store.items.first?.statusTitle, "待补充")
        XCTAssertEqual(system.saves, 0)
    }
    func testDurableRetryReadAndDelete() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let repo = try ActionRepository(database:DaybookDatabase(url:root.appendingPathComponent("test.sqlite")))
        let system = ActionFakeSystem()
        let store = ActionStore(repository:repo,system:system)
        var event = ActionItem(kind:.event,title:"讨论")
        event.start = Date.now.addingTimeInterval(3600); event.end = event.start!.addingTimeInterval(3600)
        event.link = .init(listID:"test",listTitle:"Test")
        system.failAfterSave = true
        let failed = await store.save(event)
        XCTAssertFalse(failed); XCTAssertEqual(store.items.first?.sync,.failed); XCTAssertEqual(system.values.count,1)
        let reopened = ActionStore(repository:try ActionRepository(database:DaybookDatabase(url:root.appendingPathComponent("test.sqlite"))),system:system)
        let retried = await reopened.retry(try XCTUnwrap(reopened.items.first))
        XCTAssertTrue(retried); XCTAssertEqual(system.values.count,1); XCTAssertEqual(reopened.items.first?.sync,.linked)
        let saves = system.saves
        let staleEdit = await reopened.save(event)
        XCTAssertFalse(staleEdit); XCTAssertEqual(system.saves,saves,"Stale UI must fail before a system write")
        system.failRead = true; await reopened.refresh()
        XCTAssertEqual(reopened.items.first?.operation,.refresh)
        system.failRead = false
        let refreshed = await reopened.retry(try XCTUnwrap(reopened.items.first))
        XCTAssertTrue(refreshed); XCTAssertEqual(system.saves,saves,"Refreshing must not overwrite external edits")
        system.failDelete = true
        let deleted = await reopened.delete(try XCTUnwrap(reopened.items.first))
        XCTAssertFalse(deleted); XCTAssertEqual(reopened.items.count,1)
        XCTAssertEqual(reopened.items.first?.operation,.delete)
        system.failDelete = false
        let deletionRetry = await reopened.retry(try XCTUnwrap(reopened.items.first))
        XCTAssertTrue(deletionRetry); XCTAssertTrue(reopened.items.isEmpty); XCTAssertTrue(system.values.isEmpty)
        XCTAssertTrue(try repo.load().first?.deleted == true)
    }
    func testUndatedTaskAndLegacyIdentity() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let repo = try ActionRepository(database:DaybookDatabase(url:root.appendingPathComponent("actions.sqlite")))
        let system = ActionFakeSystem(), scheduler = ActionFakeScheduler()
        let reminderStore = DaybookReminderStore(root:root.appendingPathComponent("reminders"),scheduler:scheduler,apple:ActionFakeApple())
        await reminderStore.refreshAuthorization()
        while reminderStore.isBusy { await Task.yield() }
        let made = await reminderStore.confirm(title:"已有提醒",scheduledAt:.now.addingTimeInterval(7200))
        XCTAssertTrue(made)
        let existing = try XCTUnwrap(reminderStore.items.first)
        let store = ActionStore(repository:repo,system:system); store.attach(reminderStore)
        await store.refresh()
        XCTAssertEqual(store.items.first?.id,existing.id)
        XCTAssertEqual(reminderStore.items.first?.notificationID,existing.notificationID)
        XCTAssertEqual(scheduler.schedules,1)
        let saved = await store.save(ActionItem(kind:.todo,title:"无时间待办"))
        XCTAssertTrue(saved); XCTAssertEqual(store.items.count,2); XCTAssertEqual(scheduler.schedules,1)
        await store.refresh(); XCTAssertEqual(store.items.count,2)
        let task = try XCTUnwrap(store.items.first{$0.kind == .todo})
        let done = await store.setStatus(task,.completed); XCTAssertTrue(done)
        let restore = await store.setStatus(try XCTUnwrap(store.items.first{$0.id == task.id}),.active)
        XCTAssertTrue(restore); XCTAssertEqual(scheduler.schedules,1)
        var allDay = ActionItem(kind:.event,title:"全天安排")
        allDay.timeZoneID = "Asia/Shanghai"; allDay.allDay = true
        var calendar = Calendar(identifier:.gregorian); calendar.timeZone = TimeZone(identifier:allDay.timeZoneID)!
        allDay.start = calendar.date(from:DateComponents(year:2026,month:10,day:25,hour:10))
        allDay.end = calendar.date(from:DateComponents(year:2026,month:10,day:26,hour:16))
        let savedEvent = await store.save(allDay); XCTAssertTrue(savedEvent)
        let normalized = try XCTUnwrap(store.items.first{$0.id == allDay.id})
        XCTAssertEqual(calendar.component(.hour,from:try XCTUnwrap(normalized.start)),0)
        XCTAssertEqual(calendar.component(.hour,from:try XCTUnwrap(normalized.end)),0)
        XCTAssertEqual(normalized.end!.timeIntervalSince(normalized.start!),86400)
    }
}
