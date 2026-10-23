import Foundation

/// Synchronous intake retains the WC temporary file. All media/SQLite work is on worker.
/// Repository is ALWAYS the outermost SQL transaction owner.
final class RecordingChunkReceiver {
    static let didChange = Notification.Name("WiseLife.RecordingSessionsDidChange")
    enum Event: String { case inbox, validate, commit, outbox }
    private struct Identity: Codable {
        let phoneID: UUID
        var pairings: [String: UUID]
        var challenges: [String: RecordingCapabilityHello]? = nil
    }
    private struct Incoming: Codable {
        let binding: RecordingTransferBinding
        let chunk: RecordingChunkDescriptor?
        let end: RecordingSessionEnd?
        var location: RecordingLocationSample? = nil
    }
    private struct Outgoing: Codable {
        let counterpart: RecordingCounterpart
        let chunk: RecordingSavedChunk?
        let end: RecordingSessionEnd?
        var location: RecordingLocationSample? = nil
        var nextAttempt: Date? = nil
    }
    private let retainUntilDelivery: Bool
    private let now: () -> Date
    private let root: URL
    private let openRepository: () throws -> RecordingSessionRepository
    private let send: (RecordingTransferAcknowledgement) throws -> Void
    private let event: ((Event) throws -> Void)?
    private let committed: ((RecordingTransferAcknowledgement) throws -> Void)?
    private let worker = DispatchQueue(label: "WiseLife.recordingChunkReceiver", qos: .utility)
    private let lock = NSLock()
    private var binding: RecordingTransferBinding?
    private var wakeScheduled = false
    var onFailure: ((Error) -> Void)?
    /// One publication after the complete serial drain, including empty replay.
    var onStatusChange: (() -> Void)?
    private var failedCounterparts: Set<String> = []
    private var intakeFailureVersions: [String: UInt64] = [:]
    private struct DrainStatus {
        var attempted: Set<String> = []
        var failed: Set<String> = []
        mutating func include(_ key: String?) { if let key { attempted.insert(key) } }
        mutating func fail(_ key: String?) { if let key { attempted.insert(key); failed.insert(key) } }
    }
    func saveFailed(for counterpart: RecordingCounterpart) -> Bool {
        lock.withLock { failedCounterparts.contains(counterpart.key) }
    }
    private func publish(_ status: DrainStatus, startedWith versions: [String: UInt64]) {
        lock.withLock {
            // Intake runs synchronously on WC callbacks, outside this worker.
            // A drain cannot clear a failure newer than its inbox snapshot.
            for key in status.attempted where intakeFailureVersions[key, default: 0] == versions[key, default: 0] {
                failedCounterparts.remove(key)
            }
            failedCounterparts.formUnion(status.failed)
        }
        onStatusChange?()
    }
    private func intakeFailed(_ error: Error, counterpart: RecordingCounterpart) {
        lock.withLock {
            failedCounterparts.insert(counterpart.key)
            intakeFailureVersions[counterpart.key, default: 0] &+= 1
        }
        onFailure?(error); onStatusChange?()
    }

    init(root: URL, openRepository: @escaping () throws -> RecordingSessionRepository,
         send: @escaping (RecordingTransferAcknowledgement) throws -> Void,
         retainUntilDelivery: Bool = false, now: @escaping () -> Date = Date.init,
         committed: ((RecordingTransferAcknowledgement) throws -> Void)? = nil,
         event: ((Event) throws -> Void)? = nil) throws {
        self.root = root; self.openRepository = openRepository; self.send = send
        self.retainUntilDelivery = retainUntilDelivery; self.now = now
        self.committed = committed; self.event = event
        // No protected storage access here: the delegate can activate while locked.
    }
    var currentBinding: RecordingTransferBinding? { lock.withLock { binding } }
    func setBinding(_ value: RecordingTransferBinding?) { lock.withLock { binding = value } }

    /// Small durable capability identity; no database, audio, or legacy model dependency.
    func negotiate(_ hello: RecordingCapabilityHello, systemPairingID: String) throws -> RecordingCapabilityReply {
        try lock.withLock {
            guard hello.version == 2, hello.generation >= 0, !systemPairingID.isEmpty else { throw RecordingTransportError.invalidEnvelope }
            let url = root.appendingPathComponent("identity.json")
            var identity: Identity
            if FileManager.default.fileExists(atPath: url.path) { identity = try RecordingTransportDisk.read(Identity.self, at: url) }
            else { identity = Identity(phoneID: UUID(), pairings: [:]) }
            let key = "\(systemPairingID)/\(hello.watchID.uuidString)"
            if let previous = identity.challenges?[key] {
                guard hello.generation > previous.generation || hello == previous else { throw RecordingTransportError.invalidEnvelope }
            }
            if identity.challenges == nil { identity.challenges = [:] }
            identity.challenges?[key] = hello
            if identity.pairings[key] == nil { identity.pairings[key] = UUID() }
            try RecordingTransportDisk.write(identity, to: url)
            let value = RecordingTransferBinding(counterpart: .init(phoneID: identity.phoneID, pairingID: identity.pairings[key]!), watchID: hello.watchID, nonce: hello.nonce)
            binding = value
            return .init(version: 2, versions: [2], binding: value, maximumChunkDuration: RecordingChunkProtocol.chunkDuration, supportsLocationSamples: true)
        }
    }
    func stage(_ envelope: RecordingWireEnvelope<RecordingChunkDescriptor>, temporaryFile: URL) throws {
        guard let current = currentBinding else { throw RecordingTransportError.unavailable }
        try envelope.validate(binding: current); try envelope.payload.validate()
        do {
            let folder = root.appendingPathComponent("Incoming").appendingPathComponent(UUID().uuidString)
            try RecordingTransportDisk.directory(folder)
            try RecordingTransportDisk.write(Incoming(binding: current, chunk: envelope.payload, end: nil), to: folder.appendingPathComponent("manifest.json"))
            let destination = folder.appendingPathComponent("audio.m4a")
            try RecordingAudioFile.requireSafePath(temporaryFile)
            try FileManager.default.moveItem(at: temporaryFile, to: destination)
            #if os(iOS)
            try FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: destination.path)
            #endif
            try RecordingTransportDisk.syncFile(destination)
            try RecordingTransportDisk.syncDirectory(folder)
            try event?(.inbox)
        } catch { intakeFailed(error, counterpart: current.counterpart); throw error }
    }
    func stage(_ envelope: RecordingWireEnvelope<RecordingSessionEnd>) throws {
        guard let current = currentBinding else { throw RecordingTransportError.unavailable }
        try envelope.validate(binding: current); try envelope.payload.validate()
        do {
            let folder = root.appendingPathComponent("Incoming").appendingPathComponent(UUID().uuidString)
            try RecordingTransportDisk.write(Incoming(binding: current, chunk: nil, end: envelope.payload), to: folder.appendingPathComponent("manifest.json"))
            try event?(.inbox)
        } catch { intakeFailed(error, counterpart: current.counterpart); throw error }
    }
    func stage(_ envelope: RecordingWireEnvelope<RecordingLocationSample>) throws {
        guard let current = currentBinding else { throw RecordingTransportError.unavailable }
        try envelope.validate(binding: current); try envelope.payload.validate()
        do {
            let folder = root.appendingPathComponent("Incoming").appendingPathComponent(UUID().uuidString)
            try RecordingTransportDisk.write(Incoming(binding: current, chunk: nil, end: nil, location: envelope.payload), to: folder.appendingPathComponent("manifest.json"))
            try event?(.inbox)
        } catch { intakeFailed(error, counterpart: current.counterpart); throw error }
    }
    func wake() {
        let enqueue = lock.withLock { () -> Bool in
            guard !wakeScheduled else { return false }; wakeScheduled = true; return true
        }
        guard enqueue else { return }
        worker.async { [weak self] in
            guard let self else { return }
            self.lock.withLock { self.wakeScheduled = false }
            do { try self.drainLocked() } catch { self.onFailure?(error) }
        }
    }
    /// Synchronous entry also used by deterministic tests; the same serial worker owns it.
    func drain() throws { try worker.sync { try drainLocked() } }

    private func drainLocked() throws {
        let (currentKey, versions) = lock.withLock { (binding?.counterpart.key, intakeFailureVersions) }
        var status = DrainStatus()
        status.include(currentKey)
        defer { publish(status, startedWith: versions) }
        let repository: RecordingSessionRepository
        let folders: [URL]
        do {
            repository = try openRepository()
            // The 30-second receipt retry also visits an empty inbox. Only actual
            // recovery commits may invalidate content; transfer health is still
            // published by the deferred onStatusChange callback on every drain.
            if repository.consumeRecoveryChanges() {
                NotificationCenter.default.post(name: Self.didChange, object: nil)
            }
            let inbox = root.appendingPathComponent("Incoming")
            try RecordingTransportDisk.directory(inbox)
            folders = try FileManager.default.contentsOfDirectory(at: inbox, includingPropertiesForKeys: nil)
        } catch { status.fail(currentKey); throw error }
        var firstError: Error?
        for folder in folders.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            guard UUID(uuidString: folder.lastPathComponent) != nil else { continue }
            var itemKey = currentKey
            do {
                try RecordingAudioFile.requireSafePath(folder)
                let incoming = try RecordingTransportDisk.read(Incoming.self, at: folder.appendingPathComponent("manifest.json"))
                itemKey = incoming.binding.counterpart.key
                status.include(itemKey)
                let outgoing: Outgoing
                if let chunk = incoming.chunk, incoming.end == nil, incoming.location == nil {
                    let audio = folder.appendingPathComponent("audio.m4a")
                    _ = try RecordingAudioFile.validate(chunk, at: audio)
                    try event?(.validate)
                    // No enclosing transaction/savepoint: successful return proves COMMIT.
                    let receipt = try repository.importChunk(chunk, from: audio, pairingID: incoming.binding.counterpart.key)
                    guard let savedAt = try repository.receiptSavedAt(chunkID: receipt.chunkID, pairingID: incoming.binding.counterpart.key) else { throw RecordingTransportError.invalidStorage }
                    outgoing = .init(counterpart: incoming.binding.counterpart, chunk: .init(receipt: receipt, savedAt: savedAt), end: nil)
                } else if let end = incoming.end, incoming.chunk == nil, incoming.location == nil {
                    try repository.applyEnd(end, pairingID: incoming.binding.counterpart.key)
                    guard let stored = try repository.storedEnd(sessionID: end.sessionID), stored == end else { throw RecordingTransportError.conflict }
                    outgoing = .init(counterpart: incoming.binding.counterpart, chunk: nil, end: stored)
                } else if let sample = incoming.location, incoming.chunk == nil, incoming.end == nil {
                    try repository.importLocationSample(sample, pairingID: incoming.binding.counterpart.key)
                    outgoing = .init(counterpart: incoming.binding.counterpart, chunk: nil, end: nil, location: sample)
                } else { throw RecordingTransportError.invalidStorage }
                NotificationCenter.default.post(name: Self.didChange, object: nil,
                    userInfo: incoming.location.map { ["sessionID": $0.sessionID, "locationUpdated": true] })
                try event?(.commit)
                try RecordingTransportDisk.write(outgoing, to: outboxURL(outgoing))
                try event?(.outbox)
                // Cleanup may fail; the same durable inbox replays idempotently.
                try? FileManager.default.removeItem(at: folder)
            } catch { status.fail(itemKey); firstError = firstError ?? error; onFailure?(error) }
        }
        // Independently replay durable receipts even when another inbox item fails.
        do { try sendOutbox(status: &status, currentKey: currentKey) }
        catch { firstError = firstError ?? error; onFailure?(error) }
        if let firstError { throw firstError }
    }
    private func outboxURL(_ value: Outgoing) -> URL {
        let name: String
        if let chunk = value.chunk { name = "chunk_\(chunk.receipt.chunkID.uuidString)" }
        else if let sample = value.location { name = "location_\(sample.id.uuidString)" }
        else { name = "end_\(value.end!.sessionID.uuidString)_\(value.end!.revision)" }
        return root.appendingPathComponent("Outgoing").appendingPathComponent("\(value.counterpart.key)_\(name).json")
    }
    /// WC delivery completion is distinct from enqueue. A stale nonce cannot retire
    /// an ACK that the current Watch would reject. Watch persistence still replays via file/end retry.
    func deliveryFinished(_ acknowledgement: RecordingTransferAcknowledgement, succeeded: Bool) {
        worker.async { [weak self] in
            guard let self else { return }
            do {
                guard self.currentBinding == acknowledgement.binding else { return }
                let expected: Outgoing
                switch acknowledgement {
                case .chunk(let v):
                    try v.validate(binding: acknowledgement.binding)
                    expected = .init(counterpart: v.binding.counterpart, chunk: v.payload, end: nil)
                case .location(let v):
                    try v.validate(binding: acknowledgement.binding)
                    expected = .init(counterpart: v.binding.counterpart, chunk: nil, end: nil, location: v.payload)
                case .end(let v):
                    try v.validate(binding: acknowledgement.binding)
                    expected = .init(counterpart: v.binding.counterpart, chunk: nil, end: v.payload)
                }
                let url = self.outboxURL(expected)
                guard FileManager.default.fileExists(atPath: url.path) else { return }
                var value = try RecordingTransportDisk.read(Outgoing.self, at: url)
                guard value.counterpart == expected.counterpart, value.chunk == expected.chunk, value.end == expected.end, value.location == expected.location else { return }
                if succeeded { try FileManager.default.removeItem(at: url) }
                else { value.nextAttempt = nil; try RecordingTransportDisk.write(value, to: url) }
            } catch { self.intakeFailed(error, counterpart: acknowledgement.binding.counterpart) }
        }
    }
    private func sendOutbox(status: inout DrainStatus, currentKey: String?) throws {
        let directory = root.appendingPathComponent("Outgoing")
        let files: [URL]
        do {
            try RecordingTransportDisk.directory(directory)
            files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        } catch { status.fail(currentKey); throw error }
        var firstError: Error?
        for url in files where url.pathExtension == "json" {
            var itemKey = currentKey
            do {
                var value = try RecordingTransportDisk.read(Outgoing.self, at: url)
                itemKey = value.counterpart.key
                // Inactive counterparts keep their own status until their outbox
                // can actually be retried against an authorized binding.
                guard let current = currentBinding, current.counterpart == value.counterpart else { continue }
                status.include(itemKey)
                if let deadline = value.nextAttempt, deadline > now(), deadline.timeIntervalSince(now()) <= 3600 { continue }
                let acknowledgement: RecordingTransferAcknowledgement
                if let chunk = value.chunk, value.end == nil, value.location == nil {
                    try chunk.validate()
                    acknowledgement = .chunk(.init(binding: current, payload: chunk))
                } else if let end = value.end, value.chunk == nil, value.location == nil {
                    try end.validate()
                    acknowledgement = .end(.init(binding: current, payload: end))
                } else if let sample = value.location, value.chunk == nil, value.end == nil {
                    try sample.validate()
                    acknowledgement = .location(.init(binding: current, payload: sample))
                } else { throw RecordingTransportError.invalidStorage }
                try committed?(acknowledgement)
                // Adapter must check the current system pairing again at submission.
                try send(acknowledgement)
                if retainUntilDelivery {
                    value.nextAttempt = now().addingTimeInterval(30)
                    try RecordingTransportDisk.write(value, to: url)
                } else { try FileManager.default.removeItem(at: url) }
            } catch { status.fail(itemKey); firstError = firstError ?? error }
        }
        if let firstError { throw firstError }
    }
}
