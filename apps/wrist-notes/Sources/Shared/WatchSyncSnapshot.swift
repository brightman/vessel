import Foundation

/// Latest known queue, delivered through background application context (not reachability).
struct WatchSyncSnapshot: Codable, Equatable {
    static let contextKey = "wiseLifeWatchSyncV1"
    let updatedAt: Date
    let pendingIDs: [UUID]
    var failures: [WatchSyncFailure]? = nil
    var lastHandledRetryID: UUID? = nil

    static func decode(_ context: [String: Any]) -> WatchSyncSnapshot? {
        guard let data = context[contextKey] as? Data,
              let snapshot = try? JSONDecoder().decode(Self.self, from: data),
              snapshot.updatedAt.timeIntervalSinceReferenceDate.isFinite else { return nil }
        return snapshot
    }
}

struct WatchSyncFailure: Codable, Equatable {
    enum Reason: String, Codable { case transferFailed, fileMissing }
    let id: UUID
    let reason: Reason
}

/// Background context is retained by the OS; consume each request once and expire old intent.
struct WatchSyncRetryRequest: Codable, Equatable {
    static let contextKey = "wiseLifeWatchRetryV1"
    static let handledKey = "wiseLifeWatchRetryHandledV1"
    let id: UUID
    let requestedAt: Date

    func shouldHandle(lastHandledID: UUID?, now: Date = .now) -> Bool {
        let age = now.timeIntervalSince(requestedAt)
        return id != lastHandledID && age.isFinite && age >= -300 && age <= 86_400
    }

    static func preparingContext(
        _ context: [String: Any], lastHandledID: UUID?, now: Date = .now
    ) throws -> [String: Any] {
        let request: Self
        if let previous = decode(context), previous.shouldHandle(lastHandledID: lastHandledID, now: now) {
            request = previous
        } else {
            request = Self(id: UUID(), requestedAt: now)
        }
        var updated = context
        updated[contextKey] = try JSONEncoder().encode(request)
        return updated
    }

    static func decode(_ context: [String: Any]) -> Self? {
        guard let data = context[contextKey] as? Data else { return nil }
        return try? JSONDecoder().decode(Self.self, from: data)
    }
}

/// Separate V2 namespace prevents legacy generic ID receipts from hiding an open tail.
enum WatchTransferPhase: String, Codable {
    case waiting, queued, transferring
}

struct WatchSessionSyncSnapshot: Codable, Equatable {
    static let contextKey = "wiseLifeWatchSyncV2"
    struct Pending: Codable, Equatable {
        let sessionID: UUID
        let lastOrdinal: Int?
        let end: RecordingSessionEnd?
        var totalChunkCount: Int? = nil
        var phase: WatchTransferPhase? = nil
        var transferringChunkOrdinal: Int? = nil
        var currentChunkFraction: Double? = nil
    }
    let updatedAt: Date
    let pending: [Pending]

    static func phase(outstandingCount: Int, transferringCount: Int) -> WatchTransferPhase {
        if transferringCount > 0 { return .transferring }
        if outstandingCount > 0 { return .queued }
        return .waiting
    }

    static func validProgressFraction(_ fraction: Double) -> Double? {
        fraction.isFinite && (0...1).contains(fraction) ? fraction : nil
    }

    private static func isValid(_ item: Pending) -> Bool {
        let maximumOrdinal = RecordingChunkProtocol.maximumOrdinal
        if let lastOrdinal = item.lastOrdinal {
            guard (0...maximumOrdinal).contains(lastOrdinal) else { return false }
            if let total = item.totalChunkCount, total < lastOrdinal + 1 { return false }
        }
        if let total = item.totalChunkCount, !(0...(maximumOrdinal + 1)).contains(total) { return false }
        if let ordinal = item.transferringChunkOrdinal {
            guard (0...maximumOrdinal).contains(ordinal), item.phase == .transferring else { return false }
            if let total = item.totalChunkCount, ordinal >= total { return false }
            if let last = item.lastOrdinal, ordinal > last { return false }
        }
        if let fraction = item.currentChunkFraction {
            guard validProgressFraction(fraction) == fraction, item.phase == .transferring else { return false }
        }
        if let end = item.end {
            guard end.sessionID == item.sessionID, (try? end.validate()) != nil else { return false }
            let endedChunkCount = end.finalOrdinal.map { $0 + 1 } ?? 0
            if let total = item.totalChunkCount, total != endedChunkCount { return false }
        }
        return true
    }

    static func decode(_ context: [String: Any], binding: RecordingTransferBinding) -> Self? {
        guard let data = context[contextKey] as? Data, data.count <= RecordingChunkWire.maximumMetadataBytes,
              let wire = try? JSONDecoder().decode(RecordingWireEnvelope<Self>.self, from: data),
              (try? wire.validate(binding: binding)) != nil,
              wire.payload.updatedAt.timeIntervalSinceReferenceDate.isFinite,
              Set(wire.payload.pending.map(\.sessionID)).count == wire.payload.pending.count,
              wire.payload.pending.allSatisfy(Self.isValid) else { return nil }
        return wire.payload
    }
}
