import Foundation

@MainActor private final class HealthReader: LifeSourceReading {
    struct Read {
        let day: Date
        let continuation: CheckedContinuation<[DayRecord], Error>
    }
    var onLocationAuthorizationChange: (() -> Void)?
    var authorizations: [LifeSource] = []
    var reads: [Date] = []
    var pending: [Read] = []
    var starts = 0
    var stops = 0
    var change: ((@escaping () -> Void) -> Void)?
    var observationError: ((Error) -> Void)?
    func authorize(_ source: LifeSource) async throws { authorizations.append(source) }
    func read(_ source: LifeSource, day: Date, calendar: Calendar) async throws -> [DayRecord] {
        precondition(source == .health)
        reads.append(day)
        return try await withCheckedThrowingContinuation { pending.append(Read(day: day, continuation: $0)) }
    }
    func startHealthObservation(onChange: @escaping (@escaping () -> Void) -> Void, onError: @escaping (Error) -> Void) {
        starts += 1; change = onChange; observationError = onError
    }
    func stopHealthObservation() { stops += 1; change = nil }
    func stop(_ source: LifeSource) {} // Deliberately allow late callbacks to test generation guards.
    func oneShotLocation() async throws -> LifeCoordinate { fatalError("must not acquire location") }
    func finish(_ result: Result<[DayRecord], Error>? = nil) {
        let read = pending.removeFirst()
        read.continuation.resume(with: result ?? .success([record(day: read.day)]))
    }
    func record(day: Date) -> DayRecord {
        DayRecord(id: LifeAggregation.recordID(source: .health, key: "steps", day: day), capturedAt: day,
                  kind: .activity, title: "步数", text: "10 步", metricValue: 10)
    }
}

@main struct HealthRefreshSmoke {
    @MainActor static func spin() async { for _ in 0..<80 { await Task.yield() } }
    @MainActor static func until(_ condition: () -> Bool) async {
        for _ in 0..<2000 { if condition() { return }; await Task.yield() }
        precondition(condition(), "async condition did not become true")
    }
    @MainActor private static func drain(_ reader: HealthReader, model: LifeSourceModel) async {
        for _ in 0..<100 {
            await spin()
            if !reader.pending.isEmpty { reader.finish() }
            else if !model.refreshing.contains(.health) { return }
        }
        preconditionFailure("health queue did not drain")
    }
    @MainActor static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let day = Calendar.current.startOfDay(for: .now)
        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: day)!
        let historical = Calendar.current.date(byAdding: .day, value: -12, to: day)!
        let beforeHistorical = Calendar.current.date(byAdding: .day, value: -1, to: historical)!
        let disabledReader = HealthReader()
        let disabled = LifeSourceModel(url: root.appendingPathComponent("disabled.json"), reader: disabledReader)
        disabled.setForeground(true, day: day); await spin()
        precondition(disabledReader.starts == 0 && disabledReader.reads.isEmpty && disabledReader.authorizations.isEmpty)

        let url = root.appendingPathComponent("enabled.json")
        try LifeSourceStore(url: url).setEnabled(true, source: .health)
        let reader = HealthReader()
        let model = LifeSourceModel(url: url, reader: reader)
        precondition(reader.starts == 1, "enabled health observation must register on initialization, before a view appears")
        precondition(reader.authorizations.isEmpty && reader.reads.isEmpty, "relaunch never prompts")
        model.setForeground(false, day: historical)
        var completed = 0
        reader.change? { completed += 1 }
        reader.change? { completed += 1 }
        await until { !reader.pending.isEmpty }
        precondition(reader.pending.count == 1 && completed == 0)
        await drain(reader, model: model)
        precondition(completed == 2 && Set(reader.reads) == Set([day, yesterday, historical, beforeHistorical]) && reader.reads.count == 4,
                     "a notification burst merges into one refresh per day, including yesterday, selected day and its prior day")
        let persisted = try LifeSourceStore(url: url)
        precondition(persisted.records.count == 4, "background updates must commit SQLite before completion")

        // A new change during an in-flight read requires a subsequent pass, without parallel reads.
        let before = reader.reads.count
        reader.change? { completed += 1 }
        await until { !reader.pending.isEmpty }
        reader.change? { completed += 1 }
        precondition(reader.pending.count == 1)
        await drain(reader, model: model)
        precondition(completed == 4 && reader.reads.count == before + 8)
        model.setForeground(true, day: historical)
        await drain(reader, model: model)
        precondition(reader.starts == 1 && reader.authorizations.isEmpty, "foreground catch-up must not duplicate observers")
        let beforeMidnight = reader.reads.count
        let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: day)!
        model.refreshForCalendarChange(now: tomorrow, day: historical)
        await drain(reader, model: model)
        precondition(Set(reader.reads.dropFirst(beforeMidnight)) == Set([tomorrow, day, historical, beforeHistorical]),
                     "Midnight refresh includes the completed statistical day even while viewing history")
        let afterMidnight = reader.reads.count
        model.refreshForCalendarChange(now: tomorrow.addingTimeInterval(60), day: historical)
        await spin()
        precondition(reader.reads.count == afterMidnight, "Same-day ticks do not keep querying HealthKit")
        let oldObservationError = reader.observationError!
        oldObservationError(LifeSourceReadFailure(status: .error, message: "Background delivery failed"))
        precondition(model.healthObservationMessage?.contains("Background delivery failed") == true)
        model.setForeground(true, day: historical)
        await drain(reader, model: model)
        precondition(reader.starts == 2 && reader.stops == 1 && model.healthObservationMessage == nil,
                     "foreground retries a failed observer registration without prompting")
        oldObservationError(LifeSourceReadFailure(status: .error, message: "stale error"))
        precondition(model.healthObservationMessage == nil, "old observation session errors must be ignored")

        // A successful empty read reconciles samples deleted in HealthKit.
        reader.change? {}
        await until { !reader.pending.isEmpty }
        let deletedDay = reader.pending[0].day
        reader.finish(.success([]))
        await drain(reader, model: model)
        precondition(model.snapshot(.health, day: deletedDay)?.status == .empty)
        let afterDeletion = try LifeSourceStore(url: url)
        precondition(afterDeletion.snapshot(source: .health, day: deletedDay)?.records.isEmpty == true)
        model.recoverAfterUnlock(); await drain(reader, model: model)

        // A protected-data/query error keeps the old data, marks it stale and acknowledges delivery.
        reader.change? { completed += 1 }
        await until { !reader.pending.isEmpty }
        let failedDay = reader.pending[0].day
        reader.finish(.failure(LifeSourceReadFailure(status: .error, message: "Protected data unavailable")))
        await drain(reader, model: model)
        precondition(completed == 5 && model.snapshot(.health, day: failedDay)?.isStale == true)
        precondition(model.snapshot(.health, day: failedDay)?.records.count == 1)
        model.recoverAfterUnlock()
        await drain(reader, model: model)
        precondition(model.snapshot(.health, day: failedDay)?.isStale == false)

        // Pause drains pending handlers once; stale observer/read callbacks cannot overwrite saved data.
        let staleChange = reader.change!
        reader.change? { completed += 1 }
        await until { !reader.pending.isEmpty }
        let old = model.records
        await model.setEnabled(false, source: .health, day: day)
        precondition(completed == 6 && reader.stops == 2 && !model.refreshing.contains(.health))
        staleChange { completed += 1 }
        reader.finish(.success([])); await spin()
        precondition(completed == 7 && model.records == old)
        model.setForeground(true, day: day); await spin()
        precondition(reader.pending.isEmpty)
        await model.setEnabled(true, source: .health, day: day)
        await drain(reader, model: model)
        precondition(reader.starts == 3 && reader.authorizations == [.health])
        staleChange { completed += 1 }; await spin()
        precondition(completed == 8 && reader.pending.isEmpty, "prior observation session must remain invalid after re-enable")

        let restoredReader = HealthReader()
        let restored = LifeSourceModel(url: url, reader: restoredReader)
        precondition(restoredReader.starts == 1 && restored.records == model.records && restoredReader.authorizations.isEmpty)
        await restored.setEnabled(false, source: .health, day: day)

        // A hung read must not leave HealthKit completion handlers pending indefinitely.
        let timeoutURL = root.appendingPathComponent("timeout.json")
        let timeoutStore = try LifeSourceStore(url: timeoutURL)
        try timeoutStore.setEnabled(true, source: .health)
        try timeoutStore.replace(source: .health, day: day, records: [reader.record(day: day)], refreshedAt: .now)
        let slow = HealthReader()
        let timeoutModel = LifeSourceModel(url: timeoutURL, reader: slow, healthTimeout: .milliseconds(50))
        var timeouts = 0
        slow.change? { timeouts += 1 }
        await until { !slow.pending.isEmpty }
        slow.change? { timeouts += 1 }
        try await Task.sleep(for: .milliseconds(150))
        precondition(timeouts == 2 && !timeoutModel.refreshing.contains(.health))
        precondition(timeoutModel.snapshot(.health, day: day)?.isStale == true)
        slow.finish(.success([])); await spin()
        precondition(timeouts == 2 && timeoutModel.snapshot(.health, day: day)?.records.count == 1)
        await timeoutModel.setEnabled(false, source: .health, day: day)

        // A cold launch with unavailable SQLite is recoverable; it must not create empty history.
        let recoveryURL = root.appendingPathComponent("recovery.json")
        let recoveryDB = DaybookDatabase.url(forLegacy: recoveryURL)
        try FileManager.default.createDirectory(at: recoveryDB, withIntermediateDirectories: true)
        let recoveringReader = HealthReader()
        let recovering = LifeSourceModel(url: recoveryURL, reader: recoveringReader)
        precondition(recovering.errorMessage != nil && recoveringReader.starts == 0)
        try FileManager.default.removeItem(at: recoveryDB)
        let recoveryStore = try LifeSourceStore(url: recoveryURL)
        try recoveryStore.setEnabled(true, source: .health)
        recovering.recoverAfterUnlock()
        await drain(recoveringReader, model: recovering)
        precondition(recovering.errorMessage == nil && recoveringReader.starts == 1 && recovering.records.count == 2)
        precondition(recoveringReader.authorizations.isEmpty)
        await recovering.setEnabled(false, source: .health, day: day)

        // A non-sensitive opt-in hint installs observers on a locked cold launch, but cannot
        // authorize reads or override a disabled SQLite setting once the store can be opened.
        let suite = "health-observation-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let hintURL = root.appendingPathComponent("hint.json")
        let hintReader = HealthReader()
        let optedIn = LifeSourceModel(url: hintURL, reader: hintReader, observationDefaults: defaults)
        await optedIn.setEnabled(true, source: .health, day: day)
        await drain(hintReader, model: optedIn)
        let blockedURL = root.appendingPathComponent("locked-hint.json")
        let blockedDB = DaybookDatabase.url(forLegacy: blockedURL)
        try FileManager.default.createDirectory(at: blockedDB, withIntermediateDirectories: true)
        let lockedReader = HealthReader()
        let locked = LifeSourceModel(url: blockedURL, reader: lockedReader, observationDefaults: defaults)
        precondition(lockedReader.starts == 1 && !locked.isEnabled(.health))
        var lockedAcknowledgments = 0
        lockedReader.change? { lockedAcknowledgments += 1 }
        await spin()
        precondition(lockedAcknowledgments == 1 && lockedReader.reads.isEmpty && lockedReader.authorizations.isEmpty)
        try FileManager.default.removeItem(at: blockedDB)
        locked.recoverAfterUnlock(); await spin()
        precondition(lockedReader.stops == 1 && lockedReader.reads.isEmpty && !locked.isEnabled(.health))
        await optedIn.setEnabled(false, source: .health, day: day)
        print("Health refresh: consent, app-lifetime observers, burst coalescing, in-flight changes, background SQLite commits, deletion reconciliation, selected-day catch-up, failures, unlock, timeout and pause races passed")
    }
}
