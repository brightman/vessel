import Foundation
import AVFAudio

@main struct StoreSmoke {
    static func main() throws {
        let root = URL(fileURLWithPath: "/private/tmp").appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let audio = root.appendingPathComponent("synthetic.m4a")
        let format = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)!
        var writer: AVAudioFile? = try AVAudioFile(forWriting: audio, settings: [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 16000, AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 32000])
        let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16001)!
        pcm.frameLength = 16001
        for i in 0..<16001 { pcm.floatChannelData![0][i] = Float(sin(Double(i) * 0.1)) * 0.1 }
        try writer!.write(from: pcm); writer = nil
        let info = try RecordingAudioFile.inspect(audio)
        print("AAC fixture: effective=16001 decoded=\(info.frameCount) padding=\(info.frameCount - 16001)")
        let descriptor = RecordingChunkDescriptor(id: UUID(), sessionID: UUID(), ordinal: 0, sessionStartedAt: .now, capturedAt: .now, timeZoneIdentifier: "UTC", sessionStartOffset: 0, frameCount: 16001, sampleRate: 16000, byteCount: info.byteCount, sha256: info.sha256.uppercased(), origin: RecordingOrigin(device: "watch", deviceID: "synthetic", fileName: "synthetic.m4a", recordingTimeIsEstimated: false), location: nil)
        let pcmURL = root.appendingPathComponent("not-aac.caf")
        var pcmWriter: AVAudioFile? = try AVAudioFile(forWriting: pcmURL, settings: format.settings)
        try pcmWriter!.write(from: pcm); pcmWriter = nil
        let pcmInfo = try RecordingAudioFile.inspect(pcmURL)
        var pcmJSON = try JSONSerialization.jsonObject(with: JSONEncoder().encode(descriptor)) as! [String: Any]
        pcmJSON["sha256"] = pcmInfo.sha256; pcmJSON["byteCount"] = pcmInfo.byteCount
        let pcmDescriptor = try JSONDecoder().decode(RecordingChunkDescriptor.self, from: JSONSerialization.data(withJSONObject: pcmJSON))
        do { _ = try RecordingAudioFile.validate(pcmDescriptor, at: pcmURL); fatalError("PCM masquerading as AAC must fail") } catch {}
        for (field, value) in [("sha256", String(repeating: "0", count: 64) as Any), ("frameCount", 14977 as Any), ("sampleRate", 8000 as Any)] {
            var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(descriptor)) as! [String: Any]
            json[field] = value
            let bad = try JSONDecoder().decode(RecordingChunkDescriptor.self, from: JSONSerialization.data(withJSONObject: json))
            do { _ = try RecordingAudioFile.validate(bad, at: audio); fatalError("invalid hash/header/frame padding accepted") } catch {}
        }
        let store = WatchRecordingSessionStore(root: root.appendingPathComponent("sessions"))
        try store.seal(descriptor, file: audio)
        try store.seal(descriptor, file: audio)
        precondition(store.chunks.count == 1, "duplicate seal must be idempotent")
        let manifest = store.root.appendingPathComponent(descriptor.sessionID.uuidString).appendingPathComponent("manifest.json")
        let invalid = Data("broken manifest".utf8)
        try invalid.write(to: manifest)
        let recovered = WatchRecordingSessionStore(root: store.root)
        try recovered.recover(); try recovered.recover()
        precondition(recovered.chunks.count == 1 && recovered.chunks[0] == descriptor, "sidecar must recover without manifest")
        let retained = try Data(contentsOf: manifest)
        precondition(retained == invalid, "invalid manifest bytes must survive")
        // Missing sidecar after final publication must recover from durable seal intent.
        let sidecar = recovered.audioURL(for: descriptor).appendingPathExtension("json")
        try FileManager.default.removeItem(at: sidecar)
        try recovered.recover()
        precondition(recovered.chunks.count == 1, "published final survives missing sidecar")
        precondition(recovered.sessionEnds.first?.interrupted == true, "unfinished session gets interrupted end")
        let legacy = root.appendingPathComponent("pending.json")
        try invalid.write(to: legacy); try recovered.recover()
        let legacyData = try Data(contentsOf: legacy)
        precondition(legacyData == invalid)
        let receipt = RecordingChunkReceipt(sessionID: descriptor.sessionID, chunkID: descriptor.id, ordinal: 0, sha256: info.sha256)
        try recovered.acknowledge(receipt)
        try recovered.recover()
        precondition(recovered.pendingChunks.isEmpty, "receipt is durable")
        let link = root.appendingPathComponent("link.m4a")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: audio)
        do { _ = try RecordingAudioFile.inspect(link); fatalError("symlinks must fail") } catch {}
        // Recover readable partial only to its checkpoint; retain corrupt siblings
        // and continue scanning independent sessions despite malformed manifests.
        let partialSession = UUID()
        let partialFolder = store.root.appendingPathComponent(partialSession.uuidString)
        try FileManager.default.createDirectory(at: partialFolder, withIntermediateDirectories: true)
        let context = RecordingCaptureContext(sessionID: partialSession, startedAt: Date(timeIntervalSince1970: 1700000000), timeZoneIdentifier: "Asia/Singapore", origin: descriptor.origin,
            location: CaptureLocation(latitude: 1.3, longitude: 103.8, source: .watchRecording))
        let intent = RecordingCaptureIntent(id: UUID(), context: context, ordinal: 0, sessionStartOffset: 0, effectiveFrames: 8000)
        let partial = partialFolder.appendingPathComponent(intent.partialFilename)
        try FileManager.default.copyItem(at: audio, to: partial)
        let originalPartial = try Data(contentsOf: partial)
        try JSONEncoder().encode(intent).write(to: partial.appendingPathExtension("capture.json"))
        let badIntent = RecordingCaptureIntent(id: UUID(), context: context, ordinal: 1, sessionStartOffset: 0.5, effectiveFrames: 10)
        let badPartial = partialFolder.appendingPathComponent(badIntent.partialFilename)
        try invalid.write(to: badPartial)
        try JSONEncoder().encode(badIntent).write(to: badPartial.appendingPathExtension("capture.json"))
        // Simulate termination halfway through a copy and a prefix re-encode.
        // These derived files must not poison retries against the valid original.
        for suffix in ["publishing.m4a", "recovered.m4a", "recovering.m4a"] {
            try invalid.write(to: partialFolder.appendingPathComponent("\(intent.id.uuidString).\(suffix)"))
        }
        try recovered.recover()
        precondition(recovered.chunks.contains { $0.id == intent.id }, "incomplete derived artifacts must rebuild from retained original")
        let sealedPrefix = recovered.chunks.first { $0.id == intent.id }!
        let persistedInfo = try RecordingAudioFile.inspect(recovered.audioURL(for: sealedPrefix))
        precondition(persistedInfo.sha256 == sealedPrefix.sha256 && persistedInfo.byteCount == sealedPrefix.byteCount, "prefix changed after sealing: \(persistedInfo.sha256) vs \(sealedPrefix.sha256), bytes \(persistedInfo.byteCount)/\(sealedPrefix.byteCount), frames \(persistedInfo.frameCount)")
        let restarted = WatchRecordingSessionStore(root: store.root)
        try restarted.recover(); try restarted.recover()
        precondition(restarted.chunks == recovered.chunks, "restart must preserve recovered IDs, hashes and frames: \(restarted.chunks.map { ($0.id, $0.sha256, $0.frameCount) }) vs \(recovered.chunks.map { ($0.id, $0.sha256, $0.frameCount) }); issues \(restarted.recoveryIssues)")
        // A seal intent may already exist when a recovery encode/copy is killed.
        // Return this synthetic unacknowledged fixture to that unpublished state.
        try FileManager.default.removeItem(at: restarted.audioURL(for: sealedPrefix))
        try FileManager.default.removeItem(at: restarted.audioURL(for: sealedPrefix).appendingPathExtension("json"))
        try invalid.write(to: partialFolder.appendingPathComponent("\(intent.id.uuidString).publishing.m4a"))
        // A readable derived file with the wrong prefix length is also invalid.
        try originalPartial.write(to: partialFolder.appendingPathComponent("\(intent.id.uuidString).recovered.m4a"))
        var pendingJSON = try JSONSerialization.jsonObject(with: JSONEncoder().encode(sealedPrefix)) as! [String: Any]
        pendingJSON["sha256"] = String(repeating: "0", count: 64)
        try JSONSerialization.data(withJSONObject: pendingJSON).write(to: restarted.audioURL(for: sealedPrefix).appendingPathExtension("seal.json"))
        try recovered.recover()
        precondition(recovered.chunks.contains { $0.id == intent.id }, "existing uncommitted seal intent must not prevent derived rebuild")
        let rebuilt = recovered.chunks.first { $0.id == intent.id }!
        try recovered.recover()
        precondition(recovered.chunks.first { $0.id == intent.id } == rebuilt)
        let salvaged = recovered.chunks.first { $0.id == intent.id }!
        precondition(salvaged.frameCount == 8000 && salvaged.sessionStartedAt == context.startedAt)
        precondition(salvaged.location == context.location && salvaged.timeZoneIdentifier == "Asia/Singapore")
        precondition(recovered.chunks.count == 2 && !recovered.recoveryIssues.isEmpty)
        let retainedPartial = try Data(contentsOf: partial)
        let retainedBad = try Data(contentsOf: badPartial)
        precondition(retainedPartial == originalPartial && retainedBad == invalid)
        precondition(recovered.sessionEnds.first { $0.sessionID == partialSession }?.interrupted == true)
        // A stop can persist its end even when sealing the last partial failed.
        // Recovery must extend that same end, with a revision the phone can accept.
        for priorFinal: Int? in [nil, 0] {
            let scope = root.appendingPathComponent("extended-" + UUID().uuidString)
            let recoveryStore = WatchRecordingSessionStore(root: scope)
            let sid = UUID(), startedAt = Date(timeIntervalSince1970: 1700000000)
            let context = RecordingCaptureContext(sessionID: sid, startedAt: startedAt,
                timeZoneIdentifier: "UTC", origin: descriptor.origin, location: nil)
            let ordinal = priorFinal == nil ? 0 : 1
            if priorFinal != nil {
                let first = RecordingCaptureIntent(id: UUID(), context: context, ordinal: 0,
                    sessionStartOffset: 0, effectiveFrames: 16001).descriptor(info: info)
                try recoveryStore.seal(first, file: audio)
            }
            let old = RecordingSessionEnd(sessionID: sid, finalOrdinal: priorFinal,
                endedAt: startedAt, interrupted: true, revision: 4)
            try recoveryStore.finish(old)
            let tail = RecordingCaptureIntent(id: UUID(), context: context, ordinal: ordinal,
                sessionStartOffset: Double(ordinal) * 2, effectiveFrames: 8000)
            let folder = scope.appendingPathComponent(sid.uuidString)
            let partial = folder.appendingPathComponent(tail.partialFilename)
            try FileManager.default.copyItem(at: audio, to: partial)
            try JSONEncoder().encode(tail).write(to: partial.appendingPathExtension("capture.json"))
            try recoveryStore.recover()
            let revised = recoveryStore.sessionEnds.first!
            precondition(revised.finalOrdinal == ordinal && revised.revision == 5,
                "recovered tail must extend a nil/lower persisted end with a newer revision")
            precondition(revised.interrupted && revised.endedAt == startedAt.addingTimeInterval(Double(ordinal) * 2 + 0.5),
                "recovery end must include actual recovered audio time and remain interrupted")
            try recoveryStore.recover(); try recoveryStore.recover()
            precondition(recoveryStore.sessionEnds == [revised], "repeated recovery must not manufacture revisions")
            precondition(FileManager.default.fileExists(atPath: partial.path), "recovery retains original partial")
        }
        let exhaustedStore = WatchRecordingSessionStore(root: root.appendingPathComponent("exhausted-revision"))
        let exhaustedID = UUID()
        let exhaustedEnd = RecordingSessionEnd(sessionID: exhaustedID, finalOrdinal: nil, endedAt: descriptor.capturedAt,
            interrupted: true, revision: Int.max)
        try exhaustedStore.finish(exhaustedEnd)
        let exhaustedIntent = RecordingCaptureIntent(id: UUID(), context: .init(sessionID: exhaustedID,
            startedAt: descriptor.capturedAt, timeZoneIdentifier: "UTC", origin: descriptor.origin, location: nil),
            ordinal: 0, sessionStartOffset: 0, effectiveFrames: 8000)
        let exhaustedFolder = exhaustedStore.root.appendingPathComponent(exhaustedID.uuidString)
        let exhaustedPartial = exhaustedFolder.appendingPathComponent(exhaustedIntent.partialFilename)
        try FileManager.default.copyItem(at: audio, to: exhaustedPartial)
        try JSONEncoder().encode(exhaustedIntent).write(to: exhaustedPartial.appendingPathExtension("capture.json"))
        try exhaustedStore.recover(); try exhaustedStore.recover()
        let unchangedEnd = try JSONDecoder().decode(RecordingSessionEnd.self, from: Data(contentsOf: exhaustedFolder.appendingPathComponent("end.json")))
        precondition(unchangedEnd == exhaustedEnd && exhaustedStore.recoveryIssues.contains { $0.contains("descriptorMismatch") },
            "revision exhaustion must report recovery failure without wrapping or replacing persisted end")
        precondition(exhaustedStore.chunks.count == 1 && FileManager.default.fileExists(atPath: exhaustedPartial.path),
            "revision exhaustion preserves both recovered bytes and original partial")
        let external = root.appendingPathComponent("external")
        try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)
        let linkedFolder = root.appendingPathComponent("linked-folder")
        try FileManager.default.createSymbolicLink(at: linkedFolder, withDestinationURL: external)
        do { try RecordingAudioFile.requireSafePath(linkedFolder.appendingPathComponent("a.m4a")); fatalError("linked parents must fail") } catch {}
        print("Watch session store smoke passed")
    }
}
