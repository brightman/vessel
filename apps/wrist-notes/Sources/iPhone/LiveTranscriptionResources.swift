import Foundation

extension TranscriptionResourceClient {
    static func live(store: WhisperModelStore = WhisperModelStore()) -> Self {
        let apple = AppleSpeechResources()
        return .init(languages: { await apple.languages() }, status: { configuration in
            if configuration.engine == .apple { return await apple.status(locale: configuration.appleLocale) }
            let verification = Task.detached {
                (try? store.validate(configuration.whisperSize)) != nil ? SpeechResourceState.ready : .missing
            }
            return await withTaskCancellationHandler { await verification.value }
                onCancel: { verification.cancel() }
        }, download: { configuration, progress in
            if configuration.engine == .apple {
                try await apple.download(locale: configuration.appleLocale, progress: progress)
            } else {
                try await store.download(configuration.whisperSize, progress: progress)
            }
        })
    }
}
