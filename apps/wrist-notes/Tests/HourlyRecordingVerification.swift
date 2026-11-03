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
        let ringFile = root.appendingPathComponent("ring-whole.m4a")
        var ringWriter: AVAudioFile? = try AVAudioFile(forWriting: ringFile, settings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 16000,
            AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 32000])
        var remaining: Int64 = 57_600_000 + 16_000
        while remaining > 0 {
            let count = min(remaining, 8192)
            pcm.frameLength = AVAudioFrameCount(count)
            pcm.floatChannelData![0].initialize(repeating: 0.02, count: Int(count))
            try writer.append(pcm)
            try ringWriter!.write(from: pcm)
            remaining -= count
        }
        try writer.finish()
        ringWriter = nil
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
        let library = root.appendingPathComponent("phone-local", isDirectory: true)
        let databaseURL = DaybookDatabase.metadataURL(forRoot: library)
        let media = library.appendingPathComponent("RecordingSessions", isDirectory: true)
        let repo = try RecordingSessionRepository(root: media, database: DaybookDatabase(url: databaseURL))
        for (descriptor, url) in files { try repo.storeLocalChunk(descriptor, from: url) }
        try repo.storeLocalChunk(files[0].0, from: files[0].1)
        try repo.applyEnd(.init(sessionID: groupID, finalOrdinal: 1, endedAt: started.addingTimeInterval(3601), interrupted: false, revision: 0))
        let reopened = try RecordingSessionRepository(root: media, database: DaybookDatabase(url: databaseURL))
        let summary = try reopened.session(id: groupID)
        precondition(summary?.savedCount == 2 && summary?.syncComplete == true)
        let ranges = try reopened.sourceRanges(sessionID: groupID)
        precondition(ranges.count == 2)
        let notes = try NoteRepository(root: library, database: DaybookDatabase(url: databaseURL))
        let ringID = UUID()
        try notes.importRecording(id: ringID, from: ringFile, kind: .long, capturedAt: started, duration: 3601,
            origin: .init(device: "EurekaRing", deviceID: "ring-fixture", fileName: "device-long.opus", recordingTimeIsEstimated: false, captureDevice: .ring))
        let reloaded = try NoteRepository(root: library, database: DaybookDatabase(url: databaseURL))
        precondition(reloaded.notes.first?.origin?.captureDevice == .ring)
        precondition(reloaded.notes.first?.recordingGroupID == nil)
        let phoneFiles = try FileManager.default.contentsOfDirectory(atPath: library.appendingPathComponent("Audio").path)
        precondition(phoneFiles == ["\(ringID.uuidString).m4a"])
        let discovery = AudioSourceDiscovery(root: library)
        var sources = try discovery.sources(explicit: [])
        let ringSource = sources.first { $0.id == .init(kind: .legacyNote, id: ringID) }!
        let watchSource = sources.first { $0.id == .init(kind: .session, id: groupID) }!
        precondition(ringSource.origin?.deviceKind == .ring && ringSource.ranges.count == 1)
        precondition(ringSource.ranges[0].duration >= 3601 && ringSource.ranges[0].duration < 3601.1)
        precondition(watchSource.origin?.deviceKind == .watch && watchSource.ranges.count == 2)
        for source in [ringSource, watchSource] {
            let windows = try AudioWindowPlanner.plan(source: source, configurationKey: "hourly-and-whole")
            precondition(windows.count == 13 && windows.last!.coreEnd >= 3601)
            precondition(windows.allSatisfy { $0.inputDuration <= 304 })
        }
        // Even stale hourly metadata must not combine a Ring file with Watch chunks.
        try notes.update(id: ringID) { $0.recordingGroupID = groupID; $0.recordingGroupOrdinal = 0 }
        sources = try discovery.sources(explicit: [])
        precondition(sources.first { $0.id == ringSource.id }?.recordingGroupID == nil)
        precondition(sources.first { $0.id == watchSource.id }?.ranges.count == 2)
        try notes.update(id: ringID) { $0.recordingGroupID = nil; $0.recordingGroupOrdinal = nil }
        try reopened.deleteSession(groupID)
        let removed = try reopened.session(id: groupID)
        precondition(removed == nil)
        for (descriptor, _) in files {
            precondition(!FileManager.default.fileExists(atPath: media.appendingPathComponent("Audio").appendingPathComponent(descriptor.audioFilename).path))
        }
        precondition(FileManager.default.fileExists(atPath: library.appendingPathComponent("Audio/\(ringID.uuidString).m4a").path))
        print("3601s Watch hourly files + Ring whole file: persistence, source markers, bounded processing, reopen and isolated deletion passed")
    }
}
