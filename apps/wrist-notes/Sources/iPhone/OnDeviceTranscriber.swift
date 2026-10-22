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
        guard SpeechTranscriber.isAvailable else { throw TranscriptionFailure.deviceUnsupported }
        guard let supportedLocale = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else {
            throw TranscriptionFailure.languageUnsupported
        }
        return try await AppleSpeechReservationCoordinator.shared.withReservation(locale: supportedLocale.identifier) {
            try await transcribeInstalled(fileURL: fileURL, locale: supportedLocale)
        }
    }

    private func transcribeInstalled(fileURL: URL, locale: Locale) async throws -> TranscriptionOutput {
        let transcriber = SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [], attributeOptions: [.audioTimeRange])
        guard await AssetInventory.status(forModules: [transcriber]) == .installed else { throw TranscriptionResourceError.missing }
        let file = try AVAudioFile(forReading: fileURL)
        async let result = collectResults(from: transcriber)
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        do {
            if let finalSample = try await analyzer.analyzeSequence(from: file) {
                try await analyzer.finalizeAndFinish(through: finalSample)
            } else {
                await analyzer.cancelAndFinishNow()
            }
            return try await result
        } catch {
            await analyzer.cancelAndFinishNow()
            throw error
        }
    }

    private func collectResults(from transcriber: SpeechTranscriber) async throws -> TranscriptionOutput {
        var text = ""
        var segments: [TranscriptSegment] = []
        for try await result in transcriber.results {
            if result.isFinal {
                text += String(result.text.characters)
                let pieces = result.text.runs.map { run in
                    TimedTranscriptBuilder.Piece(text: String(result.text[run.range].characters),
                        start: run.audioTimeRange.map { CMTimeGetSeconds($0.start) },
                        end: run.audioTimeRange.map { CMTimeGetSeconds(CMTimeRangeGetEnd($0)) })
                }
                segments += TimedTranscriptBuilder.segments(pieces,
                    fallbackStart: CMTimeGetSeconds(result.range.start), fallbackEnd: CMTimeGetSeconds(CMTimeRangeGetEnd(result.range)))
            }
        }
        return TranscriptionOutput(text: text.trimmingCharacters(in: .whitespacesAndNewlines), segments: segments)
    }
}
