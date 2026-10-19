import AVFAudio
import Foundation
import WristNotesDiarization

@main
struct SpeakerModelCheck {
    static func main() async throws {
        guard CommandLine.arguments.count == 3 else {
            throw NSError(domain: "SpeakerModelCheck", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Usage: SpeakerModelCheck <synthetic-audio> <model-cache-directory>"])
        }
        let file = URL(fileURLWithPath: CommandLine.arguments[1])
        let directory = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
        let audio = try AVAudioFile(forReading: file)
        let duration = Double(audio.length) / audio.processingFormat.sampleRate
        let spans = try await LocalDiarization.identify(audio: file, modelsDirectory: directory) { _ in }
        let report: [String: Any] = ["speaker_count": Set(spans.map(\.speakerID)).count,
            "turn_count": spans.count, "audio_duration_seconds": duration,
            "all_ranges_valid": spans.allSatisfy { $0.start.isFinite && $0.end.isFinite && $0.start >= 0 && $0.end > $0.start && $0.end <= duration + 0.1 }]
        let data = try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])
        print(String(decoding: data, as: UTF8.self))
    }
}
