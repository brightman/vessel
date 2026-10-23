import Combine
import Foundation
import EventKit
import UserNotifications
import UIKit

@MainActor
final class DaybookReminderStore: ObservableObject {
    @Published private(set) var items: [DaybookReminder] = []
    @Published private(set) var isBusy = false
    @Published private(set) var isAvailable = false
    @Published private(set) var authorization: DaybookNotificationAuthorization = .notDetermined
    @Published var errorMessage: String?
    @Published private(set) var appleAccess: AppleReminderAccess = .notDetermined
    @Published private(set) var appleLists: [AppleReminderList] = []
    @Published private(set) var isLoadingApple = false
    @Published private(set) var appleError: String?

    private let apple: any AppleReminderServing
    private let scheduler: any DaybookReminderScheduling
    private let root: URL
    private var coordinator: DaybookReminderCoordinator?
    private var lifecycleObservation: AnyCancellable?
    private var refreshRequested = false
    private var storageError: String?

    init(root: URL? = nil, scheduler: (any DaybookReminderScheduling)? = nil, apple: (any AppleReminderServing)? = nil) {
        let scheduler = scheduler ?? DaybookSystemNotificationScheduler()
        self.scheduler = scheduler
        self.apple = apple ?? AppleReminderService()
        self.root = root ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DaybookReminders", isDirectory: true)
        do {
            let opened = try openCoordinator()
            items = opened.items
            isAvailable = true
        } catch {
            storageError = error.localizedDescription
            errorMessage = storageError
        }
        lifecycleObservation = NotificationCenter.default.publisher(for: UIApplication.protectedDataDidBecomeAvailableNotification)
            .merge(with: NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification))
            .merge(with: NotificationCenter.default.publisher(for: .EKEventStoreChanged))
            .sink { [weak self] _ in Task { @MainActor [weak self] in await self?.refreshAuthorization() } }
        Task { [weak self] in await self?.refreshAuthorization() }
    }

    /// Confirmation persists the chosen destination and schedules the reminder.
    /// Call it after the user has reviewed the title/date and pressed the confirmation button.
    @discardableResult
    func confirm(title: String, scheduledAt: Date, sourceID: UUID? = nil, editingID: UUID? = nil, appleList: AppleReminderList? = nil, newID: UUID? = nil) async -> Bool {
        await perform { coordinator in
            try await coordinator.confirm(title: title, scheduledAt: scheduledAt, sourceID: sourceID, editingID: editingID, appleList: appleList, newID: newID)
        }
    }

    /// Permission is requested only from the editor's explicit Apple opt-in action.
    func requestAppleAccess() async {
        guard !isLoadingApple else { return }
        isLoadingApple = true
        defer { isLoadingApple = false }
        appleError = nil
        do {
            if apple.authorization() == .notDetermined { _ = try await apple.requestAccess() }
            refreshAppleLists()
            if appleAccess != .authorized { appleError = AppleReminderFailure.accessDenied.localizedDescription }
        } catch {
            appleAccess = apple.authorization()
            appleError = error.localizedDescription
        }
    }

    func refreshAppleLists() {
        appleAccess = apple.authorization()
        appleLists = []
        appleError = nil
        guard appleAccess == .authorized else { return }
        do {
            appleLists = try apple.lists()
            if appleLists.isEmpty { appleError = AppleReminderFailure.noList.localizedDescription }
        } catch { appleError = error.localizedDescription }
    }

    @discardableResult
    func retryApple(_ id: UUID) async -> Bool {
        await perform { try await $0.retryApple(id) }
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
        guard !isBusy else { refreshRequested = true; return }
        isBusy = true
        defer { finishOperation() }
        authorization = await scheduler.authorization()
        refreshAppleLists()
        do {
            let coordinator = try openCoordinator()
            try await coordinator.reconcile()
            items = coordinator.items
            isAvailable = true
            if errorMessage == storageError { errorMessage = nil }
            storageError = nil
        } catch {
            isAvailable = false
            storageError = error.localizedDescription
            errorMessage = storageError
        }
    }

    private func perform<T>(_ operation: (DaybookReminderCoordinator) async throws -> T) async -> Bool {
        guard !isBusy else { errorMessage = DaybookReminderError.busy.localizedDescription; return false }
        isBusy = true
        errorMessage = nil
        defer { finishOperation() }
        do {
            let coordinator = try openCoordinator()
            _ = try await operation(coordinator)
            items = coordinator.items
            isAvailable = true
            authorization = await scheduler.authorization()
            return true
        } catch {
            if let coordinator { items = coordinator.items }
            else { isAvailable = false }
            authorization = await scheduler.authorization()
            errorMessage = error is CancellationError ? "操作已取消，原有提醒已保留。" : error.localizedDescription
            return false
        }
    }
    private func openCoordinator() throws -> DaybookReminderCoordinator {
        if let coordinator { return coordinator }
        let repository = try DaybookReminderRepository(root: root)
        let opened = DaybookReminderCoordinator(repository: repository, scheduler: scheduler, apple: apple)
        coordinator = opened
        return opened
    }

    private func finishOperation() {
        isBusy = false
        if refreshRequested {
            refreshRequested = false
            Task { [weak self] in await self?.refreshAuthorization() }
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
        content.title = String(localized: "WiseLife 提醒", locale: Locale(identifier: UserDefaults.standard.string(forKey: "interfaceLanguage") ?? "zh-Hans"))
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
