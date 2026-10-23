import AVFAudio
import Foundation

/// Synthetic AAC only. OS delivery and native inference are the injected boundaries.
@main struct StreamingRecordingSmoke {
    static func require(_ value: Bool, _ message: String) throws {
        if !value { throw NSError(domain: "StreamingRecordingSmoke", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
    }
    static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("wiselife-streaming-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let sessionID = UUID(), sourceID = AudioSourceID(kind: .session, id: sessionID)
        let databaseURL = root.appendingPathComponent("phone.sqlite")
        let phoneRoot = root.appendingPathComponent("PhoneSessions")
        func sessions() throws -> RecordingSessionRepository {
            try RecordingSessionRepository(root: phoneRoot, database: DaybookDatabase(url: databaseURL))
        }
        func source() throws -> AudioSourceSnapshot {
            let repository = try sessions()
            let summary = try repository.sessions().first!
            let chunks = try repository.chunks(sessionID: sessionID)
            let hashes = Dictionary(uniqueKeysWithValues: chunks.map { ($0.id, $0.sha256) })
            let ranges = try repository.sourceRanges(sessionID: sessionID).map {
                try AudioSourceRange(range: $0, contentHash: hashes[$0.chunkID]!)
            }
            return try .init(id: sourceID, capturedAt: summary.startedAt!, title: "Synthetic stream", ranges: ranges, complete: summary.syncComplete)
        }
        _ = try sessions()
        let inference = StreamingInference(root: root.appendingPathComponent("BoundedPCM"))
        func coordinator() -> AudioProcessingCoordinator {
            AudioProcessingCoordinator(open: { AudioProcessingRepository(database: try DaybookDatabase(url: databaseURL)) },
                configuration: .init(), discover: { _ in
                    guard try !sessions().sessions().isEmpty else { return [] }
                    return [try source()]
                }, infer: { window, _, _, _, _, _ in try await inference.run(window) })
        }
        var worker = coordinator()
        var notifications = StreamingReceiveNotifications(worker: worker)
        let delivery = StreamingDelivery()
        let watch = WatchRecordingSessionStore(root: root.appendingPathComponent("Watch"))
        let queue = try WatchChunkTransferQueue(root: root.appendingPathComponent("WatchQueue"),
            sendFile: { url, envelope in delivery.files.append((url, envelope)) },
            sendEnd: { delivery.ends.append($0) })
        let receiver = try RecordingChunkReceiver(root: root.appendingPathComponent("Receiver"), openRepository: sessions,
            send: { acknowledgement in
                switch acknowledgement {
                case .chunk(let value): try queue.receive(value)
                case .end(let value): try queue.receive(value); case .location(let value): try queue.receive(value)
                }
            })
        try queue.accept(receiver.negotiate(queue.beginHandshake(), systemPairingID: "synthetic-pair"))
        func pump() throws {
            try queue.update(chunks: watch.chunks, ends: watch.sessionEnds, audioURL: watch.audioURL)
            try queue.pump(force: true)
        }
        func stage(_ item: (URL, RecordingWireEnvelope<RecordingChunkDescriptor>)) throws {
            let temporary = root.appendingPathComponent("wc-\(UUID()).m4a")
            try FileManager.default.copyItem(at: item.0, to: temporary)
            try receiver.stage(item.1, temporaryFile: temporary)
        }
        let writer = try RecordingChunkWriter(sessionID: sessionID, root: root.appendingPathComponent("Capture"),
            onSeal: { try watch.seal($0, file: $1) })
        let pcm = AVAudioPCMBuffer(pcmFormat: AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)!, frameCapacity: 4096)!
        for index in 0..<4096 { pcm.floatChannelData![0][index] = Float(sin(Double(index) * 0.17)) * 0.1 }
        func append(seconds: Int) throws {
            var remaining = seconds * 16000
            while remaining > 0 {
                let count = min(remaining, 4096); pcm.frameLength = AVAudioFrameCount(count)
                try writer.append(pcm); remaining -= count
            }
        }
        // Catches any receive path that waits for sessionEnd before durable analysis.
        try append(seconds: 600); try pump()
        try require(delivery.files.count == 1 && delivery.ends.isEmpty, "first file must be deliverable before stop")
        let first = delivery.files.removeFirst(); try stage(first); try receiver.drain()
        await notifications.flush()
        let processing = AudioProcessingRepository(database: try DaybookDatabase(url: databaseURL))
        try require(watch.sessionEnds.isEmpty, "fixture must still be recording")
        try require(try !source().complete, "phone must not complete without end")
        try require(try sessions().receiptSavedAt(chunkID: first.1.payload.id, pairingID: first.1.binding.counterpart.key) != nil, "early receipt must be durable")
        try require(try processing.results(sourceID: sourceID).count == 1, "stable ASR/VAD window must commit before writer.finish")
        try require(try processing.results(sourceID: sourceID).first?.vad == .success, "early VAD must commit")
        try require(queue.sessionStates.first?.savedChunkCount == 1 && queue.sessionStates.first?.isComplete == false, "partial ACK must not imply complete")
        _ = try RecordingAudioFile.validate(first.1.payload, at: first.0)
        print("Streaming: first 600s AAC, receipt and stable ASR/VAD committed before writer.finish or sessionEnd")

        try append(seconds: 600); try pump()
        let second = delivery.files.removeFirst(); try stage(second); try receiver.drain(); await notifications.flush()
        let calls = await inference.starts
        try require(calls == [0, 300, 600], "append must preserve stable first window and add only newly stable windows")
        try stage(second); try receiver.drain(); await notifications.flush()
        try require(await inference.starts == calls, "replay must not repeat unchanged committed inference")
        let checkDB = try DaybookDatabase(url: databaseURL)
        try require(try checkDB.query("SELECT id FROM recording_chunks WHERE id=?", [.text(second.1.payload.id.uuidString)]).count == 1, "duplicate chunk row")
        try require(try checkDB.query("SELECT chunk_id FROM recording_receipts WHERE chunk_id=?", [.text(second.1.payload.id.uuidString)]).count == 1, "duplicate receipt row")
        notifications.close(); await worker.shutdown()
        worker = coordinator(); notifications = StreamingReceiveNotifications(worker: worker)
        // Empty receiver replay posts the same documented refresh boundary after reopening SQLite.
        try receiver.drain(); await notifications.flush()
        try require(await inference.starts == calls, "reopen must preserve committed progress")
        print("Streaming: second file, replay and SQLite/coordinator reopen preserved committed windows")

        try append(seconds: 10); try writer.finish()
        try watch.finish(.init(sessionID: sessionID, finalOrdinal: 2, endedAt: .now, interrupted: false, revision: 0))
        try pump()
        try require(delivery.files.count == 1 && delivery.ends.count == 1, "tail and end must be separate deliveries")
        // End arriving first cannot complete a session with a missing tail.
        try receiver.stage(delivery.ends.removeFirst()); try receiver.drain(); await notifications.flush()
        try require(try !source().complete, "end without all original files must stay incomplete")
        try require(queue.sessionStates.first?.isComplete == false, "end ACK without tail ACK must stay incomplete")
        let tail = delivery.files.removeFirst(); try stage(tail); try receiver.drain(); await notifications.flush()
        try require(try source().complete, "all files plus end must complete")
        try require(queue.sessionStates.first?.isComplete == true, "all saved chunks plus end ACK must complete Watch state")
        try require(await inference.starts == [0, 300, 600, 900, 1200], "finalization must process only remaining windows")
        let reopened = AudioProcessingRepository(database: try DaybookDatabase(url: databaseURL))
        try require(try reopened.results(sourceID: sourceID).count == 5, "all bounded windows persisted")
        let content = ContentSegmentRepository(database: try DaybookDatabase(url: databaseURL))
        try content.reconcile(sourceID: sourceID)
        let segments = try content.segments(sourceID: sourceID)
        let gaps=zip(segments,segments.dropFirst()).filter { $0.ranges.last!.end < $1.ranges.first!.sessionStartOffset }
        try require(gaps.count == 1, "successful 600s noSpeech crossing files excludes one interior gap; ASR-empty chapters remain visible")
        try require(gaps[0].0.ranges.last?.end == 482 && gaps[0].1.ranges.first?.sessionStartOffset == 1078, "silence boundary must retain two seconds context")
        try require(try segments.flatMap { try content.spans(segmentID:$0.id) }.count == 2, "ASR-empty chapter strategy preserves every raw transcript row")
        try content.reconcile(sourceID: sourceID)
        try require(try content.segments(sourceID: sourceID).map(\.id) == segments.map(\.id), "reconcile must not duplicate the split")
        let fullSource = try source()
        for segment in segments {
            for range in segment.ranges {
                try range.validate()
                try require(fullSource.ranges.contains { original in
                    original.chunkID == range.chunkID && original.url == range.url && original.contentHash == range.contentHash &&
                    range.startFrame >= original.startFrame && range.endFrame <= original.endFrame
                }, "content must reference valid original frames and hashes")
            }
        }
        for chunk in watch.chunks {
            _ = try RecordingAudioFile.validate(chunk, at: watch.audioURL(for: chunk))
            let phoneRange = fullSource.ranges.first { $0.chunkID == chunk.id }!
            _ = try RecordingAudioFile.validate(chunk, at: phoneRange.url)
        }
        // A failed or missing middle analysis interval never counts as silence.
        let silence = [AudioTimeRange(start: 480, end: 1080)]
        for coverage in [[AudioTimeRange(start: 0, end: 600), .init(start: 900, end: 1210)],
                         [.init(start: 0, end: 600), .init(start: 601, end: 1210)]] {
            let partial = try ContentSegmentation.build(source: fullSource, reliableNoSpeech: silence, successfulCoverage: coverage)
            try require(partial.segments.count == 1, "failed/missing middle coverage must not create a silence split")
        }
        notifications.close(); await worker.shutdown()
        print("Streaming: final tail/end coverage, bounded real decoding, one cross-file silence split and original byte preservation passed")
        try presentation()
    }
    static func presentation() throws {
        let id = UUID()
        let active = RecordingSessionSyncPresentation(sessionID: id, activeSessionID: id, savedChunkCount: 1, sealedChunkCount: 1, hasEnd: false, syncComplete: true)
        try require(active.phase == .recording && !active.isComplete, "active recording cannot be wholly synced even when every sealed chunk is saved")
        try require(active.savedChunkCount == 1 && active.sealedChunkCount == 1, "partial saved/total progress must remain visible")
        let unknown = RecordingSessionSyncPresentation(sessionID: id, activeSessionID: nil, savedChunkCount: 1, sealedChunkCount: 2, hasEnd: false, syncComplete: false)
        try require(unknown.phase == .awaitingEnd, "missing end must not claim active recording or error")
        let pending = RecordingSessionSyncPresentation(sessionID: id, activeSessionID: nil, savedChunkCount: 2, sealedChunkCount: 2, hasEnd: true, syncComplete: false)
        try require(pending.phase == .syncing && !pending.isComplete, "saved chunks still require end ACK")
        let complete = RecordingSessionSyncPresentation(sessionID: id, activeSessionID: UUID(), savedChunkCount: 2, sealedChunkCount: 2, hasEnd: true, syncComplete: true)
        try require(complete.isComplete, "another active session must not hide completed history")
        print("Presentation: active partial sync, unknown end, end ACK and completed history passed")
    }
}

private final class StreamingDelivery {
    var files: [(URL, RecordingWireEnvelope<RecordingChunkDescriptor>)] = []
    var ends: [RecordingWireEnvelope<RecordingSessionEnd>] = []
}

/// Same receive notification observed by AudioProcessingModel. Its UIKit/native
/// facade cannot execute in this macOS fixture; generic iOS build verifies it.
private final class StreamingReceiveNotifications: @unchecked Sendable {
    private let lock = NSLock()
    private var tasks: [Task<Void, Never>] = []
    private var token: NSObjectProtocol?
    private let worker: AudioProcessingCoordinator
    init(worker: AudioProcessingCoordinator) {
        self.worker = worker
        token = NotificationCenter.default.addObserver(forName: RecordingChunkReceiver.didChange, object: nil, queue: nil) { [weak self] _ in
            guard let self else { return }
            self.lock.withLock { self.tasks.append(Task { await worker.refresh() }) }
        }
    }
    func flush() async {
        let pending = lock.withLock { let value = tasks; tasks = []; return value }
        for task in pending { await task.value }
        await worker.waitUntilIdle()
    }
    func close() { if let token { NotificationCenter.default.removeObserver(token) }; token = nil }
    deinit { close() }
}

private actor StreamingInference {
    var starts: [Double] = []
    let root: URL
    init(root: URL) { self.root = root }
    func run(_ window: AudioProcessingWindow) throws -> AudioInferenceDelta {
        try StreamingRecordingSmoke.require(window.coreEnd - window.coreStart <= 300 && window.inputDuration <= 304, "model window exceeded core/input limit")
        let decoded = try BoundedAudioReader(temporaryRoot: root).materialize(window)
        defer { decoded.cleanup() }
        try StreamingRecordingSmoke.require(decoded.duration <= 304 && decoded.maximumSourceBufferFrames <= 4096, "real AAC decoding must stay bounded")
        starts.append(window.coreStart)
        var activities: [AudioActivityInterval] = []
        let a = window.coreStart, b = window.coreEnd
        if a < 480 { activities.append(.init(start: a, end: min(b, 480), kind: .speech)) }
        if max(a, 480) < min(b, 1080) { activities.append(.init(start: max(a, 480), end: min(b, 1080), kind: .noSpeech)) }
        if b > 1080 { activities.append(.init(start: max(a, 1080), end: b, kind: .speech)) }
        let spans: [AudioTranscriptSpan] = a == 0 ? [.init(start: 1, end: 2, text: "Synthetic beginning")] :
            a == 900 ? [.init(start: 1190, end: 1191, text: "Synthetic ending")] : []
        return .init(result: .init(spans: spans, activities: activities, asr: .success, vad: .success, speaker: .notRequested,
            asrCoverage: [.init(start: a, end: b)], vadCoverage: [.init(start: a, end: b)]), speakerSpanUpdates: [])
    }
}
