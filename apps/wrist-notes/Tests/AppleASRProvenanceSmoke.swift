import Foundation

@main struct AppleASRProvenanceSmoke {
    static func main() async throws {
        var note = VoiceNote(id: UUID(), kind: .long, capturedAt: Date(timeIntervalSinceReferenceDate: 100), duration: 3)
        note.applyTranscription(TranscriptionOutput(text: "这是一段转写", engineName: "Apple DictationTranscriber"))
        let noteData = try JSONEncoder().encode(note)
        let decodedNote = try JSONDecoder().decode(VoiceNote.self, from: noteData)
        expect(decodedNote.transcriptionEngineName == "Apple DictationTranscriber", "note retains actual ASR engine")
        var legacyNoteJSON = try JSONSerialization.jsonObject(with: noteData) as! [String: Any]
        legacyNoteJSON.removeValue(forKey: "transcriptionEngineName")
        let legacyNote = try JSONDecoder().decode(VoiceNote.self, from: JSONSerialization.data(withJSONObject: legacyNoteJSON))
        expect(legacyNote.transcriptionEngineName == nil, "legacy note without engine metadata remains readable")
        var editedNote = decodedNote
        editedNote.applyEdit(title: editedNote.title, transcript: "手工编辑的文本")
        expect(editedNote.transcriptionEngineName == nil, "manual transcript edit clears stale engine provenance")

        let encodedWindow = AudioWindowResult(spans: [], activities: [], asr: .success,
            asrEngineName: "Apple DictationTranscriber", vad: .notRequested, speaker: .notRequested,
            asrCoverage: [], vadCoverage: [])
        let windowData = try JSONEncoder().encode(encodedWindow)
        let decodedWindow = try JSONDecoder().decode(AudioWindowResult.self, from: windowData)
        expect(decodedWindow.asrEngineName == "Apple DictationTranscriber", "window JSON retains actual ASR engine")
        var legacyWindowJSON = try JSONSerialization.jsonObject(with: windowData) as! [String: Any]
        legacyWindowJSON.removeValue(forKey: "asrEngineName")
        let legacyWindow = try JSONDecoder().decode(AudioWindowResult.self, from: JSONSerialization.data(withJSONObject: legacyWindowJSON))
        expect(legacyWindow.asrEngineName == nil, "legacy window JSON without engine metadata remains readable")

        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceID = AudioSourceID(kind: .session, id: UUID())
        let chunkID = UUID()
        let range = try AudioSourceRange(
            range: RecordingSourceRange(chunkID: chunkID, url: root.appendingPathComponent("\(chunkID).wav"),
                startFrame: 0, endFrame: 16_000 * 1_801, sampleRate: 16_000),
            contentHash: String(repeating: "a", count: 64))
        let source = try AudioSourceSnapshot(id: sourceID, capturedAt: Date(), title: "ASR provenance",
            ranges: [range], complete: true)
        let database = try DaybookDatabase(url: root.appendingPathComponent("processing.sqlite3"))
        try database.execute("INSERT INTO recording_sessions(id,created_at) VALUES (?,0)", [.text(sourceID.id.uuidString)])
        let repository = AudioProcessingRepository(database: database)
        let windows = try AudioWindowPlanner.plan(source: source, configurationKey: "asr-provenance")
        try repository.register(source: source, configurationKey: "asr-provenance", windows: windows)
        let firstJob = try repository.claimNext()!
        let initial = AudioWindowResult(spans: [.init(start: 1, end: 2, text: "sample")], activities: [], asr: .success,
            asrEngineName: "Apple SpeechTranscriber", vad: .missingResource, speaker: .success,
            asrCoverage: [.init(start: 0, end: 10)], vadCoverage: [])
        try repository.commit(job: firstJob, result: initial)
        let firstStored = try repository.results(sourceID: sourceID).first
        expect(firstStored?.asrEngineName == "Apple SpeechTranscriber", "SQLite result payload stores actual engine")

        try repository.retryIncompleteStages(sourceID: sourceID, resourceOnly: true)
        let retry = try repository.claimNext()!
        let retryStages = try repository.stages(for: retry)
        expect(retryStages == [.vad], "resource retry does not rerun successful ASR")
        let vadOnly = AudioInferenceDelta(result: .init(spans: [], activities: [], asr: .notRequested,
            vad: .success, speaker: .notRequested, asrCoverage: [], vadCoverage: [.init(start: 0, end: 10)]),
            speakerSpanUpdates: [])
        try repository.commit(job: retry, delta: vadOnly)
        let retriedStored = try repository.results(sourceID: sourceID).first
        expect(retriedStored?.asrEngineName == "Apple SpeechTranscriber", "stage retry retains provenance from successful ASR")

        let longChunkID = UUID()
        let longRange = try AudioSourceRange(
            range: RecordingSourceRange(chunkID: longChunkID, url: root.appendingPathComponent("\(longChunkID).wav"),
                startFrame: 0, endFrame: 16_000 * 60, sampleRate: 16_000),
            contentHash: String(repeating: "b", count: 64))
        let longSource = try AudioSourceSnapshot(id: sourceID, capturedAt: Date(), title: "Adaptive ASR provenance",
            ranges: [longRange], complete: true)
        let longWindows = try AudioWindowPlanner.plan(source: longSource, configurationKey: "adaptive-provenance")
        let adaptive = try await AudioAdaptiveInference.process(window: longWindows[0], maximumCoreDuration: 30, priorSpans: []) { _, _ in
            AudioInferenceDelta(result: .init(spans: [], activities: [], asr: .success,
                asrEngineName: "Apple DictationTranscriber", vad: .notRequested, speaker: .notRequested,
                asrCoverage: [.init(start: 0, end: 30)], vadCoverage: []), speakerSpanUpdates: [])
        }
        expect(adaptive.result.asrEngineName == "Apple DictationTranscriber", "adaptive windows aggregate the actual ASR engine")

        print("Apple ASR provenance: direct-note persistence, legacy decoding, SQLite retries and adaptive-window aggregation passed")
    }

    private static func expect(_ condition: Bool, _ message: String) {
        guard condition else { fatalError(message) }
    }
}
