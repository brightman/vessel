import Foundation

struct PhoneRecordingChunkFile: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    let ordinal: Int
    let capturedAt: Date
    let sessionStartOffset: TimeInterval
    let frameCount: Int64
    let sampleRate: Double
    let byteCount: Int64
    let sha256: String
    var location: CaptureLocation? = nil
    var duration: TimeInterval { Double(frameCount) / sampleRate }
}

struct PhoneRecordingDraft: Identifiable, Codable {
    let id: UUID
    /// Active chunk URL while recording; otherwise the last finalized chunk or legacy file.
    let fileURL: URL
    let duration: TimeInterval
    let capturedAt: Date
    var location: CaptureLocation? = nil
    var chunks: [PhoneRecordingChunkFile] = []
    var activeChunkOrdinal: Int? = nil
    var isChunked: Bool = false
    var timeZoneIdentifier: String = TimeZone.current.identifier

    init(id: UUID = UUID(), fileURL: URL, duration: TimeInterval, capturedAt: Date,
         location: CaptureLocation? = nil, chunks: [PhoneRecordingChunkFile] = [],
         activeChunkOrdinal: Int? = nil, isChunked: Bool = false,
         timeZoneIdentifier: String = TimeZone.current.identifier) {
        self.id = id; self.fileURL = fileURL; self.duration = duration; self.capturedAt = capturedAt
        self.location = location; self.chunks = chunks; self.activeChunkOrdinal = activeChunkOrdinal
        self.isChunked = isChunked; self.timeZoneIdentifier = timeZoneIdentifier
    }
}

/// Draft metadata is written before capture. New long recordings use durable chunk files;
/// the legacy single-M4A manifest remains readable for in-flight recordings from older builds.
final class PhoneRecordingDraftStore {
    private let root: URL
    private struct Manifest: Codable {
        let id: UUID
        let duration: TimeInterval
        let capturedAt: Date
        var location: CaptureLocation? = nil
        var chunks: [PhoneRecordingChunkFile]? = nil
        var activeChunkOrdinal: Int? = nil
        var isChunked: Bool? = nil
        var timeZoneIdentifier: String? = nil

        private enum CodingKeys: String, CodingKey { case id, duration, capturedAt, location, chunks, activeChunkOrdinal, isChunked, timeZoneIdentifier }
        init(id: UUID, duration: TimeInterval, capturedAt: Date, location: CaptureLocation?, chunks: [PhoneRecordingChunkFile]?, activeChunkOrdinal: Int?, isChunked: Bool?, timeZoneIdentifier: String?) {
            self.id = id; self.duration = duration; self.capturedAt = capturedAt; self.location = location
            self.chunks = chunks; self.activeChunkOrdinal = activeChunkOrdinal; self.isChunked = isChunked
            self.timeZoneIdentifier = timeZoneIdentifier
        }
        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            id = try values.decode(UUID.self, forKey: .id)
            duration = try values.decode(TimeInterval.self, forKey: .duration)
            capturedAt = try values.decode(Date.self, forKey: .capturedAt)
            location = try values.decodeIfPresent(CaptureLocation.self, forKey: .location)
            chunks = try values.decodeIfPresent([PhoneRecordingChunkFile].self, forKey: .chunks)
            activeChunkOrdinal = try values.decodeIfPresent(Int.self, forKey: .activeChunkOrdinal)
            isChunked = try values.decodeIfPresent(Bool.self, forKey: .isChunked)
            timeZoneIdentifier = try values.decodeIfPresent(String.self, forKey: .timeZoneIdentifier)
        }
    }
    private(set) var recoveryWarning: String?

    init(root: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("WiseLife/RecordingDrafts", isDirectory: true)) { self.root = root }

    func prepare(id: UUID, at date: Date) throws -> PhoneRecordingDraft {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let folder = sessionDirectory(id)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let draft = PhoneRecordingDraft(id: id, fileURL: chunkURL(id, ordinal: 0), duration: 0,
            capturedAt: date, activeChunkOrdinal: 0, isChunked: true, timeZoneIdentifier: TimeZone.current.identifier)
        try persist(draft); return draft
    }

    func persist(_ draft: PhoneRecordingDraft) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try rejectSymlink(root); try rejectSymlink(manifest(draft.id))
        if draft.isChunked {
            try FileManager.default.createDirectory(at: sessionDirectory(draft.id), withIntermediateDirectories: true)
            try rejectSymlink(sessionDirectory(draft.id))
            for chunk in draft.chunks { try rejectSymlink(chunkURL(draft.id, ordinal: chunk.ordinal)) }
        }
        let metadata = Manifest(id: draft.id, duration: draft.duration, capturedAt: draft.capturedAt,
            location: draft.location, chunks: draft.isChunked ? draft.chunks : nil,
            activeChunkOrdinal: draft.isChunked ? draft.activeChunkOrdinal : nil,
            isChunked: draft.isChunked ? true : nil,
            timeZoneIdentifier: draft.isChunked ? draft.timeZoneIdentifier : nil)
        try JSONEncoder().encode(metadata).write(to: manifest(draft.id), options: .atomic)
    }

    /// Commit a sealed file to the durable manifest before optionally creating the next slot.
    func seal(_ chunk: PhoneRecordingChunkFile, in draft: PhoneRecordingDraft, startNextChunk: Bool) throws -> PhoneRecordingDraft {
        guard draft.isChunked, chunk.ordinal >= 0, chunk.frameCount > 0, chunk.sampleRate.isFinite, chunk.sampleRate > 0,
              chunk.duration.isFinite, chunk.duration > 0, chunk.duration <= 600,
              chunk.sessionStartOffset.isFinite, chunk.sessionStartOffset >= 0, chunk.byteCount > 0,
              chunk.sha256.utf8.count == 64, chunk.sha256.utf8.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }) else { throw CocoaError(.fileReadCorruptFile) }
        let existing = draft.chunks.first { $0.ordinal == chunk.ordinal }
        if let existing, existing != chunk { throw CocoaError(.fileWriteFileExists) }
        var chunks = draft.chunks
        if existing == nil { chunks.append(chunk) }
        chunks.sort { $0.ordinal < $1.ordinal }
        guard chunks.enumerated().allSatisfy({ $0.offset == $0.element.ordinal }) else { throw CocoaError(.fileReadCorruptFile) }
        let next = startNextChunk ? (chunks.last!.ordinal + 1) : nil
        let finalURL = next.map { chunkURL(draft.id, ordinal: $0) } ?? chunkURL(draft.id, ordinal: chunks.last!.ordinal)
        let updated = PhoneRecordingDraft(id: draft.id, fileURL: finalURL,
            duration: chunks.reduce(0) { $0 + $1.duration }, capturedAt: draft.capturedAt,
            location: draft.location, chunks: chunks, activeChunkOrdinal: next,
            isChunked: true, timeZoneIdentifier: draft.timeZoneIdentifier)
        try persist(updated)
        return updated
    }

    func close(_ draft: PhoneRecordingDraft) throws -> PhoneRecordingDraft {
        guard draft.isChunked else { return draft }
        let lastOrdinal = draft.chunks.last?.ordinal
        let url = lastOrdinal.map { chunkURL(draft.id, ordinal: $0) } ?? draft.fileURL
        let closed = PhoneRecordingDraft(id:draft.id,fileURL:url,duration:draft.duration,capturedAt:draft.capturedAt,
            location:draft.location,chunks:draft.chunks,activeChunkOrdinal:nil,isChunked:true,timeZoneIdentifier:draft.timeZoneIdentifier)
        try persist(closed)
        return closed
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
            let data = try Data(contentsOf: url)
            do {
                let metadata = try JSONDecoder().decode(Manifest.self, from: data)
                guard url.lastPathComponent == manifest(metadata.id).lastPathComponent,
                      metadata.duration.isFinite, metadata.duration >= 0 else { throw CocoaError(.fileReadCorruptFile) }
                if metadata.isChunked == true {
                    let chunks = metadata.chunks ?? []
                    guard TimeZone(identifier: metadata.timeZoneIdentifier ?? "") != nil,
                          chunks.enumerated().allSatisfy({ $0.offset == $0.element.ordinal }) else { throw CocoaError(.fileReadCorruptFile) }
                    for chunk in chunks { try rejectSymlink(chunkURL(metadata.id, ordinal: chunk.ordinal)) }
                    let active = metadata.activeChunkOrdinal
                    guard active == nil || active == chunks.count else { throw CocoaError(.fileReadCorruptFile) }
                    let pathOrdinal = active ?? chunks.last?.ordinal ?? 0
                    let file = chunkURL(metadata.id, ordinal: pathOrdinal)
                    try rejectSymlink(file)
                    drafts.append(PhoneRecordingDraft(id: metadata.id, fileURL: file, duration: metadata.duration,
                        capturedAt: metadata.capturedAt, location: metadata.location, chunks: chunks,
                        activeChunkOrdinal: active, isChunked: true,
                        timeZoneIdentifier: metadata.timeZoneIdentifier ?? TimeZone.current.identifier))
                } else {
                    let audio = audioURL(metadata.id)
                    try rejectSymlink(audio)
                    drafts.append(PhoneRecordingDraft(id: metadata.id, fileURL: audio, duration: metadata.duration,
                        capturedAt: metadata.capturedAt, location: metadata.location))
                }
            } catch {
                let quarantine = url.appendingPathExtension("invalid-" + UUID().uuidString)
                try FileManager.default.moveItem(at: url, to: quarantine)
                recoveryWarning = "部分录音资料损坏，原始文件已保留，请联系支持恢复。"
            }
        }
        return drafts.sorted { $0.capturedAt < $1.capturedAt }
    }

    func remove(_ draft: PhoneRecordingDraft) throws {
        try rejectSymlink(root); try rejectSymlink(manifest(draft.id))
        let folder = sessionDirectory(draft.id)
        try rejectSymlink(folder)
        if FileManager.default.fileExists(atPath: folder.path) {
            for item in try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) { try rejectSymlink(item) }
            try FileManager.default.removeItem(at: folder)
        }
        let legacy = audioURL(draft.id)
        try rejectSymlink(legacy)
        if FileManager.default.fileExists(atPath: legacy.path) { try FileManager.default.removeItem(at: legacy) }
        if FileManager.default.fileExists(atPath: manifest(draft.id).path) { try FileManager.default.removeItem(at: manifest(draft.id)) }
    }

    private func sessionDirectory(_ id: UUID) -> URL { root.appendingPathComponent(id.uuidString, isDirectory: true) }
    private func chunkURL(_ id: UUID, ordinal: Int) -> URL { sessionDirectory(id).appendingPathComponent(String(format: "chunk-%04d.m4a", ordinal)) }
    private func audioURL(_ id: UUID) -> URL { root.appendingPathComponent("\(id.uuidString).m4a") }
    private func rejectSymlink(_ url: URL) throws {
        if (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true { throw CocoaError(.fileReadInvalidFileName) }
    }
    private func manifest(_ id: UUID) -> URL { root.appendingPathComponent("\(id.uuidString).json") }
}
