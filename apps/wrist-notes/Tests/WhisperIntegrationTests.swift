import XCTest
import WhisperKit
@testable import WiseNote

@MainActor final class WhisperIntegrationTests: XCTestCase {
    func testBaseModelTranscribesKnownSpeechThroughAppPipeline() async throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("WhisperKit 0.18 forces Core ML to CPU-only on Simulator; known-speech inference returns non-speech tokens. Run this integration test on a physical iPhone.")
        #endif
        let store = WhisperModelStore()
        guard store.installed(.base) else {
            throw XCTSkip("Install Whisper Base from Settings before running this offline integration test.")
        }
        try store.validate(.base)

        // Public-domain JFK speech fixture used in WhisperKit's own integration tests.
        let audio = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "whisper-jfk", withExtension: "wav"))
        let configuration = TranscriptionConfiguration(engine: .whisper, whisperSize: .base, whisperLanguage: "en")
        let transcript: String
        do {
            transcript = try await LocalTranscriptionService(store: store).transcribe(fileURL: audio, configuration: configuration)
        } catch {
            XCTFail("App Whisper pipeline failed: \(type(of: error)): \(String(reflecting: error))")
            throw error
        }
        let normalized = transcript.lowercased()
        print("WHISPER_APP_TRANSCRIPT: \(transcript)")

        XCTAssertTrue(normalized.contains("country"), "Expected recognizable speech; got: \(transcript)")
        XCTAssertTrue(normalized.contains("ask not") || normalized.contains("what your"), "Unexpected transcription: \(transcript)")
    }

    func testWhisperKitDirectBaseInferenceTranscribesKnownSpeech() async throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("WhisperKit 0.18 forces Core ML to CPU-only on Simulator; known-speech inference returns non-speech tokens. Run this integration test on a physical iPhone.")
        #endif
        let store = WhisperModelStore()
        guard store.installed(.base) else { throw XCTSkip("Install Whisper Base before this offline test.") }
        try store.validate(.base)
        let folder = store.folder(for: .base)
        let audio = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "whisper-jfk", withExtension: "wav"))
        let engine = try await WhisperKit(WhisperKitConfig(modelFolder: folder.path, tokenizerFolder: folder,
            verbose: true, logLevel: .debug, prewarm: false, load: false, download: false))
        do {
            try await engine.loadModels()
            XCTAssertEqual(engine.modelVariant, .base, "WhisperKit must infer the variant from loaded model dimensions")
            XCTAssertTrue(engine.textDecoder.isModelMultilingual, "Whisper Base must enable multilingual decoding")
            let results = try await engine.transcribe(audioPath: audio.path,
                decodeOptions: DecodingOptions(language: "en", skipSpecialTokens: true, withoutTimestamps: false,
                    wordTimestamps: false, concurrentWorkerCount: 1))
            let transcript = results.flatMap(\.segments).map(\.text).joined().lowercased()
            print("WHISPER_DIRECT_TRANSCRIPT: \(transcript)")
            XCTAssertTrue(transcript.contains("country"), "Expected recognizable speech; got: \(transcript)")
            await engine.unloadModels()
        } catch {
            await engine.unloadModels()
            XCTFail("Direct WhisperKit inference failed: \(type(of: error)): \(String(reflecting: error))")
            throw error
        }
    }
}
