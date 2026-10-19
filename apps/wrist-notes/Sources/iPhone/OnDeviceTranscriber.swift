import AVFAudio
import Foundation
import Speech
import CoreMedia

struct TimedTranscription {
    let text: String
    let segments: [TranscriptSegment]
    let words: [TranscriptSegment]
}

enum TranscriptionFailure: LocalizedError {
    case deviceUnsupported
    case languageUnsupported

    var errorDescription: String? {
        switch self {
        case .deviceUnsupported: "这台 iPhone 不支持端上转写"
        case .languageUnsupported: "当前语种不受端上转写支持"
        }
    }
}

struct OnDeviceTranscriber {
    func transcribe(fileURL: URL, locale: Locale) async throws -> TimedTranscription {
        guard SpeechTranscriber.isAvailable else { throw TranscriptionFailure.deviceUnsupported }
        guard let supportedLocale = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else {
            throw TranscriptionFailure.languageUnsupported
        }
        let transcriber = SpeechTranscriber(locale: supportedLocale, transcriptionOptions: [],
            reportingOptions: [], attributeOptions: [.audioTimeRange])
        if let installation = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await installation.downloadAndInstall()
        }
        let file = try AVAudioFile(forReading: fileURL)
        async let result = collectResults(from: transcriber)
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        if let finalSample = try await analyzer.analyzeSequence(from: file) {
            try await analyzer.finalizeAndFinish(through: finalSample)
        } else {
            await analyzer.cancelAndFinishNow()
        }
        return try await result
    }

    private func collectResults(from transcriber: SpeechTranscriber) async throws -> TimedTranscription {
        var text = ""
        var segments: [TranscriptSegment] = []
        var tokens: [TranscriptSegment] = []
        for try await result in transcriber.results {
            if result.isFinal {
                text += String(result.text.characters)
                for run in result.text.runs {
                    guard let range = run.audioTimeRange else { continue }
                    let start = range.start.seconds
                    let end = CMTimeRangeGetEnd(range).seconds
                    let words = String(result.text[run.range].characters)
                    guard start.isFinite, end.isFinite, start >= 0, end > start,
                          !words.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                    tokens.append(TranscriptSegment(start: start, end: end, text: words))
                    // Group nearby words into readable, bounded excerpts while preserving real ASR times.
                    if let last = segments.last, start >= last.start, start - last.end < 1.5,
                       end - last.start <= 12, last.text.count + words.count <= 100 {
                        segments[segments.count - 1] = TranscriptSegment(start: last.start, end: max(last.end, end), text: last.text + words)
                    } else { segments.append(TranscriptSegment(start: start, end: end, text: words)) }
                }
            }
        }
        return TimedTranscription(text: text.trimmingCharacters(in: .whitespacesAndNewlines), segments: segments, words: tokens)
    }
}
