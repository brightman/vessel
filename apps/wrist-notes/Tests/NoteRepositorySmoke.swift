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

        let mergeSourceIDs = [UUID(), UUID()]
        let sourceOrigins = [
            RecordingOrigin(device: "Apple Watch", deviceID: "watch-se", fileName: "watch-part.m4a", recordingTimeIsEstimated: false),
            RecordingOrigin(device: "iPhone", deviceID: "phone-15", fileName: "phone-part.m4a", recordingTimeIsEstimated: false)
        ]
        for (index, id) in mergeSourceIDs.enumerated() {
            let source = root.appendingPathComponent("merge-\(id.uuidString).m4a")
            try Data([10, 11, 12]).write(to: source)
            _ = try afterRetry.importRecording(id: id, from: source, kind: .long, capturedAt: .now, duration: 1,
                origin: sourceOrigins[index])
        }
        let mergeDatabase = try DaybookDatabase(url: DaybookDatabase.metadataURL(forRoot: root))
        try mergeDatabase.execute("CREATE TRIGGER fail_voice_delete BEFORE DELETE ON voice_notes WHEN OLD.id='\(mergeSourceIDs[1].uuidString)' BEGIN SELECT RAISE(ABORT,'injected'); END")
        do {
            try afterRetry.delete(ids: mergeSourceIDs)
            preconditionFailure("batch deletion should fail atomically")
        } catch {}
        precondition(mergeSourceIDs.allSatisfy { id in afterRetry.notes.contains { $0.id == id } },
                     "a failed batch delete must retain every source note")
        precondition(mergeSourceIDs.allSatisfy { id in
            guard let note = afterRetry.notes.first(where: { $0.id == id }) else { return false }
            return FileManager.default.fileExists(atPath: afterRetry.audioURL(for: note).path)
        }, "a failed batch delete must retain every source audio file")
        try mergeDatabase.execute("DROP TRIGGER fail_voice_delete")
        try afterRetry.delete(ids: mergeSourceIDs)
        precondition(mergeSourceIDs.allSatisfy { id in !afterRetry.notes.contains { $0.id == id } },
                     "all selected source notes are removed together")
        precondition(mergeSourceIDs.allSatisfy { id in !FileManager.default.fileExists(atPath: root.appendingPathComponent("Audio/\(id.uuidString).m4a").path) },
                     "source audio files are removed after the database commit")
        let mergedID = UUID()
        let mergedAudio = root.appendingPathComponent("merged-audio.m4a")
        try Data([14, 15, 16]).write(to: mergedAudio)
        let mergedSources = zip(mergeSourceIDs, sourceOrigins).map { id, origin in
            MergedRecordingSource(recordingID: id, capturedAt: Date(timeIntervalSince1970: 100), duration: 1, origin: origin)
        }
        _ = try afterRetry.importRecording(id: mergedID, from: mergedAudio, kind: .long, capturedAt: .now, duration: 2,
            origin: RecordingOrigin(device: "Apple Watch · iPhone", deviceID: "", fileName: "merged-recording.m4a", recordingTimeIsEstimated: false),
            mergedSources: mergedSources)
        let reopenedMerge = try NoteRepository(root: root)
        let restoredSources = reopenedMerge.notes.first { $0.id == mergedID }?.mergedSources
        precondition(restoredSources?.compactMap(\.origin?.device) == ["Apple Watch", "iPhone"],
                     "merged source devices remain available after database reload")
        precondition(restoredSources?.map(\.recordingID) == mergeSourceIDs,
                     "merged source IDs remain available after original entries are deleted")
        print("NoteRepositorySmoke passed")
    }
}
