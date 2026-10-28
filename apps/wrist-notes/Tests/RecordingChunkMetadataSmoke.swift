import Foundation

@main struct RecordingChunkMetadataSmoke {
    static func main() throws {
        let root = URL(fileURLWithPath: "/private/tmp").appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let audioURL = root.appendingPathComponent("metadata-roundtrip.m4a")
        let audioFixture = Data("synthetic ISO-BMFF audio payload".utf8)
        try audioFixture.write(to: audioURL)

        let groupID = UUID()
        let capturedAt = Date(timeIntervalSince1970: 1_798_000_123.456)
        try RecordingChunkFileMetadata.embed(groupID: groupID, ordinal: 7, capturedAt: capturedAt, audioURL: audioURL)
        precondition(RecordingChunkFileMetadata.matches(groupID: groupID, ordinal: 7, capturedAt: capturedAt, audioURL: audioURL))
        precondition(RecordingChunkFileMetadata.matches(groupID: groupID, ordinal: 7,
            capturedAt: Date(timeIntervalSince1970: 1_798_000_123), audioURL: audioURL),
            "filename timestamps rounded to seconds must still match embedded capture time")
        precondition(!RecordingChunkFileMetadata.matches(groupID: groupID, ordinal: 6, capturedAt: capturedAt, audioURL: audioURL))
        let dataAfterFirstWrite = try Data(contentsOf: audioURL)
        precondition(dataAfterFirstWrite.starts(with: audioFixture), "embedding must preserve existing media bytes")
        try RecordingChunkFileMetadata.embed(groupID: groupID, ordinal: 7, capturedAt: capturedAt, audioURL: audioURL)
        let dataAfterSecondWrite = try Data(contentsOf: audioURL)
        precondition(dataAfterSecondWrite.count == dataAfterFirstWrite.count, "embedding the same metadata is idempotent")
        print("Recording chunk metadata smoke passed")
    }
}
