import Foundation

private func expect(_ value: Bool, _ message: String) { if !value { fatalError(message) } }

@MainActor private final class FakeLocalAlerts: DaybookReminderScheduling {
    var pending: [String: DaybookReminder] = [:]
    func authorization() async -> DaybookNotificationAuthorization { .authorized }
    func requestAuthorization() async throws -> DaybookNotificationAuthorization { .authorized }
    func schedule(_ reminder: DaybookReminder) async throws { pending[reminder.notificationID] = reminder }
    func remove(ids: [String]) async { for id in ids { pending[id] = nil } }
    func pendingIDs() async -> Set<String> { Set(pending.keys) }
}

@MainActor private final class FakeAppleReminders: AppleReminderServing {
    var access = AppleReminderAccess.authorized
    var records: [UUID: AppleReminderSnapshot] = [:]
    var failWrite = false, failAfterWrite = false, failDelete = false
    var creations = 0
    var afterWrite: (() throws -> Void)?
    let list = AppleReminderList(id: "example-list", title: "WiseLife", accountTitle: "iCloud")
    func authorization() -> AppleReminderAccess { access }
    func requestAccess() async throws -> Bool { access == .authorized }
    func lists() throws -> [AppleReminderList] { [list] }
    func upsert(_ reminder: DaybookReminder) async throws -> AppleReminderSnapshot {
        guard access == .authorized else { throw AppleReminderFailure.accessDenied }
        if failWrite { throw AppleReminderFailure.writeFailed }
        if records[reminder.id] == nil, reminder.appleLink?.lastSynced != nil { throw AppleReminderFailure.missing }
        if records[reminder.id] == nil { creations += 1 }
        let snapshot = AppleReminderSnapshot(identifier: records[reminder.id]?.identifier ?? UUID().uuidString,
            title: reminder.title, scheduledAt: reminder.scheduledAt, completed: reminder.status == .completed,
            list: reminder.appleLink!.list)
        records[reminder.id] = snapshot
        try afterWrite?()
        if failAfterWrite { throw AppleReminderFailure.writeFailed }
        return snapshot
    }
    func remove(_ reminder: DaybookReminder) async throws {
        guard access == .authorized else { throw AppleReminderFailure.accessDenied }
        if failDelete { throw AppleReminderFailure.writeFailed }
        records[reminder.id] = nil
    }
    func read(_ reminder: DaybookReminder) async throws -> AppleReminderSnapshot? {
        guard access == .authorized else { throw AppleReminderFailure.accessDenied }
        return records[reminder.id]
    }
}

@main struct AppleRemindersSmoke {
    @MainActor static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = try DaybookReminderRepository(root: root), local = FakeLocalAlerts(), apple = FakeAppleReminders()
        let service = DaybookReminderCoordinator(repository: repo, scheduler: local, apple: apple)
        let future = Date.now.addingTimeInterval(86_400)
        let original = try await service.confirm(title: "Local reminder", scheduledAt: future)
        expect(local.pending.count == 1 && original.appleLink == nil, "existing local-only behavior")
        let linked = try await service.confirm(title: "Contact follow-up", scheduledAt: future,
            editingID: original.id, appleList: apple.list)
        expect(linked.appleLink?.state == .linked && local.pending.isEmpty, "Apple link suppresses local alert")
        expect(apple.creations == 1, "one actual task")
        expect(try DaybookReminderRepository(root: root).items == service.items, "Apple payload survives reopening")

        apple.failWrite = true
        let edited = try await service.confirm(title: "Updated title", scheduledAt: future.addingTimeInterval(60),
            editingID: linked.id, appleList: apple.list)
        expect(edited.appleLink?.state == .failed && edited.title == "Updated title", "failed change keeps local intent")
        expect(apple.records[linked.id]?.title == "Contact follow-up" && local.pending.isEmpty, "old Apple item remains without duplicate local alert")
        apple.failWrite = false
        try await service.retryApple(linked.id)
        expect(apple.records[linked.id]?.title == "Updated title" && apple.creations == 1, "retry updates same task")
        try await service.complete(linked.id)
        expect(apple.records[linked.id]?.completed == true, "completion reaches Apple")

        apple.failDelete = true
        try await service.delete(linked.id)
        expect(service.items.contains { $0.id == linked.id } && apple.records[linked.id] != nil, "delete failure preserves both")
        apple.failDelete = false
        try await service.retryApple(linked.id)
        expect(!service.items.contains { $0.id == linked.id } && apple.records[linked.id] == nil, "delete retry removes both")

        apple.access = .denied
        let denied = try await service.confirm(title: "Keep despite denied access", scheduledAt: future, appleList: apple.list)
        expect(denied.appleLink?.state == .failed && denied.status == .needsAttention, "permission loss keeps task data")
        expect(local.pending.isEmpty, "no false notification claim on failed Apple add")
        apple.access = .authorized
        try await service.retryApple(denied.id)
        var external = apple.records[denied.id]!
        external.title = "Edited in Reminders"; external.scheduledAt = future.addingTimeInterval(3600); external.completed = true
        apple.records[denied.id] = external
        try await service.reconcile()
        expect(service.items.first { $0.id == denied.id }?.title == external.title, "external title pulled only for linked item")
        expect(service.items.first { $0.id == denied.id }?.status == .completed, "external completion reflected")
        apple.access = .denied
        try await service.reconcile()
        expect(service.items.first { $0.id == denied.id }?.appleLink?.operation == .refresh, "read failure is never retried as a write")
        external.title = "External changes while permission denied"
        apple.records[denied.id] = external
        apple.access = .authorized
        try await service.retryApple(denied.id)
        expect(service.items.first { $0.id == denied.id }?.title == external.title, "permission recovery preserves external edit")
        apple.records[denied.id] = nil
        try await service.reconcile()
        expect(service.items.first { $0.id == denied.id }?.appleLink?.state == .missing, "external deletion retained as missing")
        let creationCount = apple.creations
        try await service.retryApple(denied.id)
        expect(apple.creations == creationCount, "never silently recreate externally deleted linked task")

        apple.failAfterWrite = true
        let interrupted = try await service.confirm(title: "Interrupted after external save", scheduledAt: future, appleList: apple.list)
        let beforeRetry = apple.creations
        expect(interrupted.appleLink?.state == .failed && apple.records[interrupted.id] != nil, "ambiguous save retained")
        apple.failAfterWrite = false
        let reopened = DaybookReminderCoordinator(repository: try DaybookReminderRepository(root: root), scheduler: local, apple: apple)
        try await reopened.retryApple(interrupted.id)
        expect(apple.creations == beforeRetry && reopened.items.first { $0.id == interrupted.id }?.appleLink?.state == .linked, "restart retry finds same opaque task marker")
        let unlinked = try await reopened.confirm(title: "Back to local", scheduledAt: future, editingID: interrupted.id)
        expect(unlinked.appleLink == nil && apple.records[interrupted.id] == nil && local.pending.count == 1, "unlink removes Apple before scheduling local")
        let draftID = UUID()
        let acknowledgementDB = try DaybookDatabase(url: DaybookDatabase.metadataURL(forRoot: root))
        apple.afterWrite = {
            try acknowledgementDB.execute("CREATE TRIGGER fail_apple_ack BEFORE UPDATE ON daybook_reminders BEGIN SELECT RAISE(FAIL, 'simulated acknowledgement failure'); END")
        }
        do {
            _ = try await reopened.confirm(title: "Stable editor draft", scheduledAt: future, appleList: apple.list, newID: draftID)
            fatalError("acknowledgement persistence should fail")
        } catch DaybookReminderError.storageUnavailable {}
        let beforeDraftRetry = apple.creations
        expect(apple.records[draftID] != nil, "external task already created before acknowledgement failure")
        try acknowledgementDB.execute("DROP TRIGGER fail_apple_ack")
        apple.afterWrite = nil
        _ = try await reopened.confirm(title: "Stable editor draft", scheduledAt: future, appleList: apple.list, newID: draftID)
        expect(apple.creations == beforeDraftRetry && reopened.items.filter { $0.id == draftID }.count == 1,
               "new-editor retry reuses durable intent identity after acknowledgement failure")

        // Reopen an actual v3 schema with existing reminder data, then migrate in place.
        let legacyRoot = root.appendingPathComponent("v3")
        let legacy = try DaybookReminderRepository(root: legacyRoot)
        var old = original; old.appleLink = nil
        try legacy.replace(with: [old])
        let databaseURL = DaybookDatabase.metadataURL(forRoot: legacyRoot)
        do {
            let database = try DaybookDatabase(url: databaseURL)
            try database.execute("DROP TABLE reminder_apple_links")
            try database.execute("PRAGMA user_version=3")
        }
        let migrated = try DaybookReminderRepository(root: legacyRoot)
        expect(migrated.items == [old], "v3 migration preserves local reminders")
        let db = try DaybookDatabase(url: databaseURL)
        expect(try db.query("PRAGMA user_version").first?.requiredDouble("user_version") == 9, "schema migrates to current version")
        print("Apple reminder persistence, recovery and synchronization tests passed")
    }
}
