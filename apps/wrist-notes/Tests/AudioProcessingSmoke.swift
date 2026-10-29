import Foundation

@main struct AudioProcessingSmoke {
    static func expect(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
        let passed = try value()
        precondition(passed, message)
    }
    static func rejects(_ action: () throws -> Void) {
        do { try action(); fatalError("invalid operation accepted") } catch {}
    }
    static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let origin = AudioSourceOrigin(recordingOrigin: RecordingOrigin(device: "synthetic", deviceID: "fixture", fileName: "fixture.wav", recordingTimeIsEstimated: false))
        try expect(origin.recordingOrigin.deviceID == "fixture", "origin retains immutable metadata")
        try expect(AudioInferenceStagePolicy.initialStages(sourceDuration:16) == [.asr,.speaker], "short completed recordings skip VAD while retaining ASR and independent speaker analysis")
        try expect(AudioInferenceStagePolicy.initialStages(sourceDuration:1_800) == [.asr,.speaker], "the exact thirty-minute boundary skips VAD")
        try expect(AudioInferenceStagePolicy.initialStages(sourceDuration:1_801) == .all, "recordings beyond thirty minutes request VAD for topic processing")
        try expect(AudioInferenceStagePolicy.initialStages(sourceDuration:nil) == .all, "unknown duration keeps the existing conservative processing route")
        try shortRecordingCrossingThresholdRequestsVAD()
        let id = AudioSourceID(kind: .session, id: UUID())
        let chunk = UUID()
        func range(_ start: Double, _ duration: Double, chunkID: UUID = UUID(), gap: String? = nil) throws -> AudioSourceRange {
            try AudioSourceRange(range: RecordingSourceRange(chunkID: chunkID, url: root.appendingPathComponent(chunkID.uuidString + ".wav"), startFrame: 0, endFrame: Int64(duration * 16000), sampleRate: 16000, sessionStartOffset: start, discontinuityBefore: gap), contentHash: String(repeating: "a", count: 64))
        }
        func source(_ ranges: [AudioSourceRange], complete: Bool = true) throws -> AudioSourceSnapshot {
            try AudioSourceSnapshot(id: id, capturedAt: Date(timeIntervalSinceReferenceDate: 0), title: "Synthetic", ranges: ranges, complete: complete)
        }
        // Integer frame endpoints must survive a seconds round trip, including tiny tails.
        let frameCases: [(Int64, Int64, Double, Int)] = [
            (1_024_003, 0, 0, 1),
            (4_800_001, 0, 0, 2),
            (9_600_001, 137, 19.1234567, 3),
            (10_624_003, 0, 0, 3),
            (1_024_003, 137, 19.1234567, 1),
            (10_624_003, 137, 19.1234567, 3),
            (1, 137, 19.1234567, 1)
        ]
        for (count, firstFrame, offset, expectedCount) in frameCases {
            let raw = RecordingSourceRange(chunkID: UUID(), url: root.appendingPathComponent("frame-fixture.wav"), startFrame: firstFrame, endFrame: firstFrame + count, sampleRate: 16000, sessionStartOffset: offset)
            let descriptor = try AudioSourceRange(range: raw, contentHash: String(repeating: "b", count: 64))
            let planned = try AudioWindowPlanner.plan(source: source([descriptor]), configurationKey: "frames")
            try expect(planned.count == expectedCount, "non-round frame tail makes bounded forward progress")
            try expect(planned.first?.coreStart == offset && planned.last?.coreEnd == descriptor.end, "complete core coverage reaches exact source endpoint")
            try expect(planned.first?.ranges.first?.startFrame == firstFrame && planned.last?.ranges.last?.endFrame == firstFrame + count, "effective input frame endpoints are exact")
            try expect(planned.allSatisfy { $0.coreEnd > $0.coreStart && $0.coreEnd - $0.coreStart <= 300 && $0.inputDuration <= 304 }, "non-round frame cores/input stay bounded")
            for index in 1..<planned.count {
                try expect(planned[index - 1].coreEnd == planned[index].coreStart, "non-round frame core coverage has no gap")
            }
            let full = try AudioWindowPlanner.slices([descriptor], start: offset, end: descriptor.end)
            try expect(full.first?.startFrame == firstFrame && full.last?.endFrame == firstFrame + count, "whole-range slicing preserves integer endpoints")
            // This time is formed from an exact interior frame; cancellation error must not lose it.
            if count > 1000 {
                let lower = offset + 101.0 / 16000, upper = offset + 997.0 / 16000
                let inner = try AudioWindowPlanner.slices([descriptor], start: lower, end: upper)
                try expect(inner.first?.startFrame == firstFrame + 101 && inner.last?.endFrame == firstFrame + 997, "interior frame snapping absorbs only representation error")
                let fractional = try AudioWindowPlanner.slices([descriptor], start: offset + 101.25 / 16000, end: offset + 997.75 / 16000)
                try expect(fractional.first?.startFrame == firstFrame + 102 && fractional.last?.endFrame == firstFrame + 997, "genuinely fractional boundaries round inward")
            }
        }
        for rate in [44100.0, 48000.0] {
            let descriptor = try AudioSourceRange(range: RecordingSourceRange(chunkID: UUID(), url: root.appendingPathComponent("rate-fixture.wav"), startFrame: 137, endFrame: 30_000_138, sampleRate: rate, sessionStartOffset: 43.1234567), contentHash: String(repeating: "c", count: 64))
            let planned = try AudioWindowPlanner.plan(source: source([descriptor]), configurationKey: "frames")
            try expect(planned.count == 3 && planned.last?.coreEnd == descriptor.end && planned.last?.ranges.last?.endFrame == 30_000_138, "native sample rates retain exact multi-window tail")
            try expect(planned.allSatisfy { $0.coreEnd - $0.coreStart <= 300 && $0.inputDuration <= 304 }, "native sample-rate window bounds")
        }
        rejects { _ = try AudioWindowPlanner.slices([], start: .nan, end: 1) }
        rejects { _ = try AudioWindowPlanner.slices([], start: 2, end: 1) }
        rejects { _ = try AudioSourceRange(range: RecordingSourceRange(chunkID: UUID(), url: root, startFrame: 5, endFrame: 5, sampleRate: 16000), contentHash: String(repeating: "b", count: 64)) }
        rejects { _ = try AudioSourceRange(range: RecordingSourceRange(chunkID: UUID(), url: root, startFrame: -1, endFrame: 5, sampleRate: 16000), contentHash: String(repeating: "b", count: 64)) }
        let first = try range(0, 302, chunkID: chunk)
        let receiving = try source([first], complete: false)
        let initial = try AudioWindowPlanner.plan(source: receiving, configurationKey: "v1")
        try expect(initial.count == 1 && initial[0].coreEnd == 300, "receiving holds unstable tail")
        let appended = try source([first, range(302, 302)])
        let windows = try AudioWindowPlanner.plan(source: appended, configurationKey: "v1")
        try expect(windows.count == 3 && windows[0].id == initial[0].id, "append reuses committed input")
        try expect(windows.allSatisfy { $0.coreEnd - $0.coreStart <= 300 && $0.inputDuration <= 304 }, "bounded input")
        try expect(windows[1].ranges.count == 2, "file boundary does not break core")
        let long = try AudioWindowPlanner.plan(source: source([range(0, 23400)]), configurationKey: "v1")
        try expect(long.count == 78 && long.last?.coreEnd == 23400, "6.5 hour plan")
        let gaps = try AudioWindowPlanner.plan(source: source([range(0, 100), range(110, 100, gap: "captureGap")]), configurationKey: "v1")
        try expect(gaps.count == 2 && gaps[0].inputEnd == 100 && gaps[1].inputStart == 110, "gap clips context")
        let repeated = [AudioTranscriptSpan(start: 299, end: 301, text: "again"), AudioTranscriptSpan(start: 310, end: 311, text: "again")]
        try expect(try AudioWindowPlanner.ownedSpans(repeated, window: windows[0]).isEmpty, "half open midpoint")
        try expect(try AudioWindowPlanner.ownedSpans(repeated, window: windows[1]).count == 2, "equal words survive by time")
        let transcript = [AudioTranscriptSpan(start: 1, end: 2, text: "first"), AudioTranscriptSpan(start: 3, end: 4, text: "second")]
        try expect(AudioTranscriptPresentation.fullText(transcript) == "firstsecond", "full transcript preserves every span in time order without splitting one-character ASR rows into lines")
        rejects { _ = try source([first, first]) }
        rejects { _ = try range(.infinity, 1) }
        rejects { _ = try AudioSourceRange(range: RecordingSourceRange(chunkID: UUID(), url: root, startFrame: 2, endFrame: 1, sampleRate: 16000), contentHash: "hash") }
        let dbURL = root.appendingPathComponent("processing.sqlite3")
        let db = try DaybookDatabase(url: dbURL)
        try db.execute("INSERT INTO recording_sessions(id,created_at) VALUES (?,0)", [.text(id.id.uuidString)])
        var repo = AudioProcessingRepository(database: db)
        try repo.register(source: receiving, configurationKey: "v1", windows: initial)
        let job = try repo.claimNext()!
        let result = AudioWindowResult(spans: [AudioTranscriptSpan(start: 1, end: 2, text: "synthetic")], activities: [], asr: .success, vad: .missingResource, speaker: .notRequested, asrCoverage: [AudioTimeRange(start: 0, end: 300)], vadCoverage: [])
        // A trigger simulates disk/constraint failure AFTER inserting spans, before job completion.
        try db.execute("CREATE TRIGGER interrupt_audio_commit BEFORE UPDATE OF state ON audio_processing_jobs WHEN NEW.state='completed' BEGIN SELECT RAISE(ABORT,'synthetic interruption'); END")
        rejects { try repo.commit(job: job, result: result) }
        try expect(try repo.spans(sourceID: id).isEmpty, "rollback removes inserted spans")
        try expect(try repo.progress(sourceID: id).states[.running] == 1, "rollback keeps running lease")
        try db.execute("DROP TRIGGER interrupt_audio_commit")
        try repo.commit(job: job, result: result)
        try repo.commit(job: job, result: result)
        try expect(try repo.spans(sourceID: id).count == 1, "completion replay idempotent")
        try repo.register(source: appended, configurationKey: "v1", windows: windows)
        let speakerBackfill = try repo.claimNext()!
        try expect(speakerBackfill.window.id == job.window.id, "source completion must backfill the previously skipped speaker stage first")
        try expect(try repo.stages(for:speakerBackfill) == [.speaker], "completion backfill must preserve successful ASR and skip short-recording VAD")
        try repo.commit(job:speakerBackfill,delta:.init(result:.init(spans:[],activities:[],asr:.notRequested,vad:.notRequested,speaker:.success,asrCoverage:[],vadCoverage:[]),speakerSpanUpdates:[.init(start:1,end:2,text:"synthetic")]))
        try expect(try repo.progress(sourceID: id).states[.completed] == 1, "append retains unchanged completed job")
        let lost = try repo.claimNext()!
        repo = AudioProcessingRepository(database: try DaybookDatabase(url: dbURL))
        try repo.recoverInterrupted()
        try expect(try repo.spans(sourceID: id).count == 1, "committed result survives reopen")
        rejects { try repo.commit(job: lost, result: result) }
        let recovered = try repo.claimNext()!
        try expect(recovered.window.id == lost.window.id && recovered.lease != lost.lease, "running recovers with fresh lease")
        try repo.fail(job: recovered, state: .missingResource, message: "private transcript must not persist")
        try expect(try repo.progress(sourceID: id).states[.missingResource] == 1, "resource state distinct")
        try expect(try db.query("SELECT message FROM audio_processing_jobs WHERE id=?", [.text(recovered.window.id)])[0]["message"]?.string == "missingResource", "error text redacted")
        let emptyJob = try repo.claimNext()!
        try repo.commit(job: emptyJob, result: AudioWindowResult(spans: [], activities: [], asr: .success, vad: .missingResource, speaker: .notRequested, asrCoverage: [AudioTimeRange(start: 600, end: 604)], vadCoverage: []))
        try expect(try repo.results(sourceID: id).last?.asr == .success, "empty ASR successful, VAD independent")
        try expect(try repo.results(sourceID: id).last?.vad == .missingResource, "empty ASR is not no speech")
        let partial = try repo.completedAnalyses(sourceID: id)
        try expect(partial.count == 2 && partial[0].window.id == initial[0].id && partial[0].result.speaker == .success && partial[0].result.vad == .notRequested, "speaker backfill retains window provenance while skipping short-recording VAD")
        try expect(try repo.spans(sourceID: id).count == 1, "missing VAD retains successful ASR")
        try repo.retry(sourceID: id)
        let failing = try repo.claimNext()!
        try repo.fail(job: failing, state: .failed, message: "synthetic")
        try expect(try repo.progress(sourceID: id).states[.failed] == 1, "failure distinct from resource/cancel")
        try repo.retry(sourceID: id)
        let staleConfig = try repo.claimNext()!
        let v2 = try AudioWindowPlanner.plan(source: appended, configurationKey: "v2")
        try repo.register(source: appended, configurationKey: "v2", windows: v2)
        rejects { try repo.commit(job: staleConfig, result: result) }
        try expect(try repo.spans(sourceID: id).isEmpty, "old config results separate")
        try repo.cancel(sourceID: id)
        repo = AudioProcessingRepository(database: try DaybookDatabase(url: dbURL))
        try repo.recoverInterrupted()
        try expect(try repo.claimNext() == nil, "cancel persists")
        try repo.register(source: appended, configurationKey: "v2", windows: v2)
        try expect(try repo.claimNext() == nil, "rediscovery does not reset cancellation")
        try repo.retry(sourceID: id)
        let doomed = try repo.claimNext()!
        try db.execute("DELETE FROM recording_sessions WHERE id=?", [.text(id.id.uuidString)])
        rejects { try repo.commit(job: doomed, result: result) }
        try db.execute("INSERT INTO recording_sessions(id,created_at) VALUES (?,0)", [.text(id.id.uuidString)])
        rejects { try repo.register(source: appended, configurationKey: "v2", windows: v2) }
        try expect(try repo.currentSource(id) == nil, "parent deletion removes derived source")
        // Invalid model output must fail without a precondition trap or partial rows.
        let legacyID = AudioSourceID(kind: .legacyNote, id: UUID())
        try db.execute("INSERT INTO voice_notes(id,captured_at,kind,title,transcript,summary,duration,audio_filename,payload) VALUES (?,0,'long','','','',1,?,?)", [.text(legacyID.id.uuidString), .text("synthetic.wav"), .blob(Data())])
        let legacy = try AudioSourceSnapshot(id: legacyID, capturedAt: Date(), title: "Synthetic", ranges: [range(0, 10)], complete: true)
        let legacyWindows = try AudioWindowPlanner.plan(source: legacy, configurationKey: "v1")
        try repo.register(source: legacy, configurationKey: "v1", windows: legacyWindows)
        let invalidJob = try repo.claimNext()!
        rejects { try repo.commit(job: invalidJob, result: AudioWindowResult(spans: [AudioTranscriptSpan(start: .nan, end: 2, text: "synthetic")], activities: [], asr: .success, vad: .notRequested, speaker: .notRequested, asrCoverage: [], vadCoverage: [])) }
        try expect(try repo.spans(sourceID: legacyID).isEmpty, "invalid result atomic rejection")
        try repo.delete(sourceID: legacyID)
        rejects { try repo.commit(job: invalidJob, result: result) }
        rejects { try repo.register(source: legacy, configurationKey: "v1", windows: legacyWindows) }
        // A legacy parent removed before any discovery still leaves a durable guard.
        let removedID = AudioSourceID(kind: .legacyNote, id: UUID())
        try db.execute("INSERT INTO voice_notes(id,captured_at,kind,title,transcript,summary,duration,audio_filename,payload) VALUES (?,0,'long','','','',1,?,?)", [.text(removedID.id.uuidString), .text("removed.wav"), .blob(Data())])
        try db.execute("DELETE FROM voice_notes WHERE id=?", [.text(removedID.id.uuidString)])
        try expect(try db.query("SELECT source_key FROM audio_source_tombstones WHERE source_key=?", [.text(removedID.key)]).count == 1, "legacy deletion before discovery tombstoned")
        // Different wire IDs must not disguise repeated raw bytes in one source.
        let disguised = try AudioSourceRange(range: RecordingSourceRange(chunkID: UUID(), url: first.url, startFrame: 0, endFrame: 16000, sampleRate: 16000, sessionStartOffset: 302), contentHash: first.contentHash)
        rejects { _ = try source([first, disguised]) }
        print("AudioProcessingSmoke passed: bounded/gapped/append plans, timestamp ownership, SQLite atomic rollback/reopen, leases, versions, outcomes, cancellation and tombstones")
    }

    static func shortRecordingCrossingThresholdRequestsVAD() throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:root) }
        let db=try DaybookDatabase(inMemory:true),id=AudioSourceID(kind:.session,id:UUID())
        try db.execute("INSERT INTO recording_sessions(id,created_at) VALUES (?,0)",[.text(id.id.uuidString)])
        let chunkID=UUID(uuidString:"11111111-1111-4111-8111-111111111111")!
        func makeSource(_ duration:Double) throws -> AudioSourceSnapshot {
            let range=try AudioSourceRange(range:.init(chunkID:chunkID,url:root.appendingPathComponent("growing.wav"),startFrame:0,endFrame:Int64(duration*16_000),sampleRate:16_000),contentHash:String(repeating:"a",count:64))
            return try AudioSourceSnapshot(id:id,capturedAt:Date(timeIntervalSinceReferenceDate:0),title:"growing",ranges:[range],complete:true)
        }
        let repository=AudioProcessingRepository(database:db),short=try makeSource(600),key="grow"
        try repository.register(source:short,configurationKey:key,windows:AudioWindowPlanner.plan(source:short,configurationKey:key))
        let job=try repository.claimNext()!
        try expect(try repository.stages(for:job) == [.asr,.speaker],"short source stage selection unexpectedly requested VAD")
        try repository.commit(job:job,result:.init(spans:[.init(start:1,end:2,text:"short")],activities:[],asr:.success,vad:.notRequested,speaker:.success,asrCoverage:[.init(start:0,end:300)],vadCoverage:[]))
        let long=try makeSource(1_801)
        try repository.register(source:long,configurationKey:key,windows:AudioWindowPlanner.plan(source:long,configurationKey:key))
        let upgraded=try repository.claimNext()!
        try expect(try repository.stages(for:upgraded) == [.vad],"recording crossing thirty minutes did not schedule VAD for retained ASR")
    }
}
