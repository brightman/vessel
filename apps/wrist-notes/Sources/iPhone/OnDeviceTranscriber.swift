import AVFAudio
import Foundation
import CoreMedia
import Speech

enum TranscriptionFailure: LocalizedError {
    case deviceUnsupported
    case languageUnsupported

    var errorDescription: String? {
        switch self {
        case .deviceUnsupported: TranscriptionResourceError.appleUnavailableMessage
        case .languageUnsupported: "当前语种不受端上转写支持"
        }
    }
}

struct OnDeviceTranscriber {
    func transcribe(fileURL: URL, locale: Locale) async throws -> String {
        try await transcribeWithSegments(fileURL: fileURL, locale: locale).text
    }

    func transcribeWithSegments(fileURL: URL, locale: Locale) async throws -> TranscriptionOutput {
        let input = try AVAudioFile(forReading: fileURL)
        guard input.length > 0, Double(input.length) / input.processingFormat.sampleRate <= 304.0000001 else {
            throw BoundedAudioError.invalidWindow
        }

        let speechAvailable = SpeechTranscriber.isAvailable
        let speechLocale = speechAvailable ? await SpeechTranscriber.supportedLocale(equivalentTo: locale) : nil
        let dictationLocale = await DictationTranscriber.supportedLocale(equivalentTo: locale)
        guard let preferred = AppleTranscriptionEnginePolicy.preferred(
            speechAvailable: speechAvailable,
            speechLocaleSupported: speechLocale != nil,
            dictationLocaleSupported: dictationLocale != nil
        ) else {
            if !speechAvailable && dictationLocale == nil { throw TranscriptionFailure.deviceUnsupported }
            throw TranscriptionFailure.languageUnsupported
        }

        let fallback: AppleTranscriptionEngine? = preferred == .speechTranscriber && dictationLocale != nil
            ? .dictationTranscriber : nil
        let attempt = try await AppleTranscriptionEnginePolicy.run(
            preferred: preferred,
            fallback: fallback,
            shouldFallback: { error in
                guard !Task.isCancelled, !(error is CancellationError) else { return false }
                if let error = error as? BoundedAudioError, case .invalidWindow = error { return false }
                return true
            }
        ) { engine in
            switch engine {
            case .speechTranscriber:
                guard let speechLocale else { throw TranscriptionFailure.languageUnsupported }
                return try await AppleSpeechReservationCoordinator.shared.withReservation(locale: speechLocale.identifier) {
                    try await transcribeSpeechInstalled(fileURL: fileURL, locale: speechLocale)
                }
            case .dictationTranscriber:
                guard let dictationLocale else { throw TranscriptionFailure.languageUnsupported }
                return try await AppleSpeechReservationCoordinator.shared.withReservation(locale: dictationLocale.identifier) {
                    try await transcribeDictationInstalled(fileURL: fileURL, locale: dictationLocale)
                }
            }
        }
        var output = attempt.value
        output.engineName = attempt.engine.displayName
        return output
    }

    private func transcribeSpeechInstalled(fileURL: URL, locale: Locale) async throws -> TranscriptionOutput {
        let transcriber = SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [], attributeOptions: [.audioTimeRange])
        guard await AssetInventory.status(forModules: [transcriber]) == .installed else {
            throw TranscriptionResourceError.missing
        }
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let result = Task { try await collectResults(from: transcriber) }
        return try await analyze(fileURL: fileURL, analyzer: analyzer, result: result)
    }

    private func transcribeDictationInstalled(fileURL: URL, locale: Locale) async throws -> TranscriptionOutput {
        let transcriber = DictationTranscriber(locale: locale, preset: .timeIndexedLongDictation)
        guard await AssetInventory.status(forModules: [transcriber]) == .installed else {
            throw TranscriptionResourceError.missing
        }
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let result = Task { try await collectResults(from: transcriber) }
        return try await analyze(fileURL: fileURL, analyzer: analyzer, result: result)
    }

    private func analyze(fileURL: URL, analyzer: SpeechAnalyzer,
                         result: Task<TranscriptionOutput, Error>) async throws -> TranscriptionOutput {
        let file = try AVAudioFile(forReading: fileURL)
        do {
            if let finalSample = try await analyzer.analyzeSequence(from: file) {
                try await analyzer.finalizeAndFinish(through: finalSample)
            } else {
                await analyzer.cancelAndFinishNow()
            }
            try Task.checkCancellation()
            let output = try await result.value
            guard !output.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw TranscriptionResourceError.emptyTranscript
            }
            return output
        } catch {
            result.cancel()
            await analyzer.cancelAndFinishNow()
            throw error
        }
    }

    private func collectResults(from transcriber: SpeechTranscriber) async throws -> TranscriptionOutput {
        var accumulator = TranscriptResultAccumulator()
        for try await result in transcriber.results where result.isFinal {
            accumulator.append(result.text, range: result.range)
        }
        return accumulator.output
    }

    private func collectResults(from transcriber: DictationTranscriber) async throws -> TranscriptionOutput {
        var accumulator = TranscriptResultAccumulator()
        for try await result in transcriber.results where result.isFinal {
            accumulator.append(result.text, range: result.range)
        }
        return accumulator.output
    }
}

private struct TranscriptResultAccumulator {
    private(set) var text = ""
    private(set) var segments: [TranscriptSegment] = []

    mutating func append(_ attributed: AttributedString, range: CMTimeRange) {
        text += String(attributed.characters)
        let pieces = attributed.runs.map { run in
            TimedTranscriptBuilder.Piece(
                text: String(attributed[run.range].characters),
                start: run.audioTimeRange.map { CMTimeGetSeconds($0.start) },
                end: run.audioTimeRange.map { CMTimeGetSeconds(CMTimeRangeGetEnd($0)) }
            )
        }
        segments += TimedTranscriptBuilder.segments(
            pieces,
            fallbackStart: CMTimeGetSeconds(range.start),
            fallbackEnd: CMTimeGetSeconds(CMTimeRangeGetEnd(range))
        )
    }

    var output: TranscriptionOutput {
        TranscriptionOutput(text: text.trimmingCharacters(in: .whitespacesAndNewlines), segments: segments)
    }
}
