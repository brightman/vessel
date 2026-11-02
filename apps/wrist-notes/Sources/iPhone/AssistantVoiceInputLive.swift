import AVFAudio
import Foundation

@MainActor private final class AssistantVoiceRecorder: AssistantVoiceRecording {
    private let recorder = PhoneRecorder()
    private var captureActivityID: UUID?
    var duration: TimeInterval { recorder.duration }
    var level: Float { recorder.inputLevel }
    var onEnded: (() -> Void)? {
        get { recorder.onRecordingEnded }
        set { recorder.onRecordingEnded = newValue }
    }
    func start() async throws {
        // Disposable protected audio; do not collect a location or create a persisted recording session.
        // Keep bulk recording analysis suspended until this short take has been transcribed.
        // PhoneRecorder releases its own microphone lease on stop, before ASR is enqueued.
        captureActivityID = AudioCaptureActivity.begin()
        await recorder.start(maximumDuration: 60, builtInMicrophoneOnly: true)
        try Task.checkCancellation()
        guard recorder.isRecording else {
            if AVAudioApplication.shared.recordPermission == .denied { throw AssistantVoiceInputFailure.microphoneDenied }
            throw AssistantVoiceInputFailure.recording(recorder.errorMessage ?? "无法开始语音输入，请重试。")
        }
    }
    func finish() throws -> URL {
        recorder.stop()
        if let error = recorder.errorMessage {
            if error.contains("中断") || error.contains("意外结束") { throw AssistantVoiceInputFailure.interrupted }
            throw AssistantVoiceInputFailure.recording(error)
        }
        guard let draft = recorder.draft else { throw AssistantVoiceInputFailure.recording("未能保存语音输入，请重新录制。") }
        return draft.fileURL
    }
    func discard() {
        recorder.discard()
        if let captureActivityID { AudioCaptureActivity.end(captureActivityID); self.captureActivityID = nil }
    }
}

extension AssistantVoiceInputModel {
    static func live() -> AssistantVoiceInputModel {
        .init(recorder: AssistantVoiceRecorder(), prepare: { configuration in
            if configuration.engine == .apple {
                switch await AppleSpeechResources().status(locale: configuration.appleLocale) {
                case .ready: break
                case .unavailable(let message), .failed(let message):
                    throw AssistantVoiceInputFailure.recording(message)
                default: throw TranscriptionResourceError.missing
                }
            } else {
                guard configuration.validWhisperLanguage else { throw TranscriptionResourceError.unsupported }
                let validation = Task.detached { try WhisperModelStore().validate(configuration.whisperSize) }
                try await withTaskCancellationHandler { try await validation.value } onCancel: { validation.cancel() }
            }
        }, transcribe: { url, configuration in
            try await LocalTranscriptionService.shared.transcribe(fileURL: url, configuration: configuration)
        })
    }
}
