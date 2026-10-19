import Foundation

@main struct TranscriptionSettingsSmoke {
    @MainActor static func main() async throws {
        let defaults = UserDefaults(suiteName: "wristnotes.asr.test.\(UUID())")!
        defaults.set("ja-JP", forKey: "transcriptionLocale")
        let settings = AppSettings(defaults: defaults)
        precondition(settings.transcription.appleLocale == "ja-JP", "migrate existing language")
        let backend = FakeResources()
        let editor = TranscriptionSettingsModel(settings: settings, resources: backend.client)
        await editor.refresh()
        precondition(editor.languages.count == 2 && !editor.canSave)
        editor.startDownload()
        await settle()
        precondition(editor.canSave && editor.state == .ready)
        try editor.save()
        var draft = editor.configuration
        draft.engine = .whisper; draft.whisperSize = .tiny
        editor.configuration = draft
        await editor.refresh()
        precondition(!editor.canSave)
        backend.fail = true
        editor.startDownload(); await settle()
        guard case .failed = editor.state else { fatalError("download failure must be visible") }
        precondition(!editor.canSave)
        backend.fail = false; backend.suspended = true
        editor.startDownload(); await settle()
        editor.configuration.whisperLanguage = "en"
        precondition(editor.isDownloading, "language does not cancel shared Whisper model")
        editor.configuration.whisperSize = .small
        backend.finish()
        await settle()
        precondition(!editor.canSave, "obsolete model completion must not enable save")
        do { try editor.save(); fatalError("saved missing resource") } catch {}
        backend.suspended = false
        editor.startDownload(); await settle()
        precondition(editor.canSave)
        try editor.save()
        let restored = AppSettings(defaults: defaults)
        precondition(restored.transcription.engine == .whisper && restored.transcription.whisperLanguage == "en")
        precondition(restored.transcription.appleLocale == "ja-JP")
        precondition(TranscriptionConfiguration.whisperLanguageCodes.count == 99)
        editor.configuration.whisperSize = .base
        editor.cancel()
        precondition(settings.transcription.whisperSize == .small, "draft must not change saved setting")
        print("Transcription settings: migration, ready/save gate, failure/retry, shared language resource, stale completion, persistence passed")
    }
    static func settle() async { try? await Task.sleep(for: .milliseconds(60)) }
}

@MainActor private final class FakeResources {
    var ready: Set<String> = []
    var fail = false
    var suspended = false
    var continuation: CheckedContinuation<Void, Never>?
    func finish() { continuation?.resume(); continuation = nil }
    var client: TranscriptionResourceClient {
        .init(languages: { [SpeechLanguage(id: "ja-JP", title: "日语"), SpeechLanguage(id: "en-US", title: "英语")] },
              status: { [self] config in ready.contains(config.resourceID) ? .ready : .missing },
              download: { [self] config, progress in
                  if fail { throw TranscriptionResourceError.downloadFailed }
                  progress(.init(fraction: 0.5, completedBytes: 50, totalBytes: 100))
                  if suspended { await withCheckedContinuation { continuation = $0 } }
                  ready.insert(config.resourceID)
              })
    }
}
