import AVFAudio
import Combine
import Foundation

struct PhoneRecordingDraft: Identifiable {
    let id = UUID()
    let fileURL: URL
    let duration: TimeInterval
    let capturedAt: Date
}

@MainActor
final class PhoneRecorder: NSObject, ObservableObject, AVAudioRecorderDelegate {
    @Published private(set) var isRecording = false
    @Published private(set) var requestingPermission = false
    @Published private(set) var duration: TimeInterval = 0
    @Published private(set) var draft: PhoneRecordingDraft?
    @Published var errorMessage: String?
    private var recorder: AVAudioRecorder?
    private var timer: Timer?
    private var interruption: NSObjectProtocol?
    private var version = 0
    private var capturedAt = Date.now

    override init() {
        super.init()
        interruption = NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification,
            object: nil, queue: .main) { [weak self] notification in
                guard let value = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                      value == AVAudioSession.InterruptionType.began.rawValue else { return }
                Task { @MainActor [weak self] in
                    guard let self, self.isRecording else { return }
                    self.stop()
                    self.errorMessage = "录音被系统中断，已保留录制的部分，请保存。"
                }
            }
    }

    deinit {
        if let interruption { NotificationCenter.default.removeObserver(interruption) }
        timer?.invalidate()
    }

    func start() async {
        guard !isRecording, !requestingPermission, draft == nil else { return }
        version += 1; let request = version
        requestingPermission = true; errorMessage = nil
        let allowed = await AVAudioApplication.requestRecordPermission()
        guard request == version else { return }
        requestingPermission = false
        guard allowed else { errorMessage = "请在系统设置中允许 WiseNote 使用麦克风。"; return }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("phone-recording-\(UUID().uuidString).m4a")
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetoothHFP])
            try session.setActive(true)
            let audio = try AVAudioRecorder(url: url, settings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 44_100,
                AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 64_000
            ])
            audio.delegate = self
            guard audio.record() else { throw CocoaError(.fileWriteUnknown) }
            capturedAt = .now
            recorder = audio; duration = 0; isRecording = true
            timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self else { return }; self.duration = self.recorder?.currentTime ?? self.duration
                }
            }
        } catch {
            try? FileManager.default.removeItem(at: url)
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            errorMessage = "无法开始录音：\(error.localizedDescription)"
        }
    }

    func stop() {
        guard let recorder, isRecording else { return }
        duration = max(duration, recorder.currentTime)
        let url = recorder.url
        self.recorder = nil; isRecording = false
        timer?.invalidate(); timer = nil; recorder.stop()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        if duration > 0.2 { draft = PhoneRecordingDraft(fileURL: url, duration: duration, capturedAt: capturedAt) }
        else { try? FileManager.default.removeItem(at: url); errorMessage = "录音太短，请再说一句。" }
    }

    func discard() {
        version += 1; requestingPermission = false
        let url = recorder?.url
        isRecording = false; recorder?.stop(); recorder = nil; timer?.invalidate(); timer = nil
        if let url { try? FileManager.default.removeItem(at: url) }
        if let draft { try? FileManager.default.removeItem(at: draft.fileURL) }
        draft = nil; duration = 0; errorMessage = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    func didSave() { draft = nil; duration = 0; errorMessage = nil }

    nonisolated func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        Task { @MainActor [weak self] in
            guard let self, self.recorder === recorder, self.isRecording else { return }
            self.stop()
            if !flag { self.errorMessage = "录音意外结束，请检查并保存已录制的部分。" }
        }
    }

    nonisolated func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: Error?) {
        Task { @MainActor [weak self] in
            guard let self, self.recorder === recorder, self.isRecording else { return }
            self.stop()
            self.errorMessage = "音频编码中断，已保留录制的部分。保存后请回听检查。"
        }
    }
}
