import AVFAudio
import Foundation

/// Optional Mac real-model check. All fixtures are generated speech; catalogs are validated, never downloaded.
@main struct BoundedInferenceSmoke {
    static func main() async throws {
        let args = CommandLine.arguments
        guard args.count == 6 else { fatalError("usage: inference iphone-source whisper-root speaker-root identity-root generated-speech") }
        let source = URL(fileURLWithPath:args[1]), fileURL = URL(fileURLWithPath:args[5])
        let whisper = WhisperModelStore(root:URL(fileURLWithPath:args[2]),catalogURL:source.appendingPathComponent("WhisperModels.json"))
        let speakers = SpeakerModelStore(root:URL(fileURLWithPath:args[3]),catalogURL:source.appendingPathComponent("SpeakerModels.json"))
        let identity = VoiceIdentityModelStore(root:URL(fileURLWithPath:args[4]),catalogURL:source.appendingPathComponent("VoiceIdentityModels.json"))
        try whisper.validate(.tiny); try speakers.validate(); try identity.validate()
        let file = try AVAudioFile(forReading:fileURL)
        let duration = Double(file.length)/file.processingFormat.sampleRate
        precondition(duration >= 20 && duration <= 300)
        let range = try AudioSourceRange(range:.init(chunkID:UUID(),url:fileURL,startFrame:0,endFrame:file.length,sampleRate:file.processingFormat.sampleRate,sessionStartOffset:40,discontinuityBefore:nil),contentHash:String(repeating:"c",count:64))
        let window = AudioProcessingWindow(id:"real-model",sourceID:.init(kind:.legacyNote,id:UUID()),configurationKey:"tiny-en",coreStart:40,coreEnd:40+duration,ranges:[range])
        let configuration = TranscriptionConfiguration(engine:.whisper,whisperSize:.tiny,whisperLanguage:"en")
        let service = LocalTranscriptionService(store:whisper,speakers:speakers,identityModels:identity)
        let all = try await service.process(window:window,configuration:configuration,stages:.all,sourceDuration:40+duration).result
        precondition(all.asr == .success && !all.spans.isEmpty && all.vad == .success)
        precondition(all.asrCoverage == [.init(start:40,end:40+duration)] && all.vadCoverage == all.asrCoverage)
        precondition(all.spans.allSatisfy { $0.start >= 40 && $0.end <= 40+duration })
        precondition(all.activities.contains { $0.kind == .speech })
        precondition(all.speaker == .success && !all.speakerFeatures.isEmpty)
        precondition(all.speakerFeatures.allSatisfy { $0.modelVersion == VoiceIdentityPolicy.modelID && $0.vector.count == 256 && abs($0.vector.reduce(0.0) { $0+Double($1)*Double($1) }-1) < 0.0001 })
        print("Actual bounded service: ASR/VAD/speaker success; absolute source coverage, normalized compatible features; spans",all.spans.count,"features",all.speakerFeatures.count)
        let vadOnly = try await service.process(window:window,configuration:configuration,stages:.vad,sourceDuration:nil,priorSpans:all.spans).result
        precondition(vadOnly.asr == .notRequested && vadOnly.spans.isEmpty && vadOnly.asrCoverage.isEmpty && vadOnly.vad == .success && vadOnly.speaker == .notRequested)
        let retained = [AudioTranscriptSpan(start:40,end:41,text:"hello"),
                        AudioTranscriptSpan(start:41,end:42,text:" world")]
        let speakerRetry = try await service.process(window:window,configuration:configuration,stages:.speaker,sourceDuration:40+duration,priorSpans:retained)
        precondition(speakerRetry.result.asr == .notRequested && speakerRetry.result.spans.isEmpty && speakerRetry.result.asrCoverage.isEmpty)
        precondition(speakerRetry.result.speaker == .success && speakerRetry.speakerSpanUpdates.contains { $0.speakerID != nil })
        guard speakerRetry.speakerSpanUpdates.count == retained.count else {
            FileHandle.standardError.write(Data("FAIL: speaker retry retained rows expected \(retained.count), got \(speakerRetry.speakerSpanUpdates.count); stage \(speakerRetry.result.speaker.rawValue)\n".utf8))
            exit(1)
        }
        for (original, updated) in zip(retained,speakerRetry.speakerSpanUpdates) {
            precondition(updated.start == original.start && updated.end == original.end && updated.text == original.text,
                         "speaker retry changed an original ASR row's timestamps or text")
        }
        print("Speaker-only retained rows: exact text/start/end preserved for every row")
        let guarded = try await service.process(window:window,configuration:configuration,stages:.speaker,sourceDuration:1801,priorSpans:all.spans).result
        precondition(guarded.speaker == .notRequested && guarded.speakerFeatures.isEmpty)
        let unknown = try await service.process(window:window,configuration:configuration,stages:.speaker,sourceDuration:nil,priorSpans:all.spans).result
        precondition(unknown.speaker == .notRequested && unknown.speakerFeatures.isEmpty)
        let missing = SpeakerModelStore(root:FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString),catalogURL:source.appendingPathComponent("SpeakerModels.json"))
        let partialService = LocalTranscriptionService(store:whisper,speakers:missing,identityModels:identity)
        let partial = try await partialService.process(window:window,configuration:configuration,stages:[.asr,.vad],sourceDuration:nil).result
        precondition(partial.asr == .success && !partial.spans.isEmpty && partial.vad == .missingResource && partial.vadCoverage.isEmpty && partial.activities.allSatisfy { $0.kind == .uncertain })
        print("Actual stage retry/policy: VAD-only leaves ASR untouched; unknown/>30min speaker blocked; missing VAD preserves actual ASR, no fabricated coverage")
    }
}
