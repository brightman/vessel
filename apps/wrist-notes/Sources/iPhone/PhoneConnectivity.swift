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
}

private struct SimulatorIncomingRecording {
    let metadata: IncomingRecording
    let chunkCount: Int
    var assembler = SimulatorAudioChunkAssembler()
}

final class PhoneConnectivity: NSObject, WCSessionDelegate {
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "cloud.karama.wisenote", category: "WatchConnectivity")
    private let inbox: URL
    private let syncDatabaseURL: URL
    private let sendAcknowledgement: ((UUID) -> Bool)?
    private let transportLock = NSRecursiveLock()
    private var chunkSystemPairingID: String?
    private var chunkReceiver: RecordingChunkReceiver!
    private var receiptRetryTimer: Timer?
    private var locationObservation: NSObjectProtocol?
    private var simulatorTransfers: [UUID: SimulatorIncomingRecording] = [:]
    private let failureLock = NSLock()
    private let contextLock = NSLock()
    private var localSaveFailures: [String: Set<UUID>] = [:]
    var onReceive: ((IncomingRecording, URL) -> Void)?
    var onStatusChange: ((PhoneWatchStatus) -> Void)?

    /// The same aggregate used in the visible status; exposed internally for
    /// lifecycle verification without relying on a simulator's installed Watch.
    var recordingSaveFailed: Bool {
        guard let binding = chunkReceiver?.currentBinding else { return false }
        return chunkReceiver.saveFailed(for: binding.counterpart)
    }

    func refreshStatus() {
        guard WCSession.isSupported() else {
            onStatusChange?(PhoneWatchStatus(isSupported: false))
            return
        }
        let session = WCSession.default
        var status = PhoneWatchStatus(
            isPaired: session.isPaired, isInstalled: session.isWatchAppInstalled,
            isActivated: session.activationState == .activated, isReachable: session.isReachable
        )
        if session.isWatchAppInstalled, let pairingID = activePairingID {
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
                if let binding = currentChunkBinding {
                    if let snapshot = WatchSessionSyncSnapshot.decode(session.receivedApplicationContext, binding: binding) {
                        try store.apply(snapshot, counterpartID: binding.counterpart.key)
                    }
                    let sessions = try store.readSessions(counterpartID: binding.counterpart.key)
                    if let count = sessions.pendingCount { status.pendingCount = (status.pendingCount ?? 0) + count }
                    status.lastSyncedAt = [summary.lastSyncedAt, sessions.lastSyncedAt].compactMap { $0 }.max()
                    status.reportedAt = [summary.reportedAt, sessions.reportedAt].compactMap { $0 }.max()
                } else {
                    status.lastSyncedAt = summary.lastSyncedAt
                    status.reportedAt = summary.reportedAt
                }
                status.phoneSaveFailed = status.phoneSaveFailed || recordingSaveFailed
                status.transferFailureCount = summary.transferFailureCount
                status.missingFileCount = summary.missingFileCount
            } catch {
                status.phoneSaveFailed = true
                logger.error("Watch sync status storage temporarily unavailable: \(error.localizedDescription, privacy: .public)")
            }
        }
        onStatusChange?(status)
    }

    init(inbox: URL, sendAcknowledgement: ((UUID) -> Bool)? = nil, recordingReceiver suppliedRecordingReceiver: RecordingChunkReceiver? = nil) throws {
        self.inbox = inbox
        self.syncDatabaseURL = DaybookDatabase.metadataURL(forRoot: inbox.deletingLastPathComponent())
        self.sendAcknowledgement = sendAcknowledgement
        super.init()
        let sessionRoot = inbox.deletingLastPathComponent().appendingPathComponent("RecordingSessions", isDirectory: true)
        let metadataURL = syncDatabaseURL
        chunkReceiver = try suppliedRecordingReceiver ?? RecordingChunkReceiver(root: inbox.appendingPathComponent("RecordingV2", isDirectory: true), openRepository: {
            try RecordingSessionRepository(root: sessionRoot, database: DaybookDatabase(url: metadataURL))
        }, send: { [weak self] acknowledgement in
            guard let self else { throw RecordingTransportError.unavailable }
            try self.transportLock.withLock {
                guard self.currentChunkBinding == acknowledgement.binding else { throw RecordingTransportError.unavailable }
                let message = try acknowledgement.message()
                if !WCSession.default.outstandingUserInfoTransfers.contains(where: { transfer in
                    message.allSatisfy { key, value in (transfer.userInfo[key] as? Data) == (value as? Data) }
                }) { WCSession.default.transferUserInfo(message) }
            }
        }, retainUntilDelivery: true, committed: { [weak self] acknowledgement in
            guard let self else { throw RecordingTransportError.unavailable }
            let store = try self.syncStore()
            switch acknowledgement {
            case .chunk(let value): try store.recordSaved(value.payload, counterpartID: value.binding.counterpart.key)
            case .end(let value): try store.recordEnd(value.payload, counterpartID: value.binding.counterpart.key)
            }
        })
        chunkReceiver.onFailure = { [weak self] error in
            guard let self else { return }
            self.logger.error("V2 import retained for retry: \(error.localizedDescription, privacy: .public)")
        }
        chunkReceiver.onStatusChange = { [weak self] in
            DispatchQueue.main.async { [weak self] in self?.refreshStatus() }
        }
        receiptRetryTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in self?.resumeRecordingInbox() }
        locationObservation = NotificationCenter.default.addObserver(forName: CaptureLocationSettings.changed, object: nil, queue: .main) { [weak self] _ in self?.syncLocationPreference() }
        // Reception activation must survive protected storage being temporarily unavailable.
        do { try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true) }
        catch { logger.error("Inbox temporarily unavailable: \(error.localizedDescription, privacy: .public)") }
        if WCSession.isSupported() {
            WCSession.default.delegate = self
            logger.notice("Phone session activating; paired: \(WCSession.default.isPaired, privacy: .public), Watch app installed: \(WCSession.default.isWatchAppInstalled, privacy: .public)")
            WCSession.default.activate()
        } else {
            logger.error("Phone session is not supported")
        }
    }

    deinit {
        receiptRetryTimer?.invalidate()
        if let locationObservation { NotificationCenter.default.removeObserver(locationObservation) }
    }

    /// Independent of legacy NoteRepository and its MainActor transcription path.
    func resumeRecordingInbox() { chunkReceiver?.wake() }

    private var currentChunkBinding: RecordingTransferBinding? {
        transportLock.withLock {
            guard let pairing = activePairingID, pairing == chunkSystemPairingID else {
                chunkReceiver?.setBinding(nil); chunkSystemPairingID = nil; return nil
            }
            return chunkReceiver?.currentBinding
        }
    }
    private func offerChunkProtocol() {
        guard activePairingID != nil else { return }
        do {
            try contextLock.withLock {
                var context = WCSession.default.applicationContext
                context[RecordingChunkWire.offerKey] = UUID().uuidString
                try WCSession.default.updateApplicationContext(context)
            }
        } catch { logger.error("V2 capability offer deferred") }
    }
    private func handleChunkMessage(_ message: [String: Any], reply: (([String: Any]) -> Void)? = nil) {
        do {
            if message[RecordingChunkProtocol.capabilityKey] != nil {
                let hello = try RecordingChunkWire.decode(RecordingCapabilityHello.self, key: RecordingChunkProtocol.capabilityKey, from: message)
                let response = try transportLock.withLock { () throws -> RecordingCapabilityReply in
                    guard let pairing = activePairingID else { throw RecordingTransportError.unavailable }
                    let response = try chunkReceiver.negotiate(hello, systemPairingID: pairing)
                    guard activePairingID == pairing else { chunkReceiver.setBinding(nil); throw RecordingTransportError.unavailable }
                    chunkSystemPairingID = pairing
                    return response
                }
                let payload: [String: Any] = [RecordingChunkProtocol.capabilityKey: try JSONEncoder().encode(response)]
                if let reply { reply(payload) } else { WCSession.default.transferUserInfo(payload) }
                resumeRecordingInbox()
            } else if message[RecordingChunkProtocol.endKey] != nil {
                guard currentChunkBinding != nil else { throw RecordingTransportError.unavailable }
                try chunkReceiver.stage(RecordingChunkWire.decode(RecordingWireEnvelope<RecordingSessionEnd>.self, key: RecordingChunkProtocol.endKey, from: message))
                resumeRecordingInbox(); reply?(["accepted": true])
            } else { throw RecordingTransportError.invalidEnvelope }
        } catch {
            reply?(["accepted": false])
            logger.error("V2 message rejected or retained for retry: \(error.localizedDescription, privacy: .public)")
        }
    }

    func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        if RecordingChunkWire.owns(userInfo) { handleChunkMessage(userInfo) }
    }


    func session(_ session: WCSession, didFinish userInfoTransfer: WCSessionUserInfoTransfer, error: Error?) {
        let info = userInfoTransfer.userInfo
        do {
            if info[RecordingChunkProtocol.receiptKey] != nil {
                let value = try RecordingChunkWire.decode(RecordingWireEnvelope<RecordingSavedChunk>.self, key: RecordingChunkProtocol.receiptKey, from: info)
                chunkReceiver.deliveryFinished(.chunk(value), succeeded: error == nil)
            } else if info[RecordingChunkWire.endReceiptKey] != nil {
                let value = try RecordingChunkWire.decode(RecordingWireEnvelope<RecordingSessionEnd>.self, key: RecordingChunkWire.endReceiptKey, from: info)
                chunkReceiver.deliveryFinished(.end(value), succeeded: error == nil)
            }
        } catch { logger.error("V2 delivery completion could not be decoded") }
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
        guard WCSession.isSupported(), activePairingID != nil, WCSession.default.isWatchAppInstalled else {
            throw RetryError.unavailable
        }
        let session = WCSession.default
        let handledID = WatchSyncSnapshot.decode(session.receivedApplicationContext)?.lastHandledRetryID
        do {
            try contextLock.withLock {
                let context = try WatchSyncRetryRequest.preparingContext(
                    session.applicationContext, lastHandledID: handledID
                )
                try session.updateApplicationContext(context)
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
            guard sendAcknowledgement(id) else { return }
        } else {
            let session = WCSession.default
            guard session.activationState == .activated else {
                logger.error("Cannot acknowledge recording \(id.uuidString, privacy: .public): phone session is not activated")
                return
            }
#if targetEnvironment(simulator)
            guard session.isReachable else {
                logger.error("Cannot acknowledge simulator recording \(id.uuidString, privacy: .public): Watch app is not reachable")
                return
            }
            session.sendMessage(["ack": id.uuidString], replyHandler: nil) { error in
                self.logger.error("Failed to send simulator save acknowledgement: \(error.localizedDescription, privacy: .public)")
            }
#else
            WCSession.default.transferUserInfo(["ack": id.uuidString])
#endif
        }
        logger.notice("Queued save acknowledgement for recording \(id.uuidString, privacy: .public)")
        let sidecar = inbox.appendingPathComponent("\(id.uuidString).json")
        try? FileManager.default.removeItem(at: sidecar)
    }

    func session(_ session: WCSession, didReceiveMessage message: [String: Any], replyHandler: @escaping ([String: Any]) -> Void) {
        if RecordingChunkWire.owns(message) { handleChunkMessage(message, reply: replyHandler); return }
#if targetEnvironment(simulator)
        guard message["type"] as? String == "simulator-audio-chunk" else {
            replyHandler(["accepted": false])
            return
        }
        guard let rawID = message["id"] as? String,
              let id = UUID(uuidString: rawID),
              let rawKind = message["kind"] as? String,
              let kind = RecordingKind(rawValue: rawKind),
              let capturedAt = message["capturedAt"] as? Date,
              let duration = message["duration"] as? Double,
              let index = message["chunkIndex"] as? Int,
              let count = message["chunkCount"] as? Int,
              let chunk = message["audioChunk"] as? Data,
              count > 0, count <= 4_096,
              index >= 0, index < count,
              chunk.count <= SimulatorAudioChunks.maximumChunkSize else {
            logger.error("Rejected malformed simulator audio chunk")
            replyHandler(["accepted": false])
            return
        }

        let metadata = IncomingRecording(id: id, kind: kind, capturedAt: capturedAt, duration: duration, location: CaptureLocation.decodeTransfer(message["captureLocation"]), pairingID: activePairingID)
        var transfer: SimulatorIncomingRecording
        if index == 0 {
            transfer = SimulatorIncomingRecording(metadata: metadata, chunkCount: count)
        } else if let existing = simulatorTransfers[id],
                  existing.chunkCount == count,
                  existing.metadata.kind == kind,
                  existing.metadata.capturedAt == capturedAt,
                  existing.metadata.duration == duration {
            transfer = existing
        } else {
            logger.error("Rejected out-of-order simulator audio chunk")
            replyHandler(["accepted": false])
            return
        }

        do {
            let completedAudio = try transfer.assembler.append(chunk, at: index, total: count)
            if let completedAudio {
                try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
                simulatorTransfers.removeValue(forKey: id)
                let audio = inbox.appendingPathComponent("\(id.uuidString).m4a")
                let sidecar = inbox.appendingPathComponent("\(id.uuidString).json")
                try completedAudio.write(to: audio, options: .atomic)
                try JSONEncoder().encode(metadata).write(to: sidecar, options: .atomic)
                logger.notice("Assembled simulator recording \(id.uuidString, privacy: .public); bytes: \(completedAudio.count, privacy: .public)")
                onReceive?(metadata, audio)
            } else {
                simulatorTransfers[id] = transfer
            }
            replyHandler(["accepted": true])
        } catch {
            simulatorTransfers.removeValue(forKey: id)
            logger.error("Failed to assemble simulator recording: \(error.localizedDescription, privacy: .public)")
            reportSaveFailure(id, pairingID: metadata.pairingID)
            replyHandler(["accepted": false])
        }
#else
        replyHandler(["accepted": false])
#endif
    }

    func session(_ session: WCSession, didReceive file: WCSessionFile) {
        logger.notice("Received Watch file callback")
        if RecordingChunkWire.owns(file.metadata ?? [:]) {
            do {
                guard currentChunkBinding != nil else { throw RecordingTransportError.unavailable }
                let value = try RecordingChunkWire.decode(RecordingWireEnvelope<RecordingChunkDescriptor>.self, key: RecordingChunkProtocol.chunkKey, from: file.metadata ?? [:])
                try chunkReceiver.stage(value, temporaryFile: file.fileURL)
                resumeRecordingInbox()
            } catch {
                logger.error("V2 file not acknowledged; Watch original retained: \(error.localizedDescription, privacy: .public)")
            }
            return
        }
        guard let rawID = file.metadata?["id"] as? String,
              let id = UUID(uuidString: rawID),
              let rawKind = file.metadata?["kind"] as? String,
              let kind = RecordingKind(rawValue: rawKind),
              let capturedAt = file.metadata?["capturedAt"] as? Date,
              let duration = file.metadata?["duration"] as? Double else {
            logger.error("Rejected Watch file: transfer metadata is invalid")
            return
        }
        let metadata = IncomingRecording(id: id, kind: kind, capturedAt: capturedAt, duration: duration, location: CaptureLocation.decodeTransfer(file.metadata?["captureLocation"]), pairingID: activePairingID)
        let audio = inbox.appendingPathComponent("\(id.uuidString).m4a")
        let sidecar = inbox.appendingPathComponent("\(id.uuidString).json")
        do {
            try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
            if !FileManager.default.fileExists(atPath: audio.path) {
                // Watch Connectivity removes its temporary file when this callback returns.
                try FileManager.default.moveItem(at: file.fileURL, to: audio)
            }
            try JSONEncoder().encode(metadata).write(to: sidecar, options: .atomic)
            logger.notice("Stored received recording \(id.uuidString, privacy: .public); receiver installed: \(self.onReceive != nil, privacy: .public)")
            onReceive?(metadata, audio)
        } catch {
            // The watch retains its own copy until an acknowledgement arrives.
            logger.error("Failed to persist received Watch file: \(error.localizedDescription, privacy: .public)")
            reportSaveFailure(id, pairingID: metadata.pairingID)
        }
    }

    func session(_ session: WCSession, activationDidCompleteWith state: WCSessionActivationState, error: Error?) {
        logger.notice("Phone session activation completed with state \(state.rawValue, privacy: .public), paired: \(session.isPaired, privacy: .public), Watch app installed: \(session.isWatchAppInstalled, privacy: .public), reachable: \(session.isReachable, privacy: .public), error: \(error != nil, privacy: .public)")
        refreshStatus()
        if state == .activated { syncLocationPreference(); offerChunkProtocol(); drainInbox(); resumeRecordingInbox() }
    }
    func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) { refreshStatus() }
    func sessionReachabilityDidChange(_ session: WCSession) { refreshStatus(); syncLocationPreference(); resumeRecordingInbox() }
    func sessionWatchStateDidChange(_ session: WCSession) { _ = currentChunkBinding; refreshStatus(); offerChunkProtocol() }
    func sessionDidBecomeInactive(_ session: WCSession) { chunkReceiver.setBinding(nil); refreshStatus() }
    func sessionDidDeactivate(_ session: WCSession) { chunkReceiver.setBinding(nil); refreshStatus(); session.activate() }
}
