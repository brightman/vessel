import Foundation

private func expect(_ value: Bool, _ message: String) { if !value { fatalError(message) } }

@main struct DaybookRecapSmoke {
    @MainActor static func main() async throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        let now = calendar.date(from: DateComponents(year: 2026, month: 3, day: 9, hour: 0, minute: 15))!
        let yesterday = DaybookRecapInput.homeDay(selected: now, now: now, calendar: calendar)
        expect(calendar.component(.day, from: yesterday) == 8, "yesterday uses calendar days across DST, not 86400 seconds")
        let day = calendar.date(from: DateComponents(year: 2026, month: 10, day: 18))!
        let records = (0..<12).map { i in DayRecord(id: UUID(), capturedAt: day.addingTimeInterval(Double(i * 60)), kind: .thought, title: "想法 \(i)", text: "种植罗勒 \(i)") }
        let secret = DayRecord(id: UUID(), capturedAt: day, kind: .sleep, title: "私人睡眠", text: "不允许发送的健康信息")
        let blank = DayRecord(id: UUID(), capturedAt: day.addingTimeInterval(900), kind: .voice, title: "尚未转写", text: "")
        let input = DaybookRecapInput.prepare(records: records + [secret, blank], day: day, allowedKinds: [.thought, .voice], calendar: calendar)
        expect(input.references.count == 13 && input.sources.count == 12, "all permitted records included beyond retrieval top five; blank audio waits for ASR")
        expect(input.pendingCount == 1 && !input.preview.contains("健康信息"), "pending coverage disclosed and denied health never sent")
        expect(!input.coverage.contains("输入元信息") && !input.coverage.contains("不要写入") && input.preview.contains("输入元信息"),
               "display coverage must not expose model-only instructions; send preview must show actual metadata")
        expect(input.batches.allSatisfy { $0.count <= 2400 }, "requests stay bounded")
        expect(input.sources.last?.number == 12 && input.preview.contains("种植罗勒 11"), "last record must not disappear")
        let single = DaybookRecapInput.prepare(records: [records[0]], day: day, allowedKinds: [.thought], calendar: calendar)
        expect(single.sources.count == 1, "one record is sufficient for a recap")
        expect(single.preview.contains("主动闪念") && single.preview.contains("意图"), "active capture must carry intent provenance")
        let voice = DayRecord(id: UUID(), capturedAt: day, kind: .voice, title: "Watch", text: "前方限速120")
        let voiceInput = DaybookRecapInput.prepare(records: [voice], day: day, allowedKinds: [.voice], calendar: calendar)
        expect(voiceInput.preview.contains("说话人未确认") && voiceInput.preview.contains("背景音"), "recording device must not imply speaker ownership")
        var steps = DayRecord(id: UUID(), capturedAt: day, kind: .activity, title: "步数", text: "当天累计 6000 步。")
        steps.lifeMoment = .init(steps: .init(interval: DateInterval(start: day, duration: 86400), count: 6000, updatedAt: day, archived: false))
        let health = DaybookRecapInput.prepare(records: [steps], day: day, allowedKinds: [.activity], calendar: calendar)
        expect(health.preview.contains("系统活动数据") && health.preview.contains("测量范围"), "system measurements need scoped authority")
        var child = DayRecord(id: UUID(), capturedAt: day, kind: .location, title: "位置", text: "录音采集点")
        child.parentRecordID = voice.id
        let related = DaybookRecapInput.prepare(records: [voice, child], day: day, allowedKinds: [.voice, .location], calendar: calendar)
        expect(related.sources.allSatisfy { $0.content.contains("同源组 1") }, "derived capture and original recording are not independent evidence")
        steps.lifeMoment = .init(steps: .init(interval: DateInterval(start: day, duration: 86400), count: 6000, updatedAt: day.addingTimeInterval(3600), archived: false))
        let refreshedHealth = DaybookRecapInput.prepare(records: [steps], day: day, allowedKinds: [.activity], calendar: calendar)
        expect(health.fingerprint == refreshedHealth.fingerprint, "health refresh timestamp alone must not trigger another AI call")
        try DaybookRecapInput.validate("记录了种植罗勒的想法。[1]", sourceNumbers: [1])
        for text in ["无引用", "错误 [2]", "溢出 [99999999999999999999999]"] {
            do { try DaybookRecapInput.validate(text, sourceNumbers: [1]); fatalError("invalid citation accepted") } catch {}
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("recaps-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let db = try DaybookDatabase(url: root.appendingPathComponent("data.sqlite3"))
        let store = DaybookRecapStore(database: db)
        var entry = DaybookRecapEntry(input: single)
        entry.text = "记录了种植罗勒的想法。[1]"; entry.generatedAt = day; entry.language = "zh-Hans"
        try store.save(entry)
        expect(try store.load().first?.text == entry.text, "saved recap survives reload")
        expect(entry.relationship(to: single) == .current, "exact evidence is current")
        let added = DaybookRecapInput.prepare(records: [records[0], records[1]], day: day, allowedKinds: [.thought], calendar: calendar)
        expect(entry.relationship(to: added) == .additions, "new sources preserve the earlier recap with pending status")
        var edited = records[0]; edited.text = "修改后的原文"
        expect(entry.relationship(to: DaybookRecapInput.prepare(records: [edited], day: day, allowedKinds: [.thought], calendar: calendar)) == .invalid, "edits invalidate old generated claims")
        expect(entry.relationship(to: DaybookRecapInput.prepare(records: [], day: day, allowedKinds: [.thought], calendar: calendar)) == .invalid, "deleted sources invalidate persisted prose")
        for i in 1...40 {
            let date = calendar.date(byAdding: .day, value: -i, to: day)!
            var record = records[0]; record.capturedAt = date
            let prepared = DaybookRecapInput.prepare(records: [record], day: date, allowedKinds: [.thought], calendar: calendar)
            try store.save(DaybookRecapEntry(input: prepared))
        }
        expect(try store.load().count == 41, "archive must retain older than 30 days")
        try db.execute("CREATE TRIGGER recap_failure BEFORE UPDATE ON daily_recaps BEGIN SELECT RAISE(ABORT, 'test'); END")
        var changed = entry; changed.text = "不应提交的文本 [1]"
        do { try store.save(changed); fatalError("failed transaction accepted") } catch {}
        expect(try store.load().first?.text == entry.text, "rollback preserves previous persisted recap")
        try db.execute("DROP TRIGGER recap_failure")

        let nextDay = calendar.date(byAdding: .day, value: 1, to: day)!
        var nextRecord = records[0]; nextRecord.capturedAt = nextDay
        let nextEntry = DaybookRecapEntry(input: DaybookRecapInput.prepare(records: [nextRecord], day: nextDay, allowedKinds: [.thought], calendar: calendar))
        try db.execute("CREATE TRIGGER recap_attempt_failure BEFORE INSERT ON daily_recaps BEGIN SELECT RAISE(ABORT, 'test'); END")
        do { _ = try store.beginAttempt(nextEntry, automatic: true); fatalError("failed attempt marker accepted") } catch {}
        expect(try db.query("SELECT day FROM daily_recap_attempts WHERE day=?", [.text(nextEntry.dayKey)]).isEmpty, "failed persistence rolls back claim before any AI call")
        try db.execute("DROP TRIGGER recap_attempt_failure")
        expect(try store.beginAttempt(nextEntry, automatic: true), "first durable automatic claim succeeds")
        expect(try !store.beginAttempt(nextEntry, automatic: true), "second automatic claim is rejected")
        expect(try store.beginAttempt(nextEntry, automatic: false), "manual retry is always available")

        let legacyDB = try DaybookDatabase(url: root.appendingPathComponent("legacy.sqlite3"))
        try legacyDB.migrate("daily-recaps-v1") { try legacyDB.execute("CREATE TABLE daily_recaps (day TEXT PRIMARY KEY, payload BLOB NOT NULL)") }
        try legacyDB.execute("INSERT INTO daily_recaps(day,payload) VALUES (?,?)", [.text(entry.dayKey), try DaybookDatabase.json(entry)])
        let migrated = DaybookRecapStore(database: legacyDB)
        expect(try !migrated.beginAttempt(entry, automatic: true), "migration never automatically regenerates existing dates")
        expect(try migrated.load().first?.text == entry.text, "migration preserves previous recap text")
        print("Daily recap evidence and SQLite tests passed")
    }
}
