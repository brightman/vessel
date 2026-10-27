import Foundation

private enum ProbeFailure: Error { case unavailable }

@main struct AppleASREnginePolicySmoke {
    static func main() async throws {
        let preferred = AppleTranscriptionEnginePolicy.preferred(
            speechAvailable: true, speechLocaleSupported: true, dictationLocaleSupported: true)
        expect(preferred == .speechTranscriber, "SpeechTranscriber must win when both engines support the locale")

        let noSpeech = AppleTranscriptionEnginePolicy.preferred(
            speechAvailable: false, speechLocaleSupported: true, dictationLocaleSupported: true)
        expect(noSpeech == .dictationTranscriber, "DictationTranscriber must be selected when Speech is unavailable")

        let unsupportedSpeechLocale = AppleTranscriptionEnginePolicy.preferred(
            speechAvailable: true, speechLocaleSupported: false, dictationLocaleSupported: true)
        expect(unsupportedSpeechLocale == .dictationTranscriber, "DictationTranscriber must be selected when Speech lacks the locale")

        let noEngine = AppleTranscriptionEnginePolicy.preferred(
            speechAvailable: false, speechLocaleSupported: false, dictationLocaleSupported: false)
        expect(noEngine == nil, "unsupported locale must not select an engine")

        var attempts: [AppleTranscriptionEngine] = []
        let speechResult = try await AppleTranscriptionEnginePolicy.run(
            preferred: .speechTranscriber, fallback: .dictationTranscriber,
            shouldFallback: { _ in true }) { engine in
                attempts.append(engine)
                return "speech"
            }
        expect(speechResult.engine == .speechTranscriber && speechResult.value == "speech" &&
               attempts == [.speechTranscriber], "successful Speech inference must not run Dictation")

        attempts = []
        let fallbackResult = try await AppleTranscriptionEnginePolicy.run(
            preferred: .speechTranscriber, fallback: .dictationTranscriber,
            shouldFallback: { _ in true }) { engine in
                attempts.append(engine)
                if engine == .speechTranscriber { throw ProbeFailure.unavailable }
                return "dictation"
            }
        expect(fallbackResult.engine == .dictationTranscriber && fallbackResult.value == "dictation" &&
               attempts == [.speechTranscriber, .dictationTranscriber], "retryable Speech failure must run Dictation and report it")

        attempts = []
        do {
            _ = try await AppleTranscriptionEnginePolicy.run(
                preferred: .speechTranscriber, fallback: .dictationTranscriber,
                shouldFallback: { $0 is CancellationError }) { engine in
                    attempts.append(engine)
                    throw CancellationError()
                }
            fatalError("cancellation should propagate")
        } catch is CancellationError {}
        expect(attempts == [.speechTranscriber], "cancellation must never trigger the fallback engine")

        attempts = []
        do {
            _ = try await AppleTranscriptionEnginePolicy.run(
                preferred: .speechTranscriber, fallback: .dictationTranscriber,
                shouldFallback: { _ in false }) { engine in
                    attempts.append(engine)
                    throw ProbeFailure.unavailable
                }
            fatalError("non-retryable failure should propagate")
        } catch ProbeFailure.unavailable {}
        expect(attempts == [.speechTranscriber], "non-retryable failure must not trigger Dictation")

        let appleLabel = TranscriptionConfiguration().label
        expect(appleLabel.contains("SpeechTranscriber") && appleLabel.contains("DictationTranscriber"),
               "Apple configuration must identify Speech priority and Dictation fallback")
        var whisperConfiguration = TranscriptionConfiguration()
        whisperConfiguration.engine = .whisper
        whisperConfiguration.whisperSize = .small
        expect(whisperConfiguration.label.contains("Whisper Small"), "Whisper label must retain its configured model size")

        print("Apple ASR policy: Speech priority, Dictation fallback and cancellation handling passed")
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else { fatalError(message) }
    }
}
