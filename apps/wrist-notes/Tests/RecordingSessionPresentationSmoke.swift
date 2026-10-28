import Foundation
import AVFAudio

@main struct RecordingSessionPresentationSmoke {
    @MainActor static func main() async throws {
        // A wrong cumulative offset, inclusive boundary or decoder-length duration breaks these.
        let a = RecordingSourceRange(chunkID: UUID(), url: URL(fileURLWithPath: "/generated/a.m4a"), startFrame: 0, endFrame: 4_800_000, sampleRate: 16_000)
        let b = RecordingSourceRange(chunkID: UUID(), url: URL(fileURLWithPath: "/generated/b.m4a"), startFrame: 0, endFrame: 160_000, sampleRate: 16_000, sessionStartOffset: 600, discontinuityBefore: "missingChunks")
        let plan = try RecordingRangePlan([a, b])
        precondition(plan.duration == 310)
        precondition(plan.locate(305)?.rangeIndex == 1 && plan.locate(305)?.frame == 80_000)
        precondition(plan.locate(300)?.rangeIndex == 1 && plan.locate(300)?.frame == 0)
        precondition(plan.locate(310) == nil && plan.locate(.nan) == nil)
        precondition(plan.gaps.count == 1 && plan.gaps[0] == 300)
        let cut = try RecordingRangePlan([.init(chunkID: UUID(), url: a.url, startFrame: 32_000, endFrame: 48_000, sampleRate: 16_000)])
        precondition(cut.locate(0.5)?.frame == 40_000)
        let empty = try RecordingRangePlan([])
        precondition(empty.locate(0) == nil)

        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        let start = ISO8601DateFormatter().date(from: "2026-03-08T07:59:00Z")! // March 7 23:59; DST next day
        let id = UUID()
        let summary = RecordingSessionSummary(id: id, startedAt: start, timeZoneIdentifier: calendar.timeZone.identifier,
            origin: nil, location: nil, endedAt: nil, endRevision: nil, finalOrdinal: nil, interrupted: false,
            savedCount: 3, expectedCount: nil, recordedDuration: 240, syncComplete: false,
            recordedIntervals: [.init(start: start, end: start.addingTimeInterval(120)),
                .init(start: start.addingTimeInterval(7200), end: start.addingTimeInterval(7260)),
                .init(start: start.addingTimeInterval(10800), end: start.addingTimeInterval(10860))], legacyNoteID: nil)
        let presentations = RecordingSessionPresentation.records([summary], legacyIDs: [])
        precondition(presentations.count == 1 && presentations[0].id == id && presentations[0].text.isEmpty)
        precondition(RecordingSessionPresentation.status(summary) == "录音结束状态待同步")
        let first = presentations[0].recordingProjection(on: start, calendar: calendar)!
        let nextDay = calendar.date(byAdding: .day, value: 1, to: start)!
        let second = presentations[0].recordingProjection(on: nextDay, calendar: calendar)!
        precondition(first.duration == 60 && second.duration == 180 && second.id == id)
        precondition(first.recordingContinuation == false && second.recordingContinuation == true)
        precondition(second.intervals?.count == 3 && second.capturedAt == start.addingTimeInterval(60))
        let days = RecordingSessionPresentation.occupiedDates([summary], within: DateInterval(start: start.addingTimeInterval(-60), duration: 100_000), calendar: calendar)
        precondition(days.count == 2)
        let library = DaybookRetrieval.libraryRecords(query: "", records: presentations, dayStart: calendar.startOfDay(for: nextDay),
            dayEnd: calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: nextDay))!, allowedKinds: [.voice], semantic: nil)
        precondition(library.count == 1 && library[0].duration == 180, "continuation day library must include only available daily audio")
        let prepared = try DaybookRetrieval(calendar: calendar).prepare(question: "总时长", records: presentations,
            selectedDate: nextDay, allowedKinds: [.voice])
        precondition(prepared.statistics.audioDuration == 180 && prepared.statistics.totalCount == 1)
        precondition(prepared.isCurrent(records: presentations, allowedKinds: [.voice]))
        precondition(!prepared.isCurrent(records: [], allowedKinds: [.voice]), "deleting continuation audio invalidates evidence")
        var changed = presentations[0]
        // Losing actual daily audio, without changing start date, must invalidate old totals.
        changed = DayRecord(id: id, capturedAt: changed.capturedAt, kind: .voice, title: changed.title, text: "", duration: 120,
            intervals: [DateInterval(start: start, duration: 120)])
        changed.recordingSessionID = id
        precondition(!prepared.isCurrent(records: [changed], allowedKinds: [.voice]))
        let gapStart = calendar.startOfDay(for: start)
        let thirdDay = calendar.date(byAdding: .day, value: 2, to: gapStart)!
        let gapped = RecordingSessionSummary(id: UUID(), startedAt: gapStart, timeZoneIdentifier: nil, origin: nil, location: nil,
            endedAt: thirdDay.addingTimeInterval(60), endRevision: 0, finalOrdinal: 2, interrupted: false,
            savedCount: 2, expectedCount: 3, recordedDuration: 120, syncComplete: false,
            recordedIntervals: [.init(start: gapStart, end: gapStart.addingTimeInterval(60)), .init(start: thirdDay, end: thirdDay.addingTimeInterval(60))], legacyNoteID: nil)
        let occupied = RecordingSessionPresentation.occupiedDates([gapped], within: DateInterval(start: gapStart, end: thirdDay.addingTimeInterval(120)), calendar: calendar)
        precondition(occupied == [gapStart, thirdDay], "gap-only dates must not gain calendar markers")
        let oldJSON = try JSONEncoder().encode(DayRecord(id: UUID(), capturedAt: start, kind: .voice, title: "old", text: "legacy"))
        let oldDecoded = try JSONDecoder().decode(DayRecord.self, from: oldJSON)
        precondition(oldDecoded.recordingSessionID == nil)
        let legacy = RecordingSessionSummary(id: UUID(), startedAt: start, timeZoneIdentifier: nil, origin: nil, location: nil,
            endedAt: nil, endRevision: nil, finalOrdinal: nil, interrupted: false, savedCount: 1, expectedCount: nil,
            recordedDuration: 10, syncComplete: false, recordedIntervals: [], legacyNoteID: id)
        precondition(RecordingSessionPresentation.records([summary, legacy], legacyIDs: [id]).count == 1)
        let untimed = RecordingSessionSummary(id: UUID(), startedAt: nil, timeZoneIdentifier: nil, origin: nil, location: nil,
            endedAt: start, endRevision: 0, finalOrdinal: nil, interrupted: true, savedCount: 0, expectedCount: 0,
            recordedDuration: 0, syncComplete: true, recordedIntervals: [], legacyNoteID: nil)
        precondition(RecordingSessionPresentation.records([untimed], legacyIDs: []).isEmpty)
        precondition(RecordingSessionPresentation.occupiedDates([untimed], within: DateInterval(start: start, duration: 86_400), calendar: calendar).isEmpty)
        try waveformBounds()
        try await modelLifecycle()
        print("RecordingSessionPresentationSmoke passed: unique sessions, gap mapping, exact seeks, midnight/DST, legacy dedupe and untimed end")
    }
    static func waveformBounds() throws {
        let root = URL(fileURLWithPath: "/private/tmp/wiselife-presentation-wave-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("synthetic.caf")
        let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
        var writer: AVAudioFile? = try AVAudioFile(forWriting: url, settings: format.settings)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 32_000)!
        buffer.frameLength = 32_000
        for frame in 0..<32_000 { buffer.floatChannelData![0][frame] = frame < 16_000 ? 0 : 0.9 }
        try writer!.write(from: buffer); writer = nil
        let range = RecordingSourceRange(chunkID: UUID(), url: url, startFrame: 0, endFrame: 16_000, sampleRate: 16_000)
        let plan = try RecordingRangePlan([range, range, range])
        let peaks = try RecordingRangeWaveform.read(plan)
        precondition(peaks.count == 68 && peaks.allSatisfy { $0 == 0.08 }, "waveform must never sample the loud excluded tail")
        precondition(Array(plan.window(at: 0)) == [0, 1] && Array(plan.window(at: 1)) == [1, 2] && Array(plan.window(at: 2)) == [2])
    }

    @MainActor static func wait(_ model: RecordingSessionModel) async throws {
        let deadline = Date().addingTimeInterval(5)
        while model.loading && Date() < deadline { try await Task.sleep(nanoseconds: 5_000_000) }
        precondition(!model.loading, "model worker must settle")
    }

    @MainActor static func modelLifecycle() async throws {
        let root = URL(fileURLWithPath: "/private/tmp/wiselife-presentation-model-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let databaseURL = DaybookDatabase.metadataURL(forRoot: root)
        let media = root.appendingPathComponent("RecordingSessions")
        let repository = try RecordingSessionRepository(root: media, database: DaybookDatabase(url: databaseURL))
        for value in 0..<205 {
            try repository.applyEnd(.init(sessionID: UUID(), finalOrdinal: nil, endedAt: Date(timeIntervalSinceReferenceDate: Double(1000 + value)), interrupted: false, revision: 0))
        }
        let audio = root.appendingPathComponent("generated.m4a")
        var writer: AVAudioFile? = try AVAudioFile(forWriting: audio, settings: [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 16000, AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 32000])
        let pcm = AVAudioPCMBuffer(pcmFormat: AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)!, frameCapacity: 16001)!
        pcm.frameLength = 16001
        for frame in 0..<16001 { pcm.floatChannelData![0][frame] = Float(sin(Double(frame) * 0.1)) * 0.1 }
        try writer!.write(from: pcm); writer = nil
        let info = try RecordingAudioFile.inspect(audio), id = UUID()
        let date = Calendar.current.startOfDay(for: Date(timeIntervalSinceReferenceDate: 100)).addingTimeInterval(-0.5)
        let chunk = RecordingChunkDescriptor(id: UUID(), sessionID: id, ordinal: 0, sessionStartedAt: date, capturedAt: date,
            timeZoneIdentifier: TimeZone.current.identifier, sessionStartOffset: 0, frameCount: 16001, sampleRate: 16000,
            byteCount: info.byteCount, sha256: info.sha256,
            origin: .init(device: "Synthetic Watch", deviceID: "fixture", fileName: "generated.m4a", recordingTimeIsEstimated: false), location: nil)
        try repository.storeLocalChunk(chunk, from: audio)
        func sibling(_ ordinal: Int) -> RecordingChunkDescriptor {
            .init(id: UUID(), sessionID: id, ordinal: ordinal, sessionStartedAt: date,
                capturedAt: date.addingTimeInterval(Double(ordinal) * 2), timeZoneIdentifier: chunk.timeZoneIdentifier,
                sessionStartOffset: Double(ordinal) * 2, frameCount: chunk.frameCount, sampleRate: chunk.sampleRate,
                byteCount: chunk.byteCount, sha256: chunk.sha256, origin: chunk.origin, location: nil)
        }
        try repository.storeLocalChunk(sibling(2), from: audio)
        let gate = PresentationStorageGate(root: media, databaseURL: databaseURL)
        let model = RecordingSessionModel(root: root, openRepository: { try gate.open() })
        model.refresh(); try await wait(model)
        precondition(model.errorMessage != nil && model.sessions.isEmpty, "unavailable storage is retryable")
        gate.allow()
        model.refresh(recover: true); try await wait(model)
        precondition(model.sessions.count == 50 && model.hasMore, "general list must paginate")
        precondition(!model.sessions.contains { $0.id == id })
        model.selectDay(date.addingTimeInterval(1)); model.selectMonth(date.addingTimeInterval(1)); try await wait(model)
        precondition(model.daySessions.count == 1 && model.calendarDates.count >= 1, "date query exposes old midnight recording independently of first page")
        for _ in 0..<4 { model.loadMore(); try await wait(model) }
        precondition(model.sessions.count == 206 && !model.hasMore, "general paging must work beyond repository's 200-row cap")
        let detail = try await model.detail(id)
        precondition(detail.session?.endRevision == nil && detail.ranges.count == 2)
        precondition(detail.gaps.contains { $0.kind == "missingChunks" && $0.firstOrdinal == 1 && $0.lastOrdinal == 1 }, "missing ordinal 1 must be visible")
        let before = model.revision
        try repository.applyEnd(.init(sessionID: id, finalOrdinal: 2, endedAt: date.addingTimeInterval(6), interrupted: false, revision: 0))
        try repository.storeLocalChunk(sibling(1), from: audio)
        NotificationCenter.default.post(name: Notification.Name.recordingSourcesDidChange, object: nil)
        for _ in 0..<1000 {
            if model.revision > before { break }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        precondition(model.session(id)?.syncComplete == true, "durable receipt/end notification refreshes app-lifetime model")
        precondition(model.session(id)?.savedCount == 3 && model.sessions.filter { $0.id == id }.count == 1, "three actual files produce exactly one session row")
        let storedAudio = media.appendingPathComponent("Audio").appendingPathComponent(chunk.audioFilename)
        let retained = root.appendingPathComponent("retained-original.m4a")
        try FileManager.default.moveItem(at: storedAudio, to: retained)
        try FileManager.default.createSymbolicLink(at: storedAudio, withDestinationURL: retained)
        let deleted = await model.delete(id); try await wait(model)
        precondition(deleted && model.session(id) == nil && model.daySessions.isEmpty)
        let gone = try repository.session(id: id)
        precondition(gone == nil && model.cleanupIDs.contains(id), "failed file removal retains visible durable cleanup state")
        try FileManager.default.removeItem(at: storedAudio)
        try FileManager.default.moveItem(at: retained, to: storedAudio)
        model.refresh(recover: true); try await wait(model)
        precondition(!model.cleanupIDs.contains(id) && !FileManager.default.fileExists(atPath: storedAudio.path))
        print("Session model lifecycle passed: pagination, old day/month query, notification reload, verified ranges and full-session deletion")
    }

}

private final class PresentationStorageGate: @unchecked Sendable {
    private let lock = NSLock()
    private var blocked = true
    let root: URL
    let databaseURL: URL
    init(root: URL, databaseURL: URL) { self.root = root; self.databaseURL = databaseURL }
    func allow() { lock.lock(); blocked = false; lock.unlock() }
    func open() throws -> RecordingSessionRepository {
        precondition(!Thread.isMainThread, "repository open/recovery must run off main")
        lock.lock(); let denied = blocked; lock.unlock()
        if denied { throw CocoaError(.fileReadNoPermission) }
        return try RecordingSessionRepository(root: root, database: DaybookDatabase(url: databaseURL))
    }
}
