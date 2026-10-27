import Foundation

@main struct LifeMomentsSmoke {
    static func main() throws {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        func date(_ value: String) -> Date { ISO8601DateFormatter().date(from: value)! }
        let day = date("2026-10-19T00:00:00Z"), now = date("2026-10-19T20:00:00Z")
        let midnightUpdate = day.addingTimeInterval(1), priorClock = day.addingTimeInterval(-2)
        let rolled = LifeMomentBuilder.selectedDate(after: midnightUpdate, previousNow: priorClock, selected: priorClock, calendar: calendar)
        precondition(rolled == midnightUpdate, "A data callback before the next timer tick must roll today's selection forward")
        let history = day.addingTimeInterval(-7 * 86400)
        precondition(LifeMomentBuilder.selectedDate(after: midnightUpdate, previousNow: priorClock, selected: history, calendar: calendar) == history, "Midnight must not move a historical selection")
        func sample(_ start: String, _ end: String, _ stage: SleepStage, _ source: String = "watch") -> LifeSleepSample {
            .init(start: date(start), end: date(end), stage: stage, sourceID: source, sourceName: source)
        }
        let night = [sample("2026-10-18T23:42:00Z", "2026-10-19T00:54:00Z", .deep),
                     sample("2026-10-19T00:54:00Z", "2026-10-19T05:22:00Z", .core),
                     sample("2026-10-19T05:22:00Z", "2026-10-19T05:40:00Z", .awake),
                     sample("2026-10-19T05:40:00Z", "2026-10-19T07:18:00Z", .rem)]
        let nap = sample("2026-10-19T13:00:00Z", "2026-10-19T13:30:00Z", .asleep)
        let other = sample("2026-10-18T23:42:00Z", "2026-10-19T07:18:00Z", .asleep, "other")
        let records = LifeMomentBuilder.health(day: day, steps: 4860, samples: night + night + [other, nap], now: now, calendar: calendar)
        let main = records.first { $0.lifeMoment?.sleep?.isMain == true }!
        let sleep = main.lifeMoment!.sleep!
        let pending = LifeMomentBuilder.pendingSleep(day: day, calendar: calendar)
        precondition(LifeMomentBuilder.detail(id: pending.id, pendingSleepOn: day, records: records, calendar: calendar)?.id == main.id, "An open pending sheet resolves to the newly loaded main sleep")
        precondition(LifeMomentBuilder.detail(id: main.id, pendingSleepOn: nil, records: [], calendar: calendar) == nil, "A removed life record has an unavailable state, never a photo fallback")
        precondition(main.capturedAt == date("2026-10-19T07:18:00Z"), "Wake-up belongs at the end of the night")
        precondition(sleep.startedAt == date("2026-10-18T23:42:00Z"), "Midnight must not truncate the night")
        precondition(sleep.asleepSeconds == 26280 && sleep.awakeSeconds == 1080, "Duplicate samples and another device must not inflate sleep")
        precondition(sleep.stages[.deep] == 4320 && sleep.stages[.core] == 16080 && sleep.stages[.rem] == 5880)
        precondition(records.filter { $0.kind == .sleep }.count == 2, "A nap stays separate from morning wake-up")
        let inBed = sample("2026-10-18T22:00:00Z", "2026-10-19T08:00:00Z", .inBed)
        precondition(!LifeMomentBuilder.health(day: day, steps: nil, samples: [inBed], now: now, calendar: calendar).contains { $0.kind == .sleep }, "In-bed alone is not actual sleep")
        let recentlyEnded = LifeMomentBuilder.health(day: day, steps: nil, samples: night, now: date("2026-10-19T07:20:00Z"), calendar: calendar).first { $0.kind == .sleep }
        precondition(recentlyEnded?.lifeMoment?.sleep?.confirmed == false, "Ended samples publish an estimate immediately; there is no holdoff without a scheduled retry")
        let acrossSources = [sample("2026-10-18T21:00:00Z", "2026-10-18T23:50:00Z", .deep),
                             sample("2026-10-18T21:00:00Z", "2026-10-19T00:10:00Z", .asleep, "phone")]
        precondition(!LifeMomentBuilder.health(day: day, steps: nil, samples: acrossSources, now: now, calendar: calendar).contains { $0.kind == .sleep }, "Ending date is chosen after source selection")
        precondition(LifeMomentBuilder.health(day: day.addingTimeInterval(-86400), steps: nil, samples: acrossSources, now: now, calendar: calendar).contains { $0.kind == .sleep }, "The preferred source remains on its actual ending date")
        let ongoing = [sample("2026-10-18T22:00:00Z", "2026-10-19T01:00:00Z", .deep),
                       sample("2026-10-19T01:00:00Z", "2026-10-19T07:00:00Z", .core)]
        precondition(!LifeMomentBuilder.health(day: day, steps: nil, samples: ongoing, now: date("2026-10-19T02:00:00Z"), calendar: calendar).contains { $0.kind == .sleep }, "Ongoing later stages prevent a false wake-up from their completed prefix")
        let interrupted = [sample("2026-10-18T22:00:00Z", "2026-10-19T02:00:00Z", .core),
                           sample("2026-10-19T02:00:00Z", "2026-10-19T04:00:00Z", .awake),
                           sample("2026-10-19T04:00:00Z", "2026-10-19T07:00:00Z", .rem)]
        let interruptedSleep = LifeMomentBuilder.health(day: day, steps: nil, samples: interrupted, now: now, calendar: calendar).filter { $0.kind == .sleep }
        precondition(interruptedSleep.count == 1 && interruptedSleep[0].lifeMoment?.sleep?.awakeSeconds == 7200 && interruptedSleep[0].capturedAt == date("2026-10-19T07:00:00Z"), "Explicit overnight awake continuity is part of one night")
        let previous = date("2026-10-18T00:00:00Z")
        let raw = LifeMomentBuilder.health(day: previous, steps: 6240, samples: [], now: now, calendar: calendar)
        let archive = LifeMomentBuilder.archive(records: raw, day: day, updatedAt: now, calendar: calendar)
        precondition(archive.capturedAt == day && archive.metricValue == nil && archive.lifeMoment?.steps?.count == 6240, "Yesterday archive cannot inflate today's metric")
        let revised = LifeMomentBuilder.archive(records: LifeMomentBuilder.health(day: previous, steps: 6300, samples: [], now: now, calendar: calendar), day: day, updatedAt: now, calendar: calendar)
        precondition(archive.id == revised.id && revised.lifeMoment?.steps?.count == 6300, "Late totals update one archive")
        precondition(LifeMomentBuilder.archive(records: [], day: day, updatedAt: nil, calendar: calendar).lifeMoment?.steps?.count == nil, "Missing data is not zero steps")
        var dst = calendar; dst.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        let spring = LifeMomentBuilder.archive(records: [], day: date("2026-03-09T12:00:00Z"), updatedAt: nil, calendar: dst)
        let autumn = LifeMomentBuilder.archive(records: [], day: date("2026-11-02T12:00:00Z"), updatedAt: nil, calendar: dst)
        precondition(spring.lifeMoment?.steps?.interval.duration == 23 * 3600 && autumn.lifeMoment?.steps?.interval.duration == 25 * 3600, "Archive uses calendar days across DST")
        let timeline = LifeMomentBuilder.timeline(records: raw + records, day: day, now: now, healthEnabled: true, calendar: calendar, snapshot: { _ in nil }, isSuppressed: { _ in false })
        precondition(timeline.count == 1 && timeline[0].lifeMoment?.steps?.count == 6240, "No duplicate sleep or future archive; current overview remains separate")
        let hidden = LifeMomentBuilder.timeline(records: raw, day: day, now: now, healthEnabled: true, calendar: calendar, snapshot: { _ in nil }, isSuppressed: { $0 == archive.id || $0 == main.id })
        precondition(hidden.isEmpty, "Deleting archive or main sleep must not recreate it as a placeholder")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("life.json")
        let store = try LifeSourceStore(url: url)
        try store.setEnabled(true, source: .health)
        try store.replace(source: .health, day: day, records: records, refreshedAt: now)
        try store.confirmWake(main.id, expectedEnd: sleep.endedAt!, confirmed: true)
        try store.replace(source: .health, day: day, records: records, refreshedAt: now.addingTimeInterval(10))
        let reopened = try LifeSourceStore(url: url)
        precondition(reopened.records.first { $0.id == main.id }?.lifeMoment?.sleep?.confirmed == true, "Confirmation survives refresh and SQLite reopen")
        try reopened.confirmWake(main.id, expectedEnd: sleep.endedAt!, confirmed: false)
        precondition(reopened.records.first { $0.id == main.id }?.lifeMoment?.sleep?.confirmed == false)
        do { try reopened.confirmWake(main.id, expectedEnd: now, confirmed: true); preconditionFailure("stale confirmation accepted") }
        catch LifeSourceStore.Failure.staleConfirmation {}
        try reopened.confirmWake(main.id, expectedEnd: sleep.endedAt!, confirmed: true)
        let revisedSleep = LifeMomentBuilder.health(day: day, steps: 4860, samples: [sample("2026-10-18T23:30:00Z", "2026-10-19T07:18:00Z", .asleep)], now: now, calendar: calendar)
        try reopened.replace(source: .health, day: day, records: revisedSleep, refreshedAt: now)
        precondition(reopened.records.first { $0.id == main.id }?.lifeMoment?.sleep?.confirmed == false, "Changed sleep boundaries invalidate confirmation")
        let database = try DaybookDatabase(url: DaybookDatabase.url(forLegacy: url))
        try database.execute("CREATE TRIGGER reject_confirmation BEFORE UPDATE ON life_moment_metadata BEGIN SELECT RAISE(ABORT, 'confirmation write failure'); END")
        do { try reopened.confirmWake(main.id, expectedEnd: sleep.endedAt!, confirmed: true); preconditionFailure("failed write was accepted") } catch {}
        precondition(reopened.records.first { $0.id == main.id }?.lifeMoment?.sleep?.confirmed == false, "A failed metadata save cannot publish confirmation")
        let afterFailure = try LifeSourceStore(url: url)
        precondition(afterFailure.records.first { $0.id == main.id }?.title == "起床 · 估计", "Title and payload roll back together")
        try database.execute("DROP TRIGGER reject_confirmation")
        try reopened.delete(main.id)
        let metadata = try database.query("SELECT * FROM life_moment_metadata WHERE record_id = ?", [.text(main.id.uuidString)])
        precondition(metadata.isEmpty, "Deleting a health snapshot cascades to its moment metadata")
        try reopened.replace(source: .health, day: previous, records: LifeMomentBuilder.health(day: previous, steps: nil, samples: [], now: now, calendar: calendar), refreshedAt: now)
        precondition(reopened.snapshot(source: .health, day: previous)?.status == .empty, "Unknown daily total must not report readable health data")
        try reopened.delete(archive.id)
        let deletedReload = try LifeSourceStore(url: url)
        precondition(deletedReload.isSuppressed(archive.id), "Deleting a derived archive persists its suppression")
        let workoutStart = date("2026-10-18T23:40:00Z"), workoutEnd = date("2026-10-19T00:20:00Z")
        let workout = WorkoutMoment(id: UUID(), activity: "跑步", startedAt: workoutStart, endedAt: workoutEnd,
            duration: 2100, distanceMeters: 5000, activeKilocalories: 240, sourceName: "Apple Watch", manuallyEntered: false)
        let training = LifeMomentBuilder.workouts([workout, workout], day: workoutStart, now: now, calendar: calendar)
        precondition(training.count == 1 && training[0].id == workout.id, "Repeated workout UUIDs deduplicate")
        precondition(training[0].duration == 2100 && training[0].text.contains("35分"), "Use duration excluding pauses")
        precondition(training[0].lifeMoment?.workout == workout && training[0].metricValue == nil, "Workout cannot masquerade as steps")
        precondition(LifeMomentBuilder.workouts([workout], day: workoutEnd, now: now, calendar: calendar).isEmpty, "Cross-midnight workout belongs to start day")
        precondition(LifeMomentBuilder.workouts([workout], day: workoutStart, now: workoutStart, calendar: calendar).isEmpty, "Exclude unfinished workouts")
        let decodedWorkout = try JSONDecoder().decode(DayRecord.self, from: JSONEncoder().encode(training[0]))
        precondition(decodedWorkout == training[0], "Workout metadata roundtrip")
        let noMetrics = WorkoutMoment(id: UUID(), activity: "瑜伽", startedAt: workoutStart, endedAt: workoutEnd,
            duration: 1800, distanceMeters: nil, activeKilocalories: nil, sourceName: "健康", manuallyEntered: true)
        let noMetricsRecord = LifeMomentBuilder.workouts([noMetrics], day: workoutStart, now: now, calendar: calendar)[0]
        precondition(!noMetricsRecord.text.contains("千卡") && noMetricsRecord.text.contains("手动录入"), "Missing metrics not fabricated; manual provenance retained")
        let workoutArchive = LifeMomentBuilder.archive(records: training, day: workoutEnd, updatedAt: now, calendar: calendar)
        precondition(workoutArchive.lifeMoment?.steps?.count == nil, "Workout cannot pollute step archive")
        try reopened.replace(source: .health, day: previous, records: training, refreshedAt: now)
        precondition(reopened.snapshot(source: .health, day: previous)?.status == .ready, "Workout-only health authorization is readable")
        let workoutReload = try LifeSourceStore(url: url)
        precondition(workoutReload.records.contains { $0.lifeMoment?.workout == workout }, "SQLite preserves workout metadata")
        try reopened.replace(source: .health, day: previous, records: [], refreshedAt: now)
        precondition(!reopened.records.contains { $0.id == workout.id }, "Health deletion removed on refresh")
        print("Life moments: whole-night sleep, overlap, source choice, nap, missing data, archive identity and SQLite confirmation passed")
    }
}
