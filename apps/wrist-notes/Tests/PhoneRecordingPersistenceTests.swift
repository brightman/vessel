import AVFAudio
import XCTest
@testable import WiseNote

@MainActor final class PhoneRecordingPersistenceTests: XCTestCase {
    private final class Activities: RecordingActivityManaging {
        var onDismiss: ((UUID) -> Void)?
        func start(sessionID: UUID, startedAt: Date) async throws {}
        func finish(sessionID: UUID, saved: Bool) async {}
    }

    private func writeAudio(_ url: URL) throws {
        let file = try AVAudioFile(forWriting: url, settings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 32_000
        ])
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 16_000))
        buffer.frameLength = 16_000
        buffer.floatChannelData![0].initialize(repeating: 0, count: 16_000)
        try file.write(from: buffer)
    }

    func testFinalizedDraftSurvivesSaveFailureThenImportsOnePlayableNote() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = PhoneRecordingDraftStore(root: root.appendingPathComponent("Drafts"))
        let draft = try store.prepare(id: UUID(), at: .now)
        try writeAudio(draft.fileURL)
        let repository = try NoteRepository(root: root.appendingPathComponent("Notes"))
        var canSave = false
        let session = PhoneRecordingSession(engine: PhoneRecorder(), activity: Activities(), store: store) { draft in
            guard canSave else { throw CocoaError(.fileWriteNoPermission) }
            try repository.importRecording(id: draft.id, from: draft.fileURL, kind: .long, capturedAt: draft.capturedAt, duration: draft.duration)
        }
        do { try await session.recoverPendingRecordings(); XCTFail("Must retain draft on save failure") }
        catch {}
        XCTAssertEqual(session.phase, .failed)
        XCTAssertTrue(FileManager.default.fileExists(atPath: draft.fileURL.path))
        XCTAssertTrue(repository.notes.isEmpty)
        canSave = true
        try await session.retrySave()
        XCTAssertEqual(session.phase, .idle)
        XCTAssertEqual(repository.notes.map(\.id), [draft.id])
        let note = try XCTUnwrap(repository.notes.first)
        XCTAssertGreaterThan(PhoneRecorder.completedFileDuration(url: repository.audioURL(for: note), fallback: 0), 0.9)
        XCTAssertTrue(try store.load().isEmpty)
        try await session.retrySave()
        XCTAssertEqual(repository.notes.count, 1)
    }

    func testRelaunchAfterImportBeforeManifestCleanupKeepsSameNote() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = PhoneRecordingDraftStore(root: root.appendingPathComponent("Drafts"))
        let prepared = try store.prepare(id: UUID(), at: .now)
        try writeAudio(prepared.fileURL)
        let draft = PhoneRecordingDraft(id: prepared.id, fileURL: prepared.fileURL, duration: 1, capturedAt: prepared.capturedAt)
        try store.persist(draft)
        let repository = try NoteRepository(root: root.appendingPathComponent("Notes"))
        try repository.importRecording(id: draft.id, from: draft.fileURL, kind: .long, capturedAt: draft.capturedAt, duration: draft.duration)
        XCTAssertFalse(FileManager.default.fileExists(atPath: draft.fileURL.path))
        let relaunched = PhoneRecordingSession(engine: PhoneRecorder(), activity: Activities(), store: store) { draft in
            try repository.importRecording(id: draft.id, from: draft.fileURL, kind: .long, capturedAt: draft.capturedAt, duration: draft.duration)
        }
        try await relaunched.recoverPendingRecordings()
        XCTAssertEqual(relaunched.lastSaved?.id, draft.id)
        XCTAssertEqual(repository.notes.map(\.id), [draft.id])
        XCTAssertTrue(try store.load().isEmpty)
    }
}
