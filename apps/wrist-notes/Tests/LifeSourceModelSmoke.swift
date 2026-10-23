import Foundation

@MainActor private final class Reader: LifeSourceReading {
    var authorizations: [LifeSource] = []
    var reads: [LifeSource] = []
    var locationReads = 0
    var onLocationAuthorizationChange: (() -> Void)?
    var locationIssue: LifeSourceReadFailure?
    func locationAvailabilityIssue() -> LifeSourceReadFailure? { locationIssue }
    var continuations: [CheckedContinuation<[DayRecord], Error>] = []
    func authorize(_ source: LifeSource) async throws { authorizations.append(source) }
    func read(_ source: LifeSource, day: Date, calendar: Calendar) async throws -> [DayRecord] {
        reads.append(source)
        return try await withCheckedThrowingContinuation { continuations.append($0) }
    }
    func oneShotLocation() async throws -> LifeCoordinate { locationReads += 1; return LifeCoordinate(latitude: 1, longitude: 2, accuracy: 10) }
    func stop(_ source: LifeSource) {}
    func finish(_ records: [DayRecord]) { if !continuations.isEmpty { continuations.removeFirst().resume(returning: records) } }
}

@main struct LifeSourceModelSmoke {
    @MainActor static func spin() async { for _ in 0..<30 { await Task.yield() } }
    @MainActor static func main() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("sources.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let reader = Reader()
        var model = LifeSourceModel(url: url, reader: reader)
        let day = Calendar.current.startOfDay(for: .now)
        let event = DayRecord(id: UUID(), capturedAt: day, kind: .calendar, title: "Meeting", text: "Event")
        model.refreshEnabled(day: day); await spin()
        precondition(reader.reads.isEmpty && reader.authorizations.isEmpty, "launch never prompts or queries disabled sources")
        await model.setEnabled(true, source: .calendar, day: day); await spin()
        precondition(reader.authorizations == [.calendar] && reader.reads == [.calendar])
        await model.setEnabled(false, source: .calendar, day: day)
        reader.finish([event]); await spin()
        precondition(model.records.isEmpty, "late completion after pause cannot import data")
        await model.setEnabled(true, source: .calendar, day: day); await spin()
        reader.finish([event]); await spin()
        precondition(model.records == [event])
        model.refresh(.calendar, day: day); await spin()
        model.setForeground(false, day: day)
        reader.finish([]); await spin()
        precondition(model.records == [event], "background late result preserves prior snapshot")
        let count = reader.reads.count
        model.refreshEnabled(day: day); await spin()
        precondition(reader.reads.count == count, "background refresh has no reads")
        model.setForeground(true, day: day); await spin()
        reader.finish([]); await spin()
        precondition(model.records.isEmpty, "foreground successful empty removes cancelled event")
        // A refresh for a newly selected date invalidates the previous date's suspended query.
        let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: day)!
        model.refresh(.calendar, day: day); await spin()
        model.refresh(.calendar, day: tomorrow); await spin()
        reader.finish([event]); await spin()
        precondition(model.records.isEmpty, "old selected-day completion cannot publish")
        let nextEvent = DayRecord(id: UUID(), capturedAt: tomorrow, kind: .calendar, title: "Next", text: "New date")
        reader.finish([nextEvent]); await spin()
        precondition(model.records == [nextEvent])
        reader.locationIssue = LifeSourceReadFailure(status: .awaitingAuthorization, message: "Waiting for location authorization")
        await model.setEnabled(true, source: .location, day: day)
        precondition(reader.locationReads == 0, "enabling location never captures")
        precondition(model.status(.location, day: day) == "等待定位授权", "pending permission must never be labeled granted")
        reader.locationIssue = nil
        reader.onLocationAuthorizationChange?()
        precondition(model.status(.location, day: day) == "权限已允许 · 采集时记录" && reader.locationReads == 0, "authorization callback observes granted permission without capture")
        reader.locationIssue = LifeSourceReadFailure(status: .denied, message: "Location denied")
        reader.onLocationAuthorizationChange?()
        precondition(model.status(.location, day: day) == "权限受限 · 保留旧数据" && reader.locationReads == 0, "denial callback changes status without capture")
        reader.locationIssue = nil
        reader.onLocationAuthorizationChange?()
        // Existing save-time snapshots retain their honest labels after the capture-time upgrade.
        let place = DayRecord(id: UUID(), capturedAt: .now, kind: .location, title: "保存时的地点", text: "旧版保存时坐标，不是历史地点")
        let legacyStore = try LifeSourceStore(url: url)
        try legacyStore.appendLocation(place, day: day, refreshedAt: .now)
        model = LifeSourceModel(url: url, reader: reader)
        reader.locationIssue = LifeSourceReadFailure(status: .denied, message: "Location denied")
        model.refreshLocationStatus(day: .now)
        precondition(model.snapshot(.location, day: .now)?.status == .denied && model.records.contains { $0.id == place.id }, "permission refresh labels denial and preserves location")
        reader.locationIssue = nil
        model.refreshLocationStatus(day: .now)
        precondition(model.snapshot(.location, day: .now)?.isStale == false && reader.locationReads == 0, "permission-only refresh never captures a coordinate")
        await model.setEnabled(false, source: .location, day: day)
        model.refreshEnabled(day: day); await spin()
        precondition(reader.locationReads == 0)
        let suite = "life-permissions-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = DaybookPreferences(defaults: defaults)
        precondition(!preferences.allowHealth && !preferences.allowCalendar && !preferences.allowLocation)
        preferences.allowHealth = true
        let restoredPreferences = DaybookPreferences(defaults: defaults)
        precondition(restoredPreferences.allowHealth && !restoredPreferences.allowLocation && !restoredPreferences.allowCalendar)
        precondition(preferences.allowedKinds.contains(.sleep) && preferences.allowedKinds.contains(.activity) && !preferences.allowedKinds.contains(.calendar))
        let record = DayRecord(id: UUID(), capturedAt: day, kind: .sleep, title: "Sleep", text: "Sleep", duration: 3600)
        let evidence = try DaybookRetrieval().prepare(question: "多少条记录", records: [record], selectedDate: day, allowedKinds: preferences.allowedKinds)
        precondition(evidence.statistics.lifeCount == 1 && evidence.statistics.audioDuration == 0, "life snapshot duration cannot inflate audio statistics")
        print("Life source lifecycle: no launch permissions/queries, pause and foreground races, empty reconciliation, legacy location retention without save-time acquisition and independent AI permissions passed")
    }
}
