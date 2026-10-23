import Foundation

/// Capability advertisements must be scoped to the currently paired counterpart.
/// A V2 value is Codable Data; never send it through the legacy V1 metadata key.
enum RecordingChunkProtocol {
    static let version = 2
    static let chunkKey = "wiseLifeRecordingChunkV2"
    static let receiptKey = "wiseLifeRecordingReceiptV2"
    static let endKey = "wiseLifeRecordingEndV2"
    static let capabilityKey = "wiseLifeRecordingProtocolVersions"
    static let legacyChunkDuration: TimeInterval = 300
    static let chunkDuration: TimeInterval = 600
    static let captureSampleRate: Double = 16_000
    static let maximumChunkFrames = Int64(chunkDuration * captureSampleRate)
    // Bounds untrusted manifests; receivers must still avoid ordinal-sized allocations.
    static let maximumOrdinal = 100_000
}

struct RecordingChunkDescriptor: Codable, Equatable, Identifiable {
    let id: UUID
    let sessionID: UUID
    let ordinal: Int
    let sessionStartedAt: Date
    let capturedAt: Date
    let timeZoneIdentifier: String
    let sessionStartOffset: Double
    let frameCount: Int64
    let sampleRate: Double
    let byteCount: Int64
    let sha256: String
    let origin: RecordingOrigin
    let location: CaptureLocation?

    var duration: Double { Double(frameCount) / sampleRate }
    /// Untrusted origin.fileName is descriptive only. Both IDs and ordinal are typed.
    var audioFilename: String { "\(sessionID.uuidString)_\(String(format: "%04lld", Int64(ordinal))).m4a" }

    func validate() throws {
        guard (0...RecordingChunkProtocol.maximumOrdinal).contains(ordinal) else { throw RecordingSessionValidationError.invalidField("ordinal") }
        guard sessionStartedAt.timeIntervalSinceReferenceDate.isFinite,
              capturedAt.timeIntervalSinceReferenceDate.isFinite else {
            throw RecordingSessionValidationError.invalidField("captureTime")
        }
        guard TimeZone(identifier: timeZoneIdentifier) != nil else {
            throw RecordingSessionValidationError.invalidField("timeZoneIdentifier")
        }
        guard sampleRate.isFinite, sampleRate > 0 else {
            throw RecordingSessionValidationError.invalidField("sampleRate")
        }
        guard frameCount > 0, duration.isFinite, duration > 0,
              duration <= RecordingChunkProtocol.chunkDuration else {
            throw RecordingSessionValidationError.invalidField("frameCount")
        }
        guard sessionStartOffset.isFinite, sessionStartOffset >= 0,
              (sessionStartOffset + duration).isFinite else {
            throw RecordingSessionValidationError.invalidField("sessionStartOffset")
        }
        guard byteCount > 0 else { throw RecordingSessionValidationError.invalidField("byteCount") }
        try validateRecordingSHA256(sha256)
    }
}

extension RecordingChunkDescriptor {
    private enum CodingKeys: String, CodingKey {
        case id, sessionID, ordinal, sessionStartedAt, capturedAt, timeZoneIdentifier
        case sessionStartOffset, frameCount, sampleRate, byteCount, sha256, origin, location
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(id: try c.decode(UUID.self, forKey: .id), sessionID: try c.decode(UUID.self, forKey: .sessionID),
                  ordinal: try c.decode(Int.self, forKey: .ordinal),
                  sessionStartedAt: try c.decode(Date.self, forKey: .sessionStartedAt),
                  capturedAt: try c.decode(Date.self, forKey: .capturedAt),
                  timeZoneIdentifier: try c.decode(String.self, forKey: .timeZoneIdentifier),
                  sessionStartOffset: try c.decode(Double.self, forKey: .sessionStartOffset),
                  frameCount: try c.decode(Int64.self, forKey: .frameCount),
                  sampleRate: try c.decode(Double.self, forKey: .sampleRate),
                  byteCount: try c.decode(Int64.self, forKey: .byteCount),
                  sha256: try c.decode(String.self, forKey: .sha256),
                  origin: try c.decode(RecordingOrigin.self, forKey: .origin),
                  location: try c.decodeIfPresent(CaptureLocation.self, forKey: .location))
        try validate()
    }
}

struct RecordingChunkReceipt: Codable, Equatable {
    let sessionID: UUID
    let chunkID: UUID
    let ordinal: Int
    let sha256: String

    func validate() throws {
        guard (0...RecordingChunkProtocol.maximumOrdinal).contains(ordinal) else { throw RecordingSessionValidationError.invalidField("ordinal") }
        try validateRecordingSHA256(sha256)
    }
}

extension RecordingChunkReceipt {
    private enum CodingKeys: String, CodingKey { case sessionID, chunkID, ordinal, sha256 }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(sessionID: try c.decode(UUID.self, forKey: .sessionID),
                  chunkID: try c.decode(UUID.self, forKey: .chunkID),
                  ordinal: try c.decode(Int.self, forKey: .ordinal), sha256: try c.decode(String.self, forKey: .sha256))
        try validate()
    }
}

struct RecordingSessionEnd: Codable, Equatable {
    let sessionID: UUID
    /// Nil explicitly describes a session with no sealed audio, not an unknown tail.
    let finalOrdinal: Int?
    let endedAt: Date
    let interrupted: Bool
    let revision: Int

    func validate() throws {
        guard finalOrdinal.map({ (0...RecordingChunkProtocol.maximumOrdinal).contains($0) }) ?? true else {
            throw RecordingSessionValidationError.invalidField("finalOrdinal")
        }
        guard endedAt.timeIntervalSinceReferenceDate.isFinite else {
            throw RecordingSessionValidationError.invalidField("endedAt")
        }
        guard revision >= 0 else { throw RecordingSessionValidationError.invalidField("revision") }
    }
}

extension RecordingSessionEnd {
    private enum CodingKeys: String, CodingKey { case sessionID, finalOrdinal, endedAt, interrupted, revision }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(sessionID: try c.decode(UUID.self, forKey: .sessionID),
                  finalOrdinal: try c.decodeIfPresent(Int.self, forKey: .finalOrdinal),
                  endedAt: try c.decode(Date.self, forKey: .endedAt),
                  interrupted: try c.decode(Bool.self, forKey: .interrupted), revision: try c.decode(Int.self, forKey: .revision))
        try validate()
    }
}

private func validateRecordingSHA256(_ value: String) throws {
    guard value.utf8.count == 64, value.utf8.allSatisfy({
        (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0)
    }) else { throw RecordingSessionValidationError.invalidField("sha256") }
}
