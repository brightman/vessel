import Foundation
import Hub
import Tokenizers
import WhisperKit

/// Serialize work: actors are reentrant across awaits, so an explicit FIFO protects model memory.
actor LocalTranscriptionService {
    private var running = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private let store: WhisperModelStore
    init(store: WhisperModelStore = WhisperModelStore()) { self.store = store }

    func transcribe(fileURL: URL, configuration: TranscriptionConfiguration) async throws -> String {
        if running { await withCheckedContinuation { waiters.append($0) } } else { running = true }
        defer {
            if waiters.isEmpty { running = false } else { waiters.removeFirst().resume() }
        }
        try Task.checkCancellation()
        let text: String
        if configuration.engine == .apple {
            text = try await OnDeviceTranscriber().transcribe(fileURL: fileURL, locale: Locale(identifier: configuration.appleLocale))
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
                    detectLanguage: automatic, skipSpecialTokens: true, withoutTimestamps: true, concurrentWorkerCount: 1)
                let results: [TranscriptionResult] = try await engine.transcribe(audioPath: fileURL.path, decodeOptions: options)
                text = results.map(\.text).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
                await engine.unloadModels()
            } catch {
                await engine.unloadModels()
                throw error
            }
        }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw TranscriptionResourceError.emptyTranscript }
        return text
    }
}
