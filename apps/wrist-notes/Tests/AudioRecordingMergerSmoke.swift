import AVFoundation
import Foundation

@main
struct AudioRecordingMergerSmoke {
    static func main() async {
        do { try await run() }
        catch { fputs("AudioRecordingMergerSmoke failed: \(error.localizedDescription)\n", stderr); exit(1) }
    }

    private static func run() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let first = root.appendingPathComponent("first.caf")
        let second = root.appendingPathComponent("second.caf")
        let merged = root.appendingPathComponent("merged.m4a")
        print("creating fixtures")
        try makeTone(at: first, frames: 22_050, frequency: 440)
        try makeTone(at: second, frames: 22_050, frequency: 880)

        do {
            _ = try await AudioRecordingMerger.merge([first], to: merged)
            preconditionFailure("a single source is not a merge")
        } catch AudioRecordingMerger.Failure.insufficientSources {}
        do {
            _ = try await AudioRecordingMerger.merge([root.appendingPathComponent("missing.m4a"), second], to: merged)
            preconditionFailure("a missing source must stop the merge")
        } catch AudioRecordingMerger.Failure.missingAudio {}

        let duration: TimeInterval
        do {
            duration = try await AudioRecordingMerger.merge([first, second], to: merged)
        } catch AudioRecordingMerger.Failure.exportFailed(let details) where details.contains("fmt?") {
            precondition(FileManager.default.fileExists(atPath: first.path) && FileManager.default.fileExists(atPath: second.path),
                         "an unavailable AAC encoder must not damage source audio")
            print("AudioRecordingMergerSmoke skipped export: this macOS runtime has no AAC encoder")
            return
        }
        let audio = try AVAudioFile(forReading: merged)
        let measuredDuration = Double(audio.length) / audio.processingFormat.sampleRate
        precondition(FileManager.default.fileExists(atPath: merged.path))
        precondition(abs(duration - 1.0) < 0.08, "merged duration should equal the sum of the source durations")
        precondition(abs(measuredDuration - 1.0) < 0.08, "exported audio should contain both source recordings")
        precondition(FileManager.default.fileExists(atPath: first.path) && FileManager.default.fileExists(atPath: second.path),
                     "merging never deletes source audio")

        print("AudioRecordingMergerSmoke passed")
    }

    private static func makeTone(at url: URL, frames: AVAudioFrameCount, frequency: Double) throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        let samples = buffer.floatChannelData![0]
        for frame in 0..<Int(frames) {
            samples[frame] = Float(sin(2 * Double.pi * frequency * Double(frame) / 44_100) * 0.2)
        }
        try file.write(from: buffer)
    }
}
