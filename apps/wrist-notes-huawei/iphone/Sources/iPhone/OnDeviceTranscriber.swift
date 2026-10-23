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
        let transcriber = SpeechTranscriber(locale: supportedLocale, preset: .transcription)
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
        let text = try await result
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
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
