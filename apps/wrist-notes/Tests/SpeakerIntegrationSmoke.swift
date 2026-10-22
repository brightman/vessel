import Foundation

/// Runs actual Core ML inference against a caller-supplied audio fixture; never mocks the models.
@main struct SpeakerIntegrationSmoke {
    static func main() async throws {
        let args = CommandLine.arguments
        guard args.count == 6 else { fatalError("usage: smoke whisper-manifest speaker-manifest whisper-root speaker-root audio") }
        let asr = WhisperModelStore(root: URL(fileURLWithPath: args[3]), catalogURL: URL(fileURLWithPath: args[1]))
        let speakers = SpeakerModelStore(root: URL(fileURLWithPath: args[4]), catalogURL: URL(fileURLWithPath: args[2]))
        try await asr.download(.tiny) { _ in }
        try await speakers.download { _ in }
        try speakers.validate()
        let service = LocalTranscriptionService(store: asr, speakers: speakers)
        let start = Date()
        let output = try await service.transcribeWithSegments(fileURL: URL(fileURLWithPath: args[5]),
            configuration: .init(engine: .whisper, whisperSize: .tiny, whisperLanguage: "en"))
        precondition(!output.text.isEmpty && !output.segments.isEmpty)
        let aligned = try await service.diarize(fileURL: URL(fileURLWithPath: args[5]), segments: output.segments)
        precondition(aligned.map(\.text).joined().trimmingCharacters(in: .whitespacesAndNewlines) == output.text,
                     "Alignment must retain all recognized text")
        let ids = Set(aligned.compactMap(\.speakerID))
        precondition(!ids.isEmpty)
        print("Real local inference passed: \(ids.count) speakers, \(output.segments.count) timed pieces, \(aligned.count) display segments; \(Date().timeIntervalSince(start)) seconds on this Mac")
        for segment in aligned {
            print(String(format: "%.2f–%.2f", segment.start, segment.end), segment.speakerID ?? "unknown", segment.text)
        }
    }
}
