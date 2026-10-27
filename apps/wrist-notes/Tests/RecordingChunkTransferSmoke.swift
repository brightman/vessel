import AVFAudio
import Foundation

@main struct RecordingChunkTransferSmoke {
    static func main() throws {
        try tenMinuteCompatibility()
        func expect(_ condition: @autoclosure () throws -> Bool, _ message: String) rethrows {
            if try !condition() { fatalError(message) }
        }
        let root = URL(fileURLWithPath: "/private/tmp").appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.m4a")
        let format = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)!
        do {
            let writer = try AVAudioFile(forWriting: source, settings: [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 16000, AVNumberOfChannelsKey: 1])
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1600)!
            buffer.frameLength = 1600
            for i in 0..<1600 { buffer.floatChannelData![0][i] = Float(sin(Double(i) * 0.1) * 0.1) }
            try writer.write(from: buffer)
        }
        let info = try RecordingAudioFile.inspect(source), sessionID = UUID()
        let chunk = RecordingChunkDescriptor(id: UUID(), sessionID: sessionID, ordinal: 0,
            sessionStartedAt: Date(timeIntervalSinceReferenceDate: 1000), capturedAt: Date(timeIntervalSinceReferenceDate: 1000),
            timeZoneIdentifier: "UTC", sessionStartOffset: 0, frameCount: 1600, sampleRate: 16000,
            byteCount: info.byteCount, sha256: info.sha256,
            origin: .init(device: "Apple Watch", deviceID: "", fileName: "original.m4a", recordingTimeIsEstimated: false), location: nil)
        let end = RecordingSessionEnd(sessionID: sessionID, finalOrdinal: 0, endedAt: Date(timeIntervalSinceReferenceDate: 1001), interrupted: false, revision: 0)
        var now = Date(timeIntervalSinceReferenceDate: 2000)
        var files: [(URL, RecordingWireEnvelope<RecordingChunkDescriptor>)] = []
        var ends: [RecordingWireEnvelope<RecordingSessionEnd>] = []
        let watchRoot = root.appendingPathComponent("watch")
        let queue = try WatchChunkTransferQueue(root: watchRoot, now: { now }, sendFile: { url, value in files.append((url, value)) }, sendEnd: { ends.append($0) })
        try queue.update(chunks: [chunk], ends: [end], audioURL: { _ in source })
        try queue.pump()
        expect(files.isEmpty && ends.isEmpty, "unnegotiated V2 must remain local")
        let hello = try queue.beginHandshake()
        let counterpart = RecordingCounterpart(phoneID: UUID(), pairingID: UUID())
        let binding = RecordingTransferBinding(counterpart: counterpart, watchID: hello.watchID, nonce: hello.nonce)
        try queue.accept(.init(version: 2, versions: [2], binding: binding))
        try queue.pump()
        expect(files.count == 1 && ends.count == 1, "file and independent end intent must be sent")
        let db = try DaybookDatabase(url: root.appendingPathComponent("metadata.sqlite3"))
        let repository = try RecordingSessionRepository(root: root.appendingPathComponent("phoneAudio"), database: db)
        var trace: [String] = [], acknowledgements: [RecordingTransferAcknowledgement] = []
        repository.importStep = { step in if step == .commit { trace.append("publish") } }
        let receiver = try RecordingChunkReceiver(root: root.appendingPathComponent("inbox"), openRepository: { repository }, send: { ack in acknowledgements.append(ack); trace.append("ACK") }, event: { trace.append($0.rawValue) })
        receiver.setBinding(binding)
        let contentChanges = ReceiverNotificationCount()
        let observation = NotificationCenter.default.addObserver(forName: RecordingChunkReceiver.didChange, object: nil, queue: nil) { _ in contentChanges.increment() }
        defer { NotificationCenter.default.removeObserver(observation) }
        var statusChecks = 0
        receiver.onStatusChange = { statusChecks += 1 }
        for _ in 0..<20 { try receiver.drain() }
        expect(contentChanges.value == 0, "empty receipt retries must not invalidate timeline content")
        expect(statusChecks == 20, "empty retries must still publish transfer health")
        let temporary = root.appendingPathComponent("WC-temp.m4a")
        try FileManager.default.copyItem(at: source, to: temporary)
        try receiver.stage(files[0].1, temporaryFile: temporary)
        expect(!FileManager.default.fileExists(atPath: temporary.path), "callback must move temporary before returning")
        expect(acknowledgements.isEmpty, "intake cannot ACK")
        try receiver.drain()
        expect(contentChanges.value == 1, "a newly committed audio chunk must invalidate timeline content")
        expect(trace == ["inbox", "validate", "publish", "commit", "outbox", "ACK"], "durable event order")
        guard case let .chunk(ack) = acknowledgements.first else { fatalError("missing chunk receipt") }
        try queue.receive(ack)
        expect(queue.sessionStates.first?.isComplete == false, "first chunk cannot acknowledge end")
        try receiver.stage(ends[0])
        try receiver.drain()
        expect(contentChanges.value == 2, "a committed end marker must invalidate timeline content")
        guard case let .end(endAck) = acknowledgements.last else { fatalError("missing end receipt") }
        try queue.receive(endAck)
        expect(queue.sessionStates.first?.isComplete == true, "all receipts plus exact end completes session")
        expect(queue.lastSavedAt == ack.payload.savedAt, "real durable saved time")
        // Recovery extends ends already accepted by the phone. Keep strict end
        // bounds: a tail sent before its newer end stays retained, then replays.
        for priorFinal: Int? in [nil, 0] {
            let scope = root.appendingPathComponent("recovery-" + UUID().uuidString)
            let store = WatchRecordingSessionStore(root: scope.appendingPathComponent("watch-media"))
            let sid = UUID(), ordinal = priorFinal == nil ? 0 : 1
            let context = RecordingCaptureContext(sessionID: sid, startedAt: chunk.sessionStartedAt,
                timeZoneIdentifier: "UTC", origin: chunk.origin, location: nil)
            if priorFinal != nil {
                try store.seal(RecordingCaptureIntent(id: UUID(), context: context, ordinal: 0,
                    sessionStartOffset: 0, effectiveFrames: 1600).descriptor(info: info), file: source)
            }
            let old = RecordingSessionEnd(sessionID: sid, finalOrdinal: priorFinal,
                endedAt: chunk.sessionStartedAt.addingTimeInterval(0.1), interrupted: true, revision: 0)
            try store.finish(old)
            let tail = RecordingCaptureIntent(id: UUID(), context: context, ordinal: ordinal,
                sessionStartOffset: Double(ordinal), effectiveFrames: 1600)
            let folder = store.root.appendingPathComponent(sid.uuidString)
            try FileManager.default.copyItem(at: source, to: folder.appendingPathComponent(tail.partialFilename))
            try JSONEncoder().encode(tail).write(to: folder.appendingPathComponent(tail.partialFilename + ".capture.json"))
            let recoveryRepo = try RecordingSessionRepository(root: scope.appendingPathComponent("phone-media"),
                database: DaybookDatabase(url: scope.appendingPathComponent("db.sqlite3")))
            var recoveryACKs: [RecordingTransferAcknowledgement] = []
            let recoveryReceiver = try RecordingChunkReceiver(root: scope.appendingPathComponent("inbox"),
                openRepository: { recoveryRepo }, send: { recoveryACKs.append($0) })
            var recoveryFiles: [(URL, RecordingWireEnvelope<RecordingChunkDescriptor>)] = []
            var recoveryEnds: [RecordingWireEnvelope<RecordingSessionEnd>] = []
            let recoveryQueue = try WatchChunkTransferQueue(root: scope.appendingPathComponent("ledger"),
                sendFile: { recoveryFiles.append(($0, $1)) }, sendEnd: { recoveryEnds.append($0) })
            let hello = try recoveryQueue.beginHandshake()
            let rb = RecordingTransferBinding(counterpart: counterpart, watchID: hello.watchID, nonce: hello.nonce)
            try recoveryQueue.accept(.init(version: 2, versions: [2], binding: rb))
            recoveryReceiver.setBinding(rb)
            try recoveryQueue.update(chunks: store.chunks, ends: [old], audioURL: store.audioURL)
            for existing in store.chunks {
                let receipt = try recoveryRepo.importChunk(existing, from: store.audioURL(for: existing), pairingID: counterpart.key)
                try recoveryQueue.receive(.init(binding: rb, payload: .init(receipt: receipt,
                    savedAt: recoveryRepo.receiptSavedAt(chunkID: existing.id, pairingID: counterpart.key)!)))
            }
            try recoveryReceiver.stage(.init(binding: rb, payload: old)); try recoveryReceiver.drain()
            guard case .end(let acceptedOld) = recoveryACKs.removeLast() else { fatalError("old end not accepted") }
            try recoveryQueue.receive(acceptedOld)
            expect(recoveryQueue.pendingCount == 0, "prior end is already independently acknowledged")
            try store.recover(); let revised = store.sessionEnds[0]
            try store.recover(); expect(store.sessionEnds == [revised], "recovery end revision is idempotent")
            try recoveryQueue.update(chunks: store.chunks, ends: store.sessionEnds, audioURL: store.audioURL)
            expect(recoveryQueue.pendingCount == 1, "old end ACK cannot complete a recovered tail")
            try recoveryQueue.pump(force: true)
            expect(recoveryFiles.count == 1 && recoveryEnds.count == 1 && recoveryEnds[0].payload.revision == 1,
                "recovery schedules only unsaved tail and independently revised end")
            let temp = scope.appendingPathComponent("wire.m4a")
            try FileManager.default.copyItem(at: recoveryFiles[0].0, to: temp)
            try recoveryReceiver.stage(recoveryFiles[0].1, temporaryFile: temp)
            do { try recoveryReceiver.drain(); fatalError("old end must still reject a tail beyond its bound") } catch {}
            expect(recoveryACKs.isEmpty, "rejected tail cannot ACK before COMMIT")
            try recoveryReceiver.stage(recoveryEnds[0])
            do { try recoveryReceiver.drain() } catch {} // Inbox order may put the old-bound tail first.
            try recoveryReceiver.drain()
            guard let chunkACK = recoveryACKs.first(where: { if case .chunk = $0 { return true }; return false }),
                  let endACK = recoveryACKs.first(where: { if case .end = $0 { return true }; return false }) else {
                fatalError("recovery did not produce independent chunk/end receipts")
            }
            if case .chunk(let value) = chunkACK { try recoveryQueue.receive(value) }
            expect(recoveryQueue.pendingCount == 1, "recovered tail ACK still cannot acknowledge revised end")
            if case .end(let value) = endACK { try recoveryQueue.receive(value) }
            expect(recoveryQueue.pendingCount == 0, "recovered tail plus revised end eventually complete")
            try expect(try recoveryRepo.session(id: sid)?.syncComplete == true, "phone completes recovered session under strict validation")
            expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent(tail.partialFilename).path), "sync retains recovery original")
        }
        // Same verified counterpart, fresh nonce: no resend. New counterpart: every chunk/end pending.
        let restarted = try WatchChunkTransferQueue(root: watchRoot, now: { now }, sendFile: { _, value in files.append((source, value)) }, sendEnd: { ends.append($0) })
        try restarted.update(chunks: [chunk], ends: [end], audioURL: { _ in source })
        let hello2 = try restarted.beginHandshake()
        let binding2 = RecordingTransferBinding(counterpart: counterpart, watchID: hello2.watchID, nonce: hello2.nonce)
        try restarted.accept(.init(version: 2, versions: [2], binding: binding2))
        try restarted.pump()
        expect(files.count == 1 && ends.count == 1 && restarted.sessionStates.first?.isComplete == true, "same-counterpart ledger survives nonce/restart")
        let hello3 = try restarted.beginHandshake()
        let newBinding = RecordingTransferBinding(counterpart: .init(phoneID: UUID(), pairingID: UUID()), watchID: hello3.watchID, nonce: hello3.nonce)
        try restarted.accept(.init(version: 2, versions: [2], binding: newBinding))
        try restarted.pump()
        expect(files.count == 2 && ends.count == 2 && restarted.sessionStates.first?.isComplete == false, "new pairing inherits no ACK or uploaded UI")
        do { try restarted.receive(ack); fatalError("stale ACK accepted") } catch {}
        now = now.addingTimeInterval(120)
        try restarted.pump()
        expect(files.count == 3 && ends.count == 3, "lost receipt and end retry independently")
        // A late/incorrect wire value must never become a legacy recording or clear a chunk.
        var future = RecordingWireEnvelope(binding: newBinding, payload: chunk); future.version = 3
        do { try future.validate(binding: newBinding); fatalError("future envelope accepted") } catch {}
        let futureMetadata: [String: Any] = ["wiseLifeRecordingChunkV3": try JSONEncoder().encode(future)]
        expect(RecordingChunkWire.owns(futureMetadata), "future key owns dispatch and cannot fall through to V1")
        do { let _: RecordingWireEnvelope<RecordingChunkDescriptor> = try RecordingChunkWire.decode(RecordingWireEnvelope<RecordingChunkDescriptor>.self, key: RecordingChunkProtocol.chunkKey, from: futureMetadata); fatalError("future key decoded") } catch {}
        let mixed: [String: Any] = [RecordingChunkProtocol.chunkKey: try JSONEncoder().encode(future), "id": UUID().uuidString]
        do { let _: RecordingWireEnvelope<RecordingChunkDescriptor> = try RecordingChunkWire.decode(RecordingWireEnvelope<RecordingChunkDescriptor>.self, key: RecordingChunkProtocol.chunkKey, from: mixed); fatalError("mixed wire accepted") } catch {}
        for receipt in [
            RecordingChunkReceipt(sessionID: UUID(), chunkID: chunk.id, ordinal: 0, sha256: chunk.sha256),
            .init(sessionID: chunk.sessionID, chunkID: UUID(), ordinal: 0, sha256: chunk.sha256),
            .init(sessionID: chunk.sessionID, chunkID: chunk.id, ordinal: 1, sha256: chunk.sha256),
            .init(sessionID: chunk.sessionID, chunkID: chunk.id, ordinal: 0, sha256: String(repeating: "0", count: 64))
        ] {
            do { try restarted.receive(.init(binding: newBinding, payload: RecordingSavedChunk(receipt: receipt, savedAt: now))); fatalError("incorrect full identity accepted") } catch {}
        }
        expect(restarted.pendingCount == 1, "wrong ACK cannot clear pending")
        let wrongHello = try restarted.beginHandshake()
        do { try restarted.accept(.init(version: 2, versions: [2], binding: binding)); fatalError("stale challenge accepted") } catch {}
        try restarted.accept(.init(version: 2, versions: [2], binding: .init(counterpart: newBinding.counterpart, watchID: wrongHello.watchID, nonce: wrongHello.nonce)))

        // Actual receipt projections preserve an open tail, reconcile a delayed completed manifest,
        // and keep end/ACK replay from changing the original saved time.
        let sync = try WatchSyncStore(database: db)
        let pendingOpen = WatchSessionSyncSnapshot(updatedAt: now, pending: [.init(sessionID: sessionID, lastOrdinal: 0, end: nil)])
        try sync.apply(pendingOpen, counterpartID: counterpart.key)
        try sync.recordSaved(ack.payload, counterpartID: counterpart.key)
        try expect(try sync.readSessions(counterpartID: counterpart.key).pendingCount == 1, "early saved chunk cannot hide unsaved tail")
        try sync.recordEnd(end, counterpartID: counterpart.key)
        try expect(try sync.readSessions(counterpartID: counterpart.key).pendingCount == 1, "open snapshot is not completed by arbitrary ID receipt")
        try sync.apply(.init(updatedAt: now.addingTimeInterval(1), pending: [.init(sessionID: sessionID, lastOrdinal: 0, end: end)]), counterpartID: counterpart.key)
        try expect(try sync.readSessions(counterpartID: counterpart.key).pendingCount == 0, "exact end and saved coverage reconcile ACK loss")
        try expect(try sync.readSessions(counterpartID: counterpart.key).lastSyncedAt == ack.payload.savedAt, "end cannot advance real save time")
        try expect(try sync.readSessions(counterpartID: newBinding.counterpart.key).pendingCount == nil, "new pair snapshot is unknown")

        enum Injected: Error { case failure }
        // Each failure runs real private files and SQLite. Removing COMMIT discipline or
        // moving ACK above import makes these assertions fail.
        for point in ["inbox", "validate", "publish", "sqlCommit", "afterCommit", "send"] {
            let scope = root.appendingPathComponent(point)
            try FileManager.default.createDirectory(at: scope, withIntermediateDirectories: true)
            let dbURL = scope.appendingPathComponent("db.sqlite3")
            let failingDB = try DaybookDatabase(url: dbURL)
            let audioRoot = scope.appendingPathComponent("AudioRoot")
            let repo = try RecordingSessionRepository(root: audioRoot, database: failingDB)
            if point == "sqlCommit" {
                try failingDB.execute("CREATE TABLE fault_parent(id INTEGER PRIMARY KEY)")
                try failingDB.execute("CREATE TABLE fault_child(id INTEGER REFERENCES fault_parent(id) DEFERRABLE INITIALLY DEFERRED)")
            }
            repo.importStep = { step in
                if point == "publish", step == .publish { throw Injected.failure }
                if point == "sqlCommit", step == .commit { try failingDB.execute("INSERT INTO fault_child(id) VALUES (1)") }
            }
            var delivered: [RecordingTransferAcknowledgement] = []
            let inbox = scope.appendingPathComponent("Inbox")
            let failing = try RecordingChunkReceiver(root: inbox, openRepository: { repo }, send: {
                if point == "send" { throw Injected.failure }; delivered.append($0)
            }, event: { step in
                if point == step.rawValue || (point == "afterCommit" && step == .commit) { throw Injected.failure }
            })
            failing.setBinding(binding)
            let temp = scope.appendingPathComponent("temporary.m4a")
            try FileManager.default.copyItem(at: source, to: temp)
            do { try failing.stage(.init(binding: binding, payload: chunk), temporaryFile: temp) } catch { expect(point == "inbox", "only injected intake fails") }
            if point != "inbox" { do { try failing.drain() } catch {} }
            expect(delivered.isEmpty, "no receipt for failed durable stage or failed send")
            let before = try repo.receiptSavedAt(chunkID: chunk.id, pairingID: counterpart.key)
            if ["afterCommit", "send"].contains(point) { expect(before != nil, "COMMIT already durable before crash") }
            else { expect(before == nil, "precommit failure has no successful receipt") }
            let reopened = try RecordingSessionRepository(root: audioRoot, database: DaybookDatabase(url: dbURL))
            let replay = try RecordingChunkReceiver(root: inbox, openRepository: { reopened }, send: { delivered.append($0) })
            replay.setBinding(binding2)
            try replay.drain()
            expect(delivered.count == 1, "restart replays exactly one receipt")
            try expect(try reopened.chunks(sessionID: chunk.sessionID).count == 1, "restart creates one chunk")
            if case .chunk(let value) = delivered[0] {
                expect(value.binding == binding2 && value.payload.receipt == ack.payload.receipt, "replay uses fresh wire token and same full identity")
                if let before { expect(value.payload.savedAt == before, "restart preserves first commit time") }
            } else { fatalError("wrong replay type") }
        }

        // Locked repository does not disable synchronous intake or delete its only copy.
        let lockedRoot = root.appendingPathComponent("locked")
        var locked = true, unlockedReceipts = 0
        let lockedReceiver = try RecordingChunkReceiver(root: lockedRoot, openRepository: {
            if locked { throw Injected.failure }; return repository
        }, send: { _ in unlockedReceipts += 1 })
        lockedReceiver.setBinding(binding)
        let lockedTemp = root.appendingPathComponent("locked-temp.m4a")
        try FileManager.default.copyItem(at: source, to: lockedTemp)
        try lockedReceiver.stage(.init(binding: binding, payload: chunk), temporaryFile: lockedTemp)
        do { try lockedReceiver.drain(); fatalError("locked repository opened") } catch {}
        expect(unlockedReceipts == 0 && !FileManager.default.fileExists(atPath: lockedTemp.path), "locked database keeps private inbox without ACK")
        locked = false; try lockedReceiver.drain()
        expect(unlockedReceipts == 1, "unlock resumes independent receiver")

        // Empty unlock must clear a failed storage open; one committed ACK must
        // never clear another item's failure in the same serial drain.
        let statusRoot = root.appendingPathComponent("status")
        var statusLocked = true, statusPublications = 0, statusACKs = 0
        let statusReceiver = try RecordingChunkReceiver(root: statusRoot, openRepository: {
            if statusLocked { throw Injected.failure }; return repository
        }, send: { _ in statusACKs += 1 })
        statusReceiver.setBinding(binding)
        statusReceiver.onStatusChange = { statusPublications += 1 }
        do { try statusReceiver.drain(); fatalError("locked empty inbox opened") } catch {}
        expect(statusReceiver.saveFailed(for: counterpart), "empty locked replay publishes failure")
        expect(statusPublications == 1, "failed drain publishes one aggregate status")
        statusLocked = false; try statusReceiver.drain()
        expect(!statusReceiver.saveFailed(for: counterpart) && statusPublications == 2,
            "successful empty unlock replay clears storage failure and publishes")
        let invalidTemp = root.appendingPathComponent("status-invalid.m4a")
        try Data([1,2,3]).write(to: invalidTemp)
        try statusReceiver.stage(.init(binding: binding, payload: chunk), temporaryFile: invalidTemp)
        let validTemp = root.appendingPathComponent("status-valid.m4a")
        try FileManager.default.copyItem(at: source, to: validTemp)
        try statusReceiver.stage(.init(binding: binding, payload: chunk), temporaryFile: validTemp)
        do { try statusReceiver.drain(); fatalError("mixed drain cannot succeed") } catch {}
        expect(statusACKs == 1 && statusReceiver.saveFailed(for: counterpart),
            "one durable success cannot conceal another retained invalid item")
        expect(statusPublications == 3, "mixed drain publishes only its final aggregate status")
        statusReceiver.setBinding(newBinding)
        do { try statusReceiver.drain() } catch {} // Old counterpart's invalid file remains retryable.
        expect(!statusReceiver.saveFailed(for: newBinding.counterpart) && statusReceiver.saveFailed(for: counterpart),
            "counterpart replacement isolates retained failures")
        do { try statusReceiver.stage(.init(binding: binding, payload: end)); fatalError("stale end accepted") } catch {}
        expect(!statusReceiver.saveFailed(for: newBinding.counterpart), "rejected stale envelope cannot taint current pairing")
        // Synchronous WC intake can fail after the worker took its inbox
        // snapshot. Its newer failure must survive that older drain's success.
        let intakeRaceRoot = root.appendingPathComponent("intake-race")
        var intakeRace: RecordingChunkReceiver!, injectedIntake = false
        intakeRace = try RecordingChunkReceiver(root: intakeRaceRoot, openRepository: { repository }, send: { _ in }, event: { event in
            if event == .validate && !injectedIntake {
                injectedIntake = true
                do {
                    try intakeRace.stage(.init(binding: binding, payload: chunk), temporaryFile: root.appendingPathComponent("missing-intake.m4a"))
                    fatalError("missing synchronous intake succeeded")
                } catch {}
            }
        })
        intakeRace.setBinding(binding)
        let raceTemp = root.appendingPathComponent("intake-race.m4a")
        try FileManager.default.copyItem(at: source, to: raceTemp)
        try intakeRace.stage(.init(binding: binding, payload: chunk), temporaryFile: raceTemp)
        try intakeRace.drain()
        expect(intakeRace.saveFailed(for: counterpart), "older successful drain cannot erase a newer synchronous intake failure")
        // Persistent negotiation survives a phone restart but a different system pairing
        // gets a distinct stable identity. Stale wire receipts never prove current saves.
        let identityRoot = root.appendingPathComponent("identity")
        let negotiator = try RecordingChunkReceiver(root: identityRoot, openRepository: { repository }, send: { _ in })
        let helloA = RecordingCapabilityHello(watchID: UUID(), nonce: UUID())
        let a = try negotiator.negotiate(helloA, systemPairingID: "system-A")
        let negotiator2 = try RecordingChunkReceiver(root: identityRoot, openRepository: { repository }, send: { _ in })
        let a2 = try negotiator2.negotiate(.init(watchID: helloA.watchID, nonce: UUID(), generation: 1), systemPairingID: "system-A")
        let b = try negotiator2.negotiate(.init(watchID: helloA.watchID, nonce: UUID(), generation: 2), systemPairingID: "system-B")
        expect(a.binding.counterpart == a2.binding.counterpart && a.binding.nonce != a2.binding.nonce, "stable counterpart survives nonce and phone process")
        expect(a2.binding.counterpart != b.binding.counterpart, "different pairing inherits no ledger identity")
        do { _ = try negotiator2.negotiate(helloA, systemPairingID: "system-A"); fatalError("late old hello must not replace a newer handshake") } catch {}
        do { try negotiator2.stage(.init(binding: a2.binding, payload: end)); fatalError("old pair end accepted") } catch {}

        // Keep the batch bounded even when four previous files remain outstanding.
        let many = (0..<8).map { ordinal in
            RecordingChunkDescriptor(id: UUID(), sessionID: sessionID, ordinal: ordinal, sessionStartedAt: chunk.sessionStartedAt,
                capturedAt: chunk.capturedAt, timeZoneIdentifier: "UTC", sessionStartOffset: Double(ordinal), frameCount: 1600,
                sampleRate: 16000, byteCount: chunk.byteCount, sha256: chunk.sha256, origin: chunk.origin, location: nil)
        }
        var outstanding = Set<UUID>(), batchCount = 0
        let bounded = try WatchChunkTransferQueue(root: root.appendingPathComponent("bounded"), isOutstanding: { id, end, _ in !end && outstanding.contains(id) }, sendFile: { _, value in outstanding.insert(value.payload.id); batchCount += 1 }, sendEnd: { _ in })
        try bounded.update(chunks: many, ends: [], audioURL: { _ in source })
        let boundedHello = try bounded.beginHandshake()
        try bounded.accept(.init(version: 2, versions: [2], binding: .init(counterpart: counterpart, watchID: boundedHello.watchID, nonce: boundedHello.nonce)))
        try bounded.pump(); try bounded.pump()
        expect(batchCount == 4, "in-flight limit includes already outstanding files")
        // Foreground handshakes change wire nonces while the system may still hold
        // old jobs. All owned V2 files must consume the same four slots.
        var delayed: [RecordingWireEnvelope<RecordingChunkDescriptor>] = []
        let nonceBounded = try WatchChunkTransferQueue(root: root.appendingPathComponent("nonce-bounded"),
            outstandingFileCount: { delayed.count },
            isOutstanding: { id, end, binding in !end && delayed.contains { $0.binding == binding && $0.payload.id == id } },
            sendFile: { _, value in delayed.append(value) }, sendEnd: { _ in })
        try nonceBounded.update(chunks: many, ends: [], audioURL: { _ in source })
        for _ in 0..<5 {
            let hello = try nonceBounded.beginHandshake()
            try nonceBounded.accept(.init(version: 2, versions: [2], binding: .init(counterpart: counterpart, watchID: hello.watchID, nonce: hello.nonce)))
            try nonceBounded.pump(force: true)
            expect(delayed.count <= 4, "fresh nonces cannot exceed total outstanding V2 file cap")
        }
        let obsolete = delayed[0]
        do {
            try nonceBounded.receive(.init(binding: obsolete.binding, payload: RecordingSavedChunk(receipt:
                .init(sessionID: obsolete.payload.sessionID, chunkID: obsolete.payload.id, ordinal: obsolete.payload.ordinal, sha256: obsolete.payload.sha256), savedAt: now)))
            fatalError("obsolete wire ACK accepted after handshake refresh")
        } catch {}
        delayed.removeAll() // Actual system completions release old slots.
        try nonceBounded.pump(force: true)
        expect(delayed.count == 4 && delayed.allSatisfy { $0.binding == nonceBounded.binding }, "current binding progresses after obsolete jobs finish")
        for value in delayed {
            try nonceBounded.receive(.init(binding: value.binding, payload: .init(receipt:
                .init(sessionID: value.payload.sessionID, chunkID: value.payload.id, ordinal: value.payload.ordinal, sha256: value.payload.sha256), savedAt: now)))
        }
        delayed.removeAll(); try nonceBounded.pump(force: true)
        expect(delayed.count == 4 && Set(delayed.map { $0.payload.ordinal }) == Set(4..<8), "bounded completion eventually advances to remaining media")
        expect(FileManager.default.fileExists(atPath: source.path), "transfer completion retains original media")
        var helloSends: [RecordingCapabilityHello] = []
        let handshakeQueue = try WatchChunkTransferQueue(root: root.appendingPathComponent("hello"), sendHello: { helloSends.append($0) }, sendFile: { _, _ in fatalError("no negotiated send") }, sendEnd: { _ in fatalError("no negotiated end") })
        try handshakeQueue.requestCapability(); try handshakeQueue.requestCapability()
        expect(helloSends.count == 2 && helloSends[0].nonce == helloSends[1].nonce, "handshake retries use injected sender and current challenge")
        try handshakeQueue.accept(.init(version: 2, versions: [2], binding: .init(counterpart: counterpart, watchID: helloSends[0].watchID, nonce: helloSends[0].nonce)))
        try handshakeQueue.update(chunks: [chunk], ends: [], audioURL: { _ in root.appendingPathComponent("missing.m4a") })
        do { try handshakeQueue.pump(); fatalError("missing audio submitted") } catch {}
        var pendingACKs: [RecordingTransferAcknowledgement] = []
        let deliveryReceiver = try RecordingChunkReceiver(root: root.appendingPathComponent("delivery"), openRepository: { repository },
            send: { pendingACKs.append($0) }, retainUntilDelivery: true, now: { now })
        deliveryReceiver.setBinding(binding)
        let deliveryTemp = root.appendingPathComponent("delivery.m4a")
        try FileManager.default.copyItem(at: source, to: deliveryTemp)
        try deliveryReceiver.stage(.init(binding: binding, payload: chunk), temporaryFile: deliveryTemp)
        try deliveryReceiver.drain(); try deliveryReceiver.drain()
        expect(pendingACKs.count == 1, "OS enqueue persists receipt and bounded retry deadline")
        now = now.addingTimeInterval(31); try deliveryReceiver.drain()
        expect(pendingACKs.count == 2, "missing completion independently retries durable ACK")
        deliveryReceiver.deliveryFinished(pendingACKs[1], succeeded: true)
        now = now.addingTimeInterval(31); try deliveryReceiver.drain()
        expect(pendingACKs.count == 2, "only successful current-token completion retires ACK outbox")

        // End-first, ordinal 2/0/1/1, and Watch restart after all chunk ACKs but lost end ACK.
        let disorderRoot = root.appendingPathComponent("disorder")
        let disorderDB = try DaybookDatabase(url: disorderRoot.appendingPathComponent("db.sqlite3"))
        let disorderRepo = try RecordingSessionRepository(root: disorderRoot.appendingPathComponent("audio"), database: disorderDB)
        var disorderACKs: [RecordingTransferAcknowledgement] = []
        let disorder = try RecordingChunkReceiver(root: disorderRoot.appendingPathComponent("inbox"), openRepository: { disorderRepo }, send: { disorderACKs.append($0) })
        disorder.setBinding(binding)
        let disorderEnd = RecordingSessionEnd(sessionID: sessionID, finalOrdinal: 2, endedAt: end.endedAt, interrupted: false, revision: 0)
        try disorder.stage(.init(binding: binding, payload: disorderEnd)); try disorder.drain()
        expect(disorderACKs.count == 1, "end-first gets only manifest ACK")
        let disorderWatchRoot = root.appendingPathComponent("disorder-watch")
        var endSends = 0
        let disorderQueue = try WatchChunkTransferQueue(root: disorderWatchRoot, now: { now }, sendFile: { _, _ in }, sendEnd: { _ in endSends += 1 })
        let disorderHello = try disorderQueue.beginHandshake()
        let disorderBinding = RecordingTransferBinding(counterpart: counterpart, watchID: disorderHello.watchID, nonce: disorderHello.nonce)
        try disorderQueue.accept(.init(version: 2, versions: [2], binding: disorderBinding))
        try disorderQueue.update(chunks: Array(many.prefix(3)), ends: [disorderEnd], audioURL: { _ in source })
        for ordinal in [2, 0, 1, 1] {
            let item = many[ordinal], temp = disorderRoot.appendingPathComponent(UUID().uuidString + ".m4a")
            try FileManager.default.copyItem(at: source, to: temp)
            try disorder.stage(.init(binding: binding, payload: item), temporaryFile: temp); try disorder.drain()
            guard case .chunk(let received) = disorderACKs.last else { fatalError("missing reordered chunk ACK") }
            try disorderQueue.receive(.init(binding: disorderBinding, payload: received.payload))
        }
        try expect(try disorderRepo.session(id: sessionID)?.syncComplete == true, "reordered chunks complete one repository session")
        expect(disorderQueue.pendingCount == 1, "all chunks saved but lost end ACK stays pending")
        try disorderQueue.pump()
        let disorderRestart = try WatchChunkTransferQueue(root: disorderWatchRoot, now: { now }, sendFile: { _, _ in fatalError("confirmed chunk retransmitted") }, sendEnd: { _ in endSends += 1 })
        try disorderRestart.update(chunks: Array(many.prefix(3)), ends: [disorderEnd], audioURL: { _ in source })
        let nextHello = try disorderRestart.beginHandshake()
        let nextBinding = RecordingTransferBinding(counterpart: counterpart, watchID: nextHello.watchID, nonce: nextHello.nonce)
        try disorderRestart.accept(.init(version: 2, versions: [2], binding: nextBinding))
        now = now.addingTimeInterval(31); try disorderRestart.pump()
        expect(endSends == 2 && disorderRestart.pendingCount == 1, "independent end retry survives Watch restart")
        try disorderRestart.receive(.init(binding: nextBinding, payload: disorderEnd))
        expect(disorderRestart.pendingCount == 0, "matching end plus all current-counterpart chunk receipts completes")
        let revisionOne = RecordingSessionEnd(sessionID: sessionID, finalOrdinal: 0, endedAt: end.endedAt, interrupted: true, revision: 1)
        try sync.recordEnd(revisionOne, counterpartID: counterpart.key)
        try sync.apply(.init(updatedAt: now.addingTimeInterval(10), pending: [.init(sessionID: sessionID, lastOrdinal: 0, end: revisionOne)]), counterpartID: counterpart.key)
        try sync.recordEnd(end, counterpartID: counterpart.key)
        try expect(try sync.readSessions(counterpartID: counterpart.key).pendingCount == 0, "late outbox completion cannot regress saved end projection")
        // Real filesystem failures before intake/outbox persistence preserve the only copy.
        let blockedRoot = root.appendingPathComponent("blocked-intake")
        try FileManager.default.createDirectory(at: blockedRoot, withIntermediateDirectories: true)
        try Data([1]).write(to: blockedRoot.appendingPathComponent("Incoming"))
        var blockedACKs = 0
        let blockedReceiver = try RecordingChunkReceiver(root: blockedRoot, openRepository: { repository }, send: { _ in blockedACKs += 1 })
        blockedReceiver.setBinding(binding)
        let blockedTemp = root.appendingPathComponent("blocked-temp.m4a")
        try FileManager.default.copyItem(at: source, to: blockedTemp)
        do { try blockedReceiver.stage(.init(binding: binding, payload: chunk), temporaryFile: blockedTemp); fatalError("blocked intake succeeded") } catch {}
        expect(blockedACKs == 0 && FileManager.default.fileExists(atPath: blockedTemp.path), "failed intake never ACKs or deletes the supplied original")
        let outboxRoot = root.appendingPathComponent("blocked-outbox")
        try FileManager.default.createDirectory(at: outboxRoot, withIntermediateDirectories: true)
        let blocker = outboxRoot.appendingPathComponent("Outgoing")
        try Data([1]).write(to: blocker)
        let outboxReceiver = try RecordingChunkReceiver(root: outboxRoot, openRepository: { repository }, send: { _ in blockedACKs += 1 })
        outboxReceiver.setBinding(binding)
        try outboxReceiver.stage(.init(binding: binding, payload: chunk), temporaryFile: blockedTemp)
        do { try outboxReceiver.drain(); fatalError("blocked receipt persistence succeeded") } catch {}
        expect(blockedACKs == 0, "failed receipt outbox cannot ACK a committed chunk")
        try FileManager.default.removeItem(at: blocker); try outboxReceiver.drain()
        expect(blockedACKs == 1, "durable inbox replays after outbox storage recovers")
        let corruptRoot = root.appendingPathComponent("corrupt")
        var corruptACKs = 0
        let corrupt = try RecordingChunkReceiver(root: corruptRoot, openRepository: { repository }, send: { _ in corruptACKs += 1 })
        corrupt.setBinding(binding)
        let corruptTemp = root.appendingPathComponent("corrupt.m4a")
        try Data([1,2,3]).write(to: corruptTemp)
        try corrupt.stage(.init(binding: binding, payload: chunk), temporaryFile: corruptTemp)
        do { try corrupt.drain(); fatalError("invalid header acknowledged") } catch {}
        expect(corruptACKs == 0 && !FileManager.default.fileExists(atPath: corruptTemp.path), "invalid audio stays in durable inbox without ACK")
        print("RecordingChunkTransferSmoke passed")
    }
    // Removing duration negotiation must block this real 600 s file or send it
    // unsafely to an older phone. Only actual durable receiver ACKs release it.
    static func tenMinuteCompatibility() throws {
        let root = URL(fileURLWithPath: "/private/tmp").appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("ten-minute.m4a")
        let format = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)!
        do {
            let writer = try AVAudioFile(forWriting: source, settings: [AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 16000, AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 32000])
            let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8000)!
            pcm.frameLength = 8000
            for i in 0..<8000 { pcm.floatChannelData![0][i] = Float(sin(Double(i) * 0.1) * 0.1) }
            for _ in 0..<1200 { try writer.write(from: pcm) }
        }
        let original = try Data(contentsOf: source)
        let info = try RecordingAudioFile.inspect(source)
        let long = RecordingChunkDescriptor(id: UUID(), sessionID: UUID(), ordinal: 0,
            sessionStartedAt: Date(timeIntervalSince1970: 1700000000), capturedAt: Date(timeIntervalSince1970: 1700000000),
            timeZoneIdentifier: "UTC", sessionStartOffset: 0, frameCount: 9_600_000, sampleRate: 16000,
            byteCount: info.byteCount, sha256: info.sha256,
            origin: .init(device: "synthetic", deviceID: "fixture", fileName: "original.m4a", recordingTimeIsEstimated: false), location: nil)
        var files: [(URL, RecordingWireEnvelope<RecordingChunkDescriptor>)] = []
        var ends: [RecordingWireEnvelope<RecordingSessionEnd>] = []
        let ledger = root.appendingPathComponent("watch-ledger")
        let queue = try WatchChunkTransferQueue(root: ledger,
            sendFile: { files.append(($0, $1)) }, sendEnd: { ends.append($0) })
        let repository = try RecordingSessionRepository(root: root.appendingPathComponent("phone-audio"),
            database: DaybookDatabase(url: root.appendingPathComponent("metadata.sqlite3")))
        var acks: [RecordingTransferAcknowledgement] = []
        let receiver = try RecordingChunkReceiver(root: root.appendingPathComponent("receiver"),
            openRepository: { repository }, send: { acks.append($0) })
        try queue.update(chunks: [long], ends: [], audioURL: { _ in source })
        let hello = try queue.beginHandshake()
        let modern = try receiver.negotiate(hello, systemPairingID: "synthetic-pair")
        precondition(modern.maximumChunkDuration == 600, "modern receiver explicitly advertises ten-minute files")
        try queue.accept(modern)
        try queue.pump()
        precondition(files.count == 1 && ends.isEmpty, "600 s file must upload while recording has no end marker")
        let temp = root.appendingPathComponent("wire.m4a")
        try FileManager.default.copyItem(at: source, to: temp)
        try receiver.stage(files[0].1, temporaryFile: temp)
        precondition(acks.isEmpty, "staging is not a durable save")
        try receiver.drain()
        guard case .chunk(let saved) = acks.removeLast() else { fatalError("missing durable save") }
        try queue.receive(saved)
        precondition(queue.sessionStates.first?.savedChunkCount == 1 && queue.pendingCount == 1,
            "durable early save cannot finalize active capture")

        let blocked = RecordingChunkDescriptor(id: UUID(), sessionID: UUID(), ordinal: 0,
            sessionStartedAt: long.sessionStartedAt, capturedAt: long.capturedAt, timeZoneIdentifier: "UTC",
            sessionStartOffset: 0, frameCount: 9_600_000, sampleRate: 16000, byteCount: info.byteCount,
            sha256: info.sha256, origin: long.origin, location: nil)
        let end = RecordingSessionEnd(sessionID: blocked.sessionID, finalOrdinal: 0,
            endedAt: blocked.capturedAt.addingTimeInterval(600), interrupted: false, revision: 0)
        let legacyHello = try queue.beginHandshake()
        let advertised = try receiver.negotiate(legacyHello, systemPairingID: "synthetic-pair")
        var legacyJSON = try JSONSerialization.jsonObject(with: JSONEncoder().encode(advertised)) as! [String: Any]
        legacyJSON.removeValue(forKey: "maximumChunkDuration")
        let legacy = try JSONDecoder().decode(RecordingCapabilityReply.self,
            from: JSONSerialization.data(withJSONObject: legacyJSON))
        precondition(legacy.maximumChunkDuration == nil, "old V2 reply decodes without a new field")
        try queue.accept(legacy)
        precondition(queue.maximumChunkDuration == 300 && !queue.requiresCompanionUpdate,
            "legacy fallback must not flag already durably saved ten-minute audio")
        try queue.update(chunks: [long, blocked], ends: [end], audioURL: { _ in source })
        files.removeAll(); ends.removeAll()
        try queue.pump(force: true)
        precondition(files.isEmpty && ends.isEmpty, "missing maximum means 300 s: retain long file and its end")
        precondition(queue.requiresCompanionUpdate, "unsaved unsupported audio requires companion update")
        let ledgerFolder = ledger.appendingPathComponent(legacy.binding.counterpart.key)
        let persisted = try FileManager.default.contentsOfDirectory(atPath: ledgerFolder.path)
        precondition(!persisted.contains("chunk_\(blocked.id.uuidString).retry.json") &&
            !persisted.contains("end_\(blocked.sessionID.uuidString)_0.retry.json"),
            "unsupported work must not consume retry budget")
        // Old short media remains sendable under the exact same legacy handshake.
        let shortURL = root.appendingPathComponent("short.m4a")
        do {
            let writer = try AVAudioFile(forWriting: shortURL, settings: [AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 16000, AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 32000])
            let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1600)!
            pcm.frameLength = 1600
            for i in 0..<1600 { pcm.floatChannelData![0][i] = 0 }
            for _ in 0..<3000 { try writer.write(from: pcm) }
        }
        let shortInfo = try RecordingAudioFile.inspect(shortURL)
        let short = RecordingChunkDescriptor(id: UUID(), sessionID: UUID(), ordinal: 0,
            sessionStartedAt: long.sessionStartedAt, capturedAt: long.capturedAt, timeZoneIdentifier: "UTC",
            sessionStartOffset: 0, frameCount: 4_800_000, sampleRate: 16000, byteCount: shortInfo.byteCount,
            sha256: shortInfo.sha256, origin: long.origin, location: nil)
        try queue.update(chunks: [long, blocked, short], ends: [end], audioURL: { $0.id == short.id ? shortURL : source })
        try queue.pump(force: true)
        precondition(files.map { $0.1.payload.id } == [short.id] && ends.isEmpty,
            "legacy companion must still receive compatible short audio")
        files.removeAll()
        let upgradedHello = try queue.beginHandshake()
        try queue.accept(receiver.negotiate(upgradedHello, systemPairingID: "synthetic-pair"))
        precondition(!queue.requiresCompanionUpdate && queue.maximumChunkDuration == 600,
            "fresh capability releases update-needed state")
        try queue.pump(force: true)
        precondition(Set(files.map { $0.1.payload.id }) == Set([blocked.id, short.id]) && ends.count == 1,
            "new handshake releases blocked original without retransmitting durable early save")
        for (url, envelope) in files {
            let wire = root.appendingPathComponent(UUID().uuidString + ".m4a")
            try FileManager.default.copyItem(at: url, to: wire)
            try receiver.stage(envelope, temporaryFile: wire)
        }
        try receiver.stage(ends[0]); try receiver.drain()
        for ack in acks {
            switch ack { case .chunk(let value): try queue.receive(value); case .end(let value): try queue.receive(value); case .location(let value): try queue.receive(value) }
        }
        precondition(queue.sessionStates.first { $0.id == blocked.sessionID }?.isComplete == true,
            "upgraded durable file and end ACKs complete retained session")
        let retained = try Data(contentsOf: source)
        precondition(retained == original, "negotiation and retries preserve original AAC bytes")
        for bad in [0.0, -1.0] {
            let hello = try queue.beginHandshake()
            let reply = try receiver.negotiate(hello, systemPairingID: "synthetic-pair")
            var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(reply)) as! [String: Any]
            json["maximumChunkDuration"] = bad
            do {
                try queue.accept(JSONDecoder().decode(RecordingCapabilityReply.self,
                    from: JSONSerialization.data(withJSONObject: json)))
                fatalError("invalid negotiated duration accepted")
            } catch {}
            precondition(queue.binding == nil, "malformed duration must not establish a binding")
        }
        for bad in [Double.nan, .infinity, -.infinity] {
            let hello = try queue.beginHandshake()
            let valid = try receiver.negotiate(hello, systemPairingID: "synthetic-pair")
            do {
                try queue.accept(.init(version: 2, versions: [2], binding: valid.binding, maximumChunkDuration: bad))
                fatalError("nonfinite negotiated duration accepted")
            } catch {}
            precondition(queue.binding == nil, "nonfinite duration cannot establish a binding")
        }
    }

private final class ReceiverNotificationCount: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func increment() { lock.withLock { count += 1 } }
}

}
