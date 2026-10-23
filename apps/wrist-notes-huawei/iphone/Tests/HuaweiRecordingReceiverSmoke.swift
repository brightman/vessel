import Foundation
import CryptoKit
import AVFAudio

@main
struct HuaweiRecordingReceiverSmoke {
    static func requireFailure(_ operation: () throws -> Void) {
        do { try operation(); fatalError("expected rejection") } catch { }
    }
    static func makeAudio(_ url: URL) throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8000)!
        buffer.frameLength = 8000
        for index in 0..<8000 { buffer.floatChannelData![0][index] = sin(Float(index) * 0.05) * 0.1 }
        let output = try AVAudioFile(forWriting: url, settings: [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 16000, AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 32000])
        try output.write(from: buffer)
    }
    static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("huawei-receiver-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.m4a")
        try makeAudio(source)
        let audio = try Data(contentsOf: source)
        let checksum = SHA256.hash(data: audio).map { String(format: "%02x", $0) }.joined()
        let id = UUID()
        let metadata = HuaweiRecordingMetadata(version: 1, id: id, kind: .thought, capturedAtMilliseconds: 1_700_000_000_000, durationSeconds: 0.5, byteLength: audio.count, sha256: checksum)
        let repository = try NoteRepository(root: root.appendingPathComponent("store"))
        let receiver = try HuaweiRecordingReceiver(repository: repository, staging: root.appendingPathComponent("staging"))
        let ack = try receiver.receive(metadata: metadata, source: source)
        precondition(ack.id == id.uuidString.lowercased() && ack.type == "stored" && ack.sha256 == checksum)
        let reopened = try NoteRepository(root: root.appendingPathComponent("store"))
        precondition(reopened.notes.count == 1, "ack requires durable index")
        let storedAudio = try Data(contentsOf: reopened.audioURL(for: reopened.notes[0]))
        precondition(storedAudio == audio)
        precondition(FileManager.default.fileExists(atPath: source.path), "SDK source remains owned by SDK")
        _ = try receiver.receive(metadata: metadata, source: source)
        precondition(repository.notes.count == 1, "duplicate delivery is idempotent")
        var bad = metadata; bad.sha256 = String(repeating: "0", count: 64)
        requireFailure { _ = try receiver.receive(metadata: bad, source: source) }
        bad = metadata; bad.byteLength += 1
        requireFailure { _ = try receiver.receive(metadata: bad, source: source) }
        bad = metadata; bad.version = 2
        requireFailure { _ = try receiver.receive(metadata: bad, source: source) }
        bad = metadata; bad.durationSeconds = -1
        requireFailure { _ = try receiver.receive(metadata: bad, source: source) }
        bad = metadata; bad.capturedAtMilliseconds += 1000
        requireFailure { _ = try receiver.receive(metadata: bad, source: source) }
        let corrupt = root.appendingPathComponent("corrupt.m4a")
        let junk = Data("not audio".utf8); try junk.write(to: corrupt)
        bad = metadata; bad.id = UUID(); bad.byteLength = junk.count; bad.sha256 = SHA256.hash(data: junk).map { String(format: "%02x", $0) }.joined()
        requireFailure { _ = try receiver.receive(metadata: bad, source: corrupt) }
        precondition(repository.notes.count == 1)
        let failedRoot = root.appendingPathComponent("failed-store")
        let failingRepository = try NoteRepository(root: failedRoot)
        try FileManager.default.createDirectory(at: failedRoot.appendingPathComponent("notes.json"), withIntermediateDirectories: true)
        let failingReceiver = try HuaweiRecordingReceiver(repository: failingRepository, staging: root.appendingPathComponent("failed-staging"))
        requireFailure { _ = try failingReceiver.receive(metadata: metadata, source: source) }
        precondition(failingRepository.notes.isEmpty, "failed persistence must not acknowledge")
        try FileManager.default.removeItem(at: failedRoot.appendingPathComponent("notes.json"))
        let recoveredRepository = try NoteRepository(root: failedRoot)
        let recoveredReceiver = try HuaweiRecordingReceiver(repository: recoveredRepository, staging: root.appendingPathComponent("retry-staging"))
        _ = try recoveredReceiver.receive(metadata: metadata, source: source)
        precondition(recoveredRepository.notes.first?.kind == .thought, "retry after restart preserves original metadata")
        print("HuaweiRecordingReceiverSmoke passed: durable import, duplicate, integrity, metadata, audio and write-failure checks")
    }
}
