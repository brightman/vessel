import AVFoundation
import Foundation
import os
import WatchConnectivity

struct IncomingRecording: Codable {
    let id: UUID
    let kind: RecordingKind
    let capturedAt: Date
    let duration: TimeInterval
    var location: CaptureLocation? = nil
    var pairingID: String? = nil
    var recordingGroupID: UUID? = nil
    var recordingGroupOrdinal: Int? = nil
    var recordingGroupOffset: TimeInterval? = nil
    var recordingOrigin: RecordingOrigin? = nil
}

final class PhoneConnectivity: NSObject, WCSessionDelegate {
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "cloud.karama.wisenote", category: "WatchConnectivity")
    private let inbox: URL
    private let syncDatabaseURL: URL
    private let diagnosticsURL: URL
    private let diagnosticsLock = NSLock()
    private var diagnosticEvents: [PhoneTransferDiagnosticEvent] = []
    private let statusSnapshotLock = NSLock()
    private var latestStatus = PhoneWatchStatus()
    private var hasStatusSnapshot = false
    private let sendAcknowledgement: ((UUID) -> Bool)?
    private var locationObservation: NSObjectProtocol?
    private let failureLock = NSLock()
    private let contextLock = NSLock()
    private var localSaveFailures: [String: Set<UUID>] = [:]
    var onReceive: ((IncomingRecording, URL) -> Void)?
    var onStatusChange: ((PhoneWatchStatus) -> Void)?

    func refreshStatus() {
        guard WCSession.isSupported() else {
            var status = PhoneWatchStatus(isSupported: false)
            status.diagnosticEvents = diagnosticSnapshot()
            statusSnapshotLock.withLock { latestStatus = status; hasStatusSnapshot = true }
            onStatusChange?(status)
            return
        }
        let session = WCSession.default
        let isActivated = session.activationState == .activated
        let isPaired = isActivated && session.isPaired
        var status = PhoneWatchStatus(
            isPaired: isPaired, isInstalled: isPaired && session.isWatchAppInstalled,
            isActivated: isActivated, isReachable: isPaired && session.isReachable
        )
        status.diagnosticEvents = diagnosticSnapshot()
        if status.isInstalled, let pairingID = activePairingID {
            status.phoneSaveFailed = failureLock.withLock { !(localSaveFailures[pairingID] ?? []).isEmpty }
            let snapshot = WatchSyncSnapshot.decode(session.receivedApplicationContext)
            if let request = WatchSyncRetryRequest.decode(session.applicationContext) {
                status.retryPending = request.shouldHandle(lastHandledID: snapshot?.lastHandledRetryID)
            }
            do {
                let store = try syncStore()
                if let snapshot {
                    try store.apply(snapshot, pairingID: pairingID)
                }
                let summary = try store.read(pairingID: pairingID)
                status.pendingCount = summary.pendingCount
                status.lastSyncedAt = summary.lastSyncedAt
                status.reportedAt = summary.reportedAt
                status.transferFailureCount = summary.transferFailureCount
                status.missingFileCount = summary.missingFileCount
            } catch {
                status.phoneSaveFailed = true
                logger.error("Watch sync status storage temporarily unavailable: \(error.localizedDescription, privacy: .public)")
            }
        }
        statusSnapshotLock.withLock { latestStatus = status; hasStatusSnapshot = true }
        onStatusChange?(status)
    }

    init(inbox: URL, sendAcknowledgement: ((UUID) -> Bool)? = nil) throws {
        self.inbox = inbox
        self.syncDatabaseURL = DaybookDatabase.metadataURL(forRoot: inbox.deletingLastPathComponent())
        self.diagnosticsURL = syncDatabaseURL.deletingLastPathComponent().appendingPathComponent("watch-transfer-diagnostics.json")
        self.sendAcknowledgement = sendAcknowledgement
        super.init()
        if let data = try? Data(contentsOf: diagnosticsURL),
           let stored = try? JSONDecoder().decode([PhoneTransferDiagnosticEvent].self, from: data) {
            diagnosticEvents = Array(stored.prefix(20))
        }
        locationObservation = NotificationCenter.default.addObserver(forName: CaptureLocationSettings.changed, object: nil, queue: .main) { [weak self] _ in self?.syncLocationPreference() }
        // Reception activation must survive protected storage being temporarily unavailable.
        do { try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true) }
        catch { logger.error("Inbox temporarily unavailable: \(error.localizedDescription, privacy: .public)") }
        recordDiagnostic("iPhone 接收服务启动", "WatchConnectivity 初始化中")
        if WCSession.isSupported() {
            WCSession.default.delegate = self
            logger.notice("Phone session activating")
            WCSession.default.activate()
        } else {
            logger.error("Phone session is not supported")
        }
    }

    deinit {
        if let locationObservation { NotificationCenter.default.removeObserver(locationObservation) }
    }

    private func diagnosticSnapshot() -> [PhoneTransferDiagnosticEvent] {
        diagnosticsLock.withLock { diagnosticEvents }
    }

    func recordImportStarted(_ id: UUID) {
        recordDiagnostic("iPhone 开始导入录音", "录音文件已到达本机", recordingID: id)
    }

    func recordImportSucceeded(_ id: UUID) {
        recordDiagnostic("iPhone 本地保存成功", "等待 Watch 确认回执", recordingID: id)
    }

    func recordImportFailed(_ id: UUID, error: Error) {
        recordDiagnostic("iPhone 本地保存失败", RecordingTransportDiagnostics.errorDescription(error), recordingID: id)
    }

    private func recordDiagnostic(_ title: String, _ detail: String = "", recordingID: UUID? = nil) {
        diagnosticsLock.withLock {
            diagnosticEvents.insert(PhoneTransferDiagnosticEvent(title: title, detail: detail, recordingKey: recordingID.map(RecordingTransportDiagnostics.shortID)), at: 0)
            if diagnosticEvents.count > 20 { diagnosticEvents = Array(diagnosticEvents.prefix(20)) }
            do {
                try JSONEncoder().encode(diagnosticEvents).write(to: diagnosticsURL, options: .atomic)
                #if os(iOS)
                try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: diagnosticsURL.path)
                #endif
            } catch {
                logger.error("Could not persist transfer diagnostics error=\(RecordingTransportDiagnostics.errorCode(error), privacy: .public)")
            }
        }
        let events = diagnosticSnapshot()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let status = self.statusSnapshotLock.withLock { () -> PhoneWatchStatus? in
                guard self.hasStatusSnapshot else { return nil }
                self.latestStatus.diagnosticEvents = events
                return self.latestStatus
            }
            if let status { self.onStatusChange?(status) }
            else if self.onStatusChange != nil { self.refreshStatus() }
        }
    }

    private func syncLocationPreference() {
        guard WCSession.isSupported(), WCSession.default.activationState == .activated else { return }
        do {
            try contextLock.withLock {
                var context = WCSession.default.applicationContext
                context[CaptureLocationSettings.key] = CaptureLocationSettings.enabled
                try WCSession.default.updateApplicationContext(context)
            }
        }
        catch { logger.error("Location preference sync pending: \(error.localizedDescription, privacy: .public)") }
    }

    func drainInbox() {
        guard let files = try? FileManager.default.contentsOfDirectory(at: inbox, includingPropertiesForKeys: nil) else { return }
        logger.notice("Draining inbox with \(files.filter { $0.pathExtension == "json" }.count, privacy: .public) sidecars")
        for sidecar in files where sidecar.pathExtension == "json" {
            guard let metadata = try? JSONDecoder().decode(IncomingRecording.self, from: Data(contentsOf: sidecar)) else { continue }
            let audio = inbox.appendingPathComponent("\(metadata.id.uuidString).m4a")
            onReceive?(metadata, audio)
        }
    }

    private var activePairingID: String? {
        guard WCSession.isSupported() else { return nil }
        let session = WCSession.default
        guard session.activationState == .activated, session.isPaired else { return nil }
        return session.watchDirectoryURL?.lastPathComponent
    }

    private func syncStore() throws -> WatchSyncStore {
        try WatchSyncStore(database: DaybookDatabase(url: syncDatabaseURL))
    }

    func reportSaveFailure(_ id: UUID, pairingID: String? = nil) {
        guard let owner = pairingID ?? activePairingID else { return }
        failureLock.withLock { _ = localSaveFailures[owner, default: []].insert(id) }
        recordDiagnostic("iPhone 保存未完成", "本机保存状态待重试", recordingID: id)
        refreshStatus()
    }

    enum RetryError: LocalizedError {
        case unavailable, submissionFailed
        var errorDescription: String? {
            switch self {
            case .unavailable: String(localized: "同步服务尚未准备好，请确认手表已配对并安装 WiseLife，然后刷新状态。")
            case .submissionFailed: String(localized: "未能提交重试请求，请稍后重试。手表上的录音仍会保留。")
            }
        }
    }

    func requestSyncRetry() throws {
        let session = WCSession.default
        let isActivated = session.activationState == .activated
        let hasPairingID = activePairingID != nil
        let isPaired = isActivated && session.isPaired
        let isInstalled = isActivated && hasPairingID && isPaired && session.isWatchAppInstalled
        guard PhoneWatchStatus.canRequestSyncRetry(
            isSupported: WCSession.isSupported(), isActivated: isActivated,
            hasPairingID: hasPairingID, isPaired: isPaired, isInstalled: isInstalled
        ) else {
            throw RetryError.unavailable
        }
        let handledID = WatchSyncSnapshot.decode(session.receivedApplicationContext)?.lastHandledRetryID
        do {
            try contextLock.withLock {
                let context = try WatchSyncRetryRequest.preparingContext(
                    session.applicationContext, lastHandledID: handledID
                )
                try session.updateApplicationContext(context)
                let requestID = WatchSyncRetryRequest.decode(context)?.id
                logger.notice("Watch retry request submitted id=\(requestID.map(RecordingTransportDiagnostics.shortID) ?? "unknown", privacy: .public) reachable=\(session.isReachable, privacy: .public)")
            }
            refreshStatus()
        } catch {
            logger.error("Watch retry request submission failed: \(error.localizedDescription, privacy: .public)")
            throw RetryError.submissionFailed
        }
    }

    func acknowledge(_ id: UUID, pairingID: String? = nil) {
        // Called only after durable import. Keep the inbox receipt if SQLite is locked.
        if let owner = pairingID ?? activePairingID {
            do { try syncStore().recordSaved(id, pairingID: owner) }
            catch {
                logger.error("Watch save receipt pending: \(error.localizedDescription, privacy: .public)")
                reportSaveFailure(id, pairingID: owner)
                return
            }
            failureLock.withLock { _ = localSaveFailures[owner]?.remove(id) }
            refreshStatus()
            // Do not send a receipt to a different Watch during active-device switching.
            guard owner == activePairingID else { return }
        }
        if let sendAcknowledgement {
            guard sendAcknowledgement(id) else {
                recordDiagnostic("保存回执提交失败", "回执通道未接受", recordingID: id)
                return
            }
            recordDiagnostic("iPhone 保存回执已提交", "", recordingID: id)
        } else {
            let session = WCSession.default
            guard session.activationState == .activated else {
                logger.error("Cannot acknowledge recording \(id.uuidString, privacy: .public): phone session is not activated")
                recordDiagnostic("保存完成，回执未提交", "WatchConnectivity 未激活", recordingID: id)
                return
            }
            WCSession.default.transferUserInfo(["ack": id.uuidString])
            recordDiagnostic("iPhone 保存回执已排队", "WatchConnectivity 后台消息", recordingID: id)
        }
        logger.notice("Queued save acknowledgement for recording \(id.uuidString, privacy: .public)")
        let sidecar = inbox.appendingPathComponent("\(id.uuidString).json")
        try? FileManager.default.removeItem(at: sidecar)
    }

    func session(_ session: WCSession, didReceive file: WCSessionFile) {
        guard let rawID = file.metadata?["id"] as? String,
              let id = UUID(uuidString: rawID),
              let rawKind = file.metadata?["kind"] as? String,
              let kind = RecordingKind(rawValue: rawKind),
              let capturedAt = file.metadata?["capturedAt"] as? Date,
              let duration = file.metadata?["duration"] as? Double else {
            logger.error("Rejected Watch file: transfer metadata is invalid")
            return
        }
        let metadata = IncomingRecording(id: id, kind: kind, capturedAt: capturedAt, duration: duration,
            location: CaptureLocation.decodeTransfer(file.metadata?["captureLocation"]), pairingID: activePairingID,
            recordingGroupID: (file.metadata?["recordingGroupID"] as? String).flatMap(UUID.init(uuidString:)),
            recordingGroupOrdinal: file.metadata?["recordingGroupOrdinal"] as? Int,
            recordingGroupOffset: file.metadata?["recordingGroupOffset"] as? Double,
            recordingOrigin: (file.metadata?["recordingOrigin"] as? Data).flatMap { try? JSONDecoder().decode(RecordingOrigin.self, from: $0) })
        persistReceivedRecording(metadata, temporaryFileURL: file.fileURL)
    }

    private func persistReceivedRecording(_ metadata: IncomingRecording, temporaryFileURL: URL) {
        let id = metadata.id
        let capturedAt = metadata.capturedAt
        let duration = metadata.duration
        let hasGroupFields = metadata.recordingGroupID != nil || metadata.recordingGroupOrdinal != nil || metadata.recordingGroupOffset != nil
        if hasGroupFields {
            guard let groupID = metadata.recordingGroupID, let ordinal = metadata.recordingGroupOrdinal,
                  let offset = metadata.recordingGroupOffset, (0...RecordingSessionFileLimits.maximumOrdinal).contains(ordinal), offset.isFinite, offset >= 0,
                  abs(offset - Double(ordinal) * RecordingSessionFileLimits.fileDuration) < 0.001,
                  id == RecordingChunkFileIdentity.stableID(groupID: groupID, ordinal: ordinal),
                  RecordingChunkFileMetadata.matches(groupID: groupID, ordinal: ordinal,
                                                     capturedAt: capturedAt, audioURL: temporaryFileURL) else {
                logger.error("Rejected grouped Watch file: identity or embedded M4A metadata mismatch")
                recordDiagnostic("录音文件校验失败", "录音组信息或 M4A 开始时间不匹配", recordingID: id)
                reportSaveFailure(id, pairingID: metadata.pairingID)
                return
            }
        }
        let fileBytes = (try? temporaryFileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? -1
        logger.notice("Ordinary Watch recording file received id=\(RecordingTransportDiagnostics.shortID(id), privacy: .public) bytes=\(fileBytes, privacy: .public) duration=\(duration, privacy: .public)")
        let groupLabel = metadata.recordingGroupOrdinal.map { " · 录音组第 \($0 + 1) 个文件" } ?? ""
        recordDiagnostic("iPhone 收到录音文件", "\(fileBytes) B · \(Int(duration)) 秒\(groupLabel)", recordingID: id)
        let audio = inbox.appendingPathComponent("\(id.uuidString).m4a")
        let sidecar = inbox.appendingPathComponent("\(id.uuidString).json")
        do {
            try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
            if !FileManager.default.fileExists(atPath: audio.path) {
                try FileManager.default.moveItem(at: temporaryFileURL, to: audio)
            }
            try JSONEncoder().encode(metadata).write(to: sidecar, options: .atomic)
            logger.notice("Stored received recording \(id.uuidString, privacy: .public); receiver installed: \(self.onReceive != nil, privacy: .public)")
            recordDiagnostic("录音已暂存，准备导入", "录音文件和信息已写入本机收件箱", recordingID: id)
            onReceive?(metadata, audio)
        } catch {
            // The watch retains its own copy until an acknowledgement arrives.
            logger.error("Failed to persist received Watch file: \(error.localizedDescription, privacy: .public)")
            recordDiagnostic("录音文件保存失败", RecordingTransportDiagnostics.errorDescription(error), recordingID: id)
            reportSaveFailure(id, pairingID: metadata.pairingID)
        }
    }

    func session(_ session: WCSession, activationDidCompleteWith state: WCSessionActivationState, error: Error?) {
        let isActivated = state == .activated
        let isPaired = isActivated && session.isPaired
        let isInstalled = isPaired && session.isWatchAppInstalled
        let isReachable = isPaired && session.isReachable
        logger.notice("Phone session activation completed state=\(state.rawValue, privacy: .public) paired=\(isPaired, privacy: .public) installed=\(isInstalled, privacy: .public) reachable=\(isReachable, privacy: .public) error=\(error.map(RecordingTransportDiagnostics.errorCode) ?? "none", privacy: .public)")
        recordDiagnostic("WatchConnectivity 激活\(error == nil ? "完成" : "失败")", "配对 \(isPaired ? "是" : "否") · App \(isInstalled ? "已安装" : "未安装") · 可达 \(isReachable ? "是" : "否")\(error.map { " · \(RecordingTransportDiagnostics.errorDescription($0))" } ?? "")")
        refreshStatus()
        if state == .activated { syncLocationPreference(); drainInbox() }
    }
    func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        let hasLegacySnapshot = applicationContext[WatchSyncSnapshot.contextKey] != nil
        let hasRetryRequest = applicationContext[WatchSyncRetryRequest.contextKey] != nil
        recordDiagnostic("收到 Watch 状态快照", "同步状态 \(hasLegacySnapshot ? "有" : "无") · 重试请求 \(hasRetryRequest ? "有" : "无")")
        refreshStatus()
    }
    func sessionReachabilityDidChange(_ session: WCSession) {
        logger.notice("Phone reachability changed activation=\(session.activationState.rawValue, privacy: .public) paired=\(session.isPaired, privacy: .public) installed=\(session.isWatchAppInstalled, privacy: .public) reachable=\(session.isReachable, privacy: .public) outstandingFiles=\(session.outstandingFileTransfers.count, privacy: .public) hasContentPending=\(session.hasContentPending, privacy: .public)")
        recordDiagnostic("Watch 连接状态变化", "已配对 \(session.isPaired ? "是" : "否") · App \(session.isWatchAppInstalled ? "已安装" : "未安装") · 可达 \(session.isReachable ? "是" : "否") · 文件队列 \(session.outstandingFileTransfers.count)")
        refreshStatus(); syncLocationPreference()
    }
    func sessionWatchStateDidChange(_ session: WCSession) {
        recordDiagnostic("Watch 配对状态变化", "已配对 \(session.isPaired ? "是" : "否") · App \(session.isWatchAppInstalled ? "已安装" : "未安装") · 可达 \(session.isReachable ? "是" : "否")")
        refreshStatus()
    }
    func sessionDidBecomeInactive(_ session: WCSession) {
        recordDiagnostic("WatchConnectivity 暂停", "iPhone 正在切换配对手表")
        refreshStatus()
    }
    func sessionDidDeactivate(_ session: WCSession) {
        recordDiagnostic("WatchConnectivity 重新激活", "配对手表切换完成")
        refreshStatus(); session.activate()
    }
}
