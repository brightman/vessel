import Foundation

private func expect(_ value: Bool, _ message: String) { if !value { fatalError(message) } }

@main struct DaybookRecapSmoke {
    @MainActor static func main() async throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        let now = calendar.date(from: DateComponents(year: 2026, month: 3, day: 9, hour: 0, minute: 15))!
        let yesterday = DaybookRecapInput.homeDay(selected: now, now: now, calendar: calendar)
        let day = calendar.date(from: DateComponents(year: 2026, month: 10, day: 18))!
        expect(calendar.component(.day, from: yesterday) == 8, "yesterday uses calendar days across DST, not 86400 seconds")
        expect(DaybookHomeRecapTitle.text(date: yesterday, yesterday: true, localeIdentifier: "zh-Hans") == "昨日回顾",
               "today's home recap uses the yesterday label")
        expect(DaybookHomeRecapTitle.text(date: day, yesterday: false, localeIdentifier: "zh-Hans") == "10月18日 · 回顾",
               "past-day home recap uses its date instead of the generic daily label")
        expect(DaybookHomeRecapTitle.text(date: day, yesterday: false, localeIdentifier: "en") == "Oct 18 · Recap",
               "past-day recap title follows the selected interface language")
        expect(DaybookHomeRecapTitle.text(date: day, yesterday: false, localeIdentifier: "ja") == "10月18日 · 振り返り",
               "Japanese recap title follows the selected interface language")
        let records = (0..<12).map { i in DayRecord(id: UUID(), capturedAt: day.addingTimeInterval(Double(i * 60)), kind: .thought, title: "想法 \(i)", text: "种植罗勒 \(i)") }
        let secret = DayRecord(id: UUID(), capturedAt: day, kind: .sleep, title: "私人睡眠", text: "不允许发送的健康信息")
        let blank = DayRecord(id: UUID(), capturedAt: day.addingTimeInterval(900), kind: .voice, title: "尚未转写", text: "")
        let input = DaybookRecapInput.prepare(records: records + [secret, blank], day: day, allowedKinds: [.thought, .voice], calendar: calendar)
        expect(input.references.count == 13 && input.sources.count == 12, "all permitted records included beyond retrieval top five; blank audio waits for ASR")
        expect(input.pendingCount == 1 && !input.preview.contains("健康信息"), "pending coverage disclosed and denied health never sent")
        expect(input.coverage.contains("1 条文字待就绪") && !input.preview.contains("1 条文字待就绪"),
               "processing counts belong in UI coverage, not in model evidence or advice")
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
        var segment = voice
        segment.intervals = [DateInterval(start:day,duration:1)]; segment.duration = 1
        segment.contentProvenance = .init(segmentID:voice.id,sourceID:UUID(),sourceKind:"legacyNote",sourceRevision:1,segmentRevision:1,configurationKey:"asr",contentSignature:"same-content",sourceDate:day,ranges:[.init(chunkID:UUID(),startFrame:0,endFrame:16000,sampleRate:16000,sourceOffset:0)],transcript:[.init(start:0,end:1,text:voice.text)])
        let stable = DaybookRecapInput.prepare(records:[segment],day:day,allowedKinds:[.voice],calendar:calendar)
        let provenance = segment.contentProvenance!
        segment.contentProvenance = .init(segmentID:provenance.segmentID,sourceID:provenance.sourceID,sourceKind:provenance.sourceKind,sourceRevision:99,segmentRevision:77,configurationKey:provenance.configurationKey,contentSignature:provenance.contentSignature,sourceDate:day,ranges:provenance.ranges,transcript:provenance.transcript)
        segment.title = "AI changed title"; segment.summary = "AI changed summary"
        let progressed = DaybookRecapInput.prepare(records:[segment],day:day,allowedKinds:[.voice],calendar:calendar)
        expect(stable.fingerprint == progressed.fingerprint && DaybookRecapEntry(input:stable).relationship(to:progressed) == .current,"processing/source/title revisions are not changed recap facts")
        var attributed = voice
        attributed.text = "明天我去出差。你能帮我看看方案吗？"
        attributed.attributedTranscript = [.init(start:0,end:2,text:"明天我去出差。",speaker:"已关联联系人：Kate"),
                                          .init(start:2,end:4,text:"你能帮我看看方案吗？",speaker:"用户本人（声纹匹配）")]
        let speakerInput = DaybookRecapInput.prepare(records:[attributed],day:day,allowedKinds:[.voice],calendar:calendar)
        expect(speakerInput.preview.contains("【已关联联系人：Kate】明天我去出差。") && speakerInput.preview.contains("【用户本人（声纹匹配）】你能帮我看看方案吗？"),
               "recap evidence must bind each utterance to its own speaker, not attribute a mixed transcript to the user")
        attributed.attributedTranscript = nil
        let revokedSpeaker = DaybookRecapInput.prepare(records:[attributed],day:day,allowedKinds:[.voice],calendar:calendar)
        expect(speakerInput.fingerprint != revokedSpeaker.fingerprint, "revoked speaker identities invalidate prior attribution")
        do { try revokedSpeaker.validateNarrative("你聊到下周三的出行安排。[1]"); fatalError("unknown speech attributed to the user") }
        catch DaybookRecapFailure.invalid {}
        try revokedSpeaker.validateNarrative("录音里聊到了出行安排。[1]")
        try speakerInput.validateNarrative("你提到了希望对方看看方案。[1]")
        let pendingThought = DayRecord(id:UUID(),capturedAt:day,kind:.thought,title:"待转写闪念",text:"")
        let pendingOwnership = DaybookRecapInput.prepare(records:[voice,pendingThought],day:day,allowedKinds:[.voice,.thought],calendar:calendar)
        expect(!pendingOwnership.hasUserSpeech,"an empty flash capture is not evidence of the user's speech")
        attributed.attributedTranscript = [.init(start:0,end:4,text:"已经失效的旧转写",speaker:"用户本人（声纹匹配）")]
        let mismatchedOwnership = DaybookRecapInput.prepare(records:[attributed],day:day,allowedKinds:[.voice],calendar:calendar)
        expect(!mismatchedOwnership.hasUserSpeech,"speaker labels must match the included transcript before allowing user attribution")
        do { try revokedSpeaker.validateNarrative("因为你下周三要出行，不妨提前准备午餐。[1]"); fatalError("unknown travel assigned as user's plan") }
        catch DaybookRecapFailure.invalid {}
        attributed.text = String(repeating:"这是一段很长的本人发言。",count:100)
        attributed.attributedTranscript = [.init(start:0,end:100,text:attributed.text,speaker:"用户本人（声纹匹配）")]
        let longSpeech = DaybookRecapInput.prepare(records:[attributed],day:day,allowedKinds:[.voice],calendar:calendar)
        expect(longSpeech.sources[0].content.components(separatedBy:"【用户本人（声纹匹配）】").count == 4,
               "beginning, middle and end excerpts must each retain the speaker when cutting a long utterance")
        do { try DaybookRecapInput.validate("活动记录。[1] 其他事实。[1,999]",sourceNumbers:[1]); fatalError("combined numeric markers must not bypass citation validation") }
        catch DaybookRecapFailure.invalid {}
        try DaybookRecapInput.validate("旧回顾中的合并引用。[1,2]",sourceNumbers:[1,2])
        var legacy = DaybookRecapEntry(input:stable)
        let reference = stable.references[0]
        legacy.references = [.init(id:reference.id,number:reference.number,title:reference.title,kind:reference.kind,capturedAt:reference.capturedAt,digest:reference.legacyDigest!)]
        legacy.fingerprint = "legacy-fingerprint"
        expect(legacy.relationship(to:stable) == .current,"identical legacy evidence upgrades without discarding historical prose")
        let upgraded = legacy.upgradingDigests(to:stable)
        expect(upgraded.relationship(to:progressed) == .current,"upgraded historical references survive the next pure progress revision")
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
