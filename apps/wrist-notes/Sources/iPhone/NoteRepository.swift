import Foundation

final class NoteRepository {
    private let root: URL
    private let audioDirectory: URL
    private let indexURL: URL
    private(set) var notes: [VoiceNote]

    init(root: URL) throws {
        self.root = root
        audioDirectory = root.appendingPathComponent("Audio", isDirectory: true)
        indexURL = root.appendingPathComponent("notes.json")
        try FileManager.default.createDirectory(at: audioDirectory, withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: indexURL.path) {
            notes = try JSONDecoder().decode([VoiceNote].self, from: Data(contentsOf: indexURL))
        } else {
            notes = []
        }
        try recoverOrphanedAudio()
    }

    func audioURL(for note: VoiceNote) -> URL {
        audioDirectory.appendingPathComponent(note.audioFilename)
    }

    @discardableResult
    func importRecording(id: UUID, from source: URL, kind: RecordingKind, capturedAt: Date, duration: TimeInterval,
                         origin: RecordingOrigin? = nil) throws -> VoiceNote {
        if let existing = notes.first(where: { $0.id == id }) {
            let destination = audioURL(for: existing)
            if !FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.moveItem(at: source, to: destination)
            }
            return existing
        }
        var note = VoiceNote(id: id, kind: kind, capturedAt: capturedAt, duration: duration)
        note.origin = origin
        let destination = audioURL(for: note)
        let copied = !FileManager.default.fileExists(atPath: destination.path)
        if copied { try FileManager.default.copyItem(at: source, to: destination) }
        var revised = notes
        revised.append(note)
        do { try persist(revised) }
        catch {
            if copied { try? FileManager.default.removeItem(at: destination) }
            throw error
        }
        notes = revised
        // Keep the caller's draft intact until both audio and the index are durable.
        if copied { try? FileManager.default.removeItem(at: source) }
        return note
    }

    func update(id: UUID, _ mutate: (inout VoiceNote) -> Void) throws {
        guard let index = notes.firstIndex(where: { $0.id == id }) else { return }
        var revised = notes
        mutate(&revised[index])
        try persist(revised)
        notes = revised
    }

    func delete(id: UUID) throws {
        guard let note = notes.first(where: { $0.id == id }) else { return }
        let revised = notes.filter { $0.id != id }
        try persist(revised)
        notes = revised
        try? FileManager.default.removeItem(at: audioURL(for: note))
    }

    private func recoverOrphanedAudio() throws {
        let files = try FileManager.default.contentsOfDirectory(at: audioDirectory, includingPropertiesForKeys: [.creationDateKey])
        var recovered = notes
        for file in files where file.pathExtension.lowercased() == "m4a" {
            guard let id = UUID(uuidString: file.deletingPathExtension().lastPathComponent),
                  !recovered.contains(where: { $0.id == id }) else { continue }
            let date = (try? file.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .now
            recovered.append(VoiceNote(id: id, kind: .long, capturedAt: date, duration: 0))
        }
        if recovered.count != notes.count {
            try persist(recovered)
            notes = recovered
        }
    }

    private func persist(_ value: [VoiceNote]) throws {
        let data = try JSONEncoder().encode(value)
        try data.write(to: indexURL, options: .atomic)
    }
}
