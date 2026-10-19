import BRRecorderCore
import Foundation

enum RingTransferStage: String, Codable { case queued, downloading, converting, saved, failed }

struct RingTransferJob: Codable, Identifiable, Equatable {
    let id: UUID
    let deviceID: String
    let generation: UUID
    var file: BRRecorderFile
    var capturedAt: Date
    var recordingKind: RecordingKind { file.kind == .flashIdea ? .thought : .long }
    var stage: RingTransferStage = .queued
    var error: String?
}

struct RingPersistentState: Codable {
    var binding: BRRecorderBinding?
    var generations: [String: UUID] = [:]
    var jobs: [RingTransferJob] = []
    var lastSync: [String: Date] = [:]
    // If a format reply is lost, require explicit reconciliation instead of replaying it.
    var uncertainFormatDeviceID: String?
}

/// A local recovery journal, independent of the recording library. Saved jobs are kept
/// as deduplication receipts even when the user subsequently deletes the phone note.
final class RingTransferStore {
    let root: URL
    private let index: URL
    private(set) var state: RingPersistentState

    init(root: URL) throws {
        self.root = root
        index = root.appendingPathComponent("transfers.json")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: index.path) {
            state = try JSONDecoder().decode(RingPersistentState.self, from: Data(contentsOf: index))
        } else { state = RingPersistentState() }
        // A process can die in any stage. Only validated artifacts will be reused.
        for index in state.jobs.indices where state.jobs[index].stage != .saved {
            state.jobs[index].stage = .queued
        }
        try protect(root)
    }

    func update(_ change: (inout RingPersistentState) -> Void) throws {
        var revised = state
        change(&revised)
        try JSONEncoder().encode(revised).write(to: index, options: .atomic)
        try protect(index)
        state = revised
    }

    @discardableResult func enqueue(_ files: [BRRecorderFile], deviceID: String, now: Date = .now) throws -> [RingTransferJob] {
        guard files.allSatisfy(\.hasSafeName) else { throw BRRecorderFailure.invalidAudio("设备录音文件名无效。") }
        try update { state in
            let generation = state.generations[deviceID] ?? UUID()
            state.generations[deviceID] = generation
            for file in files {
                // File size/duration can be filled in later; name and recording timestamp identify a recording.
                if let index = state.jobs.firstIndex(where: {
                    $0.deviceID == deviceID && $0.generation == generation && $0.file.name == file.name
                        && ($0.file.recordedAt == file.recordedAt || $0.file.recordedAt == nil || file.recordedAt == nil)
                }) {
                    if state.jobs[index].stage != .saved {
                        let previous = state.jobs[index].file
                        state.jobs[index].file = BRRecorderFile(name: file.name, byteCount: file.byteCount ?? previous.byteCount,
                            recordedAt: file.recordedAt ?? previous.recordedAt, expectedDuration: file.expectedDuration ?? previous.expectedDuration,
                            kind: file.kind == .flashIdea || previous.kind == .flashIdea ? .flashIdea : .recording)
                        state.jobs[index].capturedAt = state.jobs[index].file.recordedAt ?? state.jobs[index].capturedAt
                    }
                    continue
                }
                state.jobs.append(RingTransferJob(id: UUID(), deviceID: deviceID, generation: generation,
                    file: file, capturedAt: file.recordedAt ?? now))
            }
        }
        return pending(deviceID: deviceID)
    }

    func pending(deviceID: String) -> [RingTransferJob] {
        state.jobs.filter { $0.deviceID == deviceID && $0.generation == state.generations[deviceID] && $0.stage != .saved }
            .sorted { $0.capturedAt < $1.capturedAt }
    }

    func setStage(_ id: UUID, _ stage: RingTransferStage, error: String? = nil) throws {
        try update { state in
            guard let index = state.jobs.firstIndex(where: { $0.id == id }) else { return }
            state.jobs[index].stage = stage; state.jobs[index].error = error
        }
    }

    func directory(_ id: UUID) throws -> URL {
        let path = root.appendingPathComponent(id.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        try protect(path)
        return path
    }

    func removeArtifacts(_ id: UUID) { try? FileManager.default.removeItem(at: root.appendingPathComponent(id.uuidString)) }

    /// Only finalized, CRC-verified SDK audio reaches this entry point. Reuse the same
    /// journal and conversion path as historical BLE files, including saved receipts.
    func stageFlashAudio(_ file: BRRecorderFile, from source: URL, deviceID: String) throws {
        guard file.kind == .flashIdea else { throw BRRecorderFailure.invalidAudio("闪念文件类型无效。") }
        let jobs = try enqueue([file], deviceID: deviceID)
        guard let job = jobs.first(where: { $0.file.name == file.name &&
            ($0.file.recordedAt == file.recordedAt || $0.file.recordedAt == nil || file.recordedAt == nil) }) else { return }
        let directory = try directory(job.id)
        let raw = directory.appendingPathComponent("recording.opus")
        guard !FileManager.default.fileExists(atPath: raw.path),
              !FileManager.default.fileExists(atPath: directory.appendingPathComponent("recording.m4a").path) else { return }
        let temporary = directory.appendingPathComponent("flash.download")
        try? FileManager.default.removeItem(at: temporary)
        try FileManager.default.copyItem(at: source, to: temporary)
        try protect(temporary)
        try FileManager.default.moveItem(at: temporary, to: raw)
    }

    private func protect(_ url: URL) throws {
#if os(iOS)
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: url.path)
#endif
        var value = url
        var attributes = URLResourceValues(); attributes.isExcludedFromBackup = true
        try value.setResourceValues(attributes)
    }
}
