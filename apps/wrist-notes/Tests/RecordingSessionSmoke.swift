import Foundation

@main
struct RecordingSessionSmoke {
    static func main() throws {
        let pieces = try RecordingFramePartition.split(
            inputStartFrame: 4_799_999, frameCount: 3, framesPerChunk: 4_800_000)
        precondition(pieces == [
            .init(ordinal: 0, inputOffset: 0, frameCount: 1, chunkOffset: 4_799_999),
            .init(ordinal: 1, inputOffset: 1, frameCount: 2, chunkOffset: 0)
        ])
        let empty = try RecordingFramePartition.split(
            inputStartFrame: 0, frameCount: 0, framesPerChunk: 4_800_000)
        precondition(empty.isEmpty)
        try partitionProperties()
        try protocolValidation()
        try sourceRangeValidation()
        try legacyDecoding()
        print("Recording sessions: boundary, 2000 random buffers, validation, Codable, source ranges, V1 compatibility passed")
    }

    static func mustThrow(_ body: () throws -> Void) {
        do { try body() } catch { return }
        preconditionFailure("Expected invalid input to be rejected")
    }

    static func partitionProperties() throws {
        // A wrong boundary or dropped frame fails conservation and adjacency.
        var seed: UInt64 = 0x5eed
        var cursor: Int64 = 0
        var emitted: Int64 = 0
        for _ in 0..<2000 {
            seed = seed &* 6364136223846793005 &+ 1
            let count = Int64(seed % 9_600_001)
            let slices = try RecordingFramePartition.split(inputStartFrame: cursor, frameCount: count, framesPerChunk: 4_800_000)
            var offset: Int64 = 0
            for slice in slices {
                precondition(slice.frameCount > 0 && slice.chunkOffset >= 0)
                precondition(slice.inputOffset == offset)
                precondition(Int64(slice.ordinal) * 4_800_000 + slice.chunkOffset == cursor + offset)
                precondition(slice.chunkOffset + slice.frameCount <= 4_800_000)
                offset += slice.frameCount
            }
            precondition(offset == count)
            emitted += offset
            cursor += count
        }
        precondition(cursor == emitted)
        let exact = try RecordingFramePartition.split(inputStartFrame: 0, frameCount: 4_800_000, framesPerChunk: 4_800_000)
        precondition(exact == [.init(ordinal: 0, inputOffset: 0, frameCount: 4_800_000, chunkOffset: 0)])
        let last = try RecordingFramePartition.split(inputStartFrame: Int64.max - 1, frameCount: 1, framesPerChunk: Int64.max)
        precondition(last == [.init(ordinal: 0, inputOffset: 0, frameCount: 1, chunkOffset: Int64.max - 1)])
        for (start, count, capacity): (Int64, Int64, Int64) in [(-1, 1, 1), (0, -1, 1), (0, 1, 0), (0, 1, -1), (.max, 1, 1)] {
            mustThrow { _ = try RecordingFramePartition.split(inputStartFrame: start, frameCount: count, framesPerChunk: capacity) }
        }
    }

    static func descriptor(ordinal: Int = 0, started: Date = Date(timeIntervalSinceReferenceDate: 100),
                           captured: Date = Date(timeIntervalSinceReferenceDate: 101), zone: String = "Asia/Singapore",
                           offset: Double = 1, frames: Int64 = 4_800_000, rate: Double = 16_000,
                           bytes: Int64 = 1_200_000, hash: String = String(repeating: "ab", count: 32)) -> RecordingChunkDescriptor {
        .init(id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
              sessionID: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!, ordinal: ordinal,
              sessionStartedAt: started, capturedAt: captured, timeZoneIdentifier: zone,
              sessionStartOffset: offset, frameCount: frames, sampleRate: rate, byteCount: bytes, sha256: hash,
              origin: .init(device: "Watch", deviceID: "paired-watch", fileName: "../../untrusted.m4a", recordingTimeIsEstimated: false), location: nil)
    }

    static func protocolValidation() throws {
        let valid = descriptor()
        try valid.validate()
        precondition(valid.audioFilename == "22222222-2222-2222-2222-222222222222_0000.m4a")
        let data = try JSONEncoder().encode(valid)
        let decoded = try JSONDecoder().decode(RecordingChunkDescriptor.self, from: data)
        precondition(decoded == valid)
        for bad in [descriptor(ordinal: -1), descriptor(ordinal: 100_001), descriptor(started: .init(timeIntervalSinceReferenceDate: .infinity)),
                    descriptor(captured: .init(timeIntervalSinceReferenceDate: .nan)), descriptor(zone: "bogus/zone"),
                    descriptor(offset: -1), descriptor(offset: .infinity), descriptor(frames: 0), descriptor(frames: -1),
                    descriptor(frames: 4_800_001), descriptor(rate: 0), descriptor(rate: -.infinity), descriptor(rate: .nan),
                    descriptor(bytes: 0), descriptor(hash: String(repeating: "z", count: 64)), descriptor(hash: "ab")] {
            mustThrow { try bad.validate() }
        }
        var object = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        for (field, value): (String, Any) in [("ordinal", -1), ("frameCount", 0), ("sha256", "bad"), ("id", "../bad"), ("sessionID", "invalid")] {
            var altered = object
            altered[field] = value
            let invalidData = try JSONSerialization.data(withJSONObject: altered)
            mustThrow { _ = try JSONDecoder().decode(RecordingChunkDescriptor.self, from: invalidData) }
        }
        // Unknown sender path metadata never determines the receiver's local filename.
        object["path"] = "/tmp/sender-controlled.m4a"
        let withPath = try JSONDecoder().decode(RecordingChunkDescriptor.self, from: JSONSerialization.data(withJSONObject: object))
        precondition(withPath.audioFilename == valid.audioFilename)
        let receipt = RecordingChunkReceipt(sessionID: valid.sessionID, chunkID: valid.id, ordinal: 0, sha256: valid.sha256)
        try receipt.validate()
        let decodedReceipt = try JSONDecoder().decode(RecordingChunkReceipt.self, from: JSONEncoder().encode(receipt))
        precondition(decodedReceipt == receipt)
        mustThrow { try RecordingChunkReceipt(sessionID: valid.sessionID, chunkID: valid.id, ordinal: -1, sha256: valid.sha256).validate() }
        mustThrow { try RecordingChunkReceipt(sessionID: valid.sessionID, chunkID: valid.id, ordinal: 0, sha256: "bad").validate() }
        mustThrow { try RecordingChunkReceipt(sessionID: valid.sessionID, chunkID: valid.id, ordinal: 100_001, sha256: valid.sha256).validate() }
        var invalidReceipt = try JSONSerialization.jsonObject(with: JSONEncoder().encode(receipt)) as! [String: Any]
        invalidReceipt["sha256"] = "bad"
        mustThrow { _ = try JSONDecoder().decode(RecordingChunkReceipt.self, from: JSONSerialization.data(withJSONObject: invalidReceipt)) }
        let end = RecordingSessionEnd(sessionID: valid.sessionID, finalOrdinal: nil, endedAt: valid.capturedAt, interrupted: false, revision: 0)
        try end.validate()
        let decodedEnd = try JSONDecoder().decode(RecordingSessionEnd.self, from: JSONEncoder().encode(end))
        precondition(decodedEnd == end)
        var invalidEnd = try JSONSerialization.jsonObject(with: JSONEncoder().encode(end)) as! [String: Any]
        invalidEnd["revision"] = -1
        mustThrow { _ = try JSONDecoder().decode(RecordingSessionEnd.self, from: JSONSerialization.data(withJSONObject: invalidEnd)) }
        try descriptor(ordinal: 100_000).validate()
        mustThrow { try RecordingSessionEnd(sessionID: valid.sessionID, finalOrdinal: 100_001, endedAt: valid.capturedAt, interrupted: false, revision: 0).validate() }
        mustThrow { try RecordingSessionEnd(sessionID: valid.sessionID, finalOrdinal: -1, endedAt: valid.capturedAt, interrupted: false, revision: 0).validate() }
        mustThrow { try RecordingSessionEnd(sessionID: valid.sessionID, finalOrdinal: 0, endedAt: valid.capturedAt, interrupted: false, revision: -1).validate() }
        mustThrow { try RecordingSessionEnd(sessionID: valid.sessionID, finalOrdinal: 0, endedAt: .init(timeIntervalSinceReferenceDate: .infinity), interrupted: false, revision: 0).validate() }
    }

    static func sourceRangeValidation() throws {
        let id = UUID()
        let url = URL(fileURLWithPath: "/tmp/internal.m4a")
        let valid = RecordingSourceRange(chunkID: id, url: url, startFrame: 100, endFrame: 200, sampleRate: 16_000,
                                         sessionStartOffset: 603, discontinuityBefore: "interruption")
        try valid.validate()
        precondition(valid.duration == 0.00625)
        let nearLimit = RecordingSourceRange(chunkID: id, url: url, startFrame: .max - 1, endFrame: .max, sampleRate: 1)
        try nearLimit.validate()
        precondition(nearLimit.duration == 1)
        let remote = RecordingSourceRange(chunkID: id, url: URL(string: "https://example.invalid/remote.m4a")!, startFrame: 0, endFrame: 1, sampleRate: 16_000)
        mustThrow { try remote.validate() }
        let nonfinite = RecordingSourceRange(chunkID: id, url: url, startFrame: 0, endFrame: 1, sampleRate: 16_000, sessionStartOffset: .infinity)
        mustThrow { try nonfinite.validate() }
        for range in [RecordingSourceRange(chunkID: id, url: url, startFrame: -1, endFrame: 1, sampleRate: 16_000),
                      RecordingSourceRange(chunkID: id, url: url, startFrame: 1, endFrame: 1, sampleRate: 16_000),
                      RecordingSourceRange(chunkID: id, url: url, startFrame: 2, endFrame: 1, sampleRate: 16_000),
                      RecordingSourceRange(chunkID: id, url: url, startFrame: 0, endFrame: 1, sampleRate: .nan),
                      RecordingSourceRange(chunkID: id, url: url, startFrame: 0, endFrame: 1, sampleRate: 0),
                      RecordingSourceRange(chunkID: id, url: url, startFrame: 0, endFrame: 1, sampleRate: 16_000, sessionStartOffset: -1)] {
            mustThrow { try range.validate() }
        }
    }

    static func legacyDecoding() throws {
        let fixture = Data(#"{"id":"33333333-3333-3333-3333-333333333333","kind":"long","capturedAt":100,"duration":600,"audioFilename":"original.m4a","title":"Old title","transcript":"Original text","summary":"","transcriptionState":"ready","summaryState":"pending"}"#.utf8)
        let note = try JSONDecoder().decode(VoiceNote.self, from: fixture)
        precondition(note.duration == 600 && note.audioFilename == "original.m4a")
        precondition(note.title == "Old title" && note.transcript == "Original text" && note.origin == nil)
    }
}
