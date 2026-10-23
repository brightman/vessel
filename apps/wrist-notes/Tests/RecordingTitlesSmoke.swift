import Foundation

private func expect(_ value: Bool, _ message: String) { if !value { fatalError(message) } }

@main struct RecordingTitlesSmoke {
    static func main() throws {
        expect(RecordingFormat.duration(3661, language: "zh-Hans") == "1小时1分1秒", "duration must include explicit hours, minutes and seconds")
        expect(RecordingFormat.duration(5, language: "zh-Hans") == "0小时0分5秒", "short recording keeps all three duration units")
        expect(RecordingFormat.duration(3600, language: "zh-Hans") == "1小时0分0秒", "hour boundaries keep zero minute and second")
        expect(RecordingFormat.duration(-3, language: "zh-Hans") == "0小时0分0秒", "negative duration is clamped")
        expect(RecordingFormat.duration(.infinity, language: "zh-Hans") == "0小时0分0秒", "nonfinite duration is safe")
        expect(RecordingFormat.duration(3661, language: "en") == "1h 1m 1s", "English uses all three units")
        expect(RecordingFormat.duration(3661, language: "ja") == "1時間1分1秒", "Japanese uses all three units")
        expect(RecordingFormat.duration(90061.9, language: "zh-Hans") == "25小时1分1秒", "Long durations do not wrap after 24 hours")
        expect(RecordingFormat.timecode(3661) == "1:01:01", "Transcript timestamp navigation retains timecode")
        if #available(macOS 15.0, *) {
            let start = Date(timeIntervalSinceReferenceDate: 800_000_000)
            let format = RecordingElapsedFormatStyle(startedAt: start)
            let now = start.addingTimeInterval(3661.4)
            expect(format.format(now) == "1小时1分1秒", "system-updated live activity uses the same duration units")
            expect(format.discreteInput(after: now) == start.addingTimeInterval(3662), "live timer requests its next second boundary")
            expect(format.format(format.discreteInput(before: now)!) == "1小时1分0秒", "previous live timer boundary changes output")
            expect(format.discreteInput(before: start) == nil && format.format(start.addingTimeInterval(-10)) == "0小时0分0秒", "future start is clamped at zero")
        }
        var note = VoiceNote(id: UUID(), kind: .long, capturedAt: .now, duration: 120)
        expect(note.displayTitle == "长录音·待生成标题", "legacy timestamp must not appear in iPhone heading")
        expect(!note.needsRecordingTitle, "empty transcript must not invent a title")
        note.applyTranscription(.init(text: "讨论产品首版范围。下周先完成录音和回顾。"))
        note.transcriptionState = .ready
        let opening = note
        expect(note.needsRecordingTitle, "ready transcript needs a content title")
        expect(note.applyGeneratedRecordingTitle("长录音·产品首版范围讨论", source: .model,
            expectedRevision: opening.transcriptRevision, expectedTitle: opening.title), "matching result applies")
        expect(note.displayTitle == "长录音·产品首版范围讨论", "recording prefix appears once")
        expect(!note.needsRecordingTitle, "settled title does not run again")
        note.applyEdit(title: "我的项目安排", transcript: note.transcript)
        expect(!note.applyGeneratedRecordingTitle("过时的模型标题", source: .model,
            expectedRevision: opening.transcriptRevision, expectedTitle: note.title), "manual title must win even with same transcript")
        expect(note.displayTitle == "长录音·我的项目安排", "manual name remains content")

        var stale = opening
        stale.applyEdit(title: stale.title, transcript: "修改的内容")
        stale.applyEdit(title: stale.title, transcript: opening.transcript)
        expect(!stale.applyGeneratedRecordingTitle("旧结果", source: .model,
            expectedRevision: opening.transcriptRevision, expectedTitle: opening.title), "edit-and-restore revision rejects stale output")
        var automatic = opening
        _ = automatic.applyGeneratedRecordingTitle("旧主题", source: .model,
            expectedRevision: opening.transcriptRevision, expectedTitle: opening.title)
        automatic.applyTranscription(.init(text: "新的会议主题")); automatic.transcriptionState = .ready
        expect(automatic.needsRecordingTitle && automatic.displayTitle == "长录音·待生成标题", "new transcription invalidates automatic title")
        expect(RecordingTitleText.fallback(from: "讨论首版范围。然后确认时间。") == "讨论首版范围", "local fallback comes from transcript")
        expect(RecordingTitleText.normalized("长录音 · 10月21日 12:31") == nil, "timestamp-only model output rejected")
        expect(RecordingTitleText.normalized("标题：\"产品讨论\"") == "产品讨论", "model wrapper is stripped")
        expect(RecordingTitleText.fallback(from: " \n ") == nil, "no invented title from empty input")
        var fallback = opening
        _ = fallback.applyGeneratedRecordingTitle("讨论产品首版范围", source: .transcriptExcerpt,
            expectedRevision: opening.transcriptRevision, expectedTitle: opening.title)
        expect(fallback.applyGeneratedRecordingTitle("产品首版范围讨论", source: .model,
            expectedRevision: fallback.transcriptRevision, expectedTitle: fallback.title), "temporary excerpt must be upgradeable to a model title")
        let thought = VoiceNote(id: UUID(), kind: .thought, capturedAt: .now, duration: 10)
        expect(thought.displayTitle == thought.title && !thought.needsRecordingTitle, "thought behavior preserved")

        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = try NoteRepository(root: root)
        let file = root.appendingPathComponent("input.m4a")
        try Data([1,2,3]).write(to: file)
        let stored = try repository.importRecording(id: opening.id, from: file, kind: .long, capturedAt: opening.capturedAt, duration: 120)
        try repository.update(id: stored.id) { $0 = note }
        let reopened = try NoteRepository(root: root)
        expect(reopened.notes[0] == note, "manual/provenance metadata survives SQLite reopen")
        try repository.update(id: stored.id) { $0 = automatic }
        let autoReloaded = try NoteRepository(root: root).notes[0]
        expect(autoReloaded.titleSource == .model && autoReloaded.needsRecordingTitle, "automatic provenance and stale revision survive reload")
        let legacy = try JSONDecoder().decode(VoiceNote.self, from: JSONEncoder().encode(opening))
        expect(legacy.needsRecordingTitle && legacy.titleSource == nil, "legacy optional metadata remains compatible")
        print("Recording title policy, stale guards, local fallback and persistence passed")
    }
}
