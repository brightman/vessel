import AppIntents
import Foundation

/// Resolve widget taps in the containing app, which owns the microphone session.
struct StartWiseLifeRecordingIntent: AudioRecordingIntent, LiveActivityIntent {
    static var title: LocalizedStringResource = "开始录音"
    static var description = IntentDescription("在 WiseLife 开始录音，并显示录音实时活动。")
    static var supportedModes: IntentModes = [.background, .foreground(.dynamic)]
    static var authenticationPolicy: IntentAuthenticationPolicy = .alwaysAllowed

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
#if WISELIFE_RECORDING_WIDGET
        try requireMainAppProcess()
        return .result(dialog: "请打开 WiseLife 开始录音。")
#else
        await WiseLifeRuntime.shared.prepare()
        if WiseLifeRuntime.shared.recording.phase == .idle {
            try await prepareWiseLifeRecordingMicrophone(for: self)
        }
        let result = try await WiseLifeRuntime.shared.perform(.start)
        return .result(dialog: recordingDialog(result))
#endif
    }
#if WISELIFE_RECORDING_WIDGET
    private func requireMainAppProcess() throws {
        throw NSError(domain: "WiseLife.Recording.Intent", code: 2,
                      userInfo: [NSLocalizedDescriptionKey: String(localized: "请打开 WiseLife 开始录音。")])
    }
#endif
}
