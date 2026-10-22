import Foundation

@main struct LifeSourceSmoke {
    static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("sources.json")
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        let day = calendar.date(from: DateComponents(year: 2026, month: 3, day: 8))!
        let interval = LifeAggregation.dayInterval(day, calendar: calendar)
        precondition(interval.duration == 23 * 3600, "DST day uses calendar boundaries")
        let a = DateInterval(start: interval.start.addingTimeInterval(-100), end: interval.start.addingTimeInterval(100))
        let b = DateInterval(start: interval.start.addingTimeInterval(50), end: interval.start.addingTimeInterval(200))
        precondition(LifeAggregation.sleepDuration([a, b, b], within: interval) == 200, "overlapping samples are unioned and clipped")
        let fall = calendar.date(from: DateComponents(year: 2026, month: 11, day: 1))!
        precondition(LifeAggregation.dayInterval(fall, calendar: calendar).duration == 25 * 3600)
        precondition(LifeAggregation.sleepDuration([], within: interval) == 0)
        let outOfDay = DateInterval(start: interval.end, duration: 100)
        precondition(LifeAggregation.sleepDuration([outOfDay], within: interval) == 0)
        let id = LifeAggregation.recordID(source: .calendar, key: "event-A", day: interval.start)
        precondition(id == LifeAggregation.recordID(source: .calendar, key: "event-A", day: interval.start))
        let record = DayRecord(id: id, capturedAt: day, kind: .calendar, title: "Meeting", text: "Read only")
        let store = try LifeSourceStore(url: url)
        precondition(!store.isEnabled(.health) && !store.isEnabled(.calendar) && !store.isEnabled(.location))
        try store.setEnabled(true, source: .calendar)
        try store.replace(source: .calendar, day: day, records: [record], refreshedAt: day)
        precondition(store.records == [record])
        try store.markFailure(source: .calendar, day: day, status: .error, message: "offline")
        precondition(store.records.first?.id == record.id && store.records.first?.text.contains("旧快照") == true && store.records.first?.title.hasPrefix("【旧快照】") == true && store.snapshot(source: .calendar, day: day)?.isStale == true)
        try store.setEnabled(false, source: .calendar)
        let restarted = try LifeSourceStore(url: url)
        precondition(!restarted.isEnabled(.calendar) && restarted.records.first?.id == record.id && restarted.records.first?.text.contains("旧快照") == true, "pause persists and keeps snapshots")
        try restarted.setEnabled(true, source: .calendar)
        try restarted.replace(source: .calendar, day: day, records: [], refreshedAt: day)
        precondition(restarted.records.isEmpty && restarted.snapshot(source: .calendar, day: day)?.status == .empty, "successful empty refresh removes cancelled calendar events")
        try restarted.replace(source: .calendar, day: day, records: [record], refreshedAt: day)
        try restarted.delete(id)
        try restarted.replace(source: .calendar, day: day, records: [record], refreshedAt: day)
        let afterDeletion = try LifeSourceStore(url: url)
        precondition(afterDeletion.records.isEmpty, "deleted imported IDs stay suppressed after refresh and restart")
        try restarted.setEnabled(false, source: .calendar)
        do { try restarted.replace(source: .calendar, day: day, records: [record], refreshedAt: day); fatalError("paused write accepted") }
        catch LifeSourceStore.Failure.paused { }
        let deniedDay = calendar.date(byAdding: .day, value: 1, to: day)!
        try restarted.markFailure(source: .calendar, day: deniedDay, status: .denied, message: "denied")
        precondition(restarted.snapshot(source: .calendar, day: deniedDay)?.isStale == false)
        let parent = DayRecord(id: UUID(), capturedAt: day, kind: .voice, title: "Voice", text: "")
        try restarted.setEnabled(true, source: .location)
        let place = DayRecord(id: LifeAggregation.locationID(parent.id), capturedAt: day, kind: .location, title: "Location", text: "1, 2")
        try restarted.appendLocation(place, day: day, refreshedAt: day)
        try restarted.appendLocation(place, day: day, refreshedAt: day)
        precondition(restarted.records.filter { $0.kind == .location }.count == 1)
        let healthRecord = DayRecord(id: UUID(), capturedAt: day, kind: .activity, title: "100 steps", text: "100", metricValue: 100)
        try restarted.setEnabled(true, source: .health)
        try restarted.replace(source: .health, day: day, records: [healthRecord], refreshedAt: day)
        try restarted.delete(healthRecord.id)
        try restarted.replace(source: .health, day: day, records: [healthRecord], refreshedAt: day)
        precondition(!restarted.records.contains { $0.kind == .activity }, "deleted daily metrics cannot reappear or inflate stats")
        let blocked = root.appendingPathComponent("blocker")
        try Data().write(to: blocked)
        do { _ = try LifeSourceStore(url: blocked.appendingPathComponent("data.json")); fatalError("open should fail") } catch { }
        let database = try DaybookDatabase(url: DaybookDatabase.url(forLegacy: url))
        try database.execute("CREATE TRIGGER fail_settings BEFORE INSERT ON life_settings BEGIN SELECT RAISE(ABORT, 'settings failure'); END")
        let before = restarted.isEnabled(.calendar)
        do { try restarted.setEnabled(!before, source: .calendar); fatalError("write should fail") } catch { }
        precondition(restarted.isEnabled(.calendar) == before, "failed persistence must not publish unsaved settings")
        print("Life source aggregation, DST, atomic persistence, pause/restart, empty/stale/error and suppression checks passed")
    }
}
