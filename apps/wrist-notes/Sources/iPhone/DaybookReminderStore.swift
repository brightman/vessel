import Combine
import Foundation
import UserNotifications

@MainActor
final class DaybookReminderStore: ObservableObject {
    @Published private(set) var items: [DaybookReminder] = []
    @Published private(set) var isBusy = false
    @Published private(set) var isAvailable = false
    @Published private(set) var authorization: DaybookNotificationAuthorization = .notDetermined
    @Published var errorMessage: String?

    private let scheduler: any DaybookReminderScheduling
    private let coordinator: DaybookReminderCoordinator?

    init(root: URL? = nil, scheduler: (any DaybookReminderScheduling)? = nil) {
        let scheduler = scheduler ?? DaybookSystemNotificationScheduler()
        self.scheduler = scheduler
        do {
            let directory: URL
            if let root { directory = root }
            else {
                directory = try FileManager.default.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
                    .appendingPathComponent("DaybookReminders", isDirectory: true)
            }
            let repository = try DaybookReminderRepository(root: directory)
            coordinator = DaybookReminderCoordinator(repository: repository, scheduler: scheduler)
            items = repository.items
            isAvailable = true
        } catch {
            coordinator = nil
            errorMessage = error.localizedDescription
        }
        Task { [weak self] in await self?.refreshAuthorization() }
    }

    /// This is the only path that requests permission or schedules notifications.
    /// Call it after the user has reviewed the title/date and pressed the confirmation button.
    @discardableResult
    func confirm(title: String, scheduledAt: Date, sourceID: UUID? = nil, editingID: UUID? = nil) async -> Bool {
        await perform { coordinator in
            try await coordinator.confirm(title: title, scheduledAt: scheduledAt, sourceID: sourceID, editingID: editingID)
        }
    }

    @discardableResult
    func cancel(_ id: UUID) async -> Bool {
        await perform { try await $0.cancel(id) }
    }

    @discardableResult
    func complete(_ id: UUID) async -> Bool {
        await perform { try await $0.complete(id) }
    }

    @discardableResult
    func delete(_ id: UUID) async -> Bool {
        await perform { try await $0.delete(id) }
    }

    /// Reads system state without requesting notification permission.
    /// Reconciliation repairs a process interruption between scheduling and persisting an edit.
    func refreshAuthorization() async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        authorization = await scheduler.authorization()
        guard let coordinator else { return }
        do {
            try await coordinator.reconcile()
            items = coordinator.items
        } catch { errorMessage = error.localizedDescription }
    }

    private func perform<T>(_ operation: (DaybookReminderCoordinator) async throws -> T) async -> Bool {
        guard !isBusy else { errorMessage = DaybookReminderError.busy.localizedDescription; return false }
        guard let coordinator else {
            errorMessage = DaybookReminderError.invalidStorage.localizedDescription
            return false
        }
        isBusy = true
        errorMessage = nil
        defer { isBusy = false }
        do {
            _ = try await operation(coordinator)
            items = coordinator.items
            authorization = await scheduler.authorization()
            return true
        } catch {
            items = coordinator.items
            authorization = await scheduler.authorization()
            errorMessage = error is CancellationError ? "操作已取消，原有提醒已保留。" : error.localizedDescription
            return false
        }
    }
}

@MainActor
final class DaybookSystemNotificationScheduler: NSObject, DaybookReminderScheduling, UNUserNotificationCenterDelegate {
    private let center: UNUserNotificationCenter

    init(center: UNUserNotificationCenter = .current()) {
        self.center = center
        super.init()
        // The store retains this scheduler; UNUserNotificationCenter keeps its delegate weak.
        // Respect an existing app-level delegate if another feature installs one first.
        if center.delegate == nil { center.delegate = self }
    }

    func authorization() async -> DaybookNotificationAuthorization {
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .notDetermined: return .notDetermined
        case .denied: return .denied
        case .authorized, .ephemeral: return .authorized
        case .provisional: return .provisional
        @unknown default: return .unavailable
        }
    }

    func requestAuthorization() async throws -> DaybookNotificationAuthorization {
        do { _ = try await center.requestAuthorization(options: [.alert, .sound]) }
        catch { throw DaybookReminderError.notificationFailure }
        return await authorization()
    }

    func schedule(_ reminder: DaybookReminder) async throws {
        try DaybookReminder.validateDate(reminder.scheduledAt)
        let content = UNMutableNotificationContent()
        content.title = "WiseNote 提醒"
        content.body = reminder.title
        content.sound = .default
        content.threadIdentifier = "wisenote.daybook.reminders"
        content.userInfo = ["daybookReminderID": reminder.id.uuidString]
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: reminder.scheduledAt.timeIntervalSinceNow, repeats: false)
        let request = UNNotificationRequest(identifier: reminder.notificationID, content: content, trigger: trigger)
        do {
            try await center.add(request)
            guard await pendingIDs().contains(reminder.notificationID) else {
                throw DaybookReminderError.notificationFailure
            }
        } catch { throw DaybookReminderError.notificationFailure }
    }

    func remove(ids: [String]) async {
        guard !ids.isEmpty else { return }
        center.removePendingNotificationRequests(withIdentifiers: ids)
        center.removeDeliveredNotifications(withIdentifiers: ids)
    }

    func pendingIDs() async -> Set<String> {
        Set(await center.pendingNotificationRequests().map(\.identifier))
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        guard notification.request.identifier.hasPrefix(DaybookReminder.notificationPrefix) else { return [] }
        return [.banner, .list, .sound]
    }
}
