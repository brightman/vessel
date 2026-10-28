import AVFAudio
import Foundation

@main struct HourlyRecordingVerification {
    static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("wiselife-hourly-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let capture = root.appendingPathComponent("capture", isDirectory: true)
        let sealed = root.appendingPathComponent("sealed", isDirectory: true)
        try FileManager.default.createDirectory(at: sealed, withIntermediateDirectories: true)
        let groupID = UUID()
        let started = Date(timeIntervalSince1970: 1_750_000_000)
        var files: [(RecordingChunkDescriptor, URL)] = []
        let writer = try RecordingChunkWriter(sessionID: groupID, root: capture, startedAt: started,
            capacityReader: { _ in Int64.max }, onSeal: { descriptor, source in
                let destination = sealed.appendingPathComponent(descriptor.audioFilename)
                try FileManager.default.moveItem(at: source, to: destination)
                files.append((descriptor, destination))
            })
        let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
        let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8192)!
        var remaining: Int64 = 57_600_000 + 16_000
        while remaining > 0 {
            let count = min(remaining, 8192)
            pcm.frameLength = AVAudioFrameCount(count)
            pcm.floatChannelData![0].initialize(repeating: 0.02, count: Int(count))
            try writer.append(pcm)
            remaining -= count
        }
        try writer.finish()
        precondition(files.count == 2)
        precondition(files.map { $0.0.ordinal } == [0, 1])
        precondition(files.map { $0.0.frameCount } == [57_600_000, 16_000])
        precondition(files[1].0.sessionStartOffset == 3600)
        for (descriptor, url) in files {
            precondition(RecordingChunkFileIdentity.parse(filename: url.lastPathComponent)?.id == descriptor.id)
            precondition(RecordingChunkFileMetadata.matches(groupID: groupID, ordinal: descriptor.ordinal,
                                                            capturedAt: descriptor.capturedAt, audioURL: url))
            _ = try RecordingAudioFile.validate(descriptor, at: url)
        }
        let captureFiles = try FileManager.default.contentsOfDirectory(atPath: capture.path)
        precondition(captureFiles.isEmpty)
        let databaseURL = root.appendingPathComponent("metadata.sqlite3")
        let media = root.appendingPathComponent("phone-local", isDirectory: true)
        let repo = try RecordingSessionRepository(root: media, database: DaybookDatabase(url: databaseURL))
        for (descriptor, url) in files { try repo.storeLocalChunk(descriptor, from: url) }
        try repo.storeLocalChunk(files[0].0, from: files[0].1)
        try repo.applyEnd(.init(sessionID: groupID, finalOrdinal: 1, endedAt: started.addingTimeInterval(3601), interrupted: false, revision: 0))
        let reopened = try RecordingSessionRepository(root: media, database: DaybookDatabase(url: databaseURL))
        let summary = try reopened.session(id: groupID)
        precondition(summary?.savedCount == 2 && summary?.syncComplete == true)
        let ranges = try reopened.sourceRanges(sessionID: groupID)
        precondition(ranges.count == 2)
        try reopened.deleteSession(groupID)
        let removed = try reopened.session(id: groupID)
        precondition(removed == nil)
        for (descriptor, _) in files {
            precondition(!FileManager.default.fileExists(atPath: media.appendingPathComponent("Audio").appendingPathComponent(descriptor.audioFilename).path))
        }
        print("Hourly capture, sealed metadata, local persistence, reopen and deletion passed")
    }
}
