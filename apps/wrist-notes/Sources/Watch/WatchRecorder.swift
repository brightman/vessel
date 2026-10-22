import AVFAudio
import Combine
import Foundation
import os
import WatchConnectivity
import WatchKit

final class WatchRecorder: NSObject, ObservableObject, AVAudioRecorderDelegate, WCSessionDelegate {
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "cloud.karama.wisenote.watchkitapp", category: "WatchConnectivity")
    @Published private(set) var isRecording = false
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var pending: [PendingRecording] = []
    var pendingCount: Int { pending.filter { !$0.uploaded }.count + sessionSyncStates.filter { !$0.isComplete }.count }
    @Published var message: String?
    @Published var recordingError: String?
    @Published private(set) var connectivityStatus = "正在准备同步…"

    let recordingSessionStore: WatchRecordingSessionStore
    @Published private(set) var sessionChunks: [RecordingChunkDescriptor] = []
    @Published private(set) var sessionEnds: [RecordingSessionEnd] = []
    @Published private(set) var isFinishingSession = false
    @Published private(set) var sessionSyncStates: [WatchChunkSessionState] = []
    private var chunkQueue: WatchChunkTransferQueue?
    private var chunkRetryTimer: Timer?
    private var foregroundObservation: NSObjectProtocol?
    private var lastCapabilityOffer: String?
    private var capabilityAttempts = 0
    private var continuousCapture: SegmentedAudioCapture?
    private var sessionRecoveryInProgress = true
    private let sessionWorker = DispatchQueue(label: "WiseLife.watchSessionRecovery", qos: .utility)

    private let directory: URL
    private let indexURL: URL
    private var recorder: AVAudioRecorder?
    private let captureLocation = CaptureLocationService()
    private var capturedLocation: CaptureLocation?
    private var timer: Timer?
    private var startedAt: Date?
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
        recordingSessionStore = WatchRecordingSessionStore(root: directory.appendingPathComponent("SessionsV2", isDirectory: true))
        super.init()
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: indexURL.path) {
                pending = try JSONDecoder().decode([PendingRecording].self, from: Data(contentsOf: indexURL))
            }
            recoverUnfinishedAudio()
        } catch { message = "无法打开录音目录：\(error.localizedDescription)" }
        configureChunkTransport()
        sessionWorker.async { [weak self] in
            guard let self else { return }
            do {
                try self.recordingSessionStore.recover()
                let chunks = self.recordingSessionStore.chunks
                let ends = self.recordingSessionStore.sessionEnds
                let hasIssues = !self.recordingSessionStore.recoveryIssues.isEmpty
                DispatchQueue.main.async {
                    self.sessionChunks = chunks
                    self.sessionEnds = ends
                    self.sessionRecoveryInProgress = false
                    self.refreshChunkTransfers()
                    if hasIssues { self.message = "有未完成录音已保留，等待恢复" }
                }
            } catch {
                DispatchQueue.main.async {
                    self.sessionRecoveryInProgress = false
                    self.message = "长录音恢复失败：\(error.localizedDescription)"
                }
            }
        }
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
        if kind == .long && SegmentedAudioCapture.developerEnabled && sessionRecoveryInProgress {
            message = "正在恢复已保存录音，请稍后开始"
            return
        }
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
        guard isRecording, !isFinishingSession, let id = currentID, let kind = currentKind, let startedAt else { return }
        if let capture = continuousCapture {
            finishContinuousCapture(capture, sessionID: id)
            return
        }
        captureLocation.cancel()
        let recordedDuration = recorder?.currentTime ?? elapsed
        recorder?.delegate = nil
        recorder?.stop()
        let duration = audioDuration(at: directory.appendingPathComponent("\(id.uuidString).m4a")) ?? recordedDuration
        recorder = nil
        timer?.invalidate()
        timer = nil
        isRecording = false
        elapsed = 0
        currentID = nil
        currentKind = nil
        self.startedAt = nil
        thoughtPressActive = false
        WKInterfaceDevice.current().play(.stop)
        let item = PendingRecording(id: id, kind: kind, capturedAt: startedAt, duration: duration, location: capturedLocation)
        pending.append(item)
        do {
            try persistPending()
            try? FileManager.default.removeItem(at: captureSidecar(id))
            logger.notice("Saved recording \(id.uuidString, privacy: .public); pending count: \(self.pendingCount, privacy: .public)")
            queuePending()
            message = "已保存在手表，等待传到 iPhone"
        } catch { message = "录音已保存，但列表写入失败：\(error.localizedDescription)" }
    }

    func retryTransfers() { queuePending(); refreshChunkTransfers(force: true) }

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
            try? FileManager.default.removeItem(at: captureSidecar(id))
            queuedIDs.remove(id)
            updateConnectivityStatus()
        } catch { pending = original; message = "删除失败：\(error.localizedDescription)" }
    }

    func cancelThought() {
        thoughtPressActive = false
        guard isRecording, currentKind == .thought else { return }
        captureLocation.cancel(); capturedLocation = nil
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
        if let file {
            try? FileManager.default.removeItem(at: file)
            if let id = UUID(uuidString: file.deletingPathExtension().lastPathComponent) { try? FileManager.default.removeItem(at: captureSidecar(id)) }
        }
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
            if kind == .long && SegmentedAudioCapture.developerEnabled {
                try beginContinuousCapture(sessionID: id)
                return
            }
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
            startedAt = .now
            isRecording = true
            capturedLocation = nil
            captureLocation.begin(at: startedAt!, source: .watchRecording) { [weak self] point in
                guard let self, self.currentID == id, self.isRecording else { return }
                self.capturedLocation = point
                let item = PendingRecording(id: id, kind: kind, capturedAt: self.startedAt ?? .now, duration: 0, location: point)
                try? JSONEncoder().encode(item).write(to: self.captureSidecar(id), options: .atomic)
            }
            WKInterfaceDevice.current().play(.start)
            message = nil
            timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                guard let self, let recorder = self.recorder else { return }
                self.elapsed = recorder.currentTime
            }
        } catch { recordingError = "录音启动失败：\(error.localizedDescription)" }
    }

    private func beginContinuousCapture(sessionID: UUID) throws {
        let store = recordingSessionStore
        let deviceKey = "WiseLifeRecordingDeviceID"
        let deviceID = UserDefaults.standard.string(forKey: deviceKey) ?? UUID().uuidString
        UserDefaults.standard.set(deviceID, forKey: deviceKey)
        let origin = RecordingOrigin(device: WKInterfaceDevice.current().model, deviceID: deviceID,
                                     fileName: "continuous-capture", recordingTimeIsEstimated: false)
        let capture = SegmentedAudioCapture(root: store.root.appendingPathComponent(sessionID.uuidString), origin: origin) { [weak self] chunk, url in
            try store.seal(chunk, file: url)
            DispatchQueue.main.async {
                self?.sessionChunks = store.chunks
                self?.refreshChunkTransfers()
            }
        }
        capture.onFailure = { [weak self] error in
            guard let self else { return }
            self.recordingError = error.localizedDescription
            self.stop()
        }
        capture.onStorageWarning = { [weak self] in
            self?.message = "手表存储空间偏低；空间继续减少时将自动停止并保存录音"
        }
        try capture.start(sessionID: sessionID)
        continuousCapture = capture
        currentID = sessionID; currentKind = .long; startedAt = .now
        elapsed = 0; isRecording = true; message = nil
        capturedLocation = nil
        captureLocation.begin(at: startedAt!, source: .watchRecording) { [weak self, weak capture] point in
            guard let self, self.currentID == sessionID, self.isRecording else { return }
            self.capturedLocation = point
            capture?.updateLocation(point)
        }
        WKInterfaceDevice.current().play(.start)
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self, weak capture] _ in
            self?.elapsed = capture?.sampledDuration ?? 0
        }
    }

    private func finishContinuousCapture(_ capture: SegmentedAudioCapture, sessionID: UUID) {
        isFinishingSession = true
        captureLocation.cancel()
        timer?.invalidate(); timer = nil
        WKInterfaceDevice.current().play(.stop)
        Task { @MainActor in
            var failure: Error?
            do { try await capture.stop() } catch { failure = error }
            do {
                try recordingSessionStore.finish(.init(sessionID: sessionID,
                    finalOrdinal: recordingSessionStore.chunks.filter { $0.sessionID == sessionID }.map(\.ordinal).max(),
                    endedAt: .now, interrupted: failure != nil, revision: 0), reason: failure?.localizedDescription)
            } catch { failure = error }
            sessionChunks = recordingSessionStore.chunks
            sessionEnds = recordingSessionStore.sessionEnds
            refreshChunkTransfers()
            continuousCapture = nil; isRecording = false; isFinishingSession = false
            currentID = nil; currentKind = nil; startedAt = nil; elapsed = 0
            if let failure { recordingError = failure.localizedDescription; message = "录音已中断，已封口的片段保留在手表" }
            else { message = "长录音已保存在手表" }
        }
    }

    deinit {
        chunkRetryTimer?.invalidate()
        if let foregroundObservation { NotificationCenter.default.removeObserver(foregroundObservation) }
    }

    private func configureChunkTransport() {
        do {
            chunkQueue = try WatchChunkTransferQueue(root: directory.appendingPathComponent("TransferV2"),
                outstandingFileCount: {
                    guard WCSession.isSupported() else { return 0 }
                    // System jobs from older handshakes still own capacity until
                    // actual completion; a nonce refresh cannot create more slots.
                    return WCSession.default.outstandingFileTransfers.filter {
                        RecordingChunkWire.owns($0.file.metadata ?? [:])
                    }.count
                }, isOutstanding: { id, isEnd, binding in
                    guard WCSession.isSupported() else { return false }
                    if isEnd {
                        return WCSession.default.outstandingUserInfoTransfers.contains {
                            guard let value = try? RecordingChunkWire.decode(RecordingWireEnvelope<RecordingSessionEnd>.self, key: RecordingChunkProtocol.endKey, from: $0.userInfo) else { return false }
                            return value.binding == binding && value.payload.sessionID == id
                        }
                    }
                    return WCSession.default.outstandingFileTransfers.contains {
                        guard let value = try? RecordingChunkWire.decode(RecordingWireEnvelope<RecordingChunkDescriptor>.self, key: RecordingChunkProtocol.chunkKey, from: $0.file.metadata ?? [:]) else { return false }
                        return value.binding == binding && value.payload.id == id
                    }
                }, sendHello: { [weak self] hello in
                    guard WCSession.isSupported(), WCSession.default.activationState == .activated,
                          WCSession.default.isCompanionAppInstalled else { throw RecordingTransportError.unavailable }
                    let payload: [String: Any] = [RecordingChunkProtocol.capabilityKey: try JSONEncoder().encode(hello)]
                    let session = WCSession.default
                    if session.isReachable {
                        session.sendMessage(payload, replyHandler: { [weak self] reply in
                            DispatchQueue.main.async { self?.handleChunkReply(reply) }
                        }, errorHandler: { _ in })
                    } else if !session.outstandingUserInfoTransfers.contains(where: {
                        (try? RecordingChunkWire.decode(RecordingCapabilityHello.self, key: RecordingChunkProtocol.capabilityKey, from: $0.userInfo)) == hello
                    }) {
                        session.transferUserInfo(payload)
                    }
                }, sendFile: { url, value in
                    guard WCSession.isSupported(), WCSession.default.activationState == .activated,
                          WCSession.default.isCompanionAppInstalled else { throw RecordingTransportError.unavailable }
                    WCSession.default.transferFile(url, metadata: [RecordingChunkProtocol.chunkKey: try JSONEncoder().encode(value)])
                }, sendEnd: { value in
                    guard WCSession.isSupported(), WCSession.default.activationState == .activated,
                          WCSession.default.isCompanionAppInstalled else { throw RecordingTransportError.unavailable }
                    WCSession.default.transferUserInfo([RecordingChunkProtocol.endKey: try JSONEncoder().encode(value)])
                })
        } catch { message = "长录音同步记录暂时不可用，录音仍保存在手表" }
        chunkRetryTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in self?.refreshChunkTransfers() }
        foregroundObservation = NotificationCenter.default.addObserver(forName: WKExtension.applicationDidBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in self?.startChunkHandshake() }
    }
    private func startChunkHandshake() {
        guard let chunkQueue else { return }
        do { try chunkQueue.beginHandshake(); capabilityAttempts = 0 }
        catch { message = "同步握手记录待恢复，录音保留在手表" }
        refreshChunkTransfers()
    }
    private func sendChunkHello() {
        guard WCSession.isSupported(), WCSession.default.activationState == .activated,
              WCSession.default.isCompanionAppInstalled, let chunkQueue else { return }
        do {
            try chunkQueue.requestCapability()
            capabilityAttempts += 1
            if !sessionChunks.isEmpty {
                message = capabilityAttempts > 1 ? "长录音已保留，请确认 iPhone 上的 WiseLife 已更新" : "长录音已保留，等待 iPhone 确认同步能力"
            }
        } catch { message = "长录音同步协商待重试" }
    }
    private func refreshChunkTransfers(force: Bool = false) {
        guard let chunkQueue else { return }
        do {
            let store = recordingSessionStore
            try chunkQueue.update(chunks: sessionChunks, ends: sessionEnds, audioURL: { store.audioURL(for: $0) })
            if chunkQueue.binding == nil { sendChunkHello() }
            else { try chunkQueue.pump(force: force) }
        } catch { message = "长录音同步待重试，原件保留在手表" }
        sessionSyncStates = chunkQueue.sessionStates
        updateConnectivityStatus()
    }
    private func handleChunkReply(_ message: [String: Any]) {
        guard let chunkQueue else { return }
        do {
            if message[RecordingChunkProtocol.capabilityKey] != nil {
                try chunkQueue.accept(RecordingChunkWire.decode(RecordingCapabilityReply.self, key: RecordingChunkProtocol.capabilityKey, from: message))
            } else if message[RecordingChunkProtocol.receiptKey] != nil {
                try chunkQueue.receive(RecordingChunkWire.decode(RecordingWireEnvelope<RecordingSavedChunk>.self, key: RecordingChunkProtocol.receiptKey, from: message))
            } else if message[RecordingChunkWire.endReceiptKey] != nil {
                try chunkQueue.receive(RecordingChunkWire.decode(RecordingWireEnvelope<RecordingSessionEnd>.self, key: RecordingChunkWire.endReceiptKey, from: message))
            } else { throw RecordingTransportError.invalidEnvelope }
            refreshChunkTransfers()
        } catch {
            if chunkQueue.unsupported { self.message = "长录音已保留，请更新 iPhone 上的 WiseLife" }
            logger.error("V2 receipt/capability rejected: \(error.localizedDescription, privacy: .public)")
        }
    }
    private func publishSessionSnapshot() {
        guard WCSession.isSupported(), WCSession.default.activationState == .activated,
              let chunkQueue, let binding = chunkQueue.binding else { return }
        let pending = chunkQueue.sessionStates.filter { !$0.isComplete }.map { value in
            WatchSessionSyncSnapshot.Pending(sessionID: value.id,
                lastOrdinal: sessionChunks.filter { $0.sessionID == value.id }.map(\.ordinal).max(), end: value.end)
        }
        let session = WCSession.default
        let previous = WatchSessionSyncSnapshot.decode(session.applicationContext, binding: binding)
        guard previous?.pending != pending else { return }
        let snapshot = WatchSessionSyncSnapshot(updatedAt: max(Date(), (previous?.updatedAt ?? .distantPast).addingTimeInterval(0.001)), pending: pending)
        do {
            var context = session.applicationContext
            context[WatchSessionSyncSnapshot.contextKey] = try JSONEncoder().encode(RecordingWireEnvelope(binding: binding, payload: snapshot))
            try session.updateApplicationContext(context)
        } catch { logger.error("V2 session status publication deferred") }
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
        // Rebuild from the OS queue so a missed completion callback cannot block manual retry.
        queuedIDs = Set(session.outstandingFileTransfers.compactMap {
            ($0.file.metadata?["id"] as? String).flatMap(UUID.init(uuidString:))
        })
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
            var metadata: [String: Any] = ["id": item.id.uuidString, "kind": item.kind.rawValue,
                "capturedAt": item.capturedAt, "duration": item.duration]
            metadata["captureLocation"] = item.location?.transferData
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
                message["captureLocation"] = item.location?.transferData
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
            self.setTransferFailure(id, failed: true)
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
            missingFileCount: missingAudioFileCount,
            lastSyncedAt: (pending.compactMap(\.uploadedAt) + [chunkQueue?.lastSavedAt].compactMap { $0 }).max()
        )
        publishSyncSnapshot()
    }

    private func publishSyncSnapshot() {
        publishSessionSnapshot()
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        guard session.activationState == .activated, session.isCompanionAppInstalled else { return }
        let ids = pending.filter { !$0.uploaded }.map(\.id).sorted { $0.uuidString < $1.uuidString }
        let failures: [WatchSyncFailure] = pending.filter { !$0.uploaded }.compactMap { item in
            let file = directory.appendingPathComponent("\(item.id.uuidString).m4a")
            if !FileManager.default.fileExists(atPath: file.path) { return WatchSyncFailure(id: item.id, reason: .fileMissing) }
            return item.transferFailed ? WatchSyncFailure(id: item.id, reason: .transferFailed) : nil
        }.sorted { $0.id.uuidString < $1.id.uuidString }
        let handledID = UserDefaults.standard.string(forKey: WatchSyncRetryRequest.handledKey).flatMap(UUID.init(uuidString:))
        let previous = WatchSyncSnapshot.decode(session.applicationContext)
        guard previous?.pendingIDs != ids || previous?.failures != failures || previous?.lastHandledRetryID != handledID else { return }
        let updatedAt = max(Date(), (previous?.updatedAt ?? .distantPast).addingTimeInterval(0.001))
        let snapshot = WatchSyncSnapshot(updatedAt: updatedAt, pendingIDs: ids, failures: failures, lastHandledRetryID: handledID)
        do {
            var context = session.applicationContext
            context[WatchSyncSnapshot.contextKey] = try JSONEncoder().encode(snapshot)
            try session.updateApplicationContext(context)
        } catch { logger.error("Watch sync status publication deferred: \(error.localizedDescription, privacy: .public)") }
    }

    private func captureSidecar(_ id: UUID) -> URL { directory.appendingPathComponent("\(id.uuidString).capture.json") }

    private func persistPending() throws {
        try JSONEncoder().encode(pending).write(to: indexURL, options: .atomic)
    }

    private func recoverUnfinishedAudio() {
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.creationDateKey]) else { return }
        for file in files where file.pathExtension.lowercased() == "m4a" {
            guard let id = UUID(uuidString: file.deletingPathExtension().lastPathComponent) else { continue }
            if let index = pending.firstIndex(where: { $0.id == id }) {
                if pending[index].duration == 0, let measured = audioDuration(at: file) { pending[index].duration = measured }
                continue
            }
            let date = (try? file.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .now
            let recovered = (try? Data(contentsOf: captureSidecar(id))).flatMap { try? JSONDecoder().decode(PendingRecording.self, from: $0) }
            var item = recovered?.id == id ? recovered! : PendingRecording(id: id, kind: .long, capturedAt: date, duration: 0)
            if let measured = audioDuration(at: file) { item.duration = measured }
            pending.append(item)
        }
        try? persistPending()
    }

    private func audioDuration(at url: URL) -> TimeInterval? {
        guard let file = try? AVAudioFile(forReading: url), file.length > 0,
              file.processingFormat.sampleRate.isFinite, file.processingFormat.sampleRate > 0 else { return nil }
        let duration = Double(file.length) / file.processingFormat.sampleRate
        return duration.isFinite && duration > 0 ? duration : nil
    }

    func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        if isRecording { stop() }
    }

    func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        if RecordingChunkWire.owns(userInfo) { DispatchQueue.main.async { self.handleChunkReply(userInfo) }; return }
        guard let raw = userInfo["ack"] as? String, let id = UUID(uuidString: raw) else { return }
        markUploaded(id)
    }

    func session(_ session: WCSession, didReceiveMessage message: [String: Any] = [:]) {
        if RecordingChunkWire.owns(message) { DispatchQueue.main.async { self.handleChunkReply(message) }; return }
        guard let raw = message["ack"] as? String, let id = UUID(uuidString: raw) else { return }
        markUploaded(id)
    }

    func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        DispatchQueue.main.async { self.applyPhoneContext(applicationContext) }
    }

    private func applyPhoneContext(_ context: [String: Any]) {
        if let offer = context[RecordingChunkWire.offerKey] as? String, offer != lastCapabilityOffer {
            lastCapabilityOffer = offer
            startChunkHandshake()
        }
        if let enabled = context[CaptureLocationSettings.key] as? Bool { CaptureLocationSettings.setEnabled(enabled) }
        let handledID = UserDefaults.standard.string(forKey: WatchSyncRetryRequest.handledKey).flatMap(UUID.init(uuidString:))
        guard let request = WatchSyncRetryRequest.decode(context), request.shouldHandle(lastHandledID: handledID) else { return }
        queuePending()
        refreshChunkTransfers(force: true)
        // This acknowledges processing the request, not completion of any file transfer.
        UserDefaults.standard.set(request.id.uuidString, forKey: WatchSyncRetryRequest.handledKey)
        publishSyncSnapshot()
    }

    private func setTransferFailure(_ id: UUID, failed: Bool) {
        guard let index = pending.firstIndex(where: { $0.id == id && !$0.uploaded }) else { return }
        pending[index].transferFailed = failed
        do { try persistPending() }
        catch { logger.error("Watch transfer failure state could not be saved") }
    }

    private func markUploaded(_ id: UUID) {
        logger.notice("Received phone save acknowledgement for \(id.uuidString, privacy: .public)")
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            guard let index = self.pending.firstIndex(where: { $0.id == id }) else { return }
            let original = self.pending[index]
            self.pending[index].uploaded = true
            self.pending[index].uploadedAt = original.uploadedAt ?? .now
            self.pending[index].transferFailed = false
            do {
                try self.persistPending()
                self.queuedIDs.remove(id)
                self.message = "已传到 iPhone"
                self.updateConnectivityStatus()
            } catch { self.pending[index] = original; self.message = "上传状态保存失败：\(error.localizedDescription)" }
        }
    }

    func session(_ session: WCSession, didFinish fileTransfer: WCSessionFileTransfer, error: Error?) {
        if RecordingChunkWire.owns(fileTransfer.file.metadata ?? [:]) {
            DispatchQueue.main.async { [weak self] in
                if error != nil { self?.message = "长录音传输待重试，原件保留在手表" }
                self?.refreshChunkTransfers()
            }
            return
        }
        guard let raw = fileTransfer.file.metadata?["id"] as? String,
              let id = UUID(uuidString: raw) else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.queuedIDs.remove(id)
            self.setTransferFailure(id, failed: error != nil)
            self.logger.notice("File transfer finished for \(id.uuidString, privacy: .public); error: \(error != nil, privacy: .public)")
            if let error { self.message = "传输待重试：\(error.localizedDescription)" }
            else { self.message = "已传输，等待 iPhone 确认保存" }
            self.updateConnectivityStatus()
        }
    }

    func session(_ session: WCSession, activationDidCompleteWith state: WCSessionActivationState, error: Error?) {
        DispatchQueue.main.async { [weak self] in
            self?.logger.notice("Watch session activation completed with state \(state.rawValue, privacy: .public), companion installed: \(session.isCompanionAppInstalled, privacy: .public), error: \(error != nil, privacy: .public)")
            self?.startChunkHandshake()
            self?.updateConnectivityStatus()
            self?.applyPhoneContext(session.receivedApplicationContext)
            self?.queuePending()
        }
    }
    func sessionReachabilityDidChange(_ session: WCSession) {
        DispatchQueue.main.async { [weak self] in
            self?.logger.notice("Watch reachability changed: \(session.isReachable, privacy: .public), companion installed: \(session.isCompanionAppInstalled, privacy: .public)")
            self?.updateConnectivityStatus()
            self?.applyPhoneContext(session.receivedApplicationContext)
            self?.queuePending()
            self?.refreshChunkTransfers()
        }
    }

    func sessionCompanionAppInstalledDidChange(_ session: WCSession) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.startChunkHandshake()
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
