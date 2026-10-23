import AVFAudio
import Foundation

@main struct AudioDurationSmoke {
    static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        func expect(_ condition: Bool, _ message: String) throws {
            if !condition { throw NSError(domain: "AudioDurationSmoke", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
        }
        // A real 3-second AAC file, independent of the metadata supplied to the repository.
        func audio(_ url: URL) throws {
            let settings: [String: Any] = [AVFormatIDKey: Int(kAudioFormatMPEG4AAC), AVSampleRateKey: 16_000,
                                          AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 32_000]
            let file = try AVAudioFile(forWriting: url, settings: settings)
            let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 48_000)!
            buffer.frameLength = 48_000
            for i in 0..<48_000 { buffer.floatChannelData![0][i] = 0.1 * sin(Float(i) * 2 * .pi * 440 / 16_000) }
            try file.write(from: buffer)
        }
        func isThreeSeconds(_ duration: TimeInterval?) -> Bool { duration.map { abs($0 - 3) < 0.15 } ?? false }
        func seed(_ directory: URL, id: UUID) throws -> VoiceNote {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            var note = VoiceNote(id: id, kind: .long, capturedAt: Date(timeIntervalSinceReferenceDate: 1000), duration: 0)
            note.title = "Keep this title"; note.transcript = "Keep this transcript"; note.summary = "Keep this summary"
            note.transcriptRevision = UUID(); note.transcriptionState = .ready; note.summaryState = .ready
            try JSONEncoder().encode([note]).write(to: directory.appendingPathComponent("notes.json"))
            return note
        }

        let incomingRoot = root.appendingPathComponent("incoming"), id = UUID()
        let repository = try NoteRepository(root: incomingRoot)
        let source = incomingRoot.appendingPathComponent("source.m4a")
        try audio(source)
        let original = try Data(contentsOf: source)
        let imported = try repository.importRecording(id: id, from: source, kind: .long, capturedAt: .now, duration: 0)
        try expect(isThreeSeconds(imported.duration), "Watch duration=0 must use the actual audio duration on import")
        try expect(try Data(contentsOf: repository.audioURL(for: imported)) == original, "duration repair must not rewrite audio")

        let legacyRoot = root.appendingPathComponent("legacy"), legacyID = UUID()
        let legacy = try seed(legacyRoot, id: legacyID)
        let first = try NoteRepository(root: legacyRoot)
        try audio(first.audioURL(for: legacy))
        let repaired = try NoteRepository(root: legacyRoot).notes.first!
        try expect(isThreeSeconds(repaired.duration), "existing zero-duration SQLite records must recover on reopen")
        try expect(repaired.title == legacy.title && repaired.transcript == legacy.transcript && repaired.summary == legacy.summary && repaired.transcriptRevision == legacy.transcriptRevision,
                   "repair preserves user edits and processing metadata")
        let db = try DaybookDatabase(url: DaybookDatabase.metadataURL(forRoot: legacyRoot))
        let row = try db.query("SELECT duration,payload FROM voice_notes WHERE id=?", [.text(legacyID.uuidString)]).first!
        let payload = try DaybookDatabase.decode(VoiceNote.self, row["payload"])
        try expect(row["duration"]?.double == payload.duration && isThreeSeconds(payload.duration), "SQL projection and JSON payload update together")

        let duplicateRoot = root.appendingPathComponent("duplicate"), duplicateID = UUID()
        let duplicateNote = try seed(duplicateRoot, id: duplicateID)
        let duplicateRepository = try NoteRepository(root: duplicateRoot)
        let duplicateSource = duplicateRoot.appendingPathComponent("retry.m4a")
        try audio(duplicateSource)
        let duplicate = try duplicateRepository.importRecording(id: duplicateID, from: duplicateSource, kind: .long, capturedAt: .now, duration: 0)
        try expect(isThreeSeconds(duplicate.duration) && duplicate.title == duplicateNote.title && duplicateRepository.notes.count == 1,
                   "retransmission repairs a missing file and its unknown duration without duplicating the note")

        let orphanRoot = root.appendingPathComponent("orphan"), orphanID = UUID()
        let orphanDirectory = orphanRoot.appendingPathComponent("Audio")
        try FileManager.default.createDirectory(at: orphanDirectory, withIntermediateDirectories: true)
        try audio(orphanDirectory.appendingPathComponent("\(orphanID.uuidString).m4a"))
        try expect(isThreeSeconds(try NoteRepository(root: orphanRoot).notes.first?.duration), "orphan recovery must measure audio")

        let blockedRoot = root.appendingPathComponent("blocked"), blockedID = UUID()
        let blockedNote = try seed(blockedRoot, id: blockedID)
        let blocked = try NoteRepository(root: blockedRoot)
        try audio(blocked.audioURL(for: blockedNote))
        let blockedDB = try DaybookDatabase(url: DaybookDatabase.metadataURL(forRoot: blockedRoot))
        try blockedDB.execute("CREATE TRIGGER reject_duration BEFORE UPDATE OF duration ON voice_notes BEGIN SELECT RAISE(ABORT,'injected'); END")
        try expect(try NoteRepository(root: blockedRoot).notes == [blockedNote], "failed optional repair must retain readable notes")
        try expect(FileManager.default.fileExists(atPath: blocked.audioURL(for: blockedNote).path), "failed metadata repair must retain audio")
        try blockedDB.execute("DROP TRIGGER reject_duration")
        try expect(isThreeSeconds(try NoteRepository(root: blockedRoot).notes.first?.duration), "repair retries after storage recovery")

        let badRoot = root.appendingPathComponent("bad"), badID = UUID()
        let badNote = try seed(badRoot, id: badID)
        let bad = try NoteRepository(root: badRoot)
        try Data([1, 2, 3]).write(to: bad.audioURL(for: badNote))
        try expect(try NoteRepository(root: badRoot).notes == [badNote], "unreadable audio must not invent a duration")
        try expect(try Data(contentsOf: bad.audioURL(for: badNote)) == Data([1, 2, 3]), "unreadable originals remain available for recovery")
        print("Audio duration: real AAC import, SQLite repair, duplicate/orphan recovery, rollback and original preservation passed")
    }
}
