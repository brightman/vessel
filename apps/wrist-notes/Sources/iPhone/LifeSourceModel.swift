import Combine
import Foundation

@MainActor
final class LifeSourceModel: ObservableObject {
    @Published private(set) var records: [DayRecord] = []
    @Published private(set) var revision = 0
    @Published private(set) var refreshing: Set<LifeSource> = []
    @Published var errorMessage: String?
    @Published private(set) var healthObservationMessage: String?
    private var store: LifeSourceStore?
    private let storeURL: URL
    private var reader: any LifeSourceReading
    private var locationPermissionAllowed = false
    private var locationStatusDay = Date.now
    private var active = true
    private var tasks: [LifeSource: Task<Void, Never>] = [:]
    private var generations: [LifeSource: UUID] = [:]
    private var selectedDay = Date.now
    private var lastCalendarDay = Calendar.current.startOfDay(for: Date.now)
    private var rolloverTask: Task<Void, Never>?
    private var observationID: UUID?
    private var healthObservationNeedsRetry = false
    private var healthTask: Task<Void, Never>?
    private var healthDeadline: Task<Void, Never>?
    private var healthGeneration = UUID()
    private var pendingHealthDays: Set<Date> = []
    private var currentHealthDays: Set<Date> = []
    private var pendingHealthCompletions: [() -> Void] = []
    private var currentHealthCompletions: [() -> Void] = []
    private let healthTimeout: Duration
    // Only an observation-registration hint, never permission to read. SQLite stays authoritative.
    private let observationDefaults: UserDefaults?
    private static let observationHintKey = "wiselife.health.observation.enabled"
    #if os(iOS)
    convenience init() {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        self.init(url: root.appendingPathComponent("WristNotes/LifeSources/snapshots.json"), reader: LifeSourceReader(), observationDefaults: .standard)
    }
    #endif
    init(url: URL, reader: any LifeSourceReading, healthTimeout: Duration = .seconds(20), observationDefaults: UserDefaults? = nil) {
        self.storeURL = url
        self.reader = reader
        self.healthTimeout = healthTimeout
        self.observationDefaults = observationDefaults
        do {
            store = try LifeSourceStore(url: url); publish()
            #if os(iOS)
            CaptureLocationSettings.setEnabled(isEnabled(.location))
            #endif
        }
        catch { errorMessage = "生活数据无法载入：\(error.localizedDescription)" }
        self.reader.onLocationAuthorizationChange = { [weak self] in
            guard let self else { return }
            self.refreshLocationStatus(day: self.locationStatusDay)
        }
        restoreHealthObservation()
        scheduleRollover()
    }
    func isEnabled(_ source: LifeSource) -> Bool { store?.isEnabled(source) ?? false }
    func isSuppressed(_ id: UUID) -> Bool { store?.isSuppressed(id) ?? false }
    @discardableResult func confirmWake(_ id: UUID, expectedEnd: Date, confirmed: Bool) -> Bool {
        guard let store else { errorMessage = "生活数据尚未载入。"; return false }
        do { try store.confirmWake(id, expectedEnd: expectedEnd, confirmed: confirmed); errorMessage = nil; publish(); return true }
        catch { errorMessage = "起床确认未保存；睡眠记录可能已更新，请重新打开后确认。"; return false }
    }
    func snapshot(_ source: LifeSource, day: Date) -> LifeSourceSnapshot? { store?.snapshot(source: source, day: Calendar.current.startOfDay(for: day)) }
    func status(_ source: LifeSource, day: Date = .now) -> String {
        guard isEnabled(source) else { return "已暂停" }
        if refreshing.contains(source) { return "正在刷新" }
        guard let snapshot = snapshot(source, day: day) else { return source == .location ? "仅新记录时获取" : "尚未刷新" }
        let label: String = switch snapshot.status { case .ready: "已更新"; case .empty: source == .health ? "无可读取数据" : "暂无数据"; case .awaitingAuthorization: "等待定位授权"; case .denied: "权限受限"; case .unavailable: "设备不可用"; case .error: "刷新失败" }
        if source == .location, locationPermissionAllowed, !snapshot.isStale, snapshot.status == .ready || snapshot.status == .empty { return "权限已允许 · 采集时记录" }
        return snapshot.isStale ? "\(label) · 保留旧数据" : label
    }
    func setEnabled(_ enabled: Bool, source: LifeSource, day: Date) async {
        guard let store else { return }
        do {
            try store.setEnabled(enabled, source: source)
            #if os(iOS)
            if source == .location { CaptureLocationSettings.setEnabled(enabled) }
            #endif
            cancel(source)
            if source == .health {
                observationDefaults?.set(enabled, forKey: Self.observationHintKey)
                observationID = nil
                reader.stopHealthObservation()
                healthObservationMessage = nil
                healthObservationNeedsRetry = false
            }
            if source == .location { locationPermissionAllowed = false; locationStatusDay = day }
            publish()
            guard enabled, active else { return }
            let token = UUID(); generations[source] = token
            do {
                try await reader.authorize(source)
                guard active, isEnabled(source), generations[source] == token else { return }
                if source == .health { startHealthObservationIfEnabled() }
                if source == .location { refreshLocationStatus(day: day) } else { refresh(source, day: day) }
            } catch {
                guard active, isEnabled(source), generations[source] == token else { return }
                fail(error, source: source, day: day)
            }
        } catch { errorMessage = "设置未保存：\(error.localizedDescription)" }
    }
    func refresh(_ source: LifeSource, day: Date) {
        guard active, isEnabled(source), source != .location else { return }
        if source == .health {
            selectedDay = day
            startHealthObservationIfEnabled()
            enqueueHealthRefresh(days: [day, Calendar.current.date(byAdding: .day, value: -1, to: day)!])
            return
        }
        cancel(source)
        let token = UUID(); generations[source] = token
        refreshing.insert(source)
        tasks[source] = Task {
            do {
                let records = try await reader.read(source, day: day, calendar: .current)
                try Task.checkCancellation()
                guard self.active, self.isEnabled(source), self.generations[source] == token else { return }
                try self.store?.replace(source: source, day: Calendar.current.startOfDay(for: day), records: records, refreshedAt: .now)
                self.publish()
            } catch {
                guard !Task.isCancelled, self.active, self.isEnabled(source), self.generations[source] == token else { return }
                self.fail(error, source: source, day: day)
            }
            if self.generations[source] == token { self.refreshing.remove(source); self.tasks[source] = nil }
        }
    }
    func refreshLocationStatus(day: Date) {
        guard active, isEnabled(.location), let store else { return }
        locationStatusDay = day
        if let issue = reader.locationAvailabilityIssue() {
            locationPermissionAllowed = false
            fail(issue, source: .location, day: day)
        } else {
            locationPermissionAllowed = true
            let day = Calendar.current.startOfDay(for: day)
            do {
                try store.replace(source: .location, day: day, records: store.snapshot(source: .location, day: day)?.records ?? [], refreshedAt: store.snapshot(source: .location, day: day)?.refreshedAt ?? .now)
                publish()
            } catch { errorMessage = "状态未保存：\(error.localizedDescription)" }
        }
    }
    func refreshEnabled(day: Date) {
        selectedDay = day
        for source in LifeSource.allCases where source != .location { refresh(source, day: day) }
        refreshLocationStatus(day: day)
    }
    func setForeground(_ value: Bool, day: Date) {
        active = value
        selectedDay = day
        if value {
            refreshForCalendarChange(now: .now, day: day)
            scheduleRollover()
            recoverAfterUnlock()
            refreshEnabled(day: day)
        } else {
            rolloverTask?.cancel(); rolloverTask = nil
            // Health deliveries own a completion handler and must finish even when the UI leaves.
            LifeSource.allCases.filter { $0 != .health }.forEach(cancel)
        }
    }
    /// Runs while the process is active; foreground/unlock and HealthKit catch up after suspension.
    func refreshForCalendarChange(now: Date, day: Date) {
        let today = Calendar.current.startOfDay(for: now)
        guard active, today != lastCalendarDay else { return }
        lastCalendarDay = today; selectedDay = day
        enqueueHealthRefresh(days: healthRefreshDays(now: now))
        publish()
    }
    private func scheduleRollover() {
        rolloverTask?.cancel()
        guard active else { return }
        let now = Date.now
        let next = Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: now))!
        rolloverTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(max(1, next.timeIntervalSince(now)))) } catch { return }
            guard let self, self.active else { return }
            self.refreshForCalendarChange(now: .now, day: self.selectedDay)
            self.scheduleRollover()
        }
    }
    /// Complete file protection can prevent opening SQLite on a cold background launch.
    /// Never replace a failed store with an empty one; retry it when protected data returns.
    func recoverAfterUnlock() {
        if store == nil {
            do { store = try LifeSourceStore(url: storeURL); errorMessage = nil; publish() }
            catch { errorMessage = "生活数据无法载入：\(error.localizedDescription)"; return }
        }
        restoreHealthObservation()
        enqueueHealthRefresh(days: healthRefreshDays())
    }

    private func restoreHealthObservation() {
        if store != nil { observationDefaults?.set(isEnabled(.health), forKey: Self.observationHintKey) }
        if healthObservationNeedsRetry {
            observationID = nil
            reader.stopHealthObservation()
            healthObservationNeedsRetry = false
            healthObservationMessage = nil
        }
        if store != nil, !isEnabled(.health) {
            observationID = nil
            reader.stopHealthObservation()
        } else { startHealthObservationIfEnabled() }
    }

    private func startHealthObservationIfEnabled() {
        // On a locked cold launch, install the previously enabled observer before launch ends.
        // Its callbacks acknowledge without reading until SQLite can confirm the source setting.
        let lockedLaunchHint = store == nil && observationDefaults?.bool(forKey: Self.observationHintKey) == true
        guard isEnabled(.health) || lockedLaunchHint, observationID == nil else { return }
        let id = UUID(); observationID = id
        reader.startHealthObservation(onChange: { [weak self] completion in
            guard let self, self.observationID == id, self.isEnabled(.health) else { completion(); return }
            self.enqueueHealthRefresh(days: self.healthRefreshDays(), completion: completion)
        }, onError: { [weak self] error in
            guard let self, self.observationID == id else { return }
            self.healthObservationNeedsRetry = true
            self.healthObservationMessage = "健康自动更新暂不可用：\(error.localizedDescription)。回到前台仍会尝试刷新。"
        })
    }

    private func healthRefreshDays(now: Date = .now) -> [Date] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        return [today, calendar.date(byAdding: .day, value: -1, to: today)!, selectedDay,
                calendar.date(byAdding: .day, value: -1, to: selectedDay)!]
    }

    /// One writer for manual, foreground and observer refreshes. Changes arriving during a
    /// read join the next pass, so a notification never acknowledges an older in-flight read.
    private func enqueueHealthRefresh(days: [Date], completion: (() -> Void)? = nil) {
        guard isEnabled(.health), store != nil else { completion?(); return }
        pendingHealthDays.formUnion(days.map { Calendar.current.startOfDay(for: $0) })
        if let completion { pendingHealthCompletions.append(completion) }
        guard healthTask == nil else { return }
        let token = UUID(); healthGeneration = token
        refreshing.insert(.health)
        healthDeadline = Task { [weak self, healthTimeout] in
            do { try await Task.sleep(for: healthTimeout) } catch { return }
            guard let self, self.healthGeneration == token else { return }
            for day in self.currentHealthDays.union(self.pendingHealthDays) {
                self.fail(LifeSourceReadFailure(status: .error, message: "健康刷新超时；解锁或回到前台后重试。"), source: .health, day: day)
            }
            self.cancelHealthRefresh()
        }
        healthTask = Task { [weak self] in
            guard let self else { return }
            while self.healthGeneration == token, !self.pendingHealthDays.isEmpty {
                let days = self.pendingHealthDays.sorted(by: >)
                self.currentHealthDays = self.pendingHealthDays
                self.pendingHealthDays.removeAll()
                self.currentHealthCompletions = self.pendingHealthCompletions
                self.pendingHealthCompletions.removeAll()
                for day in days {
                    do {
                        let records = try await self.reader.read(.health, day: day, calendar: .current)
                        try Task.checkCancellation()
                        guard self.healthGeneration == token, self.isEnabled(.health) else { return }
                        try self.store?.replace(source: .health, day: day, records: records, refreshedAt: .now)
                        self.publish()
                    } catch {
                        guard self.healthGeneration == token, !Task.isCancelled, self.isEnabled(.health) else { return }
                        self.fail(error, source: .health, day: day)
                    }
                    self.currentHealthDays.remove(day)
                }
                let completions = self.currentHealthCompletions
                self.currentHealthCompletions.removeAll()
                completions.forEach { $0() }
            }
            guard self.healthGeneration == token else { return }
            self.healthDeadline?.cancel(); self.healthDeadline = nil
            self.healthTask = nil; self.refreshing.remove(.health)
        }
    }

    private func cancelHealthRefresh() {
        healthGeneration = UUID()
        healthTask?.cancel(); healthTask = nil
        healthDeadline?.cancel(); healthDeadline = nil
        pendingHealthDays.removeAll(); currentHealthDays.removeAll()
        reader.stop(.health)
        refreshing.remove(.health)
        let completions = currentHealthCompletions + pendingHealthCompletions
        currentHealthCompletions.removeAll(); pendingHealthCompletions.removeAll()
        completions.forEach { $0() }
    }
    @discardableResult func delete(_ id: UUID) -> Bool {
        guard let store else { errorMessage = "本机生活数据尚未载入，无法删除。"; return false }
        do { try store.delete(id); errorMessage = nil; publish(); return true }
        catch { errorMessage = "记录未删除：\(error.localizedDescription)"; return false }
    }
    func isStale(_ record: DayRecord) -> Bool {
        let source: LifeSource = switch record.kind { case .activity, .sleep: .health; case .calendar: .calendar; default: .location }
        let date = record.lifeMoment?.steps?.archived == true ? record.lifeMoment!.steps!.interval.start : record.capturedAt
        return snapshot(source, day: date)?.isStale ?? false
    }
    private func cancel(_ source: LifeSource) {
        if source == .health { cancelHealthRefresh() }
        else { reader.stop(source) }
        generations[source] = UUID(); tasks[source]?.cancel(); tasks[source] = nil; refreshing.remove(source)
    }
    private func fail(_ error: Error, source: LifeSource, day: Date) {
        do {
            let failure = error as? LifeSourceReadFailure
            try store?.markFailure(source: source, day: Calendar.current.startOfDay(for: day), status: failure?.status ?? .error, message: error.localizedDescription)
            publish()
        } catch { errorMessage = "状态未保存：\(error.localizedDescription)" }
    }
    private func publish() { records = store?.records ?? []; revision += 1 }
}
