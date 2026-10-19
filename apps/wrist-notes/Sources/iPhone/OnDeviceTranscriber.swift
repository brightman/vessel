import AVFAudio
import Foundation
import Speech

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
    func transcribe(fileURL: URL, locale: Locale) async throws -> String {
        guard SpeechTranscriber.isAvailable else { throw TranscriptionFailure.deviceUnsupported }
        guard let supportedLocale = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else {
            throw TranscriptionFailure.languageUnsupported
        }
        return try await AppleSpeechReservationCoordinator.shared.withReservation(locale: supportedLocale.identifier) {
            try await transcribeInstalled(fileURL: fileURL, locale: supportedLocale)
        }
    }

    private func transcribeInstalled(fileURL: URL, locale: Locale) async throws -> String {
        let transcriber = SpeechTranscriber(locale: locale, preset: .transcription)
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
            let text = try await result
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            await analyzer.cancelAndFinishNow()
            throw error
        }
    }

    private func collectResults(from transcriber: SpeechTranscriber) async throws -> String {
        var text = ""
        for try await result in transcriber.results {
            if result.isFinal {
                text += String(result.text.characters)
            }
        }
        return text
    }
}
