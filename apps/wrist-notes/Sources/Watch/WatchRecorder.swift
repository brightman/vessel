import AVFoundation
import Combine
import Foundation
import os
import WatchConnectivity
import WatchKit

struct WatchTransferDiagnosticEvent: Codable, Identifiable, Equatable {
    let id: UUID
    let date: Date
    let title: String
    let detail: String
    let recordingKey: String?

    init(date: Date = .now, title: String, detail: String = "", recordingKey: String? = nil) {
        id = UUID()
        self.date = date
        self.title = title
        self.detail = detail
        self.recordingKey = recordingKey
    }
}

final class WatchRecorder: NSObject, ObservableObject, AVAudioRecorderDelegate, WCSessionDelegate {
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "cloud.karama.wisenote.watchkitapp", category: "WatchConnectivity")
    @Published private(set) var isRecording = false
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var pending: [PendingRecording] = []
    var pendingCount: Int { pending.filter { !$0.uploaded }.count }
    @Published var message: String?
    @Published var recordingError: String?
    @Published private(set) var connectivityStatus = "正在准备同步…"
    @Published private(set) var diagnosticEvents: [WatchTransferDiagnosticEvent] = []

    @Published private(set) var isFinishingSession = false
    private var continuousCapture: SegmentedAudioCapture?

    private let directory: URL
    private let indexURL: URL
    private let diagnosticsURL: URL
    private var recorder: AVAudioRecorder?
    private let captureLocation = CaptureLocationService()
    // A new recording's start request cannot replace the prior recording's pending stop fix.
    private var capturedLocation: CaptureLocation?
    private var timer: Timer?
    private var startedAt: Date?
    private var currentID: UUID?
    private var currentKind: RecordingKind?
    private var queuedIDs: Set<UUID> = []
    private var missingAudioFileCount = 0
    private var permissionRequestInFlight = false
    private var thoughtPressActive = false

    var diagnosticConnectionState: String {
        guard WCSession.isSupported() else { return "不支持" }
        switch WCSession.default.activationState {
        case .notActivated: return "未激活"
        case .inactive: return "未激活"
        case .activated: return "已激活"
        @unknown default: return "未知"
        }
    }
    var diagnosticCompanionInstalled: Bool {
        WCSession.isSupported() && WCSession.default.isCompanionAppInstalled
    }
    var diagnosticPhoneReachable: Bool {
        WCSession.isSupported() && WCSession.default.activationState == .activated && WCSession.default.isReachable
    }
    var diagnosticFileTransferStatus: WatchFileTransferStatus {
        guard WCSession.isSupported() else { return .init(outstandingCount: 0, transferringCount: 0) }
        let transfers = WCSession.default.outstandingFileTransfers
        let transferringCount = transfers.filter { $0.isTransferring }.count
        return .init(outstandingCount: transfers.count, transferringCount: transferringCount)
    }
    var diagnosticOutstandingFileCount: Int {
        diagnosticFileTransferStatus.outstandingCount
    }
    func transferStatus(for item: PendingRecording) -> String {
        if item.uploaded { return "iPhone 已保存" }
        if item.transferFailed { return "传输失败" }
        if FileManager.default.fileExists(atPath: audioFile(for: item).path) == false { return "Watch 文件缺失" }
        if WCSession.isSupported(), let transfer = WCSession.default.outstandingFileTransfers.first(where: {
            $0.file.metadata?["id"] as? String == item.id.uuidString
        }) {
            return transfer.isTransferring ? "系统传输中" : "系统排队"
        }
        if queuedIDs.contains(item.id) { return "系统传输中" }
        if item.awaitingPhoneSaveConfirmation { return "等待手机回执" }
        return "Watch 待发送"
    }
    var diagnosticLastSyncAt: Date? {
        pending.compactMap(\.uploadedAt).max()
    }

    override init() {
        directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Recordings", isDirectory: true)
        indexURL = directory.appendingPathComponent("pending.json")
        diagnosticsURL = directory.appendingPathComponent("transfer-diagnostics.json")
        super.init()
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            if let data = try? Data(contentsOf: diagnosticsURL),
               let stored = try? JSONDecoder().decode([WatchTransferDiagnosticEvent].self, from: data) {
            diagnosticEvents = Array(stored.prefix(20))
            }
            if FileManager.default.fileExists(atPath: indexURL.path) {
                pending = try JSONDecoder().decode([PendingRecording].self, from: Data(contentsOf: indexURL))
            }
            recoverLocalDeleteArtifacts()
            recoverUnfinishedAudio()
        } catch { message = "无法打开录音目录：\(error.localizedDescription)" }
        recordDiagnostic("WiseLife 已启动", detail: "本机待确认 \(pendingCount) 项")
        if WCSession.isSupported() {
            WCSession.default.delegate = self
            logger.notice("Watch session activating")
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

    func retryTransfers() {
        recordDiagnostic("手动重试同步", detail: "可达 \(diagnosticPhoneReachable ? "是" : "否") · 待确认 \(pendingCount) · 系统队列 \(diagnosticOutstandingFileCount)")
        queuePending()
    }

    private func recordDiagnostic(_ title: String, detail: String = "", recordingID: UUID? = nil) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in self?.recordDiagnostic(title, detail: detail, recordingID: recordingID) }
            return
        }
        diagnosticEvents.insert(WatchTransferDiagnosticEvent(title: title, detail: detail, recordingKey: recordingID.map(RecordingTransportDiagnostics.shortID)), at: 0)
        if diagnosticEvents.count > 20 { diagnosticEvents = Array(diagnosticEvents.prefix(20)) }
        do {
            try JSONEncoder().encode(diagnosticEvents).write(to: diagnosticsURL, options: .atomic)
        } catch {
            logger.error("Could not persist Watch transfer diagnostics error=\(RecordingTransportDiagnostics.errorCode(error), privacy: .public)")
        }
    }

    func delete(_ id: UUID) {
        guard let item = pending.first(where: { $0.id == id }) else { return }
        let source = audioFile(for: item)
        let deletionArtifact = localDeleteArtifact(for: id)
        if WCSession.isSupported() {
            for transfer in WCSession.default.outstandingFileTransfers
            where transfer.file.metadata?["id"] as? String == id.uuidString {
                transfer.cancel()
            }
        }
        do {
            if FileManager.default.fileExists(atPath: source.path) {
                guard !FileManager.default.fileExists(atPath: deletionArtifact.path) else {
                    throw RecordingTransportError.conflict
                }
                try FileManager.default.moveItem(at: source, to: deletionArtifact)
            }
        } catch {
            if !item.uploaded { queuePending() }
            message = "删除失败：\(error.localizedDescription)"
            return
        }
        let original = pending
        pending.removeAll { $0.id == id }
        do {
            try persistPending()
            try? FileManager.default.removeItem(at: deletionArtifact)
            try? FileManager.default.removeItem(at: captureSidecar(id))
            queuedIDs.remove(id)
            recordDiagnostic(item.uploaded ? "删除 Watch 本地录音" : "删除未同步 Watch 录音",
                             detail: RecordingTransportDiagnostics.shortID(id))
            updateConnectivityStatus()
        } catch {
            pending = original
            if FileManager.default.fileExists(atPath: deletionArtifact.path),
               !FileManager.default.fileExists(atPath: source.path) {
                try? FileManager.default.moveItem(at: deletionArtifact, to: source)
            }
            if !item.uploaded { queuePending() }
            message = "删除失败：\(error.localizedDescription)"
        }
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
            if kind == .long {
                try beginHourlyRecordingCapture(groupID: id)
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
                try? self.writeCaptureItem(item, id: id)
            }
            WKInterfaceDevice.current().play(.start)
            message = nil
            timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                guard let self, let recorder = self.recorder else { return }
                self.elapsed = recorder.currentTime
            }
        } catch { recordingError = "录音启动失败：\(error.localizedDescription)" }
    }

    private func beginHourlyRecordingCapture(groupID: UUID) throws {
        let deviceKey = "WiseLifeRecordingDeviceID"
        let deviceID = UserDefaults.standard.string(forKey: deviceKey) ?? UUID().uuidString
        UserDefaults.standard.set(deviceID, forKey: deviceKey)
        let origin = RecordingOrigin(device: WKInterfaceDevice.current().model, deviceID: deviceID,
                                     fileName: "hourly-recording", recordingTimeIsEstimated: false)
        let captureRoot = directory.appendingPathComponent("HourlyCapture", isDirectory: true).appendingPathComponent(groupID.uuidString, isDirectory: true)
        let capture = SegmentedAudioCapture(root: captureRoot, origin: origin) { [weak self] chunk, temporaryURL in
            guard let self else { throw RecordingTransportError.unavailable }
            let fileURL = self.directory.appendingPathComponent(chunk.audioFilename)
            let fileOrigin = RecordingOrigin(device: chunk.origin.device, deviceID: chunk.origin.deviceID,
                                             fileName: chunk.audioFilename, recordingTimeIsEstimated: false)
            let item = PendingRecording(id: chunk.id, kind: .long, capturedAt: chunk.capturedAt,
                duration: chunk.duration, location: chunk.location, recordingGroupID: groupID,
                recordingGroupOrdinal: chunk.ordinal, recordingGroupOffset: chunk.sessionStartOffset,
                recordingOrigin: fileOrigin)
            guard !FileManager.default.fileExists(atPath: fileURL.path) else { throw RecordingTransportError.invalidStorage }
            try FileManager.default.moveItem(at: temporaryURL, to: fileURL)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                if !self.pending.contains(where: { $0.id == item.id }) {
                    self.pending.append(item)
                    do {
                        try self.persistPending()
                        let fileSize = (try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                        self.recordDiagnostic("录音文件已封存", detail: "\(Int(chunk.duration)) 秒 · \(fileSize) B\(chunk.ordinal > 0 ? " · 录音组第 \(chunk.ordinal + 1) 个文件" : " · 录音组首个文件")", recordingID: item.id)
                        self.queuePending()
                    }
                    catch { self.message = "录音文件已保存，列表写入待重试：\(error.localizedDescription)" }
                }
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
        try capture.start(sessionID: groupID)
        continuousCapture = capture
        currentID = groupID; currentKind = .long; startedAt = .now
        elapsed = 0; isRecording = true; message = nil
        capturedLocation = nil
        requestRecordingLocation(groupID: groupID, offset: 0)
        WKInterfaceDevice.current().play(.start)
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self, weak capture] _ in
            guard let self else { return }
            self.elapsed = capture?.sampledDuration ?? 0
        }
    }

    /// GPS and its independent durable journal never participate in the audio worker's failure path.
    private func requestRecordingLocation(groupID: UUID, offset: TimeInterval, requestedAt: Date = .now) {
        let policyRevision = CaptureLocationSettings.revision
        captureLocation.begin(at: requestedAt, source: .watchRecording) { [weak self] point in
            guard let self, CaptureLocationSettings.enabled, CaptureLocationSettings.revision == policyRevision,
                  self.currentID == groupID else { return }
            self.capturedLocation = point
            self.continuousCapture?.updateLocation(point)
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
            continuousCapture = nil; isRecording = false; isFinishingSession = false
            currentID = nil; currentKind = nil; startedAt = nil; elapsed = 0
            if let failure { recordingError = failure.localizedDescription; message = "录音已中断，已封存的录音文件保留在手表" }
            else { message = "录音已结束，每小时录音文件将分别传到 iPhone" }
            guard failure == nil else { return }
            let captureRoot = self.directory.appendingPathComponent("HourlyCapture", isDirectory: true).appendingPathComponent(sessionID.uuidString, isDirectory: true)
            if let remaining = try? FileManager.default.contentsOfDirectory(atPath: captureRoot.path), remaining.isEmpty {
                try? FileManager.default.removeItem(at: captureRoot)
            }
        }
    }

    private func updateConnectivityStatus() {
        let supported = WCSession.isSupported()
        let session = supported ? WCSession.default : nil
        let isActivated = session?.activationState == .activated
        connectivityStatus = WatchConnectivityStatus.message(
            isSupported: supported,
            isActivated: isActivated,
            companionInstalled: isActivated && (session?.isCompanionAppInstalled == true),
            pendingCount: pendingCount,
            transferCount: queuedIDs.count,
            missingFileCount: missingAudioFileCount,
            lastSyncedAt: pending.compactMap(\.uploadedAt).max()
        )
        publishSyncSnapshot()
    }

    private func publishSyncSnapshot() {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        guard session.activationState == .activated, session.isCompanionAppInstalled else { return }
        let ids = pending.filter { !$0.uploaded }.map(\.id).sorted { $0.uuidString < $1.uuidString }
        let failures: [WatchSyncFailure] = pending.filter { !$0.uploaded }.compactMap { item in
            let file = audioFile(for: item)
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

    private func captureSidecar(_ id: UUID) -> URL { directory.appendingPathComponent("\(id.uuidString).capture.plist") }

    private func audioFile(for item: PendingRecording) -> URL {
        if let groupID = item.recordingGroupID, let ordinal = item.recordingGroupOrdinal {
            return directory.appendingPathComponent(RecordingChunkFileIdentity.filename(
                groupID: groupID, ordinal: ordinal, capturedAt: item.capturedAt))
        }
        return directory.appendingPathComponent("\(item.id.uuidString).m4a")
    }

    private func localDeleteArtifact(for id: UUID) -> URL {
        directory.appendingPathComponent(".local-delete-\(id.uuidString).tmp")
    }

    /// Finish or roll back a local-only deletion interrupted by process exit.
    private func recoverLocalDeleteArtifacts() {
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory,
            includingPropertiesForKeys: nil) else { return }
        for artifact in files where artifact.lastPathComponent.hasPrefix(".local-delete-") && artifact.pathExtension == "tmp" {
            let rawID = String(artifact.lastPathComponent.dropFirst(".local-delete-".count).dropLast(".tmp".count))
            guard let id = UUID(uuidString: rawID) else { continue }
            if let item = pending.first(where: { $0.id == id }) {
                let source = audioFile(for: item)
                if !FileManager.default.fileExists(atPath: source.path) {
                    try? FileManager.default.moveItem(at: artifact, to: source)
                } else {
                    try? FileManager.default.removeItem(at: artifact)
                }
            } else {
                try? FileManager.default.removeItem(at: artifact)
            }
        }
    }

    private func writeCaptureItem(_ item: PendingRecording, id: UUID) throws {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        try encoder.encode(item).write(to: captureSidecar(id), options: .atomic)
    }

    private func readCaptureItem(_ id: UUID) -> PendingRecording? {
        guard let data = try? Data(contentsOf: captureSidecar(id)) else { return nil }
        return try? PropertyListDecoder().decode(PendingRecording.self, from: data)
    }

    private func persistPending() throws {
        try JSONEncoder().encode(pending).write(to: indexURL, options: .atomic)
    }

    private func recoverUnfinishedAudio() {
        recoverSealedHourlyPartials()
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.creationDateKey]) else { return }
        for file in files where file.pathExtension.lowercased() == "m4a" {
            let parsedGroupFile = RecordingChunkFileIdentity.parse(filename: file.lastPathComponent)
            let legacyID = UUID(uuidString: file.deletingPathExtension().lastPathComponent)
            guard let id = parsedGroupFile?.id ?? legacyID else { continue }
            let measuredDuration = audioDuration(at: file)
            if let parsedGroupFile,
               (measuredDuration == nil || !RecordingChunkFileMetadata.matches(groupID: parsedGroupFile.groupID,
                   ordinal: parsedGroupFile.ordinal, capturedAt: parsedGroupFile.capturedAt, audioURL: file)) {
                pending.removeAll { $0.id == id }
                continue
            }
            if let index = pending.firstIndex(where: { $0.id == id }) {
                if pending[index].duration == 0, let measuredDuration { pending[index].duration = measuredDuration }
                continue
            }
            let date = parsedGroupFile?.capturedAt ?? (try? file.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .now
            let recovered = readCaptureItem(id)
            let defaultOrigin = RecordingOrigin(device: WKInterfaceDevice.current().model,
                deviceID: UserDefaults.standard.string(forKey: "WiseLifeRecordingDeviceID") ?? "unknown",
                fileName: file.lastPathComponent, recordingTimeIsEstimated: parsedGroupFile == nil)
            var item = recovered?.id == id ? recovered! : PendingRecording(id: id, kind: .long, capturedAt: date,
                duration: 0, recordingGroupID: parsedGroupFile?.groupID,
                recordingGroupOrdinal: parsedGroupFile?.ordinal,
                recordingGroupOffset: parsedGroupFile.map { Double($0.ordinal) * RecordingSessionFileLimits.fileDuration },
                recordingOrigin: defaultOrigin)
            if let measuredDuration { item.duration = measuredDuration }
            pending.append(item)
        }
        try? persistPending()
    }

    /// A process may stop after AVAudioFile finalized its M4A but before the
    /// ordinary Watch queue received the file. The binary-plist checkpoint makes
    /// that narrow window replayable; an open/incomplete M4A is never queued.
    private func recoverSealedHourlyPartials() {
        let captureRoot = directory.appendingPathComponent("HourlyCapture", isDirectory: true)
        guard let groups = try? FileManager.default.contentsOfDirectory(at: captureRoot,
            includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else { return }
        for groupFolder in groups {
            guard UUID(uuidString: groupFolder.lastPathComponent) != nil,
                  let files = try? FileManager.default.contentsOfDirectory(at: groupFolder, includingPropertiesForKeys: nil) else { continue }
            for partial in files where partial.lastPathComponent.hasSuffix(".partial.m4a") {
                let canonicalName = String(partial.lastPathComponent.dropLast(".partial.m4a".count)) + ".m4a"
                guard let identity = RecordingChunkFileIdentity.parse(filename: canonicalName),
                      identity.groupID.uuidString == groupFolder.lastPathComponent,
                      let duration = audioDuration(at: partial), duration > 0,
                      RecordingChunkFileMetadata.matches(groupID: identity.groupID, ordinal: identity.ordinal,
                                                         capturedAt: identity.capturedAt, audioURL: partial) else { continue }
                let checkpointURL = partial.appendingPathExtension("capture.plist")
                guard let data = try? Data(contentsOf: checkpointURL),
                      let intent = try? PropertyListDecoder().decode(RecordingCaptureIntent.self, from: data),
                      intent.context.sessionID == identity.groupID, intent.ordinal == identity.ordinal,
                      intent.id == identity.id, abs(intent.capturedAt.timeIntervalSince(identity.capturedAt)) < 1.1 else { continue }
                let destination = directory.appendingPathComponent(canonicalName)
                guard !FileManager.default.fileExists(atPath: destination.path) else { continue }
                do {
                    try RecordingAudioFile.requireSafePath(partial)
                    try RecordingAudioFile.requireSafePath(destination)
                    try FileManager.default.moveItem(at: partial, to: destination)
                    try? FileManager.default.removeItem(at: checkpointURL)
                    if !pending.contains(where: { $0.id == identity.id }) {
                        let item = PendingRecording(id: identity.id, kind: .long, capturedAt: identity.capturedAt,
                            duration: duration, location: intent.context.location,
                            recordingGroupID: identity.groupID, recordingGroupOrdinal: identity.ordinal,
                            recordingGroupOffset: intent.sessionStartOffset,
                            recordingOrigin: RecordingOrigin(device: intent.context.origin.device,
                                deviceID: intent.context.origin.deviceID, fileName: canonicalName,
                                recordingTimeIsEstimated: false))
                        pending.append(item)
                    }
                    recordDiagnostic("恢复已封存录音", detail: "\(RecordingTransportDiagnostics.shortID(identity.id)) · \(Int(duration))秒")
                } catch {
                    logger.error("Could not recover finalized hourly recording: \(RecordingTransportDiagnostics.errorCode(error), privacy: .public)")
                }
            }
        }
    }

    /// Each sealed hourly recording is transferred as one ordinary audio file.
    private func queuePending() {
        guard WCSession.isSupported() else { updateConnectivityStatus(); return }
        let session = WCSession.default
        guard session.activationState == .activated, session.isCompanionAppInstalled else {
            updateConnectivityStatus()
            return
        }
        let outstandingIDs = Set(session.outstandingFileTransfers.compactMap { transfer in
            (transfer.file.metadata?["id"] as? String).flatMap(UUID.init(uuidString:))
        })
        queuedIDs = outstandingIDs
        missingAudioFileCount = 0
        for item in pending where !item.uploaded && !queuedIDs.contains(item.id) {
            let file = audioFile(for: item)
            guard FileManager.default.fileExists(atPath: file.path) else {
                missingAudioFileCount += 1
                recordDiagnostic("手表录音文件缺失", detail: RecordingTransportDiagnostics.shortID(item.id))
                continue
            }
            updatePendingTransferState(item.id, failed: false, awaitingReceipt: false)
            let transfer = session.transferFile(file, metadata: recordingTransferMetadata(item))
            queuedIDs.insert(item.id)
            logger.notice("Queued ordinary recording id=\(RecordingTransportDiagnostics.shortID(item.id), privacy: .public) transferring=\(transfer.isTransferring, privacy: .public)")
            recordDiagnostic("录音文件已交给系统", detail: "系统队列 \(session.outstandingFileTransfers.count)", recordingID: item.id)
        }
        updateConnectivityStatus()
    }

    private func recordingTransferMetadata(_ item: PendingRecording) -> [String: Any] {
        var metadata: [String: Any] = [
            "id": item.id.uuidString,
            "kind": item.kind.rawValue,
            "capturedAt": item.capturedAt,
            "duration": item.duration
        ]
        metadata["captureLocation"] = item.location?.transferData
        metadata["recordingGroupID"] = item.recordingGroupID?.uuidString
        metadata["recordingGroupOrdinal"] = item.recordingGroupOrdinal
        metadata["recordingGroupOffset"] = item.recordingGroupOffset
        metadata["recordingOrigin"] = item.recordingOrigin.flatMap { try? JSONEncoder().encode($0) }
        return metadata
    }

    private func updatePendingTransferState(_ id: UUID, failed: Bool, awaitingReceipt: Bool) {
        guard let index = pending.firstIndex(where: { $0.id == id }) else { return }
        pending[index].transferFailed = failed
        pending[index].awaitingPhoneSaveConfirmation = awaitingReceipt
        do { try persistPending() }
        catch { logger.error("Could not persist transfer status for recording \(RecordingTransportDiagnostics.shortID(id), privacy: .public)") }
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
        guard let raw = userInfo["ack"] as? String, let id = UUID(uuidString: raw) else { return }
        logger.notice("Recording acknowledgement received id=\(RecordingTransportDiagnostics.shortID(id), privacy: .public) path=userInfo")
        recordDiagnostic("iPhone 已保存并回执", recordingID: id)
        markUploaded(id)
    }

    func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        DispatchQueue.main.async { self.applyPhoneContext(applicationContext) }
    }

    private func applyPhoneContext(_ context: [String: Any]) {
        if let enabled = context[CaptureLocationSettings.key] as? Bool { CaptureLocationSettings.setEnabled(enabled) }
        let handledID = UserDefaults.standard.string(forKey: WatchSyncRetryRequest.handledKey).flatMap(UUID.init(uuidString:))
        guard let request = WatchSyncRetryRequest.decode(context), request.shouldHandle(lastHandledID: handledID) else { return }
        logger.notice("Watch retry request received id=\(RecordingTransportDiagnostics.shortID(request.id), privacy: .public) pendingFiles=\(self.pendingCount, privacy: .public) outstandingFiles=\(WCSession.default.outstandingFileTransfers.count, privacy: .public)")
        recordDiagnostic("收到 iPhone 重试请求", detail: "系统队列 \(diagnosticOutstandingFileCount)")
        queuePending()
        // This acknowledges processing the request, not completion of any file transfer.
        UserDefaults.standard.set(request.id.uuidString, forKey: WatchSyncRetryRequest.handledKey)
        publishSyncSnapshot()
    }

    private func markUploaded(_ id: UUID) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            guard let index = self.pending.firstIndex(where: { $0.id == id }) else { return }
            let original = self.pending[index]
            self.pending[index].uploaded = true
            self.pending[index].uploadedAt = original.uploadedAt ?? .now
            self.pending[index].transferFailed = false
            self.pending[index].awaitingPhoneSaveConfirmation = false
            do {
                try self.persistPending()
                self.queuedIDs.remove(id)
                self.message = "已传到 iPhone"
                self.recordDiagnostic("iPhone 已保存并回执", recordingID: id)
                self.updateConnectivityStatus()
            } catch { self.pending[index] = original; self.message = "上传状态保存失败：\(error.localizedDescription)" }
        }
    }

    func session(_ session: WCSession, didFinish fileTransfer: WCSessionFileTransfer, error: Error?) {
        guard let raw = fileTransfer.file.metadata?["id"] as? String,
              let id = UUID(uuidString: raw) else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.queuedIDs.remove(id)
            self.updatePendingTransferState(id, failed: error != nil, awaitingReceipt: error == nil)
            self.logger.notice("File transfer finished for \(id.uuidString, privacy: .public); error: \(error != nil, privacy: .public)")
            self.recordDiagnostic(error == nil ? "系统传输回调成功" : "系统传输失败", detail: error.map(RecordingTransportDiagnostics.errorDescription) ?? "等待 iPhone 保存回执", recordingID: id)
            if let error { self.message = "传输待重试：\(error.localizedDescription)" }
            else { self.message = "已传输，等待 iPhone 确认保存" }
            self.updateConnectivityStatus()
        }
    }

    func session(_ session: WCSession, activationDidCompleteWith state: WCSessionActivationState, error: Error?) {
        DispatchQueue.main.async { [weak self] in
            let isActivated = state == .activated
            let companionInstalled = isActivated && session.isCompanionAppInstalled
            let errorTag = error.map(RecordingTransportDiagnostics.errorCode) ?? "none"
            self?.logger.notice("Watch session activation completed state=\(state.rawValue, privacy: .public) installed=\(companionInstalled, privacy: .public) reachable=\(session.isReachable, privacy: .public) error=\(errorTag, privacy: .public)")
            self?.recordDiagnostic("WatchConnectivity 激活完成", detail: "状态 \(state.rawValue) · iPhone App \(companionInstalled ? "已安装" : "未检测到") · 错误 \(errorTag)")
            self?.updateConnectivityStatus()
            self?.applyPhoneContext(session.receivedApplicationContext)
            self?.queuePending()
        }
    }
    func sessionReachabilityDidChange(_ session: WCSession) {
        DispatchQueue.main.async { [weak self] in
            let isActivated = session.activationState == .activated
            let isReachable = isActivated && session.isReachable
            let companionInstalled = isActivated && session.isCompanionAppInstalled
            self?.logger.notice("Watch reachability changed activation=\(session.activationState.rawValue, privacy: .public) reachable=\(isReachable, privacy: .public) installed=\(companionInstalled, privacy: .public) outstandingFiles=\(session.outstandingFileTransfers.count, privacy: .public) hasContentPending=\(session.hasContentPending, privacy: .public)")
            self?.recordDiagnostic("连接状态变化", detail: "手机可达 \(isReachable ? "是" : "否") · App \(companionInstalled ? "已安装" : "未检测到") · 队列 \(session.outstandingFileTransfers.count)")
            self?.updateConnectivityStatus()
            self?.applyPhoneContext(session.receivedApplicationContext)
            self?.queuePending()
        }
    }

    func sessionCompanionAppInstalledDidChange(_ session: WCSession) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let isActivated = session.activationState == .activated
            let companionInstalled = isActivated && session.isCompanionAppInstalled
            self.logger.notice("Companion app installation changed: \(companionInstalled, privacy: .public)")
            self.updateConnectivityStatus()
            guard WatchConnectivityStatus.shouldRetryPendingTransfers(
                isActivated: isActivated,
                companionAppInstalled: companionInstalled
            ) else { return }
            self.queuePending()
        }
    }
}
