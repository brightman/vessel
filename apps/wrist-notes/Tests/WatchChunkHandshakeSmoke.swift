import Foundation

@main struct WatchChunkHandshakeSmoke {
    static func main() throws {
        var immediateSent = 0
        var queued = 0
        RecordingReachableMessageDelivery.submit(isReachable: true, sendImmediately: { completion in
            immediateSent += 1
            completion(true)
        }, queue: { queued += 1 })
        precondition(immediateSent == 1 && queued == 0, "reachable control messages should use the acknowledged realtime path")

        RecordingReachableMessageDelivery.submit(isReachable: true, sendImmediately: { completion in
            completion(false)
        }, queue: { queued += 1 })
        precondition(queued == 1, "a rejected realtime control message should fall back to durable user-info delivery")

        var unreachableImmediateSent = 0
        RecordingReachableMessageDelivery.submit(isReachable: false, sendImmediately: { _ in
            unreachableImmediateSent += 1
        }, queue: { queued += 1 })
        precondition(unreachableImmediateSent == 0 && queued == 2, "unreachable control messages should use durable user-info delivery")

        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let queue = try WatchChunkTransferQueue(root: root, sendFile: { _, _ in }, sendEnd: { _ in })

        let first = try queue.beginHandshake()
        let duplicate = try queue.beginHandshake()
        precondition(first == duplicate, "repeated activation/context events must preserve the in-flight nonce")
        precondition(queue.pendingHello == first, "the same challenge remains pending until its reply arrives")

        let chunkID = UUID(), sessionID = UUID(), now = Date()
        let chunk = RecordingChunkDescriptor(id: chunkID, sessionID: sessionID, ordinal: 0,
            sessionStartedAt: now, capturedAt: now, timeZoneIdentifier: "UTC", sessionStartOffset: 0,
            frameCount: 16_000, sampleRate: 16_000, byteCount: 1,
            sha256: String(repeating: "a", count: 64),
            origin: .init(device: "Watch", deviceID: "test-watch", fileName: "test.m4a", recordingTimeIsEstimated: false),
            location: nil)
        try queue.update(chunks: [chunk], ends: [], audioURL: { _ in root.appendingPathComponent("test.m4a") })

        let counterpart = RecordingCounterpart(phoneID: UUID(), pairingID: UUID())
        let binding = RecordingTransferBinding(counterpart: counterpart, watchID: first.watchID, nonce: first.nonce)
        let ledger = root.appendingPathComponent(counterpart.key)
        try RecordingTransportDisk.directory(ledger)
        try Data("damaged receipt".utf8).write(to: ledger.appendingPathComponent("chunk_\(chunkID.uuidString).json"))
        let reply = RecordingCapabilityReply(version: 2, versions: [2], binding: binding,
                                             maximumChunkDuration: 600, supportsLocationSamples: false)
        do {
            try queue.accept(reply)
            preconditionFailure("a damaged saved-receipt ledger must reject the handshake")
        } catch { }
        precondition(queue.binding == nil, "a failed ledger restore must not leave a half-accepted binding")
        precondition(queue.pendingHello == first, "the challenge must remain retryable after receipt restore fails")

        print("Watch chunk handshake: duplicate start is idempotent; receipt restore is atomic")
    }
}
