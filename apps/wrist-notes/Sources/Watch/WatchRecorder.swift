import AVFAudio
import Combine
import Foundation
import os
import WatchConnectivity
import WatchKit

final class WatchRecorder: NSObject, ObservableObject, AVAudioRecorderDelegate, WCSessionDelegate {
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.vessel.wristnotes.watchkitapp", category: "WatchConnectivity")
    @Published private(set) var isRecording = false
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var pending: [PendingRecording] = []
    var pendingCount: Int { pending.filter { !$0.uploaded }.count }
    @Published var message: String?
    @Published var recordingError: String?
    @Published private(set) var connectivityStatus = "正在连接 iPhone…"

    private let directory: URL
    private let indexURL: URL
    private var recorder: AVAudioRecorder?
    private var timer: Timer?
    private var startedAt: Date?
    private var startUptime: TimeInterval?
    private var interruptionObserver: NSObjectProtocol?
    private var currentID: UUID?
    private var currentKind: RecordingKind?
    private var queuedIDs: Set<UUID> = []
    private var missingAudioFileCount = 0
    private var permissionRequestInFlight = false
    private var thoughtPressActive = false

    override init() {
        directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Recordings", isDirectory: true)
        indexURL = directory.appendingPathComponent("pending.json")
        super.init()
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
        ) { [weak self] notification in
            guard let value = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  AVAudioSession.InterruptionType(rawValue: value) == .began,
                  self?.isRecording == true else { return }
            self?.stop()
            self?.message = "录音被系统中断，已保存现有内容"
        }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: indexURL.path) {
                pending = try JSONDecoder().decode([PendingRecording].self, from: Data(contentsOf: indexURL))
            }
            recoverUnfinishedAudio()
        } catch { message = "无法打开录音目录：\(error.localizedDescription)" }
        if WCSession.isSupported() {
            WCSession.default.delegate = self
            logger.notice("Watch session activating; companion installed: \(WCSession.default.isCompanionAppInstalled, privacy: .public)")
            WCSession.default.activate()
        } else {
            logger.error("Watch session is not supported")
        }
    }

    func start(_ kind: RecordingKind) {
        guard !isRecording, !permissionRequestInFlight else { return }
        recordingError = nil
        if kind == .thought { thoughtPressActive = true }
        switch AVAudioApplication.shared.recordPermission {
        case .granted: beginRecording(kind)
        case .denied: recordingError = "请在手表设置中允许麦克风访问"
        case .undetermined:
            permissionRequestInFlight = true
            AVAudioApplication.requestRecordPermission { [weak self] granted in
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.permissionRequestInFlight = false
                    if !granted {
                        self.recordingError = "麦克风权限未授予"
                    } else if kind == .long || self.thoughtPressActive {
                        self.beginRecording(kind)
                    } else {
                        self.message = "已获得麦克风权限，请再次按住说话"
                    }
                }
            }
        @unknown default: recordingError = "无法确认麦克风权限"
        }
    }

    func stop() {
        guard isRecording, let id = currentID, let kind = currentKind, let startedAt else { return }
        var duration = recorder?.currentTime ?? elapsed
        let endedAt = Date()
        let endUptime = ProcessInfo.processInfo.systemUptime
        let fileURL = recorder?.url
        recorder?.delegate = nil
        recorder?.stop()
        // currentTime may reset after an interruption; the finalized file owns the actual audio length.
        if let fileURL, let file = try? AVAudioFile(forReading: fileURL), file.processingFormat.sampleRate > 0 {
            duration = Double(file.length) / file.processingFormat.sampleRate
        }
        let clock = startUptime.map { RecordingClock(startedAt: startedAt, endedAt: endedAt,
            startUptime: $0, endUptime: endUptime, audioDuration: duration) }
        recorder = nil
        timer?.invalidate()
        timer = nil
        isRecording = false
        elapsed = 0
        currentID = nil
        currentKind = nil
        self.startedAt = nil
        startUptime = nil
        thoughtPressActive = false
        WKInterfaceDevice.current().play(.stop)
        var item = PendingRecording(id: id, kind: kind, capturedAt: startedAt, duration: duration)
        item.recordingClock = clock
        pending.append(item)
        do {
            try persistPending()
            logger.notice("Saved recording \(id.uuidString, privacy: .public); pending count: \(self.pendingCount, privacy: .public)")
            queuePending()
            message = "已保存在手表，等待传到 iPhone"
        } catch { message = "录音已保存，但列表写入失败：\(error.localizedDescription)" }
    }

    func retryTransfers() { queuePending() }

    func delete(_ id: UUID) {
        guard pending.contains(where: { $0.id == id }) else { return }
        if WCSession.isSupported() {
            for transfer in WCSession.default.outstandingFileTransfers
            where transfer.file.metadata?["id"] as? String == id.uuidString {
                transfer.cancel()
            }
        }
        let original = pending
        pending.removeAll { $0.id == id }
        do {
            try persistPending()
            try? FileManager.default.removeItem(at: directory.appendingPathComponent("\(id.uuidString).m4a"))
            queuedIDs.remove(id)
            updateConnectivityStatus()
        } catch { pending = original; message = "删除失败：\(error.localizedDescription)" }
    }

    func cancelThought() {
        thoughtPressActive = false
        guard isRecording, currentKind == .thought else { return }
        let file = recorder?.url
        recorder?.delegate = nil
        recorder?.stop()
        recorder = nil
        timer?.invalidate()
        timer = nil
        isRecording = false
        elapsed = 0
        currentID = nil
        currentKind = nil
        startedAt = nil
        startUptime = nil
        if let file { try? FileManager.default.removeItem(at: file) }
        WKInterfaceDevice.current().play(.failure)
        message = "已取消闪念"
    }

    @discardableResult
    func releaseThought() -> Bool {
        thoughtPressActive = false
        if isRecording && currentKind == .thought {
            if (recorder?.currentTime ?? 0) < 0.3 {
                cancelThought()
                message = "闪念太短，未保存"
            } else { stop(); return true }
        }
        return false
    }

    private func beginRecording(_ kind: RecordingKind) {
        guard !isRecording else { return }
        let id = UUID()
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .default)
            try session.setActive(true)
            let destination = directory.appendingPathComponent("\(id.uuidString).m4a")
            let settings: [String: Any] = [
                AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
                AVSampleRateKey: 16_000,
                AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: 32_000
            ]
            let active = try AVAudioRecorder(url: destination, settings: settings)
            active.delegate = self
            guard active.record() else { throw NSError(domain: "WristNotes", code: 1) }
            recorder = active
            currentID = id
            currentKind = kind
            // Anchor audio zero to wall time, checked against monotonic elapsed time at stop.
            let audioOffset = active.currentTime
            startedAt = Date().addingTimeInterval(-audioOffset)
            startUptime = ProcessInfo.processInfo.systemUptime - audioOffset
            isRecording = true
            WKInterfaceDevice.current().play(.start)
            message = nil
            timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                guard let self else { return }
                self.elapsed = self.recorder?.currentTime ?? 0
            }
        } catch { recordingError = "录音启动失败：\(error.localizedDescription)" }
    }

    private func queuePending() {
        guard WCSession.isSupported() else {
            updateConnectivityStatus()
            return
        }
        let session = WCSession.default
        updateConnectivityStatus()
        logger.notice("Queue check; activation: \(session.activationState.rawValue, privacy: .public), companion installed: \(session.isCompanionAppInstalled, privacy: .public), pending: \(self.pendingCount, privacy: .public)")
        guard session.activationState == .activated else {
            logger.notice("Deferring transfers until Watch session activation")
            return
        }
        guard session.isCompanionAppInstalled else {
            logger.notice("Deferring transfers until companion app installation")
            return
        }
#if !targetEnvironment(simulator)
        for transfer in session.outstandingFileTransfers {
            if let id = transfer.file.metadata?["id"] as? String, let uuid = UUID(uuidString: id) {
                queuedIDs.insert(uuid)
            }
        }
#endif
        missingAudioFileCount = 0
        for item in pending where !item.uploaded && !queuedIDs.contains(item.id) {
            let file = directory.appendingPathComponent("\(item.id.uuidString).m4a")
            guard FileManager.default.fileExists(atPath: file.path) else {
                missingAudioFileCount += 1
                continue
            }
#if targetEnvironment(simulator)
            guard session.isReachable else {
                message = "请保持 iPhone 模拟器中的语音笔记 App 打开后重试"
                continue
            }
            queuedIDs.insert(item.id)
            sendSimulatorRecording(item, file: file, session: session)
#else
            var metadata: [String: Any] = [
                "id": item.id.uuidString,
                "kind": item.kind.rawValue,
                "capturedAt": item.capturedAt,
                "duration": item.duration
            ]
            if let clock = item.recordingClock { metadata["recordingClock"] = try? JSONEncoder().encode(clock) }
            session.transferFile(file, metadata: metadata)
            queuedIDs.insert(item.id)
            logger.notice("Queued recording file \(item.id.uuidString, privacy: .public)")
#endif
        }
        updateConnectivityStatus()
    }

#if targetEnvironment(simulator)
    private func sendSimulatorRecording(_ item: PendingRecording, file: URL, session: WCSession) {
        do {
            let audio = try Data(contentsOf: file, options: .mappedIfSafe)
            let chunks = SimulatorAudioChunks.split(audio)
            guard !chunks.isEmpty else { throw SimulatorTransferError.emptyFile }

            func sendChunk(_ index: Int) {
                var message: [String: Any] = [
                    "type": "simulator-audio-chunk",
                    "id": item.id.uuidString,
                    "kind": item.kind.rawValue,
                    "capturedAt": item.capturedAt,
                    "duration": item.duration,
                    "chunkIndex": index,
                    "chunkCount": chunks.count,
                    "audioChunk": chunks[index]
                ]
                if let clock = item.recordingClock { message["recordingClock"] = try? JSONEncoder().encode(clock) }
                session.sendMessage(message, replyHandler: { [weak self] reply in
                    guard reply["accepted"] as? Bool == true else {
                        self?.finishSimulatorTransfer(item.id, error: SimulatorTransferError.rejected)
                        return
                    }
                    guard index + 1 < chunks.count else {
                        DispatchQueue.main.async {
                            guard let self else { return }
                            self.queuedIDs.remove(item.id)
                            if self.pending.first(where: { $0.id == item.id })?.uploaded != true {
                                self.message = "已传输，等待 iPhone 确认保存"
                            }
                            self.updateConnectivityStatus()
                        }
                        return
                    }
                    sendChunk(index + 1)
                }, errorHandler: { [weak self] error in
                    self?.finishSimulatorTransfer(item.id, error: error)
                })
            }

            sendChunk(0)
        } catch {
            finishSimulatorTransfer(item.id, error: error)
        }
    }

    private func finishSimulatorTransfer(_ id: UUID, error: Error) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.queuedIDs.remove(id)
            self.message = "模拟器传输待重试：\(error.localizedDescription)"
            self.logger.error("Simulator audio transfer failed for \(id.uuidString, privacy: .public): \(error.localizedDescription, privacy: .public)")
            self.updateConnectivityStatus()
        }
    }

    private enum SimulatorTransferError: LocalizedError {
        case emptyFile
        case rejected

        var errorDescription: String? {
            switch self {
            case .emptyFile: "录音文件为空"
            case .rejected: "iPhone 未接受录音分片"
            }
        }
    }
#endif

    private func updateConnectivityStatus() {
        let supported = WCSession.isSupported()
        let session = supported ? WCSession.default : nil
        connectivityStatus = WatchConnectivityStatus.message(
            isSupported: supported,
            isActivated: session?.activationState == .activated,
            companionInstalled: session?.isCompanionAppInstalled == true,
            pendingCount: pendingCount,
            transferCount: queuedIDs.count,
            missingFileCount: missingAudioFileCount
        )
    }

    private func persistPending() throws {
        try JSONEncoder().encode(pending).write(to: indexURL, options: .atomic)
    }

    private func recoverUnfinishedAudio() {
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.creationDateKey]) else { return }
        for file in files where file.pathExtension.lowercased() == "m4a" {
            guard let id = UUID(uuidString: file.deletingPathExtension().lastPathComponent),
                  !pending.contains(where: { $0.id == id }) else { continue }
            let date = (try? file.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .now
            pending.append(PendingRecording(id: id, kind: .long, capturedAt: date, duration: 0))
        }
        try? persistPending()
    }

    func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        DispatchQueue.main.async { [weak self] in if self?.isRecording == true { self?.stop() } }
    }

    deinit { if let interruptionObserver { NotificationCenter.default.removeObserver(interruptionObserver) } }

    func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        guard let raw = userInfo["ack"] as? String, let id = UUID(uuidString: raw) else { return }
        markUploaded(id)
    }

    func session(_ session: WCSession, didReceiveMessage message: [String: Any] = [:]) {
        guard let raw = message["ack"] as? String, let id = UUID(uuidString: raw) else { return }
        markUploaded(id)
    }

    private func markUploaded(_ id: UUID) {
        logger.notice("Received phone save acknowledgement for \(id.uuidString, privacy: .public)")
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            guard let index = self.pending.firstIndex(where: { $0.id == id }) else { return }
            self.pending[index].uploaded = true
            do {
                try self.persistPending()
                self.queuedIDs.remove(id)
                self.message = "已传到 iPhone"
                self.updateConnectivityStatus()
            } catch { self.pending[index].uploaded = false; self.message = "上传状态保存失败：\(error.localizedDescription)" }
        }
    }

    func session(_ session: WCSession, didFinish fileTransfer: WCSessionFileTransfer, error: Error?) {
        guard let raw = fileTransfer.file.metadata?["id"] as? String,
              let id = UUID(uuidString: raw) else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.queuedIDs.remove(id)
            self.logger.notice("File transfer finished for \(id.uuidString, privacy: .public); error: \(error != nil, privacy: .public)")
            if let error { self.message = "传输待重试：\(error.localizedDescription)" }
            else { self.message = "已传输，等待 iPhone 确认保存" }
            self.updateConnectivityStatus()
        }
    }

    func session(_ session: WCSession, activationDidCompleteWith state: WCSessionActivationState, error: Error?) {
        DispatchQueue.main.async { [weak self] in
            self?.logger.notice("Watch session activation completed with state \(state.rawValue, privacy: .public), companion installed: \(session.isCompanionAppInstalled, privacy: .public), error: \(error != nil, privacy: .public)")
            self?.updateConnectivityStatus()
            self?.queuePending()
        }
    }
    func sessionReachabilityDidChange(_ session: WCSession) {
        DispatchQueue.main.async { [weak self] in
            self?.logger.notice("Watch reachability changed: \(session.isReachable, privacy: .public), companion installed: \(session.isCompanionAppInstalled, privacy: .public)")
            self?.updateConnectivityStatus()
            self?.queuePending()
        }
    }

    func sessionCompanionAppInstalledDidChange(_ session: WCSession) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.logger.notice("Companion app installation changed: \(session.isCompanionAppInstalled, privacy: .public)")
            self.updateConnectivityStatus()
            guard WatchConnectivityStatus.shouldRetryPendingTransfers(
                isActivated: session.activationState == .activated,
                companionAppInstalled: session.isCompanionAppInstalled
            ) else { return }
            self.queuePending()
        }
    }
}
