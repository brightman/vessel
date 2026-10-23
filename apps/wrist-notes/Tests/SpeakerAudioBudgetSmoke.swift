import AVFAudio
import Foundation

@main struct SpeakerAudioBudgetSmoke {
    static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        // Sparse PCM file: represents multi-hour input without storing or decoding its samples.
        func fixture(seconds: UInt32, name: String) throws -> URL {
            let bytes = seconds * 16_000 * 2
            var header = Data("RIFF".utf8)
            func u32(_ n: UInt32) { var n = n.littleEndian; withUnsafeBytes(of: &n) { header.append(contentsOf: $0) } }
            func u16(_ n: UInt16) { var n = n.littleEndian; withUnsafeBytes(of: &n) { header.append(contentsOf: $0) } }
            u32(36 + bytes); header.append(Data("WAVEfmt ".utf8)); u32(16)
            u16(1); u16(1); u32(16_000); u32(32_000); u16(2); u16(16)
            header.append(Data("data".utf8)); u32(bytes)
            let url = root.appendingPathComponent(name + ".wav")
            try header.write(to: url)
            let handle = try FileHandle(forWritingTo: url)
            try handle.truncate(atOffset: UInt64(44 + bytes)); try handle.close()
            return url
        }
        let long = try fixture(seconds: 19_075, name: "long")
        var loaded = false
        do {
            _ = try SpeakerAudioInput.load(from: long) { _ in loaded = true; return [] }
            fatalError("multi-hour audio must be rejected before full-file sample allocation")
        } catch SpeakerDiarizationError.recordingTooLong {}
        precondition(!loaded, "must read the file header before invoking the memory-heavy loader")
        let short = try fixture(seconds: 3, name: "short")
        let samples = try SpeakerAudioInput.load(from: short) { path in
            let audio = try AVAudioFile(forReading: URL(fileURLWithPath: path))
            let buffer = AVAudioPCMBuffer(pcmFormat: audio.processingFormat, frameCapacity: 48_000)!
            try audio.read(into: buffer)
            return Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
        }
        precondition(samples.count == 48_000, "short recordings still reach the decoder")
        print("Speaker audio budget: real multi-hour header rejected before allocation; short audio still decodes")
    }
}
