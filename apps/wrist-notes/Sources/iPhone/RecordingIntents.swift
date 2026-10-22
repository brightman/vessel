import AppIntents
import AVFAudio
import UIKit

struct ToggleWiseLifeRecordingIntent: AudioRecordingIntent {
    static var title: LocalizedStringResource = "开始／停止录音"
    static var description = IntentDescription("开始 WiseLife 录音；已在录音时，停止并自动保存到本机。适合绑定操作按钮。")
    static var supportedModes: IntentModes = [.background, .foreground(.dynamic)]
    static var authenticationPolicy: IntentAuthenticationPolicy = .alwaysAllowed

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        await WiseLifeRuntime.shared.prepare()
        if WiseLifeRuntime.shared.recording.phase == .idle {
            try await prepareWiseLifeRecordingMicrophone(for: self)
        }
        let result = try await WiseLifeRuntime.shared.perform(.toggle)
        return .result(dialog: recordingDialog(result))
    }
}

struct SaveWiseLifeRecordingIntent: AudioRecordingIntent {
    static var title: LocalizedStringResource = "停止并保存录音"
    static var description = IntentDescription("停止当前的 WiseLife 录音，并自动保存到本机。")
    static var supportedModes: IntentModes = .background
    static var authenticationPolicy: IntentAuthenticationPolicy = .alwaysAllowed

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let result = try await WiseLifeRuntime.shared.perform(.stop)
        return .result(dialog: recordingDialog(result))
    }
}

struct WiseLifeRecordingShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: ToggleWiseLifeRecordingIntent(), phrases: [
            "用\(.applicationName)记此刻", "Toggle recording in \(.applicationName)"
        ], shortTitle: "开始／停止录音", systemImageName: "record.circle")
        AppShortcut(intent: StartWiseLifeRecordingIntent(), phrases: [
            "用\(.applicationName)开始录音", "Start recording in \(.applicationName)"
        ], shortTitle: "开始录音", systemImageName: "mic.fill")
        AppShortcut(intent: SaveWiseLifeRecordingIntent(), phrases: [
            "用\(.applicationName)停止录音", "Stop recording in \(.applicationName)"
        ], shortTitle: "停止并保存录音", systemImageName: "stop.circle")
    }
}

@MainActor
func prepareWiseLifeRecordingMicrophone<I: AppIntent>(for intent: I) async throws {
    if !UIApplication.shared.isProtectedDataAvailable || AVAudioApplication.shared.recordPermission == .undetermined {
        if UIApplication.shared.applicationState != .active {
            try await intent.continueInForeground("请打开 WiseLife，完成首次麦克风授权后开始录音。")
        }
    }
    guard AVAudioApplication.shared.recordPermission != .denied else {
        throw NSError(domain: "WiseLife.Recording.Permission", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: "请在系统设置中允许 WiseLife 使用麦克风，然后重试。"])
    }
    if AVAudioApplication.shared.recordPermission == .undetermined {
        guard await AVAudioApplication.requestRecordPermission() else {
            throw NSError(domain: "WiseLife.Recording.Permission", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "未获得麦克风权限，未开始录音。"])
        }
    }
    try Task.checkCancellation()
}

func recordingDialog(_ outcome: WiseLifeRuntime.Outcome) -> IntentDialog {
    switch outcome {
    case .recording: "正在录音"
    case .saved: "录音已保存"
    case .unchanged: "当前没有进行中的录音"
    }
}
