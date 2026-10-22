import AVFAudio
import Foundation
import os

final class NoteRepository {
    private let audioDirectory: URL
    private let db: DaybookDatabase
    private let files = FileManager.default
    private(set) var notes: [VoiceNote] = []

    init(root: URL, database: DaybookDatabase? = nil) throws {
        let root = root.standardizedFileURL
        audioDirectory = root.appendingPathComponent("Audio", isDirectory: true)
        db = try database ?? DaybookDatabase(url: DaybookDatabase.metadataURL(forRoot: root))
        try rejectSymlink(audioDirectory)
        try files.createDirectory(at: audioDirectory, withIntermediateDirectories: true)
        let indexURL = root.appendingPathComponent("notes.json")
        try db.migrate("voice_notes") {
            try rejectSymlink(indexURL)
            let imported = files.fileExists(atPath: indexURL.path)
                ? try JSONDecoder().decode([VoiceNote].self, from: Data(contentsOf: indexURL)) : []
            guard Set(imported.map(\.id)).count == imported.count else { throw invalidStorage() }
            for note in imported { try insert(note) }
            _ = try load()
        }
        try recoverOrphanedAudio()
        // Optional metadata repair must not hide otherwise readable notes if a write fails.
        do { try repairUnknownDurations() }
        catch { Logger(subsystem: "cloud.karama.wisenote", category: "RecordingMetadata").error("Audio duration repair deferred: \(error.localizedDescription, privacy: .public)") }
        cleanupTombstones()
    }

    func audioURL(for note: VoiceNote) -> URL { audioDirectory.appendingPathComponent("\(note.id.uuidString).m4a") }

    @discardableResult
    func importRecording(id: UUID, from source: URL, kind: RecordingKind, capturedAt: Date, duration: TimeInterval,
                         origin: RecordingOrigin? = nil, location: CaptureLocation? = nil) throws -> VoiceNote {
        var copied: URL?
        let result: (VoiceNote, [VoiceNote])
        do {
            result = try db.transaction {
                let current = try load()
                var note = current.first { $0.id == id } ?? VoiceNote(id: id, kind: kind, capturedAt: capturedAt, duration: duration)
                if !current.contains(where: { $0.id == id }) { note.origin = origin; note.location = location }
                let destination = try validatedURL(for: note)
                if !files.fileExists(atPath: destination.path) {
                    try rejectSymlink(source)
                    guard try source.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { throw invalidStorage() }
                    try files.copyItem(at: source, to: destination)
                    copied = destination
                }
                let oldDuration = note.duration
                if note.duration == 0, let measured = audioDuration(at: destination) { note.duration = measured }
                if !current.contains(where: { $0.id == id }) { try insert(note) }
                else if note.duration != oldDuration { try persistDuration(note) }
                try db.execute("DELETE FROM media_tombstones WHERE kind='voice' AND id=?", [.text(id.uuidString)])
                return (note, try load())
            }
        } catch {
            if let copied {
                // Another connection may adopt this file after rollback. Reacquire the write
                // lock and check ownership before removing it; failed cleanup retains media.
                try? db.transaction {
                    guard try db.query("SELECT id FROM voice_notes WHERE audio_filename=?", [.text(copied.lastPathComponent)]).isEmpty else { return }
                    _ = try validatedMediaURL(id: id, filename: copied.lastPathComponent)
                    try files.removeItem(at: copied)
                }
            }
            throw error
        }
        notes = result.1
        // The caller's draft survives any failed copy or SQLite commit.
        if copied != nil && source.standardizedFileURL != audioURL(for: result.0).standardizedFileURL { try? files.removeItem(at: source) }
        return result.0
    }

    func update(id: UUID, _ mutate: (inout VoiceNote) -> Void) throws {
        let revised = try db.transaction {
            guard var note = try load().first(where: { $0.id == id }) else { return try load() }
            mutate(&note)
            let values = try values(for: note)
            try db.execute("UPDATE voice_notes SET captured_at=?,kind=?,title=?,transcript=?,summary=?,duration=?,audio_filename=?,payload=? WHERE id=?", Array(values.dropFirst()) + [.text(id.uuidString)])
            return try load()
        }
        notes = revised
    }

    @discardableResult
    func setAddress(_ address: CaptureAddress, noteID: UUID, matching point: CaptureLocation) throws -> Bool {
        let result = try db.transaction {
            guard var note = try load().first(where: { $0.id == noteID }), note.location?.matchesCapture(point) == true else {
                return (false, try load())
            }
            note.location?.address = address
            // Only the payload changes. Never overwrite concurrently edited transcript/title fields.
            try db.execute("UPDATE voice_notes SET payload=? WHERE id=?", [try DaybookDatabase.json(note), .text(noteID.uuidString)])
            return (true, try load())
        }
        notes = result.1
        return result.0
    }

    func delete(id: UUID) throws {
        let revised = try db.transaction {
            if let note = try load().first(where: { $0.id == id }) {
                _ = try validatedURL(for: note)
                try db.execute("INSERT OR REPLACE INTO media_tombstones(kind,id,filename,deleted_at) VALUES ('voice',?,?,?)", [.text(id.uuidString), .text(note.audioFilename), .real(Date.now.timeIntervalSinceReferenceDate)])
                try db.execute("DELETE FROM voice_notes WHERE id=?", [.text(id.uuidString)])
            }
            return try load()
        }
        notes = revised
        cleanupTombstones()
    }

    private func values(for note: VoiceNote) throws -> [DaybookDatabase.Value] {
        _ = try validatedURL(for: note)
        return [.text(note.id.uuidString), .real(note.capturedAt.timeIntervalSinceReferenceDate), .text(note.kind.rawValue), .text(note.title), .text(note.transcript), .text(note.summary), .real(note.duration), .text(note.audioFilename), try DaybookDatabase.json(note)]
    }
    private func insert(_ note: VoiceNote) throws {
        try db.execute("INSERT INTO voice_notes(id,captured_at,kind,title,transcript,summary,duration,audio_filename,payload) VALUES (?,?,?,?,?,?,?,?,?)", try values(for: note))
    }
    private func audioDuration(at url: URL) -> TimeInterval? {
        guard let audio = try? AVAudioFile(forReading: url), audio.length > 0,
              audio.processingFormat.sampleRate.isFinite, audio.processingFormat.sampleRate > 0 else { return nil }
        let duration = Double(audio.length) / audio.processingFormat.sampleRate
        return duration.isFinite && duration > 0 ? duration : nil
    }
    private func persistDuration(_ note: VoiceNote) throws {
        try db.execute("UPDATE voice_notes SET duration=?,payload=? WHERE id=?",
                       [.real(note.duration), try DaybookDatabase.json(note), .text(note.id.uuidString)])
    }
    private func repairUnknownDurations() throws {
        notes = try db.transaction {
            for var note in try load() where note.duration == 0 {
                guard let duration = audioDuration(at: try validatedURL(for: note)) else { continue }
                note.duration = duration
                try persistDuration(note)
            }
            return try load()
        }
    }
    private func load() throws -> [VoiceNote] {
        try db.query("SELECT * FROM voice_notes ORDER BY captured_at,id").map { row in
            let note = try DaybookDatabase.decode(VoiceNote.self, row["payload"])
            let projected = try values(for: note)
            for (index, column) in ["id","captured_at","kind","title","transcript","summary","duration","audio_filename"].enumerated() {
                guard row[column] == projected[index] else { throw invalidStorage() }
            }
            return note
        }
    }
    private func validatedURL(for note: VoiceNote) throws -> URL {
        guard note.capturedAt.timeIntervalSinceReferenceDate.isFinite, note.duration.isFinite, note.duration >= 0,
              note.audioFilename == "\(note.id.uuidString).m4a" else { throw invalidStorage() }
        return try validatedMediaURL(id: note.id, filename: note.audioFilename)
    }
    private func validatedMediaURL(id: UUID, filename: String) throws -> URL {
        guard filename == "\(id.uuidString).m4a" else { throw invalidStorage() }
        try rejectSymlink(audioDirectory)
        let url = audioDirectory.appendingPathComponent(filename)
        try rejectSymlink(url)
        if files.fileExists(atPath: url.path) {
            guard try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { throw invalidStorage() }
        }
        return url
    }
    private func recoverOrphanedAudio() throws {
        notes = try db.transaction {
            let current = try load()
            let known = Set(current.map(\.id))
            let tombstones = Set(try db.query("SELECT id FROM media_tombstones WHERE kind='voice'").map { try $0.requiredString("id") })
            try rejectSymlink(audioDirectory)
            for file in try files.contentsOfDirectory(at: audioDirectory, includingPropertiesForKeys: [.creationDateKey]) where file.pathExtension == "m4a" {
                guard let id = UUID(uuidString: file.deletingPathExtension().lastPathComponent),
                      file.lastPathComponent == "\(id.uuidString).m4a", !known.contains(id), !tombstones.contains(id.uuidString) else { continue }
                _ = try validatedMediaURL(id: id, filename: file.lastPathComponent)
                let date = (try? file.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .now
                try insert(VoiceNote(id: id, kind: .long, capturedAt: date, duration: audioDuration(at: file) ?? 0))
            }
            return try load()
        }
    }
    private func cleanupTombstones() {
        // Keep deletion intent even after success, so delayed duplicate files cannot resurrect notes.
        // Serialize with explicit retransfers so cleanup cannot remove restored audio.
        try? db.transaction {
            for row in try db.query("SELECT id,filename FROM media_tombstones WHERE kind='voice'") {
                guard let id = UUID(uuidString: try row.requiredString("id")),
                      try db.query("SELECT id FROM voice_notes WHERE id=?", [.text(id.uuidString)]).isEmpty else { continue }
                if let url = try? validatedMediaURL(id: id, filename: row.requiredString("filename")), files.fileExists(atPath: url.path) { try? files.removeItem(at: url) }
            }
        }
    }
    private func rejectSymlink(_ url: URL) throws {
        if (try? files.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType) == .typeSymbolicLink { throw invalidStorage() }
    }
    private func invalidStorage() -> DaybookDatabase.Failure { .init(code: 11, detail: "本地录音记录或路径无效，原始文件已保留") }
}
