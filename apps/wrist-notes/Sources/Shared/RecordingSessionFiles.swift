import Foundation
import CryptoKit

/// Limits for locally captured hourly recording files and their stable identities.
enum RecordingSessionFileLimits {
    static let fileDuration: TimeInterval = 60 * 60
    static let captureSampleRate: Double = 16_000
    static let maximumFileFrames = Int64(fileDuration * captureSampleRate)
    static let maximumOrdinal = 9_999
    // Earlier releases persisted six-digit ordinals. Capture still uses maximumOrdinal.
    static let maximumStoredOrdinal = 100_000
}

extension Notification.Name {
    static let recordingSourcesDidChange = Notification.Name("WiseLifeRecordingSourcesDidChange")
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
    var audioFilename: String {
        ordinal > RecordingSessionFileLimits.maximumOrdinal ? legacyAudioFilename :
            RecordingChunkFileIdentity.filename(groupID: sessionID, ordinal: ordinal, capturedAt: capturedAt)
    }
    var legacyAudioFilename: String { "\(sessionID.uuidString)_\(String(format: "%04lld", Int64(ordinal))).m4a" }

    func validate() throws {
        guard (0...RecordingSessionFileLimits.maximumStoredOrdinal).contains(ordinal) else { throw RecordingSessionValidationError.invalidField("ordinal") }
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
              duration <= RecordingSessionFileLimits.fileDuration else {
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

/// Stable identity and filename encoding for an independently playable hourly M4A.
/// The filename is also sufficient to rebuild the Watch queue after an index loss.
enum RecordingChunkFileIdentity {
    struct Parsed: Equatable {
        let groupID: UUID
        let ordinal: Int
        let capturedAt: Date
        var id: UUID { stableID(groupID: groupID, ordinal: ordinal) }
    }

    static func stableID(groupID: UUID, ordinal: Int) -> UUID {
        var input = Data(groupID.uuidString.lowercased().utf8)
        input.append(contentsOf: [UInt8((ordinal >> 24) & 0xff), UInt8((ordinal >> 16) & 0xff), UInt8((ordinal >> 8) & 0xff), UInt8(ordinal & 0xff)])
        var bytes = Array(SHA256.hash(data: input).prefix(16))
        bytes[6] = (bytes[6] & 0x0f) | 0x50
        bytes[8] = (bytes[8] & 0x3f) | 0x80
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }

    static func filename(groupID: UUID, ordinal: Int, capturedAt: Date) -> String {
        precondition((0...RecordingSessionFileLimits.maximumOrdinal).contains(ordinal))
        return "\(groupID.uuidString)_\(String(format: "%04d", ordinal))_\(timestamp(capturedAt)).m4a"
    }

    static func partialFilename(groupID: UUID, ordinal: Int, capturedAt: Date) -> String {
        String(filename(groupID: groupID, ordinal: ordinal, capturedAt: capturedAt).dropLast(4)) + ".partial.m4a"
    }

    static func parse(filename: String) -> Parsed? {
        guard filename.hasSuffix(".m4a") else { return nil }
        let stem = String(filename.dropLast(4))
        let fields = stem.split(separator: "_", omittingEmptySubsequences: false)
        guard fields.count == 3,
              let groupID = UUID(uuidString: String(fields[0])),
              fields[1].count == 4, let ordinal = Int(fields[1]), ordinal >= 0,
              let date = parseTimestamp(String(fields[2])) else { return nil }
        return Parsed(groupID: groupID, ordinal: ordinal, capturedAt: date)
    }

    private static func timestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return formatter.string(from: date)
    }

    private static func parseTimestamp(_ value: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.isLenient = false
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return formatter.date(from: value)
    }
}

enum RecordingChunkFileMetadata {
    enum Failure: Error { case invalidMetadata, conflictingMetadata }

    // ISO-BMFF user-data box. Keeping the atom small and at EOF lets watchOS use
    // AVAudioFile for the AAC write while carrying recovery identity in the M4A.
    private static let atomType = Data("uuid".utf8)
    private static let userType = uuidBytes(UUID(uuidString: "9D13A454-7AB7-4A91-9464-6C1B3257B7C1")!)
    private static let payloadMarker = Data("WLR1".utf8)
    private static let payloadSize = 32
    private static let atomSize = 8 + 16 + payloadSize

    private struct Embedded {
        let groupID: UUID
        let ordinal: Int
        let capturedAt: Date
    }

    static func embed(groupID: UUID, ordinal: Int, capturedAt: Date, audioURL: URL) throws {
        guard (0...RecordingSessionFileLimits.maximumOrdinal).contains(ordinal),
              capturedAt.timeIntervalSince1970.isFinite else { throw Failure.invalidMetadata }
        if let existing = try read(from: audioURL) {
            guard existing.groupID == groupID, existing.ordinal == ordinal,
                  abs(existing.capturedAt.timeIntervalSince(capturedAt)) < 0.001 else {
                throw Failure.conflictingMetadata
            }
            return
        }

        var payload = payloadMarker
        payload.append(uuidBytes(groupID))
        append(UInt32(ordinal), to: &payload)
        let milliseconds = Int64((capturedAt.timeIntervalSince1970 * 1000).rounded())
        append(UInt64(bitPattern: milliseconds), to: &payload)

        var atom = Data()
        append(UInt32(atomSize), to: &atom)
        atom.append(atomType)
        atom.append(userType)
        atom.append(payload)
        guard atom.count == atomSize else { throw Failure.invalidMetadata }

        let handle = try FileHandle(forWritingTo: audioURL)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: atom)
        try handle.synchronize()
    }

    static func matches(groupID: UUID, ordinal: Int, capturedAt: Date, audioURL: URL) -> Bool {
        guard let embedded = try? read(from: audioURL) else { return false }
        return embedded.groupID == groupID && embedded.ordinal == ordinal
            && abs(embedded.capturedAt.timeIntervalSince(capturedAt)) < 1.1
    }

    private static func read(from audioURL: URL) throws -> Embedded? {
        let handle = try FileHandle(forReadingFrom: audioURL)
        defer { try? handle.close() }
        let end = try handle.seekToEnd()
        guard end >= UInt64(atomSize) else { return nil }
        try handle.seek(toOffset: end - UInt64(atomSize))
        guard let atom = try handle.read(upToCount: atomSize), atom.count == atomSize,
              readUInt32(atom, at: 0) == UInt32(atomSize),
              atom.subdata(in: 4..<8) == atomType,
              atom.subdata(in: 8..<24) == userType,
              atom.subdata(in: 24..<28) == payloadMarker else { return nil }
        let groupID = uuid(from: atom.subdata(in: 28..<44))
        let ordinal = Int(readUInt32(atom, at: 44))
        let milliseconds = Int64(bitPattern: readUInt64(atom, at: 48))
        return Embedded(groupID: groupID, ordinal: ordinal,
                        capturedAt: Date(timeIntervalSince1970: Double(milliseconds) / 1000))
    }

    private static func uuidBytes(_ value: UUID) -> Data {
        withUnsafeBytes(of: value.uuid) { Data($0) }
    }

    private static func uuid(from bytes: Data) -> UUID {
        let b = Array(bytes)
        return UUID(uuid: (b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7],
                           b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15]))
    }

    private static func append(_ value: UInt32, to data: inout Data) {
        var bigEndian = value.bigEndian
        withUnsafeBytes(of: &bigEndian) { data.append(contentsOf: $0) }
    }

    private static func append(_ value: UInt64, to data: inout Data) {
        var bigEndian = value.bigEndian
        withUnsafeBytes(of: &bigEndian) { data.append(contentsOf: $0) }
    }

    private static func readUInt32(_ data: Data, at offset: Int) -> UInt32 {
        (UInt32(data[offset]) << 24) | (UInt32(data[offset + 1]) << 16)
            | (UInt32(data[offset + 2]) << 8) | UInt32(data[offset + 3])
    }

    private static func readUInt64(_ data: Data, at offset: Int) -> UInt64 {
        data[offset..<(offset + 8)].reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
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

struct RecordingSessionEnd: Codable, Equatable {
    let sessionID: UUID
    /// Nil explicitly describes a session with no sealed audio, not an unknown tail.
    let finalOrdinal: Int?
    let endedAt: Date
    let interrupted: Bool
    let revision: Int

    func validate() throws {
        guard finalOrdinal.map({ (0...RecordingSessionFileLimits.maximumStoredOrdinal).contains($0) }) ?? true else {
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
