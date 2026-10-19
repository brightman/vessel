import Foundation

@main
struct NoteTimelineSmoke {
    static func main() throws {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        var note = VoiceNote(id: UUID(), kind: .long, capturedAt: start, duration: 1_800)
        let clock = RecordingClock(startedAt: start, endedAt: start.addingTimeInterval(1_800),
            startUptime: 100, endUptime: 1_900, audioDuration: 1_800)
        note.recordingClock = clock
        precondition(clock.canAlign(capturedAt: start, duration: 1_800))
        let changedClock = RecordingClock(startedAt: start, endedAt: start.addingTimeInterval(2_000),
            startUptime: 100, endUptime: 1_900, audioDuration: 1_800)
        precondition(!changedClock.canAlign(capturedAt: start, duration: 1_800), "wall-clock jumps cannot align")
        let interrupted = RecordingClock(startedAt: start, endedAt: start.addingTimeInterval(1_800),
            startUptime: 100, endUptime: 1_900, audioDuration: 1_200)
        precondition(!interrupted.canAlign(capturedAt: start, duration: 1_200), "recording gaps cannot align")
        precondition(!clock.canAlign(capturedAt: start, duration: .infinity))
        var legacy = try JSONSerialization.jsonObject(with: JSONEncoder().encode(note)) as! [String: Any]
        legacy.removeValue(forKey: "recordingClock")
        let old = try JSONDecoder().decode(VoiceNote.self, from: JSONSerialization.data(withJSONObject: legacy))
        precondition(old.recordingClock == nil, "existing notes still decode")

        func point(_ offset: Double, _ bpm: Double, product: String = "Watch7,18") -> HeartRatePoint {
            HeartRatePoint(id: UUID(), start: start.addingTimeInterval(offset), end: start.addingTimeInterval(offset + 1),
                bpm: bpm, sourceName: "Apple Watch", sourceBundle: "com.apple.health", productType: product, deviceName: "Watch")
        }
        let first = point(60, 70)
        let second = point(180, 90)
        let late = point(1_500, 110)
        var timeline = NoteTimeline()
        timeline.segmentTranscript = note.transcript
        timeline.segments = [TranscriptSegment(start: 65, end: 70, text: "周五前确认预算。"),
                             TranscriptSegment(start: 1_000, end: 1_005, text: "讨论下一次会议。")]
        timeline.replacePoints([late, second, first, first, point(-10, 80), point(1_800, 80), point(80, .nan)], for: note)
        precondition(timeline.points == [first, second, late], "deduplicate, sort and bound measurement timestamps")
        let events = HeartRateEvidence.changes(in: timeline, note: note)
        precondition(events.count == 1 && events[0].delta == 20)
        precondition(events[0].excerpts.map(\.text) == ["周五前确认预算。"], "only timestamp-matched words are evidence")
        let revision = timeline.revision
        timeline.analysis = MeetingAnalysis(text: "待本人确认", model: "fixture", generatedAt: .now,
            inputRevision: revision, transcript: note.transcript, summary: note.summary)
        timeline.replacePoints([late, first, second, first], for: note)
        precondition(timeline.revision == revision && timeline.currentAnalysis(for: note) != nil, "refreshing identical samples keeps analysis")
        var changed = note
        changed.summary = "新总结"
        precondition(timeline.currentAnalysis(for: changed) == nil, "changed summary makes analysis stale")
        changed = note
        changed.transcript = "手动改写"
        precondition(timeline.currentAnalysis(for: changed) == nil, "changed transcript makes analysis stale")
        precondition(timeline.alignedSegments(for: changed).isEmpty, "partial writes cannot attach timestamps to different text")
        timeline.replacePoints([first], for: note)
        precondition(timeline.points == [first] && timeline.analysis == nil, "deleted samples disappear and invalidate analysis")
        timeline.replacePoints([first, point(180, 100, product: "Watch6,1")], for: note)
        precondition(HeartRateEvidence.changes(in: timeline, note: note).isEmpty, "different watches cannot become one change")
        timeline.replacePoints([], for: note)
        precondition(timeline.points.isEmpty, "empty read removes cached health samples")

        func hrv(_ lower: Double, _ upper: Double, _ milliseconds: Double) -> HRVPoint {
            HRVPoint(id: UUID(), start: start.addingTimeInterval(lower), end: start.addingTimeInterval(upper),
                sdnnMilliseconds: milliseconds, sourceName: "Apple Watch", sourceBundle: "com.apple.health", productType: "Watch7,18", deviceName: "Watch")
        }
        let before = hrv(-30, 30, 32.5)
        let inside = hrv(900, 960, 41)
        let after = hrv(1_790, 1_820, 45.5)
        timeline.replaceHRVPoints([after, before, inside, before, hrv(-90, -30, 10), hrv(1_800, 1_820, 20),
            hrv(-30, 0, 20), hrv(30, 20, 20), hrv(50, 80, .nan), hrv(50, 80, -1)], for: note)
        precondition(timeline.hrvPoints == [before, inside, after], "HRV deduplicates and queries overlapping windows")
        precondition(before.overlap(in: note) == 0...30 && after.overlap(in: note) == 1_790...1_800)
        precondition(before.sdnnMilliseconds == 32.5 && before.start == start.addingTimeInterval(-30), "clipping a chart never changes raw HRV data")
        precondition(before.windowLabel(in: note).contains("录音前") && after.windowLabel(in: note).contains("结束后"))
        precondition(hrv(0, 0, 30).overlap(in: note) == 0...0, "zero-duration samples retain an explicitly unknown measurement window")
        let hrvRevision = timeline.revision
        timeline.analysis = MeetingAnalysis(text: "HRV 复盘", model: "fixture", generatedAt: .now,
            inputRevision: hrvRevision, transcript: note.transcript, summary: note.summary)
        timeline.replaceHRVPoints([inside, after, before], for: note)
        precondition(timeline.revision == hrvRevision && timeline.analysis != nil, "identical HRV refresh does not invalidate analysis")
        let hrvEvents = HRVEvidence.windows(in: timeline, note: note)
        precondition(hrvEvents.first?.excerpts.map(\.text) == [], "an outside transcript cannot be attributed to an overlapping HRV window")
        precondition(hrvEvents.first?.material(in: note).contains("32.5 ms") == true)
        precondition(hrvEvents.first?.material(in: note).contains("跨录音边界") == true)
        precondition(!hrvEvents[0].material(in: note).contains(before.id.uuidString), "analysis material omits HealthKit UUID")
        timeline.replaceHRVPoints([inside], for: note)
        precondition(timeline.analysis == nil && timeline.revision != hrvRevision, "HRV deletions invalidate analysis")
        let manyHRV = (0..<12).map { hrv(Double($0 * 100), Double($0 * 100 + 60), Double(20 + $0)) }
        timeline.replaceHRVPoints(manyHRV, for: note)
        let selectedHRV = HRVEvidence.windows(in: timeline, note: note)
        precondition(selectedHRV.count == 6 && selectedHRV.first?.point == manyHRV.first && selectedHRV.last?.point == manyHRV.last,
                     "bounded HRV evidence spans the meeting rather than selecting extreme values")
        timeline.replaceHRVPoints([], for: note)
        precondition(timeline.hrvPoints.isEmpty && HRVEvidence.statistics(in: timeline, note: note).contains("暂无可用"))
        let zero = hrv(50, 80, 0)
        timeline.replaceHRVPoints([zero], for: note)
        precondition(timeline.hrvPoints == [zero], "a mathematically valid SDNN of zero is not treated as missing")
        timeline.replaceHRVPoints([], for: note)

        timeline.replacePoints([first, second], for: note)
        timeline.analysis = MeetingAnalysis(text: "旧版分析", model: "fixture", generatedAt: .now,
            inputRevision: timeline.revision, transcript: note.transcript, summary: note.summary)
        var versionOne = try JSONSerialization.jsonObject(with: JSONEncoder().encode(timeline)) as! [String: Any]
        versionOne["schemaVersion"] = 1
        versionOne.removeValue(forKey: "hrvPoints")
        versionOne.removeValue(forKey: "hrvRefreshedAt")
        let migrated = try JSONDecoder().decode(NoteTimeline.self, from: JSONSerialization.data(withJSONObject: versionOne))
        precondition(migrated.schemaVersion == 4 && migrated.points == timeline.points && migrated.segments == timeline.segments)
        precondition(migrated.hrvPoints.isEmpty && migrated.analysis == nil, "v1 migration preserves source data and invalidates pre-HRV reports")

        var legacyPoint = try JSONSerialization.jsonObject(with: JSONEncoder().encode(first)) as! [String: Any]
        legacyPoint.removeValue(forKey: "motionContext")
        let decodedPoint = try JSONDecoder().decode(HeartRatePoint.self, from: JSONSerialization.data(withJSONObject: legacyPoint))
        precondition(decodedPoint.motionContext == nil && decodedPoint.motionLabel == "活动状态未知", "legacy or missing metadata is unknown, not sedentary")
        var moving = first
        moving.motionContext = 2
        var still = second
        still.motionContext = 1
        timeline.replacePoints([moving, still], for: note)
        let motionRevision = timeline.revision
        timeline.analysis = MeetingAnalysis(text: "活动上下文", model: "fixture", generatedAt: .now,
            inputRevision: motionRevision, transcript: note.transcript, summary: note.summary)
        timeline.replacePoints([moving, still], for: note)
        precondition(timeline.revision == motionRevision && timeline.analysis != nil)
        still.motionContext = 1234
        timeline.replacePoints([moving, still], for: note)
        precondition(timeline.analysis == nil && still.motionLabel == "活动状态未知", "metadata-only changes invalidate reports and unknown future values remain unknown")
        precondition(timeline.motionStatistics.contains("1 个采样时活动中") && timeline.motionStatistics.contains("1 个未知"))

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let day = calendar.dateInterval(of: .day, for: start)!
        func mind(_ offset: Double, kind: StateOfMindPoint.Kind = .momentaryEmotion, valence: Double = -0.3) -> StateOfMindPoint {
            StateOfMindPoint(id: UUID(), date: start.addingTimeInterval(offset), kind: kind, valence: valence,
                classification: 3, labels: [29], associations: [17], sourceName: "Health", sourceBundle: "fixture.health",
                dayStart: kind == .dailyMood ? day.start : nil, dayEnd: kind == .dailyMood ? day.end : nil,
                timeZoneIdentifier: kind == .dailyMood ? "GMT" : nil)
        }
        let moment = mind(67)
        let daily = mind(67, kind: .dailyMood)
        let dailyAfterMeeting = mind(2_000, kind: .dailyMood)
        timeline.replaceStatesOfMind([moment, moment, daily, dailyAfterMeeting, mind(-1), mind(1_800), mind(90, valence: .nan), mind(90, valence: 2)], for: note)
        precondition(timeline.statesOfMind.count == 3, "include bounded moments and same-day background, deduplicate and reject invalid valence")
        let mindEvents = StateOfMindEvidence.records(in: timeline, note: note)
        precondition(mindEvents.first { $0.point.id == moment.id }?.excerpts.map(\.text) == ["周五前确认预算。"])
        precondition(mindEvents.filter { $0.point.kind == .dailyMood }.allSatisfy { $0.excerpts.isEmpty }, "daily reflections never attach to words even when recorded within the meeting")
        precondition(moment.labelsText == "有压力" && moment.associationsText == "工作")
        precondition(mindEvents.first { $0.point.id == daily.id }!.material(in: note).contains("仅作背景"))
        precondition(!mindEvents[0].material(in: note).contains(moment.id.uuidString) && !mindEvents[0].material(in: note).contains("fixture.health"))
        let mindRevision = timeline.revision
        timeline.analysis = MeetingAnalysis(text: "心境报告", model: "fixture", generatedAt: .now,
            inputRevision: mindRevision, transcript: note.transcript, summary: note.summary)
        timeline.replaceStatesOfMind([dailyAfterMeeting, daily, moment], for: note)
        precondition(timeline.revision == mindRevision && timeline.analysis != nil)
        timeline.replaceStatesOfMind([moment], for: note)
        precondition(timeline.analysis == nil && timeline.revision != mindRevision, "deleted subjective records invalidate derived reports")
        let manyMoments = (0..<15).map { mind(Double($0 * 100)) }
        timeline.replaceStatesOfMind(manyMoments + [daily], for: note)
        let selectedMind = StateOfMindEvidence.records(in: timeline, note: note)
        precondition(selectedMind.count == 7 && selectedMind.contains { $0.point == manyMoments.first } && selectedMind.contains { $0.point == manyMoments.last }, "bounded subjective evidence spans the recording and keeps daily background separate")
        let outsideDay = StateOfMindPoint(id: UUID(), date: day.start.addingTimeInterval(-1), kind: .dailyMood,
            valence: 0, classification: 4, labels: [], associations: [], sourceName: "Health", sourceBundle: "fixture.health",
            dayStart: day.start.addingTimeInterval(-86400), dayEnd: day.start, timeZoneIdentifier: "GMT")
        precondition(!outsideDay.isRelevant(to: note), "previous-day reflection is not meeting-day background")
        var versionTwo = try JSONSerialization.jsonObject(with: JSONEncoder().encode(timeline)) as! [String: Any]
        versionTwo["schemaVersion"] = 2
        versionTwo.removeValue(forKey: "statesOfMind")
        versionTwo.removeValue(forKey: "stateOfMindRefreshedAt")
        let migratedTwo = try JSONDecoder().decode(NoteTimeline.self, from: JSONSerialization.data(withJSONObject: versionTwo))
        precondition(migratedTwo.schemaVersion == 4 && migratedTwo.points == timeline.points && migratedTwo.hrvPoints == timeline.hrvPoints && migratedTwo.statesOfMind.isEmpty && migratedTwo.analysis == nil)

        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try NoteTimelineStore(root: root)
        timeline.replacePoints([first, second], for: note)
        timeline.replaceHRVPoints([before, inside, after], for: note)
        try store.save(timeline, id: note.id)
        let reloaded = try store.load(note.id)
        precondition(reloaded == timeline, "sidecar survives restart")
        let directory = root.appendingPathComponent("Timelines")
        let values = try directory.resourceValues(forKeys: [.isExcludedFromBackupKey])
        precondition(values.isExcludedFromBackup == true, "health sidecars excluded from backup")
        timeline.schemaVersion = 99
        try store.save(timeline, id: note.id)
        do { _ = try store.load(note.id); preconditionFailure("unknown schemas must not be overwritten") }
        catch TimelineError.unsupportedVersion { }
        try Data("broken".utf8).write(to: directory.appendingPathComponent("\(note.id.uuidString).json"))
        do { _ = try store.load(note.id); preconditionFailure("corrupt data must be reported") }
        catch is DecodingError { }
        try store.delete(note.id)
        let empty = try store.load(note.id)
        precondition(empty.points.isEmpty)
        print("NoteTimelineSmoke passed (clock, v1/v2/v3/v4 migration, motion context, HRV, subjective records, time boundaries, evidence, invalidation, persistence, backup, corruption)")
    }
}
