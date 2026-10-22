import AVFAudio
import SwiftUI

@main
@MainActor
struct WristNotesWatchApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var recorder: WatchRecorder
    @StateObject private var recordingLauncher: WatchRecordingLauncher

    init() {
        let recorder = WatchRecorder()
        _recorder = StateObject(wrappedValue: recorder)
        _recordingLauncher = StateObject(wrappedValue: WatchRecordingLauncher(
            isRecording: { recorder.isRecording },
            permission: {
                switch AVAudioApplication.shared.recordPermission {
                case .granted: return .granted
                case .denied: return .denied
                case .undetermined: return .undetermined
                @unknown default: return .denied
                }
            },
            requestPermission: { completion in
                AVAudioApplication.requestRecordPermission { granted in
                    DispatchQueue.main.async { completion(granted) }
                }
            },
            startRecording: { recorder.start(.long) },
            reportFailure: { failure in
                switch failure {
                case .microphoneDenied: recorder.recordingError = "请在手表设置中允许麦克风访问"
                case .requestExpired: recorder.recordingError = "快捷录音请求已过期，请再次点击录音按钮"
                }
            }
        ))
    }

    var body: some Scene {
        WindowGroup {
            WatchContentView()
                .environmentObject(recorder)
                .onOpenURL { url in
                    recordingLauncher.open(url, phase: launchPhase)
                }
                .onChange(of: scenePhase) { _, _ in
                    recordingLauncher.setPhase(launchPhase)
                }
        }
    }

    private var launchPhase: WatchRecordingLauncher.Phase {
        switch scenePhase {
        case .active: return .active
        case .background: return .background
        case .inactive: return .inactive
        @unknown default: return .background
        }
    }
}
