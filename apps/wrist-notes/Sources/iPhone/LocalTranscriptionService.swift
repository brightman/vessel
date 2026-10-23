import AVFAudio
import Foundation
import Hub
import Tokenizers
import WhisperKit
import SpeakerKit

/// Every public inference entry uses the same cancellation-aware heavy-model permit.
actor LocalTranscriptionService {
    static let shared = LocalTranscriptionService()
    private let gate: LocalAudioInferenceGate
    private let reader = BoundedAudioReader()
    private let store: WhisperModelStore
    private let speakers: SpeakerModelStore
    private let identity: VoiceEmbeddingEngine
    init(store: WhisperModelStore = WhisperModelStore(), speakers: SpeakerModelStore = SpeakerModelStore(),
         identityModels: VoiceIdentityModelStore = VoiceIdentityModelStore(),
         gate: LocalAudioInferenceGate = .shared) {
        self.store = store; self.speakers = speakers; self.gate = gate
        self.identity = VoiceEmbeddingEngine(store: identityModels)
    }

    func transcribe(fileURL: URL, configuration: TranscriptionConfiguration) async throws -> String {
        try await transcribeWithSegments(fileURL: fileURL, configuration: configuration).text
    }

    func transcribeWithSegments(fileURL: URL, configuration: TranscriptionConfiguration) async throws -> TranscriptionOutput {
        try await gate.withPermit { try await self.transcribeLegacy(fileURL:fileURL,configuration:configuration) }
    }

    private func transcribeLegacy(fileURL: URL, configuration: TranscriptionConfiguration) async throws -> TranscriptionOutput {
        let windows = try legacyWindows(fileURL:fileURL,configurationKey:configuration.resourceID)
        var pieces: [TranscriptSegment] = []
        for window in windows {
            try Task.checkCancellation()
            let audio = try reader.materialize(window)
            defer { audio.cleanup() }
            let output = try await transcribeBounded(audio:audio,configuration:configuration)
            pieces += try mappedSpans(output.segments,audio:audio,window:window).map {
                .init(start:$0.start,end:$0.end,text:$0.text,speakerID:$0.speakerID)
            }
        }
        let text = pieces.map(\.text).joined().trimmingCharacters(in:.whitespacesAndNewlines)
        guard !text.isEmpty else { throw TranscriptionResourceError.emptyTranscript }
        return .init(text:text,segments:pieces)
    }

    /// Only a protected <=304-second materialization may reach either native engine.
    private func transcribeBounded(audio: BoundedAudioFile, configuration: TranscriptionConfiguration) async throws -> TranscriptionOutput {
        guard audio.duration > 0, audio.duration <= 304.0000001 else { throw BoundedAudioError.invalidWindow }
        let output: TranscriptionOutput
        if configuration.engine == .apple {
            output = try await OnDeviceTranscriber().transcribeWithSegments(fileURL: audio.url, locale: Locale(identifier: configuration.appleLocale))
        } else {
            guard configuration.validWhisperLanguage else { throw TranscriptionResourceError.unsupported }
            try store.validate(configuration.whisperSize)
            let folder = store.folder(for: configuration.whisperSize)
            // Decode tokenizer directly from files. WhisperKit's fallback Hub download is never used.
            let tokenizer = try PreTrainedTokenizer(
                tokenizerConfig: JSONDecoder().decode(Config.self, from: Data(contentsOf: folder.appendingPathComponent("tokenizer_config.json"))),
                tokenizerData: JSONDecoder().decode(Config.self, from: Data(contentsOf: folder.appendingPathComponent("tokenizer.json"))))
            let engine = try await WhisperKit(WhisperKitConfig(modelFolder: folder.path,
                tokenizerFolder: folder, verbose: false, prewarm: false, load: false, download: false))
            engine.tokenizer = try OfflineWhisperTokenizer(tokenizer: tokenizer)
            engine.textDecoder.isModelMultilingual = true
            do {
                try await engine.loadModels()
                let automatic = configuration.whisperLanguage == "auto"
                let options = DecodingOptions(language: automatic ? nil : configuration.whisperLanguage,
                    detectLanguage: automatic, skipSpecialTokens: true, withoutTimestamps: false, wordTimestamps: true, concurrentWorkerCount: 1)
                // Upstream's 16 kHz file loader reads once and can truncate a large CAF read.
                // Supply exactly accumulated, bounded samples instead of trusting its header.
                let samples = try audio.samples(maximumFrames:4_864_000)
                let results: [TranscriptionResult] = try await engine.transcribe(audioArray:samples,decodeOptions:options)
                let pieces: [TranscriptSegment] = results.flatMap(\.segments).flatMap { segment in
                    if let words = segment.words, !words.isEmpty {
                        return words.map { TranscriptSegment(start: Double($0.start), end: Double($0.end), text: $0.word) }
                    }
                    return [TranscriptSegment(start: Double(segment.start), end: Double(segment.end), text: segment.text)]
                }
                output = TranscriptionOutput(text: pieces.map(\.text).joined().trimmingCharacters(in: .whitespacesAndNewlines), segments: pieces)
                await engine.unloadModels()
            } catch {
                await engine.unloadModels()
                throw error
            }
        }
        try Task.checkCancellation()
        return output
    }

    func diarize(fileURL: URL, segments: [TranscriptSegment]) async throws -> [TranscriptSegment] {
        try await diarizeWithIdentity(fileURL: fileURL, segments: segments, profile: nil).segments
    }

    func diarizeWithIdentity(fileURL: URL, segments: [TranscriptSegment], profile: VoiceProfile?) async throws -> VoiceDiarizationOutput {
        try await gate.withPermit { try await self.diarizeLegacy(fileURL:fileURL,segments:segments,profile:profile) }
    }

    private func diarizeLegacy(fileURL: URL, segments: [TranscriptSegment], profile: VoiceProfile?) async throws -> VoiceDiarizationOutput {
        guard !segments.isEmpty else { throw SpeakerDiarizationError.missingTimestamps }
        let file = try AVAudioFile(forReading:fileURL)
        let duration = Double(file.length)/file.processingFormat.sampleRate
        guard duration.isFinite, duration > 0 else { throw SpeakerDiarizationError.invalidAudio }
        guard AudioSpeakerMapping.permitsAnalysis(sourceDuration:duration) else { throw SpeakerDiarizationError.recordingTooLong }
        let windows = try legacyWindows(fileURL:fileURL,configurationKey:"speaker")
        var candidates: [String:AudioSpeakerFeature] = [:], output: [TranscriptSegment] = []
        var owners: Set<String> = [], nextSpeaker = 1
        var identityMessage: String?
        for window in windows {
            try Task.checkCancellation()
            let audio = try reader.materialize(window)
            defer { audio.cleanup() }
            // Select words by source midpoint before converting to bounded-input time.
            let spans = try AudioWindowPlanner.ownedSpans(segments.map { .init(start:$0.start,end:$0.end,text:$0.text) },window:window)
            guard !spans.isEmpty else { continue }
            let relative = relativeSegments(spans,audio:audio)
            let analysis = try await analyzeSpeakers(audio:audio,segments:relative,profile:profile,requireFeatures:false,coalesceForPresentation:true)
            var names: [String:String] = [:]
            for feature in analysis.features {
                // An unmatched feature starts a separate label; equal local IDs never merge.
                let name = AudioSpeakerMapping.match(feature,candidates:candidates) ?? "speaker-\(nextSpeaker)"
                if candidates[name] == nil { candidates[name] = feature; nextSpeaker += 1 }
                names[feature.localSpeakerID] = name
                if analysis.ownerIDs.contains(feature.localSpeakerID) { owners.insert(name) }
            }
            for id in Set(analysis.segments.compactMap(\.speakerID)).sorted() where names[id] == nil {
                names[id] = "speaker-\(nextSpeaker)"; nextSpeaker += 1
            }
            if let message = analysis.identityMessage { identityMessage = message }
            output += try mappedSpans(analysis.segments,audio:audio,window:window).map {
                .init(start:$0.start,end:$0.end,text:$0.text,speakerID:$0.speakerID.flatMap { names[$0] })
            }
        }
        guard output.contains(where:{ $0.speakerID != nil }) else { throw SpeakerDiarizationError.noSpeakers }
        return VoiceDiarizationOutput(segments:output,ownerSpeakerIDs:owners,profileID:profile?.id,identityMessage:identityMessage)
    }

    func enrollVoice(fileURL: URL) async throws -> VoiceProfile {
        try await gate.withPermit { try await self.enrollInstalledVoice(fileURL:fileURL) }
    }

    private func enrollInstalledVoice(fileURL: URL) async throws -> VoiceProfile {
        try Task.checkCancellation()
        let file = try AVAudioFile(forReading:fileURL)
        let headerDuration = Double(file.length)/file.processingFormat.sampleRate
        guard headerDuration.isFinite, (30...60.5).contains(headerDuration) else { throw VoiceEnrollmentError.duration }
        let samples = try AudioProcessor.loadAudioAsFloatArray(fromPath: fileURL.path)
        let duration = Double(samples.count) / 16_000
        // AAC padding can add a fraction of a frame beyond the recorder's 60 second limit.
        guard duration >= 30, duration <= 60.5 else { throw VoiceEnrollmentError.duration }
        let turns = try await speakerTurns(samples: samples)
        let ranges = try VoiceSpeechSelection.enrollmentRanges(turns: turns, sampleCount: samples.count)
        let windows = ranges.flatMap { VoiceSpeechSelection.windows(samples: samples, ranges: $0, limit: 12) }
        do {
            let vectors = try await embeddings(windows)
            let profile = try VoiceIdentityPolicy.makeProfile(embeddings: vectors, duration: min(60, duration))
            await identity.unload()
            try Task.checkCancellation()
            return profile
        } catch {
            await identity.unload()
            throw error
        }
    }

    private func embeddings(_ windows: [[Float]]) async throws -> [[Float]] {
        var result: [[Float]] = []
        for window in windows {
            try Task.checkCancellation()
            result.append(try await identity.extract(samples: window))
        }
        return result
    }

    private func speakerTurns(samples: [Float]) async throws -> [SpeakerTurn] {
        do { try speakers.validate() }
        catch { try Task.checkCancellation(); throw SpeakerDiarizationError.missingModels }
        // Explicit local folder and download:false prevent network access during inference.
        let engine = try await SpeakerKit(PyannoteConfig(modelFolder: speakers.folder.path,
            download: false, load: false, verbose: false,
            concurrentSegmenterWorkers: 1, concurrentEmbedderWorkers: 1))
        do {
            let result = try await engine.diarize(audioArray: samples)
            try Task.checkCancellation()
            let turns = result.segments.compactMap { segment -> SpeakerTurn? in
                guard let speaker = segment.speaker.speakerId else { return nil }
                return SpeakerTurn(start: Double(segment.startTime), end: Double(segment.endTime), speaker: speaker)
            }
            await engine.unloadModels()
            return turns
        } catch {
            await engine.unloadModels()
            throw error
        }
    }

    // Safe default retains the long-source speaker guard because source duration is unknown.
    func process(window: AudioProcessingWindow, configuration: TranscriptionConfiguration) async throws -> AudioWindowResult {
        try await process(window:window,configuration:configuration,stages:.all,sourceDuration:nil).result
    }

    /// priorSpans are preserved successful ASR spans supplied on a VAD-only retry.
    /// Return values contain only requested stages; Task 3 merges them with committed successes.
    func process(window: AudioProcessingWindow, configuration: TranscriptionConfiguration,
                 stages: AudioInferenceStages, sourceDuration: Double?, priorSpans: [AudioTranscriptSpan] = [], maximumCoreDuration: Double = 300) async throws -> AudioInferenceDelta {
        try await gate.withPermit {
            try await AudioAdaptiveInference.process(window:window,maximumCoreDuration:maximumCoreDuration,priorSpans:priorSpans) { inner, prior in
                try await self.processInstalled(window:inner,configuration:configuration,stages:stages,sourceDuration:sourceDuration,priorSpans:prior)
            }
        }
    }

    private func processInstalled(window: AudioProcessingWindow, configuration: TranscriptionConfiguration,
                                  stages: AudioInferenceStages, sourceDuration: Double?, priorSpans: [AudioTranscriptSpan]) async throws -> AudioInferenceDelta {
        guard !stages.isEmpty else {
            return .init(result:.init(spans:[],activities:[],asr:.notRequested,vad:.notRequested,speaker:.notRequested,asrCoverage:[],vadCoverage:[]),speakerSpanUpdates:[])
        }
        let audio = try reader.materialize(window)
        defer { audio.cleanup() }
        let coverage = clippedCoverage(audio.sourceRanges(start:0,end:audio.duration),window:window)
        var contextSpans: [AudioTranscriptSpan] = [], speakerSpanUpdates: [AudioTranscriptSpan] = []
        var spans: [AudioTranscriptSpan] = [], activities: [AudioActivityInterval] = [], features: [AudioSpeakerFeature] = []
        var asr: AudioAnalysisOutcome = .notRequested, vad: AudioAnalysisOutcome = .notRequested, speaker: AudioAnalysisOutcome = .notRequested
        if stages.contains(.asr) {
            do {
                let output = try await transcribeBounded(audio:audio,configuration:configuration)
                contextSpans = try mappedSpans(output.segments,audio:audio,window:window,owned:false)
                spans = try AudioWindowPlanner.ownedSpans(contextSpans,window:window)
                asr = .success
            } catch { try Task.checkCancellation(); asr = outcome(error) }
        }
        if stages.contains(.vad) {
            do {
                let detections = try autoreleasepool { try OnDeviceSpeechActivity(store:speakers).analyze(audio) }
                let mapped = detections.flatMap { interval in
                    audio.sourceRanges(start:interval.start,end:interval.end).map { AudioActivityInterval(start:$0.start,end:$0.end,kind:interval.kind) }
                }
                activities = AudioActivityReconciler.reconcile(start:window.coreStart,end:window.coreEnd,detections:mapped,coverage:coverage,spans:contextSpans+priorSpans)
                vad = .success
            } catch {
                try Task.checkCancellation(); vad = outcome(error)
                activities = [.init(start:window.coreStart,end:window.coreEnd,kind:.uncertain)]
            }
        }
        if stages.contains(.speaker), AudioSpeakerMapping.permitsAnalysis(sourceDuration:sourceDuration),
           let sourceDuration, sourceDuration + 1e-7 >= window.inputEnd {
            do {
                let candidates = asr == .success ? spans : priorSpans
                // Filter ownership without clipping/rebuilding retained rows. Speaker-only
                // retries must match their original text/start/end exactly at commit time.
                let selected = candidates.filter {
                    let midpoint = $0.start + ($0.end-$0.start)/2
                    return midpoint >= window.coreStart && midpoint < window.coreEnd
                }
                let relative = relativeSegments(selected,audio:audio)
                let result = try await analyzeSpeakers(audio:audio,segments:relative,profile:nil)
                let updated = try AudioSpeakerMapping.annotating(selected,speakerIDs:result.segments.map(\.speakerID))
                if asr == .success { spans = updated }
                else { speakerSpanUpdates = updated }
                features = result.features; speaker = .success
            } catch { try Task.checkCancellation(); speaker = outcome(error) }
        }
        try Task.checkCancellation()
        return .init(result:.init(spans:spans,activities:activities,asr:asr,vad:vad,speaker:speaker,
                     asrCoverage:asr == .success ? coverage : [],vadCoverage:vad == .success ? coverage : [],speakerFeatures:features),speakerSpanUpdates:speakerSpanUpdates)
    }

    private struct SpeakerAnalysis {
        let segments: [TranscriptSegment]
        let features: [AudioSpeakerFeature]
        let ownerIDs: Set<String>
        let identityMessage: String?
    }
    private func analyzeSpeakers(audio: BoundedAudioFile, segments: [TranscriptSegment], profile: VoiceProfile?, requireFeatures: Bool = true, coalesceForPresentation: Bool = false) async throws -> SpeakerAnalysis {
        let samples = try audio.samples(maximumFrames:4_864_000)
        let turns = try await speakerTurns(samples:samples)
        guard !turns.isEmpty else { throw SpeakerDiarizationError.noSpeakers }
        let names = SpeakerAlignment.identifiers(for:turns)
        var features: [AudioSpeakerFeature] = [], owners: Set<String> = []
        var identityMessage: String?
        do {
            for (speaker,id) in names.sorted(by:{ $0.key < $1.key }) {
                try Task.checkCancellation()
                let ranges = VoiceSpeechSelection.ranges(turns:turns,speaker:speaker,sampleCount:samples.count)
                let windows = VoiceSpeechSelection.windows(samples:samples,ranges:ranges,limit:6)
                guard windows.count >= 2 else { continue }
                let vectors = try await embeddings(windows)
                // Every clean sample must agree. Do not turn a mixed cluster into a centroid.
                guard vectors.allSatisfy({ a in vectors.allSatisfy { b in zip(a,b).reduce(Float(0)) { $0+$1.0*$1.1 } >= VoiceIdentityPolicy.matchSimilarity } }) else { continue }
                var mean = [Float](repeating:0,count:256)
                for vector in vectors { for i in mean.indices { mean[i] += vector[i]/Float(vectors.count) } }
                let normalized = try VoiceIdentityPolicy.normalized(mean)
                features.append(.init(localSpeakerID:id,modelVersion:VoiceIdentityPolicy.modelID,vector:normalized))
                if let profile, VoiceIdentityPolicy.matches(embeddings:vectors,profile:profile) { owners.insert(id) }
            }
            await identity.unload()
        } catch {
            await identity.unload(); try Task.checkCancellation()
            if requireFeatures { throw error }
            // Retain window-local diarization when optional identity resources are unavailable.
            // Without features these labels will never be matched across windows.
            if profile != nil { identityMessage = String(format:NSLocalizedString("说话人已区分，但未能匹配我的声音：%@",comment:""),error.localizedDescription) }
        }
        if requireFeatures && features.isEmpty { throw VoiceIdentityError.invalidAudio }
        let valid = Set(features.map(\.localSpeakerID))
        let labeled = coalesceForPresentation ? SpeakerAlignment.align(segments,turns:turns) : SpeakerAlignment.annotate(segments,turns:turns)
        let aligned = labeled.map { piece -> TranscriptSegment in
            var piece = piece
            if requireFeatures, let id = piece.speakerID, !valid.contains(id) { piece.speakerID = nil }
            return piece
        }
        return .init(segments:aligned,features:features,ownerIDs:owners,identityMessage:identityMessage)
    }

    private func relativeSegments(_ spans: [AudioTranscriptSpan], audio: BoundedAudioFile) -> [TranscriptSegment] {
        spans.compactMap { span in
            let ranges = audio.inputRanges(start:span.start,end:span.end)
            guard let first = ranges.first, let last = ranges.last else { return nil }
            return .init(start:first.start,end:last.end,text:span.text)
        }
    }
    private func mappedSpans(_ pieces: [TranscriptSegment], audio: BoundedAudioFile, window: AudioProcessingWindow, owned: Bool = true) throws -> [AudioTranscriptSpan] {
        var spans: [AudioTranscriptSpan] = []
        for piece in pieces {
            guard piece.start.isFinite, piece.end.isFinite, piece.end >= piece.start else { throw BoundedAudioError.invalidFormat }
            for range in audio.sourceRanges(start:piece.start,end:piece.end) {
                spans.append(.init(start:range.start,end:range.end,text:piece.text,speakerID:piece.speakerID))
            }
        }
        return owned ? try AudioWindowPlanner.ownedSpans(spans,window:window) : spans
    }
    private func clippedCoverage(_ ranges: [AudioTimeRange], window: AudioProcessingWindow) -> [AudioTimeRange] {
        ranges.compactMap {
            let start = max(window.coreStart,$0.start), end = min(window.coreEnd,$0.end)
            return end > start ? .init(start:start,end:end) : nil
        }
    }
    private func outcome(_ error: Error) -> AudioAnalysisOutcome {
        if let error = error as? TranscriptionResourceError {
            switch error { case .missing, .invalidFiles: return .missingResource; default: break }
        }
        if let error = error as? SpeakerDiarizationError, case .missingModels = error { return .missingResource }
        return .failed
    }
    private func legacyWindows(fileURL: URL, configurationKey: String) throws -> [AudioProcessingWindow] {
        let file = try AVAudioFile(forReading:fileURL)
        guard file.length > 0, file.processingFormat.sampleRate.isFinite, file.processingFormat.sampleRate > 0 else { throw BoundedAudioError.invalidFormat }
        let range = try AudioSourceRange(range:.init(chunkID:UUID(),url:fileURL,startFrame:0,endFrame:file.length,sampleRate:file.processingFormat.sampleRate,sessionStartOffset:0,discontinuityBefore:nil),contentHash:String(repeating:"0",count:64))
        // Transient legacy adapter only: durable Task 3 discovery supplies real verified hashes.
        let source = try AudioSourceSnapshot(id:.init(kind:.legacyNote,id:UUID()),capturedAt:Date(timeIntervalSince1970:0),title:"",ranges:[range],complete:true)
        return try AudioWindowPlanner.plan(source:source,configurationKey:configurationKey)
    }
}
