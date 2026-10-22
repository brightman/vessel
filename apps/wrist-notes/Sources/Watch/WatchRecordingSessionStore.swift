import AVFAudio
import Foundation

struct RecordingCaptureContext: Codable {
    let sessionID: UUID
    let startedAt: Date
    let timeZoneIdentifier: String
    let origin: RecordingOrigin
    var location: CaptureLocation?
}

/// Written before opening AAC, then checkpointed off the tap at most once/second.
struct RecordingCaptureIntent: Codable {
    let id: UUID
    var context: RecordingCaptureContext
    let ordinal: Int
    let sessionStartOffset: Double
    var effectiveFrames: Int64
    var partialFilename: String { "\(context.sessionID.uuidString)_\(String(format: "%04d", ordinal)).partial.m4a" }
    func descriptor(info: RecordingAudioFileInfo, frames: Int64? = nil) -> RecordingChunkDescriptor {
        .init(id: id, sessionID: context.sessionID, ordinal: ordinal, sessionStartedAt: context.startedAt,
              capturedAt: context.startedAt.addingTimeInterval(sessionStartOffset), timeZoneIdentifier: context.timeZoneIdentifier,
              sessionStartOffset: sessionStartOffset, frameCount: frames ?? effectiveFrames, sampleRate: 16000,
              byteCount: info.byteCount, sha256: info.sha256, origin: context.origin, location: context.location)
    }
}

struct WatchRecordingSessionManifest: Codable {
    let sessionID: UUID
    let state: RecordingSessionState
    let finalOrdinal: Int?
    let chunks: [RecordingChunkDescriptor]
    let acknowledgements: [RecordingChunkReceipt]
}

/// Serialized durable local store. Sidecars and publication intents are authority;
/// aggregate manifests can be rebuilt without touching the legacy pending.json.
final class WatchRecordingSessionStore {
    let root: URL
    private let queue = DispatchQueue(label: "WiseLife.watchSessionStore")
    private var stored: [UUID: RecordingChunkDescriptor] = [:]
    private var receipts: Set<UUID> = []
    private var ends: [UUID: RecordingSessionEnd] = [:]
    private var problems: [String] = []
    var chunks: [RecordingChunkDescriptor] { queue.sync { stored.values.sorted { ($0.sessionStartedAt, $0.ordinal) < ($1.sessionStartedAt, $1.ordinal) } } }
    var pendingChunks: [RecordingChunkDescriptor] { queue.sync { stored.values.filter { !receipts.contains($0.id) }.sorted { $0.ordinal < $1.ordinal } } }
    var sessionEnds: [RecordingSessionEnd] { queue.sync { Array(ends.values) } }
    var recoveryIssues: [String] { queue.sync { problems } }
    init(root: URL) { self.root = root }

    func audioURL(for chunk: RecordingChunkDescriptor) -> URL {
        root.appendingPathComponent(chunk.sessionID.uuidString, isDirectory: true).appendingPathComponent(chunk.audioFilename)
    }
    func seal(_ chunk: RecordingChunkDescriptor, file: URL) throws { try queue.sync { try sealLocked(chunk, file: file) } }

    private func sealLocked(_ chunk: RecordingChunkDescriptor, file: URL) throws {
        _ = try RecordingAudioFile.validate(chunk, at: file)
        guard stored[chunk.id].map({ $0 == chunk }) ?? true,
              !stored.values.contains(where: { $0.sessionID == chunk.sessionID && $0.ordinal == chunk.ordinal && $0.id != chunk.id }) else { throw RecordingAudioFile.ValidationError.descriptorMismatch }
        try RecordingAudioFile.requireSafePath(root)
        let destination = audioURL(for: chunk)
        let folder = destination.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try RecordingAudioFile.requireSafePath(destination)
        let sidecar = destination.appendingPathExtension("json")
        let intent = destination.appendingPathExtension("seal.json")
        for metadata in [sidecar, intent] where FileManager.default.fileExists(atPath: metadata.path) {
            guard try read(RecordingChunkDescriptor.self, at: metadata) == chunk else { throw RecordingAudioFile.ValidationError.descriptorMismatch }
        }
        // Replayable before publication: protects final-file -> sidecar crash window.
        try write(chunk, to: intent)
        if FileManager.default.fileExists(atPath: destination.path) { _ = try RecordingAudioFile.validate(chunk, at: destination) }
        else {
            let staging = folder.appendingPathComponent("\(chunk.id.uuidString).publishing.m4a")
            if FileManager.default.fileExists(atPath: staging.path), (try? RecordingAudioFile.validate(chunk, at: staging)) == nil {
                // The source was validated above. Only this uncommitted derived
                // copy may be discarded; never remove a final or original partial.
                try removeDerived(staging)
            }
            if !FileManager.default.fileExists(atPath: staging.path) { try FileManager.default.copyItem(at: file, to: staging) }
            _ = try RecordingAudioFile.validate(chunk, at: staging)
            try FileManager.default.moveItem(at: staging, to: destination)
        }
        try write(chunk, to: sidecar)
        stored[chunk.id] = chunk
        try writeManifest(sessionID: chunk.sessionID)
    }

    func finish(_ end: RecordingSessionEnd, reason: String? = nil) throws {
        try queue.sync {
            try finishLocked(end)
            if let reason { try write(reason, to: root.appendingPathComponent(end.sessionID.uuidString).appendingPathComponent("interruption.json")) }
        }
    }
    private func finishLocked(_ end: RecordingSessionEnd) throws {
        try end.validate()
        let folder = root.appendingPathComponent(end.sessionID.uuidString)
        try RecordingAudioFile.requireSafePath(folder)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try write(end, to: folder.appendingPathComponent("end.json")); ends[end.sessionID] = end
        try writeManifest(sessionID: end.sessionID)
    }
    func acknowledge(_ receipt: RecordingChunkReceipt) throws {
        try queue.sync {
            try receipt.validate()
            guard let chunk = stored[receipt.chunkID], receiptMatches(receipt, chunk) else { throw RecordingAudioFile.ValidationError.descriptorMismatch }
            try write(receipt, to: audioURL(for: chunk).appendingPathExtension("receipt.json"))
            receipts.insert(receipt.chunkID)
            try writeManifest(sessionID: chunk.sessionID)
        }
    }

    func recover() throws {
        try queue.sync {
            try RecordingAudioFile.requireSafePath(root)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            stored = [:]; receipts = []; ends = [:]; problems = []
            for folder in try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) {
                guard let sessionID = UUID(uuidString: folder.lastPathComponent) else { continue }
                do { try recoverSession(folder, sessionID: sessionID) }
                catch { problems.append("\(sessionID): \(error)") }
            }
        }
    }

    private func recoverSession(_ folder: URL, sessionID: UUID) throws {
        try RecordingAudioFile.requireSafePath(folder)
        let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
        // Sidecars first, then intents; either independently restores final audio.
        for metadata in files.filter({ $0.lastPathComponent.hasSuffix(".m4a.json") }) + files.filter({ $0.lastPathComponent.hasSuffix(".m4a.seal.json") }) {
            do {
                let chunk = try read(RecordingChunkDescriptor.self, at: metadata)
                guard chunk.sessionID == sessionID,
                      metadata.lastPathComponent == chunk.audioFilename + ".json" || metadata.lastPathComponent == chunk.audioFilename + ".seal.json" else { throw RecordingAudioFile.ValidationError.descriptorMismatch }
                let final = audioURL(for: chunk)
                let staging = folder.appendingPathComponent("\(chunk.id.uuidString).publishing.m4a")
                try sealLocked(chunk, file: FileManager.default.fileExists(atPath: final.path) ? final : staging)
            } catch { problems.append("\(metadata.lastPathComponent): \(error)") }
        }
        for metadata in files where metadata.lastPathComponent.hasSuffix(".capture.json") {
            do {
                let intent = try read(RecordingCaptureIntent.self, at: metadata)
                guard intent.context.sessionID == sessionID,
                      (0...RecordingChunkProtocol.maximumOrdinal).contains(intent.ordinal),
                      intent.effectiveFrames > 0, intent.effectiveFrames <= 4_800_000,
                      metadata.lastPathComponent == intent.partialFilename + ".capture.json" else { throw RecordingAudioFile.ValidationError.descriptorMismatch }
                if stored[intent.id] != nil { continue }
                try recoverPartial(intent, folder: folder)
            } catch { problems.append("保留未封口录音 \(metadata.lastPathComponent): \(error)") }
        }
        for chunk in stored.values.filter({ $0.sessionID == sessionID }) {
            let url = audioURL(for: chunk).appendingPathExtension("receipt.json")
            if FileManager.default.fileExists(atPath: url.path) {
                do {
                    let receipt = try read(RecordingChunkReceipt.self, at: url)
                    guard receiptMatches(receipt, chunk) else { throw RecordingAudioFile.ValidationError.descriptorMismatch }
                    receipts.insert(chunk.id)
                } catch { problems.append("\(url.lastPathComponent): \(error)") }
            }
        }
        for partial in files where partial.lastPathComponent.hasSuffix(".partial.m4a") {
            problems.append("保留中断录音原件：\(partial.lastPathComponent)")
        }
        let endURL = folder.appendingPathComponent("end.json")
        if FileManager.default.fileExists(atPath: endURL.path) {
            let end = try read(RecordingSessionEnd.self, at: endURL)
            guard end.sessionID == sessionID else { throw RecordingAudioFile.ValidationError.descriptorMismatch }
            try end.validate()
            let recovered = stored.values.filter { $0.sessionID == sessionID }
            if let maximum = recovered.map(\.ordinal).max(), maximum > (end.finalOrdinal ?? -1) {
                guard end.revision < Int.max else { throw RecordingAudioFile.ValidationError.descriptorMismatch }
                let latest = recovered.map { $0.capturedAt.addingTimeInterval($0.duration) }.max()!
                // The previous end may already be COMMITted on the phone. Extend
                // coverage with a new immutable revision, preserving interruption.
                try finishLocked(.init(sessionID: sessionID, finalOrdinal: maximum,
                    endedAt: max(end.endedAt, latest), interrupted: true, revision: end.revision + 1))
            } else { ends[sessionID] = end }
        } else {
            let chunks = stored.values.filter { $0.sessionID == sessionID }
            let latest = chunks.map { $0.capturedAt.addingTimeInterval($0.duration) }.max() ?? .now
            try finishLocked(.init(sessionID: sessionID, finalOrdinal: chunks.map(\.ordinal).max(), endedAt: latest, interrupted: true, revision: 0))
            try write("进程退出后恢复；未封口音频可能不完整", to: folder.appendingPathComponent("interruption.json"))
            problems.append("已标记中断会话：\(sessionID)")
        }
        try writeManifest(sessionID: sessionID)
    }

    private func recoverPartial(_ intent: RecordingCaptureIntent, folder: URL) throws {
        let partial = folder.appendingPathComponent(intent.partialFilename)
        let info = try RecordingAudioFile.inspect(partial)
        guard info.formatID == kAudioFormatMPEG4AAC, info.sampleRate == 16000, info.channelCount == 1 else { throw RecordingAudioFile.ValidationError.invalidAudio }
        // A checkpoint is a lower bound on written effective PCM. Never invent
        // uncheckpointed time or count the decoder's padding as sampled audio.
        let frames = min(intent.effectiveFrames, info.frameCount)
        var source = partial
        if frames != info.frameCount {
            source = folder.appendingPathComponent("\(intent.id.uuidString).recovered.m4a")
            try RecordingAudioFile.requireSafePath(source)
            if (try? validateRecoveredPrefix(source, intent: intent, frames: frames)) == nil {
                if FileManager.default.fileExists(atPath: source.path) { try removeDerived(source) }
                let temporary = folder.appendingPathComponent("\(intent.id.uuidString).recovering.m4a")
                try RecordingAudioFile.requireSafePath(temporary)
                if FileManager.default.fileExists(atPath: temporary.path) { try removeDerived(temporary) }
                let reader = try AVAudioFile(forReading: partial)
                var writer: AVAudioFile? = try AVAudioFile(forWriting: temporary, settings: [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 16000, AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 32000])
                let buffer = AVAudioPCMBuffer(pcmFormat: reader.processingFormat, frameCapacity: 4096)!
                var remaining = frames
                while remaining > 0 {
                    try reader.read(into: buffer, frameCount: AVAudioFrameCount(min(remaining, 4096)))
                    guard buffer.frameLength > 0 else { throw RecordingAudioFile.ValidationError.invalidAudio }
                    try writer!.write(from: buffer); remaining -= Int64(buffer.frameLength)
                }
                writer = nil
                try validateRecoveredPrefix(temporary, intent: intent, frames: frames)
                try FileManager.default.moveItem(at: temporary, to: source)
            }
        }
        let recovered = try RecordingAudioFile.inspect(source)
        let chunk = intent.descriptor(info: recovered, frames: frames)
        let final = audioURL(for: chunk)
        let sealIntent = final.appendingPathExtension("seal.json")
        if FileManager.default.fileExists(atPath: sealIntent.path),
           !FileManager.default.fileExists(atPath: final.path),
           !FileManager.default.fileExists(atPath: final.appendingPathExtension("json").path),
           !FileManager.default.fileExists(atPath: final.appendingPathExtension("receipt.json").path) {
            let old = try read(RecordingChunkDescriptor.self, at: sealIntent)
            // A second AAC encoding may change bytes/hash. Only a never-published
            // intent may be refreshed, with all capture identity/metadata fixed.
            let sameCapture = RecordingChunkDescriptor(id: old.id, sessionID: old.sessionID, ordinal: old.ordinal,
                sessionStartedAt: old.sessionStartedAt, capturedAt: old.capturedAt, timeZoneIdentifier: old.timeZoneIdentifier,
                sessionStartOffset: old.sessionStartOffset, frameCount: old.frameCount, sampleRate: old.sampleRate,
                byteCount: chunk.byteCount, sha256: chunk.sha256, origin: old.origin, location: old.location)
            guard sameCapture == chunk else { throw RecordingAudioFile.ValidationError.descriptorMismatch }
            _ = try RecordingAudioFile.validate(chunk, at: source)
            try write(chunk, to: sealIntent)
        }
        try sealLocked(chunk, file: source)
        problems.append("已恢复可验证的录音前缀，原件保留：\(intent.partialFilename)")
    }

    private func validateRecoveredPrefix(_ url: URL, intent: RecordingCaptureIntent, frames: Int64) throws {
        let info = try RecordingAudioFile.inspect(url)
        _ = try RecordingAudioFile.validate(intent.descriptor(info: info, frames: frames), at: url)
        let reader = try AVAudioFile(forReading: url)
        let buffer = AVAudioPCMBuffer(pcmFormat: reader.processingFormat, frameCapacity: 4096)!
        var remaining = frames
        while remaining > 0 {
            try reader.read(into: buffer, frameCount: AVAudioFrameCount(min(4096, remaining)))
            guard buffer.frameLength > 0 else { throw RecordingAudioFile.ValidationError.invalidAudio }
            remaining -= Int64(buffer.frameLength)
        }
    }

    private func removeDerived(_ url: URL) throws {
        try RecordingAudioFile.requireSafePath(url)
        guard [".publishing.m4a", ".recovering.m4a", ".recovered.m4a"].contains(where: { url.lastPathComponent.hasSuffix($0) }),
              try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
            throw RecordingAudioFile.ValidationError.unsafePath
        }
        try FileManager.default.removeItem(at: url)
    }

    private func writeManifest(sessionID: UUID) throws {
        let folder = root.appendingPathComponent(sessionID.uuidString)
        let manifest = folder.appendingPathComponent("manifest.json")
        var target = manifest
        if FileManager.default.fileExists(atPath: manifest.path), (try? read(WatchRecordingSessionManifest.self, at: manifest)) == nil {
            // Keep exact damaged bytes; rebuild separately so diagnosis is reversible.
            target = folder.appendingPathComponent("recovered-manifest.json")
            if !problems.contains("保留损坏清单：\(sessionID)") { problems.append("保留损坏清单：\(sessionID)") }
        }
        let chunks = stored.values.filter { $0.sessionID == sessionID }.sorted { $0.ordinal < $1.ordinal }
        let acknowledgements = chunks.filter { receipts.contains($0.id) }.map {
            RecordingChunkReceipt(sessionID: $0.sessionID, chunkID: $0.id, ordinal: $0.ordinal, sha256: $0.sha256)
        }
        let end = ends[sessionID]
        try write(WatchRecordingSessionManifest(sessionID: sessionID,
            state: end.map { $0.interrupted ? .interrupted : .stopped } ?? .recording,
            finalOrdinal: end?.finalOrdinal, chunks: chunks, acknowledgements: acknowledgements), to: target)
    }
    private func receiptMatches(_ receipt: RecordingChunkReceipt, _ chunk: RecordingChunkDescriptor) -> Bool {
        receipt.chunkID == chunk.id && receipt.sessionID == chunk.sessionID && receipt.ordinal == chunk.ordinal && receipt.sha256.caseInsensitiveCompare(chunk.sha256) == .orderedSame
    }
    private func read<T: Decodable>(_ type: T.Type, at url: URL) throws -> T {
        try RecordingAudioFile.requireSafePath(url)
        return try JSONDecoder().decode(type, from: Data(contentsOf: url))
    }
    private func write<T: Encodable>(_ value: T, to url: URL) throws {
        try RecordingAudioFile.requireSafePath(url)
        try JSONEncoder().encode(value).write(to: url, options: .atomic)
    }
}

struct WatchRecordingSessionSummary: Identifiable {
    let id: UUID
    let startedAt: Date
    let duration: TimeInterval
    let chunkCount: Int
    let isInterrupted: Bool
    static func summarize(_ chunks: [RecordingChunkDescriptor], ends: [RecordingSessionEnd] = []) -> [Self] {
        Dictionary(grouping: chunks, by: \.sessionID).map { id, values in
            Self(id: id, startedAt: values.map(\.sessionStartedAt).min() ?? .distantPast,
                 duration: values.reduce(0) { $0 + $1.duration }, chunkCount: values.count,
                 isInterrupted: ends.first { $0.sessionID == id }?.interrupted ?? false)
        }.sorted { $0.startedAt > $1.startedAt }
    }
}
