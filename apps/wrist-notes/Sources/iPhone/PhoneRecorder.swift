import AVFAudio
import Combine
import Foundation

/// Process-wide, read-only capture snapshot; attempt tokens reject duplicate/late release.
/// Foundation-only bookkeeping is also used by isolated tests without opening the microphone.
enum AudioCaptureActivity {
    private static let lock = NSLock()
    private static var identifiers = Set<UUID>()
    static var activeIDs: Set<UUID> { lock.lock(); defer { lock.unlock() }; return identifiers }
    static func begin() -> UUID {
        let id = UUID()
        lock.lock(); identifiers.insert(id); lock.unlock()
        NotificationCenter.default.post(name:.init("WiseLife.AudioCaptureActivity"),object:nil,userInfo:["id":id,"active":true])
        return id
    }
    static func end(_ id: UUID) {
        lock.lock(); let existed = identifiers.remove(id) != nil; lock.unlock()
        if existed { NotificationCenter.default.post(name:.init("WiseLife.AudioCaptureActivity"),object:nil,userInfo:["id":id,"active":false]) }
    }
}

@MainActor
final class PhoneRecorder: NSObject, ObservableObject, AVAudioRecorderDelegate, PhoneRecordingEngine {
    private static weak var microphoneOwner: PhoneRecorder?
    static let maximumChunkDuration: TimeInterval = 600
    private let draftStore: PhoneRecordingDraftStore
    var recordingWarning: String? { errorMessage }
    var onRecordingEnded: (() -> Void)?
    var onDraftUpdated: ((PhoneRecordingDraft) -> Void)?
    var onChunkSealed: ((PhoneRecordingDraft, PhoneRecordingChunkFile, URL) -> Void)?
    private var stagedDraft: PhoneRecordingDraft?
    private var captureActivityID: UUID?
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
    private let captureLocation = CaptureLocationService()
    private var capturedLocation: CaptureLocation?
    private var measuresCompletedFile = false
    private var currentChunkStartedAt = Date.now
    private var configuredBuiltInMicrophoneOnly = false

    init(draftStore: PhoneRecordingDraftStore = PhoneRecordingDraftStore()) {
        self.draftStore = draftStore
        super.init()
        interruption = NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification,
            object: nil, queue: .main) { [weak self] notification in
                guard let value = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                      value == AVAudioSession.InterruptionType.began.rawValue else { return }
                Task { @MainActor [weak self] in
                    guard let self, self.isRecording else { return }
                    self.stop()
                    self.errorMessage = "录音被系统中断，已保留中断前录制的部分，请回听检查。"
                    self.onRecordingEnded?()
                }
            }
    }

    deinit {
        if let interruption { NotificationCenter.default.removeObserver(interruption) }
        timer?.invalidate()
        if let captureActivityID { AudioCaptureActivity.end(captureActivityID) }
    }

    func start(maximumDuration: TimeInterval? = nil, builtInMicrophoneOnly: Bool = false) async {
        guard !Task.isCancelled, !isRecording, !requestingPermission, draft == nil else { return }
        guard Self.microphoneOwner == nil || Self.microphoneOwner === self else {
            errorMessage = "麦克风正在用于另一段录音，请先完成它。"; return
        }
        Self.microphoneOwner = self
        let activityID = AudioCaptureActivity.begin()
        captureActivityID = activityID
        version += 1; let request = version
        requestingPermission = true; errorMessage = nil
        let allowed = await withTaskCancellationHandler {
            await AVAudioApplication.requestRecordPermission()
        } onCancel: { AudioCaptureActivity.end(activityID) }
        guard request == version else { return }
        requestingPermission = false
        guard !Task.isCancelled else { releaseMicrophone(); return }
        guard allowed else { releaseMicrophone(); errorMessage = "请在系统设置中允许 WiseLife 使用麦克风。"; return }
        let chunked = stagedDraft?.isChunked == true
        configuredBuiltInMicrophoneOnly = builtInMicrophoneOnly
        let url = stagedDraft?.fileURL ?? FileManager.default.temporaryDirectory.appendingPathComponent("phone-recording-\(UUID().uuidString).m4a")
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .default, options: builtInMicrophoneOnly ? [.defaultToSpeaker] : [.defaultToSpeaker, .allowBluetoothHFP])
            try session.setActive(true)
            if !builtInMicrophoneOnly { try session.setAllowHapticsAndSystemSoundsDuringRecording(true) }
            if builtInMicrophoneOnly {
                guard let microphone = session.availableInputs?.first(where: { $0.portType == .builtInMic }) else {
                    throw CocoaError(.featureUnsupported)
                }
                try session.setPreferredInput(microphone)
            } else {
                try session.setPreferredInput(nil)
            }
            if chunked { try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true) }
            let limit = chunked ? Self.maximumChunkDuration : maximumDuration
            let audio = try makeRecorder(at: url, chunked: chunked, builtInMicrophoneOnly: builtInMicrophoneOnly, maximumDuration: limit)
            recorder = audio
            measuresCompletedFile = true
            capturedAt = stagedDraft?.capturedAt ?? .now
            currentChunkStartedAt = capturedAt.addingTimeInterval(stagedDraft?.chunks.reduce(0) { $0 + $1.duration } ?? 0)
            if let staged = stagedDraft {
                let updated = PhoneRecordingDraft(id: staged.id, fileURL: staged.fileURL, duration: staged.duration, capturedAt: capturedAt,
                    location: staged.location, chunks: staged.chunks, activeChunkOrdinal: staged.activeChunkOrdinal,
                    isChunked: staged.isChunked, timeZoneIdentifier: staged.timeZoneIdentifier)
                stagedDraft = updated
                onDraftUpdated?(updated)
            }
            recorder = audio; duration = 0; isRecording = true
            capturedLocation = nil
            if !builtInMicrophoneOnly {
                captureLocation.begin(at: capturedAt, source: .phoneRecording) { [weak self] point in
                    guard let self, self.isRecording else { return }
                    self.capturedLocation = point
                    // Persist immediately so interruptions/process recovery retain the point.
                    if var pending = self.stagedDraft {
                        pending.location = point
                        self.stagedDraft = pending
                        self.onDraftUpdated?(pending)
                    }
                }
            }
            timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.duration = (self.stagedDraft?.duration ?? 0) + (self.recorder?.currentTime ?? 0)
                }
            }
        } catch {
            recorder?.stop(); recorder = nil
            try? FileManager.default.removeItem(at: url)
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            releaseMicrophone()
            errorMessage = "无法开始录音：\(error.localizedDescription)"
        }
    }

    func stop() {
        if requestingPermission { version += 1; requestingPermission = false; releaseMicrophone(); return }
        guard let recorder, isRecording else { return }
        captureLocation.cancel()
        duration = (stagedDraft?.duration ?? 0) + recorder.currentTime
        let url = recorder.url
        self.recorder = nil; isRecording = false
        timer?.invalidate(); timer = nil; recorder.stop()
        if measuresCompletedFile { duration = Self.completedFileDuration(url: url, fallback: duration) }
        measuresCompletedFile = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        releaseMicrophone()
        if stagedDraft?.isChunked == true {
            do {
                if let staged = stagedDraft {
                    let sealed = try seal(url: url, in: staged, at: currentChunkStartedAt, startNextChunk: false)
                    stagedDraft = sealed
                    draft = sealed
                    onDraftUpdated?(sealed)
                    duration = sealed.duration
                }
            } catch {
                errorMessage = "录音片段尚未完成封存，已保留原始文件，请重试保存。"
                if let staged = stagedDraft { draft = staged }
            }
        } else if duration > 0.2 { draft = PhoneRecordingDraft(id: stagedDraft?.id ?? UUID(), fileURL: url, duration: duration, capturedAt: capturedAt, location: capturedLocation) }
        else { try? FileManager.default.removeItem(at: url); errorMessage = "录音太短，请再说一句。" }
    }

    /// Read finalized frames, since currentTime can reset before the automatic-stop delegate runs.
    static func completedFileDuration(url: URL, fallback: TimeInterval) -> TimeInterval {
        guard let audio = try? AVAudioFile(forReading: url), audio.processingFormat.sampleRate > 0 else { return fallback }
        let actual = Double(audio.length) / audio.processingFormat.sampleRate
        return actual.isFinite && actual > 0 ? actual : fallback
    }

    func discard() {
        captureLocation.cancel(); capturedLocation = nil
        version += 1; requestingPermission = false
        let ownedMicrophone = Self.microphoneOwner === self
        releaseMicrophone()
        let url = recorder?.url
        isRecording = false; recorder?.stop(); recorder = nil; timer?.invalidate(); timer = nil
        if let stagedDraft { try? draftStore.remove(stagedDraft) }
        else {
            if let url { try? FileManager.default.removeItem(at: url) }
            if let draft { try? FileManager.default.removeItem(at: draft.fileURL) }
        }
        draft = nil; duration = 0; errorMessage = nil; measuresCompletedFile = false
        if ownedMicrophone { try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation) }
        stagedDraft = nil
    }

    func didSave() { draft = nil; duration = 0; errorMessage = nil }

    nonisolated func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        Task { @MainActor [weak self] in
            guard let self, self.recorder === recorder, self.isRecording else { return }
            if flag, self.stagedDraft?.isChunked == true {
                self.rotateSealedChunk(recorder)
                return
            }
            self.stop()
            if !flag { self.errorMessage = "录音意外结束，已保留录制的部分，请回听检查。" }
            self.onRecordingEnded?()
        }
    }

    nonisolated func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: Error?) {
        Task { @MainActor [weak self] in
            guard let self, self.recorder === recorder, self.isRecording else { return }
            self.stop()
            self.errorMessage = "音频编码中断，已保留录制的部分，请回听检查。"
            self.onRecordingEnded?()
        }
    }
    private func releaseMicrophone() {
        if Self.microphoneOwner === self { Self.microphoneOwner = nil }
        if let captureActivityID { AudioCaptureActivity.end(captureActivityID); self.captureActivityID = nil }
    }

    private func makeRecorder(at url: URL, chunked: Bool, builtInMicrophoneOnly: Bool,
                              maximumDuration: TimeInterval?) throws -> AVAudioRecorder {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: chunked ? 16_000 : 44_100,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: chunked ? 32_000 : 64_000
        ]
        let audio = try AVAudioRecorder(url:url,settings:settings)
        audio.delegate = self
        guard audio.prepareToRecord() else { throw CocoaError(.fileWriteUnknown) }
        if builtInMicrophoneOnly {
            try FileManager.default.setAttributes([.protectionKey:FileProtectionType.complete],ofItemAtPath:url.path)
            var protectedURL=url; var values=URLResourceValues(); values.isExcludedFromBackup=true
            try protectedURL.setResourceValues(values)
        }
        let started: Bool
        if let maximumDuration,maximumDuration.isFinite,maximumDuration > 0 { started=audio.record(forDuration:maximumDuration) }
        else { started=audio.record() }
        guard started else { throw CocoaError(.fileWriteUnknown) }
        return audio
    }

    private func seal(url:URL,in draft:PhoneRecordingDraft,at date:Date,startNextChunk:Bool) throws -> PhoneRecordingDraft {
        let info=try RecordingAudioFile.inspect(url)
        guard info.sampleRate == 16_000,info.channelCount == 1,info.formatID == kAudioFormatMPEG4AAC,
              let ordinal=draft.activeChunkOrdinal else { throw CocoaError(.fileReadCorruptFile) }
        let maximumFrames=Int64(Self.maximumChunkDuration*info.sampleRate)
        let frames=min(info.frameCount,maximumFrames)
        let offset=draft.chunks.reduce(0) { $0+$1.duration }
        let chunk=PhoneRecordingChunkFile(id:UUID(),ordinal:ordinal,capturedAt:date,sessionStartOffset:offset,
            frameCount:frames,sampleRate:info.sampleRate,byteCount:info.byteCount,sha256:info.sha256,
            location:capturedLocation ?? draft.location)
        let updated=try draftStore.seal(chunk,in:draft,startNextChunk:startNextChunk)
        onChunkSealed?(updated,chunk,url)
        return updated
    }

    private func rotateSealedChunk(_ finished:AVAudioRecorder) {
        guard let staged=stagedDraft,staged.isChunked else { return }
        let endedAt=currentChunkStartedAt.addingTimeInterval(max(0,finished.currentTime))
        do {
            let sealed=try seal(url:finished.url,in:staged,at:currentChunkStartedAt,startNextChunk:true)
            stagedDraft=sealed; duration=sealed.duration; onDraftUpdated?(sealed)
            currentChunkStartedAt=endedAt
            let next=try makeRecorder(at:sealed.fileURL,chunked:true,builtInMicrophoneOnly:configuredBuiltInMicrophoneOnly,
                maximumDuration:Self.maximumChunkDuration)
            recorder=next; measuresCompletedFile=true
        } catch {
            captureLocation.cancel(); timer?.invalidate(); timer=nil; isRecording=false; recorder=nil
            try? AVAudioSession.sharedInstance().setActive(false,options:.notifyOthersOnDeactivation)
            releaseMicrophone()
            errorMessage="录音片段封存失败，已保留此前片段，请重试保存。"
            if let stagedDraft {
                let recovered=(try? recoverDraft(stagedDraft)) ?? (try? draftStore.close(stagedDraft)) ?? stagedDraft
                self.stagedDraft=recovered; self.draft=recovered; onDraftUpdated?(recovered); duration=recovered.duration
            }
            onRecordingEnded?()
        }
    }

    func recoveredDuration(for draft:PhoneRecordingDraft) -> TimeInterval {
        guard draft.isChunked else { return max(draft.duration,recoveredDuration(at:draft.fileURL)) }
        guard draft.activeChunkOrdinal != nil else { return draft.duration }
        return draft.duration + Self.completedFileDuration(url:draft.fileURL,fallback:0)
    }

    func recoverDraft(_ draft:PhoneRecordingDraft) throws -> PhoneRecordingDraft {
        guard draft.isChunked else {
            return PhoneRecordingDraft(id:draft.id,fileURL:draft.fileURL,duration:recoveredDuration(for:draft),capturedAt:draft.capturedAt,location:draft.location)
        }
        guard let ordinal=draft.activeChunkOrdinal,FileManager.default.fileExists(atPath:draft.fileURL.path) else {
            return try draft.activeChunkOrdinal == nil ? draft : draftStore.close(draft)
        }
        guard let info=try? RecordingAudioFile.inspect(draft.fileURL),info.sampleRate == 16_000,
              info.channelCount == 1,info.formatID == kAudioFormatMPEG4AAC else { return try draftStore.close(draft) }
        let frames=min(info.frameCount,Int64(Self.maximumChunkDuration*info.sampleRate))
        let chunk=PhoneRecordingChunkFile(id:UUID(),ordinal:ordinal,capturedAt:draft.capturedAt.addingTimeInterval(draft.duration),
            sessionStartOffset:draft.duration,frameCount:frames,sampleRate:info.sampleRate,byteCount:info.byteCount,sha256:info.sha256,
            location:draft.location)
        let updated=try draftStore.seal(chunk,in:draft,startNextChunk:false)
        onChunkSealed?(updated,chunk,draft.fileURL)
        return updated
    }
    func startRecording(_ draft: PhoneRecordingDraft) async throws {
        guard !isRecording, !requestingPermission, self.draft == nil else {
            throw NSError(domain: "WiseLife.Recording", code: 2, userInfo: [NSLocalizedDescriptionKey: "请先完成当前录音。"])
        }
        stagedDraft = draft
        await start()
        guard isRecording else {
            stagedDraft = nil
            throw NSError(domain: "WiseLife.Recording", code: 3, userInfo: [NSLocalizedDescriptionKey: errorMessage ?? "无法开始录音。"])
        }
    }
    func stopRecording() -> PhoneRecordingDraft? { stop(); return draft }
    func discardRecording() { discard() }
    func recordingWasSaved() { didSave(); stagedDraft = nil }
    func recoveredDuration(at url: URL) -> TimeInterval { Self.completedFileDuration(url: url, fallback: 0) }

}
