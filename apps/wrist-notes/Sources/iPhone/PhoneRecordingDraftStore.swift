import Foundation

struct PhoneRecordingDraft: Identifiable, Codable {
    let id: UUID
    let fileURL: URL
    let duration: TimeInterval
    let capturedAt: Date
    var location: CaptureLocation? = nil
    init(id: UUID = UUID(), fileURL: URL, duration: TimeInterval, capturedAt: Date, location: CaptureLocation? = nil) {
        self.id = id; self.fileURL = fileURL; self.duration = duration; self.capturedAt = capturedAt; self.location = location
    }
}

/// A manifest is written before capture begins. Audio stays in Application Support until committed.
final class PhoneRecordingDraftStore {
    private let root: URL
    private struct Manifest: Codable { let id: UUID; let duration: TimeInterval; let capturedAt: Date; var location: CaptureLocation? = nil }
    private(set) var recoveryWarning: String?
    init(root: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("WiseLife/RecordingDrafts", isDirectory: true)) { self.root = root }
    func prepare(id: UUID, at date: Date) throws -> PhoneRecordingDraft {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let draft = PhoneRecordingDraft(id: id, fileURL: root.appendingPathComponent("\(id.uuidString).m4a"), duration: 0, capturedAt: date)
        try persist(draft); return draft
    }
    func persist(_ draft: PhoneRecordingDraft) throws {
        try rejectSymlink(root)
        try rejectSymlink(manifest(draft.id))
        let metadata = Manifest(id: draft.id, duration: draft.duration, capturedAt: draft.capturedAt, location: draft.location)
        try JSONEncoder().encode(metadata).write(to: manifest(draft.id), options: .atomic)
    }
    func load() throws -> [PhoneRecordingDraft] {
        recoveryWarning = nil
        guard FileManager.default.fileExists(atPath: root.path) else { return [] }
        try rejectSymlink(root)
        var drafts: [PhoneRecordingDraft] = []
        let entries = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        if entries.contains(where: { $0.lastPathComponent.contains(".json.invalid-") }) {
            recoveryWarning = "部分录音资料损坏，原始文件已保留，请联系支持恢复。"
        }
        for url in entries where url.pathExtension == "json" {
            try rejectSymlink(url)
            // Read failures may be protected-data errors: keep the manifest retryable.
            let data = try Data(contentsOf: url)
            do {
                let metadata = try JSONDecoder().decode(Manifest.self, from: data)
                guard url.lastPathComponent == manifest(metadata.id).lastPathComponent,
                      metadata.duration.isFinite, metadata.duration >= 0 else { throw CocoaError(.fileReadCorruptFile) }
                let audio = audioURL(metadata.id)
                try rejectSymlink(audio)
                drafts.append(PhoneRecordingDraft(id: metadata.id, fileURL: audio, duration: metadata.duration, capturedAt: metadata.capturedAt, location: metadata.location))
            } catch {
                // Isolate malformed metadata without deleting potentially valuable audio.
                let quarantine = url.appendingPathExtension("invalid-" + UUID().uuidString)
                try FileManager.default.moveItem(at: url, to: quarantine)
                recoveryWarning = "部分录音资料损坏，原始文件已保留，请联系支持恢复。"
            }
        }
        return drafts.sorted { $0.capturedAt < $1.capturedAt }
    }
    func remove(_ draft: PhoneRecordingDraft) throws {
        try rejectSymlink(root)
        let audio = audioURL(draft.id)
        try rejectSymlink(audio)
        try rejectSymlink(manifest(draft.id))
        if FileManager.default.fileExists(atPath: audio.path) { try FileManager.default.removeItem(at: audio) }
        if FileManager.default.fileExists(atPath: manifest(draft.id).path) { try FileManager.default.removeItem(at: manifest(draft.id)) }
    }
    private func audioURL(_ id: UUID) -> URL { root.appendingPathComponent("\(id.uuidString).m4a") }
    private func rejectSymlink(_ url: URL) throws {
        if (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true { throw CocoaError(.fileReadInvalidFileName) }
    }
    private func manifest(_ id: UUID) -> URL { root.appendingPathComponent("\(id.uuidString).json") }
}
