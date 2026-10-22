import Foundation
import Hub
import Tokenizers
import WhisperKit
import SpeakerKit

/// Serialize work: actors are reentrant across awaits, so an explicit FIFO protects model memory.
actor LocalTranscriptionService {
    private var running = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private let store: WhisperModelStore
    private let speakers: SpeakerModelStore
    private let identity: VoiceEmbeddingEngine
    init(store: WhisperModelStore = WhisperModelStore(), speakers: SpeakerModelStore = SpeakerModelStore(),
         identityModels: VoiceIdentityModelStore = VoiceIdentityModelStore()) {
        self.store = store; self.speakers = speakers
        self.identity = VoiceEmbeddingEngine(store: identityModels)
    }

    func transcribe(fileURL: URL, configuration: TranscriptionConfiguration) async throws -> String {
        try await transcribeWithSegments(fileURL: fileURL, configuration: configuration).text
    }

    func transcribeWithSegments(fileURL: URL, configuration: TranscriptionConfiguration) async throws -> TranscriptionOutput {
        await acquire()
        defer { release() }
        try Task.checkCancellation()
        let output: TranscriptionOutput
        if configuration.engine == .apple {
            output = try await OnDeviceTranscriber().transcribeWithSegments(fileURL: fileURL, locale: Locale(identifier: configuration.appleLocale))
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
                let results: [TranscriptionResult] = try await engine.transcribe(audioPath: fileURL.path, decodeOptions: options)
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
        guard !output.text.isEmpty else { throw TranscriptionResourceError.emptyTranscript }
        return output
    }

    func diarize(fileURL: URL, segments: [TranscriptSegment]) async throws -> [TranscriptSegment] {
        try await diarizeWithIdentity(fileURL: fileURL, segments: segments, profile: nil).segments
    }

    func diarizeWithIdentity(fileURL: URL, segments: [TranscriptSegment], profile: VoiceProfile?) async throws -> VoiceDiarizationOutput {
        await acquire()
        defer { release() }
        try Task.checkCancellation()
        guard !segments.isEmpty else { throw SpeakerDiarizationError.missingTimestamps }
        let samples = try SpeakerAudioInput.load(from: fileURL) {
            try AudioProcessor.loadAudioAsFloatArray(fromPath: $0)
        }
        let turns = try await speakerTurns(samples: samples)
        let aligned = SpeakerAlignment.align(segments, turns: turns)
        guard aligned.contains(where: { $0.speakerID != nil }) else { throw SpeakerDiarizationError.noSpeakers }
        var output = VoiceDiarizationOutput(segments: aligned, profileID: profile?.id)
        guard let profile else { return output }
        do {
            for (speaker, id) in SpeakerAlignment.identifiers(for: turns).sorted(by: { $0.key < $1.key }) {
                try Task.checkCancellation()
                let ranges = VoiceSpeechSelection.ranges(turns: turns, speaker: speaker, sampleCount: samples.count)
                let windows = VoiceSpeechSelection.windows(samples: samples, ranges: ranges, limit: 6)
                guard windows.count >= 2 else { continue }
                let vectors = try await embeddings(windows)
                if VoiceIdentityPolicy.matches(embeddings: vectors, profile: profile) { output.ownerSpeakerIDs.insert(id) }
            }
            await identity.unload()
            return output
        } catch {
            await identity.unload()
            try Task.checkCancellation()
            output.ownerSpeakerIDs = []
            output.identityMessage = String(format: NSLocalizedString("说话人已区分，但未能匹配我的声音：%@", comment: ""), error.localizedDescription)
            return output
        }
    }

    func enrollVoice(fileURL: URL) async throws -> VoiceProfile {
        await acquire()
        defer { release() }
        try Task.checkCancellation()
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

    private func acquire() async {
        if running { await withCheckedContinuation { waiters.append($0) } } else { running = true }
    }
    private func release() {
        if waiters.isEmpty { running = false } else { waiters.removeFirst().resume() }
    }
}
