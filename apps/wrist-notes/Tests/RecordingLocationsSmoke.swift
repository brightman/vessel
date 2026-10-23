import AVFAudio
import Foundation

@main struct RecordingLocationsSmoke {
    static func expect(_ value: @autoclosure () throws -> Bool, _ message: String) rethrows {
        if try !value() { fatalError(message) }
    }
    static func main() async throws {
        let root = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("recording-locations-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let db = try DaybookDatabase(url: root.appendingPathComponent("metadata.sqlite3"))
        try expect(try db.query("SELECT name FROM sqlite_master WHERE type='table' AND name='recording_location_samples'").count == 1,
               "Location observations need independent durable SQLite storage")
        try expect(try db.query("SELECT name FROM sqlite_master WHERE type='table' AND name='recording_location_addresses'").count == 1,
            "Recording location address cache must have independent durable derived storage")
        let sid = UUID(), date = Date(timeIntervalSinceReferenceDate: 1000)
        let point = CaptureLocation(latitude: 1, longitude: 2, accuracy: 30, measuredAt: date, source: .watchRecording)!
        let sample = RecordingLocationSample(sessionID: sid, sessionOffset: 0, requestedAt: date, location: point, sourceDevice: "watch-id")
        let watch = WatchRecordingSessionStore(root: root.appendingPathComponent("watch"))
        try watch.saveLocationSample(sample)
        let reopenedWatch = WatchRecordingSessionStore(root: watch.root)
        try reopenedWatch.recover()
        expect(reopenedWatch.locationSamples == [sample], "Independent outbox survives relaunch")
        var sent: [RecordingWireEnvelope<RecordingLocationSample>] = []
        let queue = try WatchChunkTransferQueue(root: root.appendingPathComponent("ledger"), sendFile: { _, _ in }, sendEnd: { _ in }, sendLocation: { sent.append($0) })
        try queue.update(chunks: [], ends: [], locations: [sample], audioURL: { _ in root })
        let hello = try queue.beginHandshake()
        let binding = RecordingTransferBinding(counterpart: .init(phoneID: UUID(), pairingID: UUID()), watchID: hello.watchID, nonce: hello.nonce)
        try queue.accept(.init(version: 2, versions: [2], binding: binding))
        try queue.pump()
        expect(sent.isEmpty, "Old peers must not receive unknown location messages")
        let hello2 = try queue.beginHandshake()
        let binding2 = RecordingTransferBinding(counterpart: binding.counterpart, watchID: hello2.watchID, nonce: hello2.nonce)
        try queue.accept(.init(version: 2, versions: [2], binding: binding2, supportsLocationSamples: true))
        try queue.pump()
        expect(sent.count == 1, "Location outbox sends without audio/end metadata")
        var schedule = RecordingLocationSchedule()
        expect(schedule.dueOffsets(through: 0) == [0], "Start sampled once")
        expect(schedule.dueOffsets(through: 599.999).isEmpty, "No early boundary request")
        expect(schedule.dueOffsets(through: 600) == [600], "First ten minute boundary")
        expect(schedule.dueOffsets(through: 600.5).isEmpty, "Polling must not duplicate observations")
        expect(schedule.dueOffsets(through: 1800) == [1200, 1800], "Audio time drives delayed polling boundaries")
        expect(schedule.stopOffset(at: 1850.25) == 1850.25, "Stop requests exact final sampled audio offset")
        expect(schedule.stopOffset(at: 1850.25) == nil, "Repeated stop must not duplicate requests")
        expect(schedule.dueOffsets(through: 2400).isEmpty, "Stopped schedule cannot emit more boundaries")
        let stale = CaptureLocation(latitude: 1, longitude: 2, accuracy: 30, measuredAt: date.addingTimeInterval(-60), source: .watchRecording)!
        let staleSample = RecordingLocationSample(sessionID: sid, sessionOffset: 0, requestedAt: date, location: stale, sourceDevice: "watch-id")
        do { try staleSample.validate(); fatalError("Stale fix must not become fresh") } catch RecordingLocationError.invalidSample {}
        let missingFixTime = CaptureLocation(latitude: 1, longitude: 2, accuracy: 30, source: .watchRecording)!
        do {
            try RecordingLocationSample(sessionID: sid, sessionOffset: 0, requestedAt: date, location: missingFixTime, sourceDevice: "watch-id").validate()
            fatalError("Unknown actual fix time must be rejected")
        } catch RecordingLocationError.invalidSample {}
        let repoRoot = root.appendingPathComponent("phoneAudio")
        let repository = try RecordingSessionRepository(root: repoRoot, database: db)
        let nextDate = date.addingTimeInterval(600)
        let next = RecordingLocationSample(sessionID: sid, sessionOffset: 600, requestedAt: nextDate,
            location: CaptureLocation(latitude: 3, longitude: 4, accuracy: 40, measuredAt: nextDate, source: .watchRecording)!, sourceDevice: "watch-id")
        try repository.importLocationSample(next, pairingID: binding2.counterpart.key)
        try repository.importLocationSample(sample, pairingID: binding2.counterpart.key)
        try repository.importLocationSample(sample, pairingID: binding2.counterpart.key)
        try expect(try repository.locationSamples(sessionID: sid) == [sample, next], "Replay is idempotent; out-of-order samples sort by session time")
        let reopened = try RecordingSessionRepository(root: repoRoot, database: DaybookDatabase(url: root.appendingPathComponent("metadata.sqlite3")))
        try expect(try reopened.locationSamples(sessionID: sid) == [sample, next], "Committed locations survive reopening")
        let conflict = RecordingLocationSample(id: sample.id, sessionID: sid, sessionOffset: 1, requestedAt: date, location: point, sourceDevice: "watch-id")
        do { try repository.importLocationSample(conflict, pairingID: binding2.counterpart.key); fatalError("Identity conflict must reject") } catch RecordingSessionRepository.RepositoryError.conflict {}
        var acks: [RecordingTransferAcknowledgement] = []
        var commitNotifications = 0
        let observer = NotificationCenter.default.addObserver(forName: RecordingChunkReceiver.didChange, object: nil, queue: nil) { value in
            if value.userInfo?["locationUpdated"] as? Bool == true { commitNotifications += 1 }
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        let inbox = root.appendingPathComponent("receiver")
        var failCommit = true
        let receiver = try RecordingChunkReceiver(root: inbox, openRepository: { repository }, send: { acks.append($0) }, event: { event in
            if event == .commit && failCommit { throw RecordingTransportError.unavailable }
        })
        receiver.setBinding(binding2)
        try receiver.stage(sent[0])
        expect(acks.isEmpty, "Location intake cannot ACK before committed receipt")
        do { try receiver.drain(); fatalError("Injected post-COMMIT failure must retain inbox") } catch RecordingTransportError.unavailable {}
        expect(acks.isEmpty, "Post-COMMIT outbox failure must retain observation without premature ACK")
        failCommit = false
        try receiver.drain()
        guard case let .location(ack) = acks.last else { fatalError("Location receipt must follow durable COMMIT") }
        expect(ack.payload == sample && commitNotifications >= 1, "Exact observation ACK and late-context notification")
        try queue.receive(ack)
        sent = []
        try queue.pump(force: true)
        expect(sent.isEmpty, "Durable ACK retires independent outbox")
        let reopenedQueue = try WatchChunkTransferQueue(root: root.appendingPathComponent("ledger"), sendFile: { _, _ in }, sendEnd: { _ in }, sendLocation: { sent.append($0) })
        try reopenedQueue.update(chunks: [], ends: [], locations: [sample], audioURL: { _ in root })
        let h3 = try reopenedQueue.beginHandshake()
        let b3 = RecordingTransferBinding(counterpart: binding2.counterpart, watchID: h3.watchID, nonce: h3.nonce)
        try reopenedQueue.accept(.init(version: 2, versions: [2], binding: b3, supportsLocationSamples: true))
        try reopenedQueue.pump(force: true)
        expect(sent.isEmpty, "Location ACK survives Watch queue relaunch and fresh nonce")
        let address = CaptureAddress(text: "Example road", localeIdentifier: "en_US", city: "Example city")!
        let rawBefore = try db.query("SELECT payload FROM recording_location_samples WHERE id=?", [.text(sample.id.uuidString)]).first?["payload"]
        try expect(try repository.applyLocationAddress(address, sampleID: sample.id, matching: point), "Apply address only to existing exact coordinate")
        let addressed = try repository.locationSamples(sessionID: sid)
        expect(addressed.first?.location.address == address, "Repository overlays durable derived address")
        try expect(try db.query("SELECT payload FROM recording_location_samples WHERE id=?", [.text(sample.id.uuidString)]).first?["payload"] == rawBefore,
            "Geocoding must never mutate wire observation payload or break replay equality")
        try repository.importLocationSample(sample, pairingID: binding2.counterpart.key)
        try expect(try reopened.locationSamples(sessionID: sid).first?.location.address == address, "Address cache survives reopen and raw wire replay")
        try expect(try !repository.applyLocationAddress(address, sampleID: sample.id, matching: next.location), "Mismatched capture cannot apply stale address")
        try repository.deleteSession(sid)
        try expect(try db.query("SELECT sample_id FROM recording_location_addresses").isEmpty, "Source deletion cascades derived address cache")
        try expect(try !repository.applyLocationAddress(address, sampleID: sample.id, matching: point), "Late geocode cannot resurrect deleted location")
        try expect(try repository.locationSamples(sessionID: sid).isEmpty, "Deleting session cascades location observations")
        do { try repository.importLocationSample(next, pairingID: binding2.counterpart.key); fatalError("Deleted session must reject delayed samples") } catch RecordingSessionRepository.RepositoryError.deletedSession {}
        try receiver.stage(.init(binding: binding2, payload: sample))
        let before = acks.count
        do { try receiver.drain(); fatalError("Deleted delayed sample cannot ACK or resurrect") } catch RecordingSessionRepository.RepositoryError.deletedSession {}
        expect(acks.count == before, "Deleted sample does not produce successful ACK")
        // A real location journal write failure must not terminate the production PCM pipeline.
        let audioRoot = root.appendingPathComponent("audio-independent")
        let format = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)!
        var sealed: [RecordingChunkDescriptor] = []
        let pipeline = try RecordingCapturePipeline(format: format, sessionID: UUID(), root: audioRoot,
            origin: .init(device: "Watch", deviceID: "watch-id", fileName: "capture", recordingTimeIsEstimated: false),
            onSeal: { chunk, _ in sealed.append(chunk) }, onFailure: { _ in })
        let context = audioRoot.appendingPathComponent("capture-context.json")
        try FileManager.default.removeItem(at: context)
        try FileManager.default.createDirectory(at: context, withIntermediateDirectories: true)
        pipeline.updateLocation(point)
        let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1600)!
        pcm.frameLength = 1600
        for frame in 0..<1600 { pcm.floatChannelData![0][frame] = Float(sin(Double(frame) * 0.1)) * 0.1 }
        pipeline.submit(pcm)
        try await pipeline.finish()
        expect(sealed.count == 1 && sealed[0].frameCount == 1600, "Location metadata storage failure must preserve audio")
        print("Recording locations scheduling, freshness, durable replay, ACK, deletion passed")
    }
}
