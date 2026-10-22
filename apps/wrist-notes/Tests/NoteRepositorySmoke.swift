import Foundation

@main
struct NoteRepositorySmoke {
    static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = try NoteRepository(root: root)
        let id = UUID()
        let incoming = root.appendingPathComponent("incoming.m4a")
        try Data([1, 2, 3, 4]).write(to: incoming)
        let first = try repository.importRecording(
            id: id, from: incoming, kind: .thought, capturedAt: Date(timeIntervalSince1970: 100), duration: 2
        )
        precondition(first.id == id)
        precondition(first.title.contains("月") && first.title.contains("日"), "new automatic titles use Chinese dates regardless of device language")
        precondition(repository.notes.count == 1)
        precondition(FileManager.default.fileExists(atPath: repository.audioURL(for: first).path))

        let duplicate = root.appendingPathComponent("duplicate.m4a")
        try Data([9]).write(to: duplicate)
        _ = try repository.importRecording(id: id, from: duplicate, kind: .thought, capturedAt: .now, duration: 2)
        precondition(repository.notes.count == 1)
        let persistedAudio = try Data(contentsOf: repository.audioURL(for: first))
        precondition(persistedAudio == Data([1, 2, 3, 4]))

        let reopened = try NoteRepository(root: root)
        precondition(reopened.notes.count == 1)
        try reopened.update(id: id) { $0.transcript = "spoken words" }
        let afterEdit = try NoteRepository(root: root)
        precondition(afterEdit.notes.first?.transcript == "spoken words")

        try FileManager.default.removeItem(at: afterEdit.audioURL(for: first))
        let replacement = root.appendingPathComponent("replacement.m4a")
        try Data([5, 6]).write(to: replacement)
        _ = try afterEdit.importRecording(id: id, from: replacement, kind: .thought, capturedAt: .now, duration: 2)
        let restoredAudio = try Data(contentsOf: afterEdit.audioURL(for: first))
        precondition(restoredAudio == Data([5, 6]), "a retransmission restores missing audio")

        // Database failure must leave a phone recording draft retryable, not move it away.
        let database = try DaybookDatabase(url: DaybookDatabase.metadataURL(forRoot: root))
        try database.execute("CREATE TRIGGER fail_voice_insert BEFORE INSERT ON voice_notes BEGIN SELECT RAISE(ABORT,'injected'); END")
        let retryID = UUID()
        let draft = root.appendingPathComponent("phone-draft.m4a")
        try Data([7, 8, 9]).write(to: draft)
        do {
            _ = try afterEdit.importRecording(id: retryID, from: draft, kind: .long, capturedAt: .now, duration: 3)
            preconditionFailure("metadata write should fail")
        } catch {}
        precondition(FileManager.default.fileExists(atPath: draft.path), "failed import must restore its source")
        precondition(!afterEdit.notes.contains { $0.id == retryID })
        try database.execute("DROP TRIGGER fail_voice_insert")
        let retried = try afterEdit.importRecording(id: retryID, from: draft, kind: .long, capturedAt: .now, duration: 3)
        precondition(retried.id == retryID)
        let afterRetry = try NoteRepository(root: root)
        precondition(afterRetry.notes.count == 2)
        print("NoteRepositorySmoke passed")
    }
}
