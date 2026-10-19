import Foundation
import os
import WatchConnectivity

struct IncomingRecording: Codable {
    let id: UUID
    let kind: RecordingKind
    let capturedAt: Date
    let duration: TimeInterval
}

private struct SimulatorIncomingRecording {
    let metadata: IncomingRecording
    let chunkCount: Int
    var assembler = SimulatorAudioChunkAssembler()
}

final class PhoneConnectivity: NSObject, WCSessionDelegate {
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "cloud.karama.wisenote", category: "WatchConnectivity")
    private let inbox: URL
    private var simulatorTransfers: [UUID: SimulatorIncomingRecording] = [:]
    var onReceive: ((IncomingRecording, URL) -> Void)?
    var onStatusChange: ((PhoneWatchStatus) -> Void)?

    func refreshStatus() {
        guard WCSession.isSupported() else {
            onStatusChange?(PhoneWatchStatus(isSupported: false))
            return
        }
        let session = WCSession.default
        onStatusChange?(PhoneWatchStatus(
            isPaired: session.isPaired, isInstalled: session.isWatchAppInstalled,
            isActivated: session.activationState == .activated, isReachable: session.isReachable
        ))
    }

    init(inbox: URL) throws {
        self.inbox = inbox
        try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        super.init()
        if WCSession.isSupported() {
            WCSession.default.delegate = self
            logger.notice("Phone session activating; paired: \(WCSession.default.isPaired, privacy: .public), Watch app installed: \(WCSession.default.isWatchAppInstalled, privacy: .public)")
            WCSession.default.activate()
        } else {
            logger.error("Phone session is not supported")
        }
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

    func acknowledge(_ id: UUID) {
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
        logger.notice("Queued save acknowledgement for recording \(id.uuidString, privacy: .public)")
        let sidecar = inbox.appendingPathComponent("\(id.uuidString).json")
        try? FileManager.default.removeItem(at: sidecar)
    }

    func session(_ session: WCSession, didReceiveMessage message: [String: Any], replyHandler: @escaping ([String: Any]) -> Void) {
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

        let metadata = IncomingRecording(id: id, kind: kind, capturedAt: capturedAt, duration: duration)
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
            replyHandler(["accepted": false])
        }
#else
        replyHandler(["accepted": false])
#endif
    }

    func session(_ session: WCSession, didReceive file: WCSessionFile) {
        logger.notice("Received Watch file callback")
        guard let rawID = file.metadata?["id"] as? String,
              let id = UUID(uuidString: rawID),
              let rawKind = file.metadata?["kind"] as? String,
              let kind = RecordingKind(rawValue: rawKind),
              let capturedAt = file.metadata?["capturedAt"] as? Date,
              let duration = file.metadata?["duration"] as? Double else {
            logger.error("Rejected Watch file: transfer metadata is invalid")
            return
        }
        let metadata = IncomingRecording(id: id, kind: kind, capturedAt: capturedAt, duration: duration)
        let audio = inbox.appendingPathComponent("\(id.uuidString).m4a")
        let sidecar = inbox.appendingPathComponent("\(id.uuidString).json")
        do {
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
        }
    }

    func session(_ session: WCSession, activationDidCompleteWith state: WCSessionActivationState, error: Error?) {
        logger.notice("Phone session activation completed with state \(state.rawValue, privacy: .public), paired: \(session.isPaired, privacy: .public), Watch app installed: \(session.isWatchAppInstalled, privacy: .public), reachable: \(session.isReachable, privacy: .public), error: \(error != nil, privacy: .public)")
        refreshStatus()
    }
    func sessionReachabilityDidChange(_ session: WCSession) { refreshStatus() }
    func sessionWatchStateDidChange(_ session: WCSession) { refreshStatus() }
    func sessionDidBecomeInactive(_ session: WCSession) { refreshStatus() }
    func sessionDidDeactivate(_ session: WCSession) { refreshStatus(); session.activate() }
}
