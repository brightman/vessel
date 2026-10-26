import Foundation
import XCTest
@testable import WiseNote

@MainActor final class VoiceEnrollmentTests: XCTestCase {
    func testWhisperOnlyAcceptsTranscriptWithSpeechCharacters() {
        XCTAssertTrue(WhisperTranscriptValidity.containsSpeechCharacters("你好，今天天气不错。"))
        XCTAssertTrue(WhisperTranscriptValidity.containsSpeechCharacters("A short voice note."))
        XCTAssertTrue(WhisperTranscriptValidity.containsSpeechCharacters("42"))
        XCTAssertFalse(WhisperTranscriptValidity.containsSpeechCharacters(" (，。… "))
        XCTAssertFalse(WhisperTranscriptValidity.containsSpeechCharacters("   "))
    }

    private func profile() throws -> VoiceProfile {
        var vector = [Float](repeating: 0, count: 256); vector[0] = 1
        return try VoiceIdentityPolicy.makeProfile(embeddings: [vector, vector, vector], duration: 35)
    }
    private func store() throws -> VoiceProfileStore {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return VoiceProfileStore(root: root)
    }
    func testCancelledReplacementAndLateCompletionKeepOldProfile() async throws {
        let store = try store(), original = try profile(), candidate = try profile(), gate = VoiceEnrollmentGate()
        try store.save(original)
        let model = MyVoiceProfileModel(store: store, enroll: { _ in await gate.pause(); return candidate })
        let task = Task { await model.saveRecording(url: store.root, duration: 35, confirmedSolo: true) }
        await gate.wait(); model.cancelEnrollment(); await gate.resume()
        let saved = await task.value
        XCTAssertFalse(saved); XCTAssertEqual(try store.load()?.id, original.id); XCTAssertEqual(model.profile?.id, original.id)
    }
    func testDeletionDuringEnrollmentCannotResurrectProfile() async throws {
        let store = try store(), candidate = try profile(), gate = VoiceEnrollmentGate()
        try store.save(try profile())
        let model = MyVoiceProfileModel(store: store, enroll: { _ in await gate.pause(); return candidate })
        let task = Task { await model.saveRecording(url: store.root, duration: 35, confirmedSolo: true) }
        await gate.wait(); XCTAssertTrue(model.delete()); await gate.resume()
        let saved = await task.value
        XCTAssertFalse(saved); XCTAssertNil(model.profile); XCTAssertNil(try store.load())
    }
    func testShortOrUnconfirmedRecordingDoesNotRunInference() async throws {
        let store = try store(), candidate = try profile()
        var calls = 0
        let model = MyVoiceProfileModel(store: store, enroll: { _ in calls += 1; return candidate })
        let short = await model.saveRecording(url: store.root, duration: 29.9, confirmedSolo: true)
        let unconfirmed = await model.saveRecording(url: store.root, duration: 35, confirmedSolo: false)
        XCTAssertFalse(short); XCTAssertFalse(unconfirmed); XCTAssertEqual(calls, 0); XCTAssertNil(try store.load())
        let saved = await model.saveRecording(url: store.root, duration: 35, confirmedSolo: true)
        XCTAssertTrue(saved); XCTAssertEqual(calls, 1); XCTAssertEqual(try store.load()?.id, candidate.id)
    }
    func testInvalidReplacementCannotDestroyOriginal() async throws {
        let store = try store(), original = try profile()
        try store.save(original)
        let invalid = VoiceProfile(id: UUID(), enrolledAt: .now, recordingDuration: 35, modelID: "incompatible", embeddings: original.embeddings)
        let model = MyVoiceProfileModel(store: store, enroll: { _ in invalid })
        let saved = await model.saveRecording(url: store.root, duration: 35, confirmedSolo: true)
        XCTAssertFalse(saved); XCTAssertEqual(try store.load()?.id, original.id); XCTAssertNotNil(model.errorMessage)
    }
    func testOverlappingSecondVoiceRejectsReplacementAndPreservesOriginal() async throws {
        let store = try store(), original = try profile()
        try store.save(original)
        let model = MyVoiceProfileModel(store: store, enroll: { _ in
            _ = try VoiceSpeechSelection.enrollmentRanges(turns: [
                .init(start: 0, end: 30, speaker: 0), .init(start: 10, end: 20, speaker: 1)
            ], sampleCount: 30 * 16_000)
            XCTFail("Overlapping second voice should be rejected")
            return original
        })
        let saved = await model.saveRecording(url: store.root, duration: 35, confirmedSolo: true)
        XCTAssertFalse(saved); XCTAssertEqual(try store.load()?.id, original.id)
        XCTAssertEqual(model.profile?.id, original.id)
        XCTAssertEqual(model.errorMessage, VoiceEnrollmentError.multipleVoices.localizedDescription)
    }

    private func noteFixture() throws -> (NoteRepository, VoiceNote, AppSettings) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let repository = try NoteRepository(root: root), audio = root.appendingPathComponent("test.m4a")
        try Data([1]).write(to: audio)
        var note = try repository.importRecording(id: UUID(), from: audio, kind: .long, capturedAt: .now, duration: 35)
        note.transcriptionState = .ready
        try repository.update(id: note.id) { $0 = note }
        let suite = "VoiceEnrollmentTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        // Use a separate app settings domain; never read user's provider configuration.
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return (repository, note, AppSettings(defaults: defaults))
    }
    func testOwnerMatchPersistsAndManualNameWins() async throws {
        let (repository, note, settings) = try noteFixture(), store = try store(), enrolled = try profile()
        try store.save(enrolled)
        let owner = MyVoiceProfileModel(store: store)
        let segments = [TranscriptSegment(start: 0, end: 15, text: "my speech", speakerID: "speaker-1")]
        let model = NotesModel(repository: repository, settings: settings, connectWatch: false,
            transcribeWithSegments: { _, _ in .init(text: "my speech", segments: segments) },
            voiceProfile: owner, diarizeWithIdentity: { _, segments, profile in
                XCTAssertEqual(profile?.id, enrolled.id)
                return .init(segments: segments, ownerSpeakerIDs: ["speaker-1"], profileID: profile?.id)
            })
        await model.transcribe(note.id)
        XCTAssertEqual(repository.notes[0].speakerName("speaker-1"), "我")
        XCTAssertTrue(model.renameSpeaker(noteID: note.id, speakerID: "speaker-1", name: "Alice"))
        XCTAssertEqual(repository.notes[0].speakerName("speaker-1"), "Alice")
    }
    func testIdentityFailureKeepsSuccessfulTranscriptAndDiarization() async throws {
        let (repository, note, settings) = try noteFixture(), store = try store(), enrolled = try profile()
        try store.save(enrolled)
        let segments = [TranscriptSegment(start: 0, end: 15, text: "keep my words", speakerID: "speaker-1")]
        let model = NotesModel(repository: repository, settings: settings, connectWatch: false,
            transcribeWithSegments: { _, _ in .init(text: "keep my words", segments: segments) },
            voiceProfile: MyVoiceProfileModel(store: store), diarizeWithIdentity: { _, segments, profile in
                .init(segments: segments, profileID: profile?.id, identityMessage: "Identity model unavailable")
            })
        await model.transcribe(note.id)
        let result = try XCTUnwrap(repository.notes.first)
        XCTAssertEqual(result.transcript, "keep my words")
        XCTAssertEqual(result.transcriptSegments, segments)
        XCTAssertEqual(result.transcriptionState, .ready)
        XCTAssertEqual(result.diarizationState, .ready)
        XCTAssertEqual(result.speakerName("speaker-1"), "说话人 1")
        XCTAssertEqual(result.voiceIdentityMessage, "Identity model unavailable")
    }
    func testProfileChangeWhileMatchingDiscardsIdentityButKeepsTranscript() async throws {
      for replacement in [false, true] {
        let (repository, note, settings) = try noteFixture(), store = try store(), enrolled = try profile(), gate = VoiceEnrollmentGate()
        try store.save(enrolled)
        let candidate = try profile()
        let owner = MyVoiceProfileModel(store: store, enroll: { _ in candidate })
        let segments = [TranscriptSegment(start: 0, end: 15, text: "keep this", speakerID: "speaker-1")]
        let model = NotesModel(repository: repository, settings: settings, connectWatch: false,
            transcribeWithSegments: { _, _ in .init(text: "keep this", segments: segments) },
            voiceProfile: owner, diarizeWithIdentity: { _, segments, profile in
                await gate.pause()
                return .init(segments: segments, ownerSpeakerIDs: ["speaker-1"], profileID: profile?.id)
            })
        let task = Task { await model.transcribe(note.id) }
        await gate.wait()
        if replacement {
            let saved = await owner.saveRecording(url: store.root, duration: 35, confirmedSolo: true)
            XCTAssertTrue(saved); XCTAssertEqual(owner.profile?.id, candidate.id)
        } else { XCTAssertTrue(owner.delete()) }
        await gate.resume(); await task.value
        XCTAssertEqual(repository.notes[0].transcript, "keep this")
        XCTAssertEqual(repository.notes[0].speakerName("speaker-1"), "说话人 1")
        XCTAssertEqual(repository.notes[0].diarizationState, .ready)
      }
    }
}

private actor VoiceEnrollmentGate {
    private var blocked = false
    private var observers: [CheckedContinuation<Void, Never>] = []
    private var continuation: CheckedContinuation<Void, Never>?
    func pause() async { blocked = true; observers.forEach { $0.resume() }; observers = []; await withCheckedContinuation { continuation = $0 } }
    func wait() async { if !blocked { await withCheckedContinuation { observers.append($0) } } }
    func resume() { continuation?.resume(); continuation = nil }
}
