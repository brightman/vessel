import AVFAudio
import Foundation

@main struct AudioSourceDiscoverySmoke {
    struct Failure: Error { let message: String }
    static func check(_ condition: Bool, _ message: String) throws {
        guard condition else { throw Failure(message: message) }
    }
    static func main() async throws {
        let root = URL(fileURLWithPath: "/private/tmp/wiselife-source-discovery-\(UUID())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let db = try DaybookDatabase(url: DaybookDatabase.metadataURL(forRoot: root))
        let fixture = root.appendingPathComponent("fixture.m4a")
        var writer: AVAudioFile? = try AVAudioFile(forWriting: fixture, settings: [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 16000, AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 32000])
        let pcm = AVAudioPCMBuffer(pcmFormat: AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)!, frameCapacity: 16000)!
        pcm.frameLength = 16000
        for i in 0..<16000 { pcm.floatChannelData![0][i] = Float(sin(Double(i) * 0.1)) * 0.1 }
        try writer!.write(from: pcm); writer = nil
        let notes = try NoteRepository(root: root, database: db)
        let good = try notes.importRecording(id: UUID(), from: fixture, kind: .long, capturedAt: .now, duration: 1)
        let id = AudioSourceID(kind: .legacyNote, id: good.id)
        let sessions = try RecordingSessionRepository(root: root.appendingPathComponent("RecordingSessions"), database: db)
        let stored = root.appendingPathComponent("Audio").appendingPathComponent(good.audioFilename)
        try RecordingAudioFile.requireSafePath(stored)
        let info = try RecordingAudioFile.inspect(stored)
        let chunk = RecordingChunkDescriptor(id: UUID(), sessionID: UUID(), ordinal: 0, sessionStartedAt: .now,
            capturedAt: .now, timeZoneIdentifier: "UTC", sessionStartOffset: 0, frameCount: 16000, sampleRate: 16000,
            byteCount: info.byteCount, sha256: info.sha256, origin: .init(device: "Watch", deviceID: "fixture", fileName: "", recordingTimeIsEstimated: false), location: nil)
        try sessions.storeLocalChunk(chunk, from: stored)
        // A damaged historical row must be reported as unavailable, not abort today's ASR discovery.
        try db.execute("UPDATE recording_chunks SET filename='invalid.m4a' WHERE id=?", [.text(chunk.id.uuidString)])
        let discovery = AudioSourceDiscovery(root: root)
        let processing = try discovery.open()
        let sources: [AudioSourceSnapshot]
        do { sources = try discovery.sources(explicit: [id]) }
        catch { throw Failure(message: "one invalid historical session blocked a valid recording: \(error)") }
        try check(sources.map(\.id) == [id], "valid recording missing")
        try check(discovery.unavailableSources == [.init(kind: .session, id: chunk.sessionID)], "damaged session must remain visible as unavailable")
        let worker = AudioProcessingCoordinator(open: { processing }, configuration: .init(),
            discover: { try discovery.sources(explicit: $0) }, infer: { window, _, _, _, _, _ in
                .init(result: .init(spans: [.init(start: 0, end: 0.8, text: "fixture transcript")], activities: [],
                    asr: .success, vad: .notRequested, speaker: .notRequested,
                    asrCoverage: [.init(start: window.coreStart, end: window.coreEnd)], vadCoverage: []), speakerSpanUpdates: [])
            }, discoveryUnavailable: { discovery.unavailableSources })
        await worker.memoryPressure()
        await worker.reprocess(id)
        await worker.waitUntilIdle()
        try check(try processing.spans(sourceID: id).map(\.text) == ["fixture transcript"], "manual reprocess did not persist ASR")
        try check(!(await worker.storageUnavailable), "isolated source error became a database error")
        let missing = AudioSourceID(kind: .legacyNote, id: UUID())
        if case .failure(.sourceUnavailable) = await worker.reprocess(missing) {} else {
            throw Failure(message: "missing source must return actionable feedback")
        }
        try check(try await worker.status(missing).sourceUnavailable, "missing source status not published")
        // A manual retry cannot bypass microphone capture/protected-data suspension.
        await worker.suspend(.capture)
        await worker.reprocess(id); await worker.waitUntilIdle()
        try check(try processing.results(sourceID: id).isEmpty, "reprocess bypassed active capture")
        await worker.resume(.capture); await worker.waitUntilIdle()
        try check(try processing.spans(sourceID: id).count == 1, "capture end did not resume queued reprocess")
        print("Audio source isolation and manual reprocess persisted transcript: passed")
    }
}
