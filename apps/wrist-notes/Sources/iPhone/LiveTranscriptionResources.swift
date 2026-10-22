import Foundation

extension TranscriptionResourceClient {
    static func live(store: WhisperModelStore = WhisperModelStore(), speakers: SpeakerModelStore = SpeakerModelStore(),
                     identity: VoiceIdentityModelStore = VoiceIdentityModelStore()) -> Self {
        let apple = AppleSpeechResources()
        return .init(languages: { await apple.languages() }, status: { configuration in
            if configuration.engine == .apple {
                let state = await apple.status(locale: configuration.appleLocale)
                guard state == .ready else { return state }
            }
            let verification = Task.detached {
                if configuration.engine == .whisper, (try? store.validate(configuration.whisperSize)) == nil { return SpeechResourceState.missing }
                return (try? speakers.validate()) != nil && (try? identity.validate()) != nil ? SpeechResourceState.ready : .missing
            }
            return await withTaskCancellationHandler { await verification.value }
                onCancel: { verification.cancel() }
        }, download: { configuration, progress in
            if configuration.engine == .apple {
                try await apple.download(locale: configuration.appleLocale) { update in
                    // System language packs do not expose a stable byte total.
                    progress(.init(fraction: update.fraction.map { $0 * 0.8 }))
                }
                try Task.checkCancellation()
                try await speakers.download { update in
                    progress(.init(fraction: update.fraction.map { 0.8 + $0 * 0.12 }))
                }
                try Task.checkCancellation()
                try await identity.download { update in
                    progress(.init(fraction: update.fraction.map { 0.92 + $0 * 0.08 }))
                }
            } else {
                let asrBytes = try store.files(for: configuration.whisperSize).reduce(Int64(0)) { $0 + $1.bytes }
                let speakerBytes = speakers.downloadBytes
                let total = asrBytes + speakerBytes + identity.downloadBytes
                try await store.download(configuration.whisperSize) { update in
                    let done = update.completedBytes ?? 0
                    progress(.init(fraction: Double(done) / Double(max(1, total)), completedBytes: done, totalBytes: total))
                }
                try Task.checkCancellation()
                try await speakers.download { update in
                    let done = asrBytes + (update.completedBytes ?? 0)
                    progress(.init(fraction: Double(done) / Double(max(1, total)), completedBytes: done, totalBytes: total))
                }
                try Task.checkCancellation()
                try await identity.download { update in
                    let done = asrBytes + speakerBytes + (update.completedBytes ?? 0)
                    progress(.init(fraction: Double(done) / Double(max(1, total)), completedBytes: done, totalBytes: total))
                }
            }
        })
    }
}
