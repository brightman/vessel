import Foundation

struct WatchChunkSessionState: Equatable, Identifiable {
    let id: UUID
    let savedChunkCount: Int
    let chunkCount: Int
    let end: RecordingSessionEnd?
    let isComplete: Bool
}

/// Serial caller ownership: the production adapter calls on the main queue.
/// Files remain in the capture store; this ledger never trusts its unscoped receipts.
final class WatchChunkTransferQueue {
    private struct Identity: Codable { let id: UUID; var generation: Int }
    private var generation = 0
    private struct Attempt: Codable { let count: Int; let retryAt: Date }
    private struct ReceiptSnapshot {
        let chunks: [UUID: RecordingSavedChunk]
        let ends: [UUID: RecordingSessionEnd]
        let locations: [UUID: RecordingLocationSample]
    }
    private let root: URL
    private let now: () -> Date
    private let sendHello: (RecordingCapabilityHello) throws -> Void
    private let sendFile: (URL, RecordingWireEnvelope<RecordingChunkDescriptor>) throws -> Void
    private let sendLocation: (RecordingWireEnvelope<RecordingLocationSample>) throws -> Void
    private var locations: [RecordingLocationSample] = []
    private var locationReceipts: [UUID: RecordingLocationSample] = [:]
    private var supportsLocationSamples = false
    private let sendEnd: (RecordingWireEnvelope<RecordingSessionEnd>) throws -> Void
    private let outstandingFileCount: () -> Int
    private let isOutstanding: (UUID, Bool, RecordingTransferBinding) -> Bool
    private var chunks: [RecordingChunkDescriptor] = []
    private var ends: [RecordingSessionEnd] = []
    private var audioURL: ((RecordingChunkDescriptor) -> URL)?
    private var chunkReceipts: [UUID: RecordingSavedChunk] = [:]
    private var endReceipts: [UUID: RecordingSessionEnd] = [:]
    private var challenge: RecordingCapabilityHello?
    private(set) var binding: RecordingTransferBinding?
    private(set) var unsupported = false
    private(set) var maximumChunkDuration: TimeInterval?
    var requiresCompanionUpdate: Bool {
        guard binding != nil, let maximumChunkDuration else { return false }
        return chunks.contains { chunkReceipts[$0.id] == nil && $0.duration > maximumChunkDuration }
    }
    let watchID: UUID
    var lastSavedAt: Date? { chunkReceipts.values.map(\.savedAt).max() }
    var sessionStates: [WatchChunkSessionState] {
        let grouped = Dictionary(grouping: chunks, by: \.sessionID)
        return Set(grouped.keys).union(ends.map(\.sessionID)).map { id in
            let values = grouped[id] ?? [], end = ends.first { $0.sessionID == id }
            let saved = values.filter { chunkReceipts[$0.id] != nil }.count
            let coverage: Bool
            if let end {
                coverage = end.finalOrdinal.map { final in
                    values.count == final + 1 && values.map(\.ordinal).sorted().enumerated().allSatisfy { $0.offset == $0.element }
                } ?? values.isEmpty
            } else { coverage = false }
            return .init(id: id, savedChunkCount: saved, chunkCount: values.count, end: end,
                         isComplete: binding != nil && coverage && saved == values.count && end != nil && endReceipts[id] == end)
        }.sorted { $0.id.uuidString < $1.id.uuidString }
    }
    var pendingCount: Int { sessionStates.filter { !$0.isComplete }.count }

    init(root: URL, now: @escaping () -> Date = Date.init,
         outstandingFileCount: @escaping () -> Int = { 0 },
         isOutstanding: @escaping (UUID, Bool, RecordingTransferBinding) -> Bool = { _, _, _ in false },
         sendHello: @escaping (RecordingCapabilityHello) throws -> Void = { _ in },
         sendFile: @escaping (URL, RecordingWireEnvelope<RecordingChunkDescriptor>) throws -> Void,
         sendEnd: @escaping (RecordingWireEnvelope<RecordingSessionEnd>) throws -> Void,
         sendLocation: @escaping (RecordingWireEnvelope<RecordingLocationSample>) throws -> Void = { _ in }) throws {
        self.root = root; self.now = now; self.isOutstanding = isOutstanding
        self.outstandingFileCount = outstandingFileCount
        self.sendLocation = sendLocation
        self.sendHello = sendHello; self.sendFile = sendFile; self.sendEnd = sendEnd
        try RecordingTransportDisk.directory(root)
        let identity = root.appendingPathComponent("watch.json")
        if FileManager.default.fileExists(atPath: identity.path) {
            if let stored = try? RecordingTransportDisk.read(Identity.self, at: identity) {
                guard stored.generation >= 0 else { throw RecordingTransportError.invalidStorage }
                watchID = stored.id; generation = stored.generation
            } else { watchID = try RecordingTransportDisk.read(UUID.self, at: identity) }
        } else { watchID = UUID(); try RecordingTransportDisk.write(Identity(id: watchID, generation: 0), to: identity) }
    }
    @discardableResult func beginHandshake() throws -> RecordingCapabilityHello {
        // WatchConnectivity activation, reachability, app-foreground, and phone
        // capability-offer callbacks can overlap. Replacing an in-flight nonce
        // makes a valid reply look stale at the Watch and the next-generation
        // challenge look invalid at the phone. Reuse the outstanding challenge;
        // a fresh nonce is only needed after the prior reply has been accepted.
        if let challenge { return challenge }
        binding = nil; supportsLocationSamples = false; locationReceipts = [:]; maximumChunkDuration = nil; unsupported = false; chunkReceipts = [:]; endReceipts = [:]; challenge = nil
        guard generation < Int.max else { throw RecordingTransportError.invalidStorage }
        let next = generation + 1
        try RecordingTransportDisk.write(Identity(id: watchID, generation: next), to: root.appendingPathComponent("watch.json"))
        generation = next
        let value = RecordingCapabilityHello(watchID: watchID, nonce: UUID(), generation: next)
        challenge = value
        return value
    }
    func requestCapability() throws {
        guard binding == nil else { return }
        try sendHello(challenge ?? beginHandshake())
    }
    /// A peer-level rejection means its in-memory receiver may have lost the
    /// negotiated binding (for example after the iPhone app was relaunched).
    /// Retain all source files and receipts, but negotiate a fresh binding before
    /// the next file retry.
    func retryAfterPeerRejection() throws {
        if let binding { try clearRetryBackoff(for: binding) }
        binding = nil
        try requestCapability()
    }
    var pendingHello: RecordingCapabilityHello? { challenge }
    func accept(_ reply: RecordingCapabilityReply) throws {
        guard reply.version == 2, let hello = challenge,
              reply.binding.nonce == hello.nonce, reply.binding.watchID == watchID else { throw RecordingTransportError.invalidEnvelope }
        guard reply.versions.contains(2) else { unsupported = true; throw RecordingTransportError.unsupported }
        let maximum = reply.maximumChunkDuration ?? RecordingChunkProtocol.legacyChunkDuration
        guard maximum.isFinite, maximum > 0 else { throw RecordingTransportError.invalidEnvelope }
        let receipts = try loadReceipts(for: reply.binding, chunks: chunks, ends: ends, locations: locations)
        supportsLocationSamples = reply.supportsLocationSamples == true
        maximumChunkDuration = maximum
        binding = reply.binding; challenge = nil; unsupported = false
        locationReceipts = receipts.locations
        chunkReceipts = receipts.chunks
        endReceipts = receipts.ends
    }
    func update(chunks: [RecordingChunkDescriptor], ends: [RecordingSessionEnd], locations: [RecordingLocationSample] = [],
                audioURL: @escaping (RecordingChunkDescriptor) -> URL) throws {
        let receipts = try binding.map { try loadReceipts(for: $0, chunks: chunks, ends: ends, locations: locations) }
        self.chunks = chunks; self.ends = ends; self.locations = locations; self.audioURL = audioURL
        if let receipts {
            chunkReceipts = receipts.chunks
            endReceipts = receipts.ends
            locationReceipts = receipts.locations
        }
    }
    func pump(force: Bool = false) throws {
        guard let binding, let audioURL, let maximumChunkDuration else { return }
        var firstError: Error?
        // Small in-flight batch. Completion/periodic wake drives subsequent work.
        var submitted = max(outstandingFileCount(), chunks.filter { isOutstanding($0.id, false, binding) }.count)
        for chunk in chunks where chunkReceipts[chunk.id] == nil {
            // Capability blocking is not a transport attempt: retain both media
            // and retry budget until a fresh handshake advertises support.
            guard chunk.duration <= maximumChunkDuration,
                  submitted < 4, !isOutstanding(chunk.id, false, binding) else { continue }
            do {
                let key = "chunk_\(chunk.id.uuidString)"
                guard try due(key, force: force) else { continue }
                try schedule(key)
                let file = audioURL(chunk)
                try RecordingAudioFile.requireSafePath(file)
                guard try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { throw RecordingTransportError.invalidStorage }
                try sendFile(file, .init(binding: binding, payload: chunk)); submitted += 1
            } catch { firstError = firstError ?? error }
        }
        for end in ends where endReceipts[end.sessionID] != end {
            guard !chunks.contains(where: {
                $0.sessionID == end.sessionID && chunkReceipts[$0.id] == nil && $0.duration > maximumChunkDuration
            }), !isOutstanding(end.sessionID, true, binding) else { continue }
            do {
                let key = "end_\(end.sessionID.uuidString)_\(end.revision)"
                guard try due(key, force: force) else { continue }
                // End retry is persisted independently, even when no audio is pending.
                try schedule(key)
                try sendEnd(.init(binding: binding, payload: end))
            } catch { firstError = firstError ?? error }
        }
        if supportsLocationSamples {
            // Independent bounded batch; GPS failures never prevent audio/end submission above.
            var submittedLocations = 0
            for sample in locations where locationReceipts[sample.id] == nil && submittedLocations < 4 {
                do {
                    let key = "location_\(sample.id.uuidString)"
                    guard try due(key, force: force) else { continue }
                    try sample.validate(); try schedule(key)
                    try sendLocation(.init(binding: binding, payload: sample))
                    submittedLocations += 1
                } catch { firstError = firstError ?? error }
            }
        }
        if let firstError { throw firstError }
    }
    func receive(_ value: RecordingWireEnvelope<RecordingSavedChunk>) throws {
        guard let binding else { throw RecordingTransportError.unavailable }
        try value.validate(binding: binding); try value.payload.validate()
        guard let chunk = chunks.first(where: { $0.id == value.payload.receipt.chunkID }),
              RecordingChunkWire.matches(value.payload.receipt, chunk) else { throw RecordingTransportError.conflict }
        let url = ledger("chunk_\(chunk.id.uuidString).json", binding: binding)
        if let old = chunkReceipts[chunk.id] {
            guard old == value.payload else { throw RecordingTransportError.conflict }
            return
        }
        try RecordingTransportDisk.write(value.payload, to: url)
        chunkReceipts[chunk.id] = value.payload
    }
    func receive(_ value: RecordingWireEnvelope<RecordingSessionEnd>) throws {
        guard let binding else { throw RecordingTransportError.unavailable }
        try value.validate(binding: binding); try value.payload.validate()
        guard ends.contains(value.payload) else { throw RecordingTransportError.conflict }
        try RecordingTransportDisk.write(value.payload, to: ledger("end_\(value.payload.sessionID.uuidString).json", binding: binding))
        endReceipts[value.payload.sessionID] = value.payload
    }
    func receive(_ value: RecordingWireEnvelope<RecordingLocationSample>) throws {
        guard let binding else { throw RecordingTransportError.unavailable }
        try value.validate(binding: binding); try value.payload.validate()
        guard locations.contains(value.payload) else { throw RecordingTransportError.conflict }
        try RecordingTransportDisk.write(value.payload, to: ledger("location_\(value.payload.id.uuidString).json", binding: binding))
        locationReceipts[value.payload.id] = value.payload
    }
    private func ledger(_ name: String, binding: RecordingTransferBinding) -> URL {
        root.appendingPathComponent(binding.counterpart.key).appendingPathComponent(name)
    }
    private func due(_ key: String, force: Bool) throws -> Bool {
        guard let binding else { return false }
        let url = ledger("\(key).retry.json", binding: binding)
        guard !force, FileManager.default.fileExists(atPath: url.path) else { return true }
        let attempt = try RecordingTransportDisk.read(Attempt.self, at: url)
        // Bound wall-clock jumps so an old deadline never strands work forever.
        return attempt.retryAt <= now() || attempt.retryAt.timeIntervalSince(now()) > 3600
    }
    private func schedule(_ key: String) throws {
        guard let binding else { return }
        let url = ledger("\(key).retry.json", binding: binding)
        let old = try? RecordingTransportDisk.read(Attempt.self, at: url)
        let count = min((old?.count ?? 0) + 1, 10)
        try RecordingTransportDisk.write(Attempt(count: count, retryAt: now().addingTimeInterval(min(30 * pow(2, Double(count - 1)), 900))), to: url)
    }
    private func clearRetryBackoff(for binding: RecordingTransferBinding) throws {
        let keys = chunks.map { "chunk_\($0.id.uuidString)" } + ends.map { "end_\($0.sessionID.uuidString)_\($0.revision)" }
        for key in keys {
            let url = ledger("\(key).retry.json", binding: binding)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            try FileManager.default.removeItem(at: url)
            try RecordingTransportDisk.syncDirectory(url.deletingLastPathComponent())
        }
    }
    private func loadReceipts(for binding: RecordingTransferBinding, chunks: [RecordingChunkDescriptor],
                              ends: [RecordingSessionEnd], locations: [RecordingLocationSample]) throws -> ReceiptSnapshot {
        var saved: [UUID: RecordingSavedChunk] = [:], completed: [UUID: RecordingSessionEnd] = [:]
        for chunk in chunks {
            let url = ledger("chunk_\(chunk.id.uuidString).json", binding: binding)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            let value = try RecordingTransportDisk.read(RecordingSavedChunk.self, at: url)
            try value.validate()
            guard RecordingChunkWire.matches(value.receipt, chunk) else { throw RecordingTransportError.conflict }
            saved[chunk.id] = value
        }
        for end in ends {
            let url = ledger("end_\(end.sessionID.uuidString).json", binding: binding)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            let value = try RecordingTransportDisk.read(RecordingSessionEnd.self, at: url)
            if value == end { completed[end.sessionID] = value }
        }
        var observed: [UUID: RecordingLocationSample] = [:]
        for sample in locations {
            let url = ledger("location_\(sample.id.uuidString).json", binding: binding)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            // Optional metadata ledger damage cannot hold the audio upload queue.
            // Retain the bytes and replay the independently stored observation.
            guard let value = try? RecordingTransportDisk.read(RecordingLocationSample.self, at: url), value == sample else { continue }
            observed[sample.id] = value
        }
        return ReceiptSnapshot(chunks: saved, ends: completed, locations: observed)
    }
}
