import AppIntents
import Foundation

/// LiveActivityIntent ensures the button executes in the main app's process.
struct StopWiseLifeRecordingIntent: AudioRecordingIntent, LiveActivityIntent {
    static var title: LocalizedStringResource = "停止这段录音"
    static var isDiscoverable: Bool = false
    static var supportedModes: IntentModes = .background
    static var authenticationPolicy: IntentAuthenticationPolicy = .alwaysAllowed

    @Parameter(title: "录音标识") var sessionID: String

    init() {}
    init(sessionID: String) { self.sessionID = sessionID }

    @MainActor
    func perform() async throws -> some IntentResult {
        guard let id = UUID(uuidString: sessionID) else {
            throw NSError(domain: "WiseLife.Recording.Intent", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "录音标识无效，请在 WiseLife 中查看录音状态。"])
        }
#if WISELIFE_RECORDING_WIDGET
        // The system resolves this shared intent in the containing app. If routing
        // fails, never acknowledge a stop that didn't reach the recorder.
        try requireMainAppProcess()
#else
        try await WiseLifeRuntime.shared.perform(.stop, expectedSessionID: id)
#endif
        return .result()
    }

#if WISELIFE_RECORDING_WIDGET
    private func requireMainAppProcess() throws {
        throw NSError(domain: "WiseLife.Recording.Intent", code: 2,
                      userInfo: [NSLocalizedDescriptionKey: "请打开 WiseLife 结束并保存录音。"])
    }
#endif
}
