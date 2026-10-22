import Foundation
import XCTest
@testable import WiseNote

@MainActor final class NotesDiarizationTests: XCTestCase {
    private func fixture() throws -> (NoteRepository, VoiceNote, AppSettings) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let repository = try NoteRepository(root: root)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let audio = root.appendingPathComponent("input.m4a")
        try Data([1, 2]).write(to: audio)
        var note = try repository.importRecording(id: UUID(), from: audio, kind: .long, capturedAt: .now, duration: 3)
        note.transcript = "previous"; note.transcriptionState = .ready
        try repository.update(id: note.id) { $0 = note }
        let suite = "SpeakerTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return (repository, note, AppSettings(defaults: defaults))
    }
    private var output: TranscriptionOutput {
        .init(text: "Hello. Hi.", segments: [.init(start: 0, end: 1, text: "Hello."), .init(start: 2, end: 3, text: " Hi.")])
    }

    func testTranscriptionPersistsBeforeDiarizationAndFailureCanRetry() async throws {
        let (repository, note, settings) = try fixture()
        let output = output
        var fail = true
        let model = NotesModel(repository: repository, settings: settings, connectWatch: false,
            transcribeWithSegments: { _, _ in output }, diarize: { _, pieces in
                XCTAssertEqual(repository.notes[0].transcript, "Hello. Hi.")
                XCTAssertEqual(repository.notes[0].transcriptionState, .ready)
                if fail { throw URLError(.cannotLoadFromNetwork) }
                return SpeakerAlignment.align(pieces, turns: [.init(start: 0, end: 1, speaker: 7), .init(start: 2, end: 3, speaker: 2)])
            })
        await model.transcribe(note.id)
        XCTAssertEqual(model.note(note.id)?.transcriptionState, .ready)
        XCTAssertEqual(model.note(note.id)?.diarizationState, .failed)
        XCTAssertEqual(model.note(note.id)?.transcript, "Hello. Hi.")
        fail = false
        await model.identifySpeakers(note.id)
        XCTAssertEqual(model.note(note.id)?.diarizationState, .ready)
        XCTAssertEqual(model.note(note.id)?.transcriptSegments?.map(\.speakerID), ["speaker-1", "speaker-2"])
        model.renameSpeaker(noteID: note.id, speakerID: "speaker-2", name: "Bob")
        XCTAssertEqual(repository.notes[0].speakerName("speaker-2"), "Bob")
    }

    func testManualEditDuringDiarizationWins() async throws {
        let (repository, note, settings) = try fixture()
        let output = output
        let gate = InferenceGate()
        let model = NotesModel(repository: repository, settings: settings, connectWatch: false,
            transcribeWithSegments: { _, _ in output }, diarize: { _, pieces in
                await gate.pause()
                return SpeakerAlignment.align(pieces, turns: [.init(start: 0, end: 3, speaker: 0)])
            })
        let task = Task { await model.transcribe(note.id) }
        await gate.waitUntilPaused()
        model.save(id: note.id, title: "edited", transcript: "My words")
        await gate.resume()
        await task.value
        XCTAssertEqual(model.note(note.id)?.transcript, "My words")
        XCTAssertNil(model.note(note.id)?.transcriptSegments)
        XCTAssertNotEqual(model.note(note.id)?.diarizationState, .running)
    }

    func testEditAndRestoreDuringASRStillWins() async throws {
        let (repository, note, settings) = try fixture()
        let output = output
        let gate = InferenceGate()
        let model = NotesModel(repository: repository, settings: settings, connectWatch: false,
            transcribeWithSegments: { _, _ in await gate.pause(); return output },
            diarize: { _, _ in XCTFail("Edited ASR result must not trigger diarization"); return [] })
        let task = Task { await model.transcribe(note.id) }
        await gate.waitUntilPaused()
        model.save(id: note.id, title: note.title, transcript: "edited")
        model.save(id: note.id, title: note.title, transcript: "previous")
        await gate.resume()
        await task.value
        XCTAssertEqual(model.note(note.id)?.transcript, "previous")
    }

    func testASRPersistenceFailureDoesNotStartDiarization() async throws {
        let (repository, note, settings) = try fixture()
        let output = output
        let index = repository.audioURL(for: note).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("notes.json")
        var diarizationCalls = 0
        let model = NotesModel(repository: repository, settings: settings, connectWatch: false,
            transcribeWithSegments: { _, _ in
                try FileManager.default.removeItem(at: index)
                try FileManager.default.createDirectory(at: index, withIntermediateDirectories: false)
                return output
            }, diarize: { _, pieces in diarizationCalls += 1; return pieces })
        await model.transcribe(note.id)
        XCTAssertEqual(diarizationCalls, 0)
        XCTAssertEqual(model.note(note.id)?.transcript, "previous")
        XCTAssertNotEqual(model.note(note.id)?.transcriptionState, .running)
        XCTAssertNotNil(model.errorMessage)
    }

    func testFinalDiarizationWriteFailureAllowsRetry() async throws {
        let (repository, note, settings) = try fixture()
        let output = output
        let index = repository.audioURL(for: note).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("notes.json")
        var fail = true
        let model = NotesModel(repository: repository, settings: settings, connectWatch: false,
            transcribeWithSegments: { _, _ in output }, diarize: { _, pieces in
                if fail {
                    try FileManager.default.removeItem(at: index)
                    try FileManager.default.createDirectory(at: index, withIntermediateDirectories: false)
                }
                return SpeakerAlignment.align(pieces, turns: [.init(start: 0, end: 3, speaker: 0)])
            })
        await model.transcribe(note.id)
        XCTAssertEqual(model.note(note.id)?.transcript, "Hello. Hi.")
        XCTAssertNotEqual(model.note(note.id)?.diarizationState, .running)
        try FileManager.default.removeItem(at: index)
        fail = false
        await model.identifySpeakers(note.id)
        XCTAssertEqual(model.note(note.id)?.diarizationState, .ready)
    }

    func testDeletionDuringInferenceDoesNotResurrectNote() async throws {
        let (repository, note, settings) = try fixture()
        let output = output
        let gate = InferenceGate()
        let model = NotesModel(repository: repository, settings: settings, connectWatch: false,
            transcribeWithSegments: { _, _ in output }, diarize: { _, pieces in await gate.pause(); return pieces })
        let task = Task { await model.transcribe(note.id) }
        await gate.waitUntilPaused()
        model.delete(note.id)
        await gate.resume()
        await task.value
        XCTAssertNil(model.note(note.id))
        XCTAssertTrue(repository.notes.isEmpty)
    }
}

private actor InferenceGate {
    var paused = false
    var observers: [CheckedContinuation<Void, Never>] = []
    var continuation: CheckedContinuation<Void, Never>?
    func pause() async {
        paused = true
        observers.forEach { $0.resume() }; observers.removeAll()
        await withCheckedContinuation { continuation = $0 }
    }
    func waitUntilPaused() async {
        if paused { return }
        await withCheckedContinuation { observers.append($0) }
    }
    func resume() { continuation?.resume(); continuation = nil }
}
