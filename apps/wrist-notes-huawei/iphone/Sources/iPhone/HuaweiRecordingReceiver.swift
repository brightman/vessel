import Foundation
import CryptoKit
import AVFAudio

/// App-level protocol, independent of Wear Engine's SDK types.
struct HuaweiRecordingMetadata: Codable {
    var version: Int
    var id: UUID
    var kind: RecordingKind
    var capturedAtMilliseconds: Double
    var durationSeconds: Double
    var byteLength: Int
    var sha256: String

    func validate() throws {
        guard version == 1, capturedAtMilliseconds.isFinite,
              capturedAtMilliseconds > 0, capturedAtMilliseconds < 4_102_444_800_000,
              durationSeconds.isFinite, durationSeconds > 0, durationSeconds <= 86_400,
              byteLength > 0, byteLength <= 1_073_741_824,
              sha256.count == 64, sha256.allSatisfy({ "0123456789abcdef".contains($0) }) else {
            throw HuaweiReceiveFailure.invalidMetadata
        }
    }
}

struct HuaweiStoredAcknowledgement: Codable {
    let version = 1
    let type = "stored"
    let id: String
    let byteLength: Int
    let sha256: String

    enum CodingKeys: String, CodingKey { case version, type, id, byteLength, sha256 }
}

enum HuaweiReceiveFailure: LocalizedError {
    case invalidMetadata, invalidAudio, integrityMismatch, conflictingRecording, unavailable
    var errorDescription: String? {
        switch self {
        case .invalidMetadata: "录音信息无效或协议版本不受支持"
        case .invalidAudio: "录音文件无法读取或时长不匹配"
        case .integrityMismatch: "录音文件不完整，请重新传输"
        case .conflictingRecording: "相同录音编号对应了不同的文件或信息"
        case .unavailable: "本地笔记存储尚未就绪"
        }
    }
}

/// Call on the same serial executor as NoteRepository. The SDK adapter must first
/// authenticate the peer and assemble all parts into a file. This class does not
/// establish a device connection or send the returned acknowledgement itself.
final class HuaweiRecordingReceiver {
    private let repository: NoteRepository
    private let staging: URL

    init(repository: NoteRepository, staging: URL) throws {
        self.repository = repository
        self.staging = staging
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
    }

    func receive(metadata: HuaweiRecordingMetadata, source: URL) throws -> HuaweiStoredAcknowledgement {
        try metadata.validate()
        guard source.isFileURL else { throw HuaweiReceiveFailure.invalidAudio }
        let attributes = try source.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard attributes.isRegularFile == true, attributes.isSymbolicLink != true,
              attributes.fileSize == metadata.byteLength else { throw HuaweiReceiveFailure.integrityMismatch }

        // Copy while the SDK still owns its temporary URL. Verify our own immutable copy.
        let incoming = staging.appendingPathComponent("\(UUID().uuidString).m4a")
        try FileManager.default.copyItem(at: source, to: incoming)
        defer { try? FileManager.default.removeItem(at: incoming) }
        let copiedSize = try incoming.resourceValues(forKeys: [.fileSizeKey]).fileSize
        guard copiedSize == metadata.byteLength, try digest(incoming) == metadata.sha256 else {
            throw HuaweiReceiveFailure.integrityMismatch
        }
        let audio = try AVAudioFile(forReading: incoming)
        let duration = Double(audio.length) / audio.processingFormat.sampleRate
        guard duration.isFinite, duration > 0,
              abs(duration - metadata.durationSeconds) <= max(1, duration * 0.02) else {
            throw HuaweiReceiveFailure.invalidAudio
        }

        let date = Date(timeIntervalSince1970: metadata.capturedAtMilliseconds / 1000)
        if let existing = repository.notes.first(where: { $0.id == metadata.id }) {
            guard existing.kind == metadata.kind, abs(existing.capturedAt.timeIntervalSince(date)) < 0.001,
                  abs(existing.duration - metadata.durationSeconds) < 0.001 else {
                throw HuaweiReceiveFailure.conflictingRecording
            }
            let destination = repository.audioURL(for: existing)
            if FileManager.default.fileExists(atPath: destination.path), try digest(destination) != metadata.sha256 {
                throw HuaweiReceiveFailure.conflictingRecording
            }
        }

        _ = try repository.importRecording(id: metadata.id, from: incoming, kind: metadata.kind,
                                           capturedAt: date, duration: metadata.durationSeconds)
        return HuaweiStoredAcknowledgement(id: metadata.id.uuidString.lowercased(), byteLength: metadata.byteLength, sha256: metadata.sha256)
    }

    private func digest(_ file: URL) throws -> String {
        let input = try FileHandle(forReadingFrom: file)
        defer { try? input.close() }
        var hash = SHA256()
        while let data = try input.read(upToCount: 65_536), !data.isEmpty { hash.update(data: data) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
