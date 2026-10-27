import Foundation

@main struct AudioProcessingCoordinatorSmoke {
    static func require(_ value: Bool, _ message: String) throws {
        guard value else { throw Failure(message: message) }
    }
    struct Failure: Error { let message: String }
    static func main() async throws {
        try require(AudioLegacyRouting.requiresDurableProcessing(kind:.long,duration:0),"zero-duration legacy long input escaped durable routing")
        try require(AudioLegacyRouting.requiresDurableProcessing(kind:.thought,duration:0),"unknown duration was assumed short")
        try require(!AudioLegacyRouting.requiresDurableProcessing(kind:.thought,duration:0,measuredDuration:2),"measured short thought lost legacy behavior")
        try require(AudioLegacyRouting.requiresDurableProcessing(kind:.thought,duration:0,measuredDuration:601),"long unknown thought escaped durable routing")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        // Collect both review regressions so a failure in one cannot hide the other.
        var regressions: [String] = []
        do { try await adaptiveCommit(root:root) } catch { regressions.append("adaptive actual commit: \(error)") }
        do { try await interruptedRetries(root:root) } catch { regressions.append("interrupted partial retry: \(error)") }
        if !regressions.isEmpty { throw Failure(message:regressions.joined(separator:"; ")) }
        let db = try DaybookDatabase(url: root.appendingPathComponent("test.sqlite"))
        let id = AudioSourceID(kind: .session, id: UUID())
        try db.execute("INSERT INTO recording_sessions(id,created_at) VALUES (?,0)", [.text(id.id.uuidString)])
        let range = try AudioSourceRange(range: .init(chunkID: UUID(), url: root.appendingPathComponent("fixture.wav"), startFrame: 0, endFrame: 9_600_000, sampleRate: 16000), contentHash: String(repeating:"a",count:64))
        let source = try AudioSourceSnapshot(id:id,capturedAt:Date(),title:"fixture",ranges:[range],complete:true)
        let repo = AudioProcessingRepository(database:db)
        let windows = try AudioWindowPlanner.plan(source:source,configurationKey:"test")
        try repo.register(source:source,configurationKey:"test",windows:windows)
        let beforeClaim = try repo.progress(sourceID:id).revision
        let first = try repo.claimNext()!
        try require(try repo.stages(for:first) == [.asr,.speaker],"short recording initial claim unexpectedly requested VAD")
        try require(try repo.progress(sourceID:id).revision > beforeClaim,"claim did not advance observable source revision")
        let partial = AudioWindowResult(spans:[.init(start:1,end:2,text:"synthetic")],activities:[],asr:.success,vad:.notRequested,speaker:.missingResource,asrCoverage:[.init(start:0,end:300)],vadCoverage:[])
        try repo.commit(job:first,result:partial)
        // A staged retry keeps the last committed snapshot visible while in flight.
        try db.execute("UPDATE audio_processing_jobs SET state='pending',lease=NULL WHERE id=?", [.text(first.window.id)])
        try require(try repo.spans(sourceID:id).count == 1,"retained ASR disappeared during pending partial retry")
        try repo.retryIncompleteStages(sourceID:id)
        var retry = try repo.claimNext()!
        try require(try repo.spans(sourceID:id).count == 1,"retained ASR disappeared during running retry")
        let reader = AudioProcessingRepository(database:try DaybookDatabase(url:root.appendingPathComponent("test.sqlite")))
        try require(try reader.spans(sourceID:id).count == 1,"retained ASR disappeared on reopen during retry")
        try repo.fail(job:retry,state:.failed)
        try require(try reader.spans(sourceID:id).count == 1,"failed replacement erased retained ASR")
        try repo.retryIncompleteStages(sourceID:id)
        retry = try repo.claimNext()!
        try repo.cancel(sourceID:id)
        try require(try reader.spans(sourceID:id).count == 1,"cancelled replacement erased retained ASR")
        try repo.retryIncompleteStages(sourceID:id)
        retry = try repo.claimNext()!
        try require(try repo.stages(for:retry) == [.speaker],"partial retry selected successful or disabled stages")
        try repo.commit(job:retry,delta:.init(result:.init(spans:[],activities:[],asr:.notRequested,vad:.notRequested,speaker:.success,asrCoverage:[],vadCoverage:[]),speakerSpanUpdates:[]))
        try require(try repo.spans(sourceID:id).map(\.text) == ["synthetic"],"speaker retry erased retained text")
        try require(try repo.results(sourceID:id).first?.asr == .success,"VAD retry erased ASR outcome")
        // A suspended native boundary lets independent wakes/cancel/config changes race real storage.
        let state = InferenceState()
        let worker = AudioProcessingCoordinator(open:{ repo },configuration:.init(),discover:{ _ in [source] },infer:{ window,_,stages,_,_,budget in
            await state.enter(window:window,stages:stages,budget:budget)
            do { try await Task.sleep(nanoseconds:2_000_000) }
            catch { await state.leave(); throw error }
            await state.leave()
            return .init(result:.init(spans:stages.contains(.asr) ? [.init(start:window.coreStart+1,end:window.coreStart+2,text:"generated")] : [],activities:[],asr:stages.contains(.asr) ? .success : .notRequested,vad:.notRequested,speaker:stages.contains(.speaker) ? .missingResource : .notRequested,asrCoverage:stages.contains(.asr) ? [.init(start:window.coreStart,end:window.coreEnd)] : [],vadCoverage:[]),speakerSpanUpdates:[])
        })
        await withTaskGroup(of:Void.self) { group in
            for _ in 0..<12 { group.addTask { await worker.refresh() } }
        }
        await worker.waitUntilIdle()
        try require(await state.maximum == 1,"simultaneous wakes started duplicate inference")
        let calls = await state.calls
        await worker.refresh(); await worker.waitUntilIdle()
        try require(await state.calls == calls,"ordinary wake retried completed missing stages")
        await worker.cancel(id)
        await worker.refresh(); await worker.waitUntilIdle()
        try require(await state.calls == calls,"ordinary wake reset cancellation")
        await worker.memoryPressure()
        await worker.resume(.capture)
        await worker.refresh(); await worker.waitUntilIdle()
        try require(await state.calls == calls,"capture end bypassed memory pressure pause")
        await worker.resume(.memoryPressure)
        await worker.retry(id); await worker.waitUntilIdle()
        try require(await state.budgets.last == 150,"memory pressure failed to reduce native budget")
        let partialCalls = await state.calls
        await worker.resourcesAvailable(); await worker.waitUntilIdle()
        let missingSpeakerWindows=max(0,windows.count-1)
        try require(await state.calls == partialCalls + missingSpeakerWindows,"resource event failed to retry exactly the missing speaker stages")
        try require(await state.requestedStages.suffix(missingSpeakerWindows).allSatisfy { $0 == [.speaker] },"resource retry repeated successful ASR")
        try require(try repo.spans(sourceID:id).count == windows.count,"resource retry erased successful source text")
        await worker.refresh(); await worker.waitUntilIdle()
        try require(await state.calls == partialCalls + missingSpeakerWindows,"missing speaker stage entered busy loop")
        let inner = try AudioAdaptiveInference.windows(windows[0],maximumCoreDuration:150)
        try require(inner.count == 2 && inner[0].coreEnd == 150 && inner[1].coreStart == 150,"adaptive cores changed ownership")
        try require(inner.allSatisfy { $0.inputDuration <= 154 },"adaptive native input not bounded")
        try require(inner[0].ranges.first?.startFrame == 0 && inner[1].ranges.last?.endFrame == 4_832_000,"adaptive ranges lost exact context endpoints")
        let boundary = AudioTranscriptSpan(start:149,end:151,text:"crossing")
        let adaptive = try await AudioAdaptiveInference.process(window:windows[0],maximumCoreDuration:150,priorSpans:[boundary]) { part,prior in
            let selected = prior.filter { let midpoint = $0.start + ($0.end-$0.start)/2; return midpoint >= part.coreStart && midpoint < part.coreEnd }
            return .init(result:.init(spans:[],activities:[],asr:.notRequested,vad:.notRequested,speaker:.success,asrCoverage:[],vadCoverage:[],speakerFeatures:[.init(localSpeakerID:"0",modelVersion:"fixture",vector:part.coreStart == 0 ? [1,0] : [0,1])]),speakerSpanUpdates:selected.map { var span = $0; span.speakerID = "0"; return span })
        }
        try require(adaptive.speakerSpanUpdates.count == 1 && adaptive.speakerSpanUpdates[0].start == 149 && adaptive.speakerSpanUpdates[0].end == 151,"adaptive speaker-only retry changed retained row")
        try require(adaptive.speakerSpanUpdates[0].speakerID == nil,"different inner speaker reused same local number")
        let observed = InferenceState()
        let failedInner = try await AudioAdaptiveInference.process(window:windows[0],maximumCoreDuration:150,priorSpans:[]) { part,_ in
            await observed.enter(window:part,stages:.asr,budget:part.inputDuration); await observed.leave()
            if part.coreStart == 0 { return full(part) }
            return .init(result:.init(spans:[],activities:[],asr:.missingResource,vad:.missingResource,speaker:.notRequested,asrCoverage:[],vadCoverage:[]),speakerSpanUpdates:[])
        }
        try require(await observed.budgets.max() == 154,"adaptive execution did not respect observed input cap")
        try require(failedInner.result.asr == .missingResource && failedInner.result.asrCoverage.isEmpty && failedInner.result.spans.isEmpty,"failed inner stage fabricated outer success/coverage")
        print("Adaptive execution observed maximum injected native input: 154 seconds")
        try retainedVADConflict(root:root)
        try speakerPersistence(root:root)
        try await lifecycle(root:root)
        var unlocked = false
        let unavailable = AudioProcessingCoordinator(open:{ if !unlocked { throw Failure(message:"synthetic lock") }; return repo },configuration:.init(),discover:{ _ in [] },infer:{ window,_,_,_,_,_ in full(window) })
        await unavailable.refresh(); await unavailable.waitUntilIdle()
        try require(await unavailable.storageUnavailable,"worker did not publish unavailable storage")
        unlocked = true
        await unavailable.refresh(); await unavailable.waitUntilIdle()
        try require(!(await unavailable.storageUnavailable),"empty successful unlock left stale unavailable storage")
        let receivingID = AudioSourceID(kind:.session,id:UUID())
        try db.execute("INSERT INTO recording_sessions(id,created_at) VALUES (?,0)",[.text(receivingID.id.uuidString)])
        let receivingRange = try AudioSourceRange(range:.init(chunkID:UUID(),url:root.appendingPathComponent("receiving.wav"),startFrame:0,endFrame:9_600_000,sampleRate:16000),contentHash:String(repeating:"b",count:64))
        let receiving = try AudioSourceSnapshot(id:receivingID,capturedAt:source.capturedAt,title:"receiving",ranges:[receivingRange],complete:false)
        let receivingState = InferenceState()
        let receivingWorker = AudioProcessingCoordinator(open:{repo},configuration:.init(),discover:{ _ in [receiving] },infer:{ window,_,stages,duration,_,budget in
            await receivingState.enter(window:window,stages:stages,budget:budget,duration:duration); await receivingState.leave()
            return full(window)
        })
        await receivingWorker.refresh(); await receivingWorker.waitUntilIdle()
        try require(await receivingState.durations == [nil],"receiving source incorrectly advertised a known full duration to speaker inference")
        let finalized = try AudioSourceSnapshot(id:receivingID,capturedAt:source.capturedAt,title:"receiving",ranges:[receivingRange],complete:true)
        let receivingKey = try repo.progress(sourceID:receivingID).configurationKey!
        try repo.register(source:finalized,configurationKey:receivingKey,windows:AudioWindowPlanner.plan(source:finalized,configurationKey:receivingKey))
        let finalTail = try repo.claimNext()!
        try repo.commit(job:finalTail,delta:full(finalTail.window))
        try require(try repo.claimNext() == nil,"finalization reran an already committed skipped stage")
        try repo.retryIncompleteStages(sourceID:receivingID,resourceOnly:true)
        try require(try repo.claimNext() == nil,"resource-only retry requeued skipped speaker stage")
        try repo.retryIncompleteStages(sourceID:receivingID)
        let eligible = try repo.claimNext()
        try require(eligible != nil,"explicit retry did not requeue newly eligible speaker-only work")
        try require(try repo.stages(for:eligible!) == [.speaker],"eligible speaker retry repeated ASR or VAD")
        try repo.deferInterrupted(job:eligible!)
        let stageReader = AudioProcessingRepository(database:try DaybookDatabase(url:root.appendingPathComponent("test.sqlite")))
        let resumedStage = try stageReader.claimNext()!
        try require(try stageReader.stages(for:resumedStage) == [.speaker],"speaker-only selection lost across worker reopen")
        print("Coordinator and adaptive bounds: passed")
    }
    static func adaptiveCommit(root: URL) async throws {
        let url = root.appendingPathComponent("adaptive-commit.sqlite"), db = try DaybookDatabase(url:url)
        let id = AudioSourceID(kind:.session,id:UUID())
        try db.execute("INSERT INTO recording_sessions(id,created_at) VALUES (?,0)",[.text(id.id.uuidString)])
        let range = try AudioSourceRange(range:.init(chunkID:UUID(),url:root.appendingPathComponent("adaptive.wav"),startFrame:0,endFrame:4_800_000,sampleRate:16000),contentHash:String(repeating:"e",count:64))
        let source = try AudioSourceSnapshot(id:id,capturedAt:Date(),title:"fixture",ranges:[range],complete:true)
        let repo = AudioProcessingRepository(database:db)
        for gap in [false,true] {
            let key = gap ? "gap" : "adjacent"
            try repo.register(source:source,configurationKey:key,windows:AudioWindowPlanner.plan(source:source,configurationKey:key))
            let job = try repo.claimNext()!
            let delta = try await AudioAdaptiveInference.process(window:job.window,maximumCoreDuration:150,priorSpans:[]) { part,_ in
                let start = part.coreStart + (gap && part.coreStart > 0 ? 10 : 0)
                return .init(result:.init(spans:[],activities:[.init(start:part.coreStart,end:part.coreEnd,kind:.noSpeech)],asr:.success,vad:.success,speaker:.notRequested,asrCoverage:[.init(start:part.coreStart,end:part.coreEnd)],vadCoverage:[.init(start:start,end:part.coreEnd)]),speakerSpanUpdates:[])
            }
            try repo.commit(job:job,delta:delta)
            let reopened = AudioProcessingRepository(database:try DaybookDatabase(url:url))
            let activities = try reopened.activities(sourceID:id)
            try require(try reopened.results(sourceID:id).count == 1,"adaptive result not durable after reopen")
            if gap {
                try require(activities.contains { $0.kind == .uncertain && $0.start == 150 && $0.end == 160 },"true coverage gap became trustworthy silence")
            } else {
                try require(activities == [.init(start:0,end:300,kind:.noSpeech)],"adjacent coverage failed continuous silent activity")
            }
        }
        print("Adaptive actual SQLite commit/reopen: adjacent silence and uncertain real gap passed")
    }
    static func interruptedRetries(root: URL) async throws {
        for (index,outcome) in [AudioAnalysisOutcome.failed,.cancelled,.notRequested].enumerated() {
            let url = root.appendingPathComponent("interrupted-\(index).sqlite"), db = try DaybookDatabase(url:url)
            let id = AudioSourceID(kind:.session,id:UUID())
            try db.execute("INSERT INTO recording_sessions(id,created_at) VALUES (?,0)",[.text(id.id.uuidString)])
            let range = try AudioSourceRange(range:.init(chunkID:UUID(),url:root.appendingPathComponent("retry.wav"),startFrame:0,endFrame:4_800_000,sampleRate:16000),contentHash:String(repeating:"f",count:64))
            let source = try AudioSourceSnapshot(id:id,capturedAt:Date(),title:"fixture",ranges:[range],complete:true)
            let repo = AudioProcessingRepository(database:db), key = AudioProcessingCoordinator.configurationKey(.init())
            try repo.register(source:source,configurationKey:key,windows:AudioWindowPlanner.plan(source:source,configurationKey:key))
            let job = try repo.claimNext()!
            let speakerOnly = outcome == .notRequested
            try repo.commit(job:job,result:.init(spans:[.init(start:1,end:2,text:"retained")],activities:[],asr:.success,vad:speakerOnly ? .success : outcome,speaker:speakerOnly ? .notRequested : .success,asrCoverage:[.init(start:0,end:300)],vadCoverage:speakerOnly ? [.init(start:0,end:300)] : []))
            let blocked = SuspendedInference(), state = InferenceState()
            let worker = AudioProcessingCoordinator(open:{repo},configuration:.init(),discover:{ _ in [source] },infer:{ window,_,stages,_,_,budget in
                await state.enter(window:window,stages:stages,budget:budget)
                let first = await state.calls == 1
                if first { _ = await blocked.run(window) }
                await state.leave()
                return .init(result:.init(spans:[],activities:stages.contains(.vad) ? [.init(start:0,end:300,kind:.speech)] : [],asr:.notRequested,vad:stages.contains(.vad) ? .success : .notRequested,speaker:stages.contains(.speaker) ? .success : .notRequested,asrCoverage:[],vadCoverage:stages.contains(.vad) ? [.init(start:0,end:300)] : []),speakerSpanUpdates:stages.contains(.speaker) ? [.init(start:1,end:2,text:"retained")] : [])
            })
            await worker.retry(id); await blocked.entered(1)
            let reason: AudioProcessingPauseReason = index == 1 ? .protectedData : .capture
            await worker.suspend(reason); await blocked.release(); await worker.waitUntilIdle()
            await worker.resume(reason); await worker.waitUntilIdle()
            let calls = await state.calls
            await worker.shutdown()
            try require(calls == 2,"\(outcome) explicit retry stranded after \(reason): \(calls) calls")
            try require(await state.requestedStages.allSatisfy { $0 == (speakerOnly ? [.speaker] : [.vad]) },"resume repeated successful stages")
            let reopened = AudioProcessingRepository(database:try DaybookDatabase(url:url))
            let committed = try reopened.results(sourceID:id).first
            try require(committed?.vad == .success && (!speakerOnly || committed?.speaker == .success),"resumed stage result was not durably committed")
            try require(try reopened.spans(sourceID:id).map(\.text) == ["retained"],"resume lost successful transcript")
        }
        print("Coordinator capture/unlock: explicit failed/cancelled VAD and skipped speaker retries committed after resume")
    }
    static func retainedVADConflict(root: URL) throws {
        let db = try DaybookDatabase(url:root.appendingPathComponent("vad-conflict.sqlite")), id = AudioSourceID(kind:.session,id:UUID())
        try db.execute("INSERT INTO recording_sessions(id,created_at) VALUES (?,0)",[.text(id.id.uuidString)])
        let range = try AudioSourceRange(range:.init(chunkID:UUID(),url:root.appendingPathComponent("conflict.wav"),startFrame:0,endFrame:9_600_000,sampleRate:16000),contentHash:String(repeating:"d",count:64))
        let source = try AudioSourceSnapshot(id:id,capturedAt:Date(),title:"fixture",ranges:[range],complete:true)
        let repo = AudioProcessingRepository(database:db)
        try repo.register(source:source,configurationKey:"conflict",windows:AudioWindowPlanner.plan(source:source,configurationKey:"conflict"))
        let first = try repo.claimNext()!
        try repo.commit(job:first,result:.init(spans:[],activities:[.init(start:0,end:300,kind:.noSpeech)],asr:.missingResource,vad:.success,speaker:.success,asrCoverage:[],vadCoverage:[.init(start:0,end:300)]))
        let neighbor = try repo.claimNext()!
        try repo.commit(job:neighbor,result:.init(spans:[.init(start:299,end:303,text:"boundary")],activities:[.init(start:300,end:600,kind:.speech)],asr:.success,vad:.success,speaker:.success,asrCoverage:[.init(start:300,end:600)],vadCoverage:[.init(start:300,end:600)]))
        try repo.retryIncompleteStages(sourceID:id)
        let retry = try repo.claimNext()!
        try require(try repo.stages(for:retry) == [.asr],"ASR retry did not retain successful VAD")
        try repo.commit(job:retry,delta:.init(result:.init(spans:[.init(start:1,end:2,text:"new words")],activities:[],asr:.success,vad:.notRequested,speaker:.notRequested,asrCoverage:[.init(start:0,end:300)],vadCoverage:[]),speakerSpanUpdates:[]))
        let activities = try repo.activities(sourceID:id)
        try require(activities.contains { $0.kind == .uncertain && $0.start <= 1 && $0.end >= 2 },"ASR-only retry retained trustworthy noSpeech over new text")
        try require(activities.contains { $0.kind == .uncertain && $0.start <= 299 && $0.end >= 300 },"stage merge ignored neighboring boundary text")
        try require(try repo.results(sourceID:id).first?.vadCoverage == [.init(start:0,end:300)],"text conflict erased successful VAD coverage")
        print("Stage merge: retained VAD reconciles new ASR and neighboring boundary words")
    }
    static func speakerPersistence(root: URL) throws {
        let url = root.appendingPathComponent("speakers.sqlite"), db = try DaybookDatabase(url:url)
        let id = AudioSourceID(kind:.session,id:UUID())
        try db.execute("INSERT INTO recording_sessions(id,created_at) VALUES (?,0)",[.text(id.id.uuidString)])
        let range = try AudioSourceRange(range:.init(chunkID:UUID(),url:root.appendingPathComponent("speaker.wav"),startFrame:0,endFrame:14_400_000,sampleRate:16000),contentHash:String(repeating:"c",count:64))
        let source = try AudioSourceSnapshot(id:id,capturedAt:Date(),title:"fixture",ranges:[range],complete:true)
        var repo = AudioProcessingRepository(database:db)
        try repo.register(source:source,configurationKey:"speaker-config",windows:AudioWindowPlanner.plan(source:source,configurationKey:"speaker-config"))
        for index in 0..<3 {
            let job = try repo.claimNext()!
            let span = AudioTranscriptSpan(start:job.window.coreStart+1,end:job.window.coreStart+2,text:"synthetic",speakerID:"0")
            let result = AudioWindowResult(spans:[span],activities:[],asr:.success,vad:.notRequested,speaker:.success,asrCoverage:[.init(start:job.window.coreStart,end:job.window.coreEnd)],vadCoverage:[],speakerFeatures:[.init(localSpeakerID:"0",modelVersion:"fixture",vector:index == 2 ? [0,1] : [1,0])])
            try repo.commit(job:job,delta:.init(result:result,speakerSpanUpdates:[]))
            repo = AudioProcessingRepository(database:try DaybookDatabase(url:url))
        }
        let rows = try repo.spans(sourceID:id)
        try require(rows[0].speakerID != nil && rows[0].speakerID == rows[1].speakerID,"compatible persisted features failed canonical mapping after reopen")
        try require(rows[2].speakerID == nil,"unmatched same local number reused prior canonical identity")
        let mappings = try db.query("SELECT local_id,canonical_id,feature FROM audio_speaker_mappings ORDER BY job_id")
        try require(mappings.count == 3 && mappings.allSatisfy { $0["local_id"]?.string == "0" },"speaker mapping lost per-window local provenance")
        print("Speaker persistence: compatible mapping, local provenance, reopen and unknown passed")
    }
    static func lifecycle(root: URL) async throws {
        let url = root.appendingPathComponent("lifecycle.sqlite")
        let db = try DaybookDatabase(url:url), id = AudioSourceID(kind:.session,id:UUID())
        try db.execute("INSERT INTO recording_sessions(id,created_at) VALUES (?,0)",[.text(id.id.uuidString)])
        let range = try AudioSourceRange(range:.init(chunkID:UUID(),url:root.appendingPathComponent("test.wav"),startFrame:0,endFrame:9_600_000,sampleRate:16000),contentHash:String(repeating:"b",count:64))
        let source = try AudioSourceSnapshot(id:id,capturedAt:Date(),title:"fixture",ranges:[range],complete:true)
        let repo = AudioProcessingRepository(database:db), blocked = SuspendedInference()
        let worker = AudioProcessingCoordinator(open:{repo},configuration:.init(),discover:{ _ in [source] },infer:{ window,_,_,_,_,_ in
            if window.coreStart == 0 { return full(window) }
            return await blocked.run(window)
        })
        await worker.refresh(); await blocked.entered(1)
        try require(try repo.spans(sourceID:id).map(\.text) == ["synthetic"],"first window not committed before next inference")
        await worker.shutdown()
        await blocked.release()
        await worker.waitUntilIdle()
        let reopened = AudioProcessingRepository(database:try DaybookDatabase(url:url)), recovered = InferenceState()
        let second = AudioProcessingCoordinator(open:{reopened},configuration:.init(),discover:{ _ in [source] },infer:{ window,_,stages,_,_,budget in
            await recovered.enter(window:window,stages:stages,budget:budget)
            await recovered.leave()
            return full(window)
        })
        await second.refresh(); await second.waitUntilIdle()
        try require(await recovered.starts == [300],"restart repeated committed first window or lost second")
        try require(try reopened.spans(sourceID:id).count == 2,"restart failed durable result recovery")
        await second.shutdown()

        // Metadata updates bump presentation revision while preserving all exact jobs.
        let renamed = try AudioSourceSnapshot(id:id,capturedAt:source.capturedAt,title:"renamed",ranges:[range],complete:true)
        let key = try reopened.progress(sourceID:id).configurationKey!
        let before = try reopened.progress(sourceID:id).revision
        try reopened.register(source:renamed,configurationKey:key,windows:AudioWindowPlanner.plan(source:renamed,configurationKey:key))
        try require(try reopened.progress(sourceID:id).revision > before,"metadata change did not advance source revision")
        try require(try reopened.claimNext() == nil,"metadata-only change reran inference")

        // A delayed old-configuration result ignores cancellation but must still be rejected.
        let old = SuspendedInference()
        let stale = AudioProcessingCoordinator(open:{reopened},configuration:.init(),discover:{ _ in [source] },infer:{ window,_,_,_,_,_ in await old.run(window) })
        await stale.reprocess(id); await old.entered(1)
        var newConfig = TranscriptionConfiguration(); newConfig.appleLocale = "en-US"
        await stale.refresh(configuration:newConfig)
        await old.release(); await old.entered(2)
        try require(try reopened.spans(sourceID:id).isEmpty,"old configuration published into new version")
        // Deleting the exact parent during inference cascades and tombstones before late commit.
        try db.execute("DELETE FROM recording_sessions WHERE id=?",[.text(id.id.uuidString)])
        await old.release(); await stale.waitUntilIdle()
        try require(try reopened.currentSource(id) == nil,"late inference recreated deleted source")
        try require(try reopened.spans(sourceID:id).isEmpty,"late inference recreated deleted text")
        await stale.refresh(); await stale.waitUntilIdle()
        try require(try reopened.currentSource(id) == nil,"discovery recreated a deleted parent")
        print("Lifecycle: committed-window recovery, metadata revision, late config/delete rejection passed")
    }
    static func full(_ window: AudioProcessingWindow) -> AudioInferenceDelta {
        .init(result:.init(spans:[.init(start:window.coreStart+1,end:window.coreStart+2,text:"synthetic")],activities:[.init(start:window.coreStart,end:window.coreEnd,kind:.speech)],asr:.success,vad:.success,speaker:.notRequested,asrCoverage:[.init(start:window.coreStart,end:window.coreEnd)],vadCoverage:[.init(start:window.coreStart,end:window.coreEnd)]),speakerSpanUpdates:[])
    }

}

actor InferenceState {
    var starts: [Double] = []
    var durations: [Double?] = []
    var requestedStages: [AudioInferenceStages] = []
    var maximum = 0; var calls = 0; var budgets: [Double] = []; var active = 0
    func leave() { active -= 1 }
    func enter(window:AudioProcessingWindow,stages:AudioInferenceStages,budget:Double,duration:Double? = nil) { durations.append(duration); requestedStages.append(stages); starts.append(window.coreStart); calls += 1; active += 1; maximum = max(maximum,active); budgets.append(budget) }
}

actor SuspendedInference {
    private var count = 0
    private var pending: [(AudioProcessingWindow,CheckedContinuation<AudioInferenceDelta,Never>)] = []
    private var waiters: [(Int,CheckedContinuation<Void,Never>)] = []
    func run(_ window: AudioProcessingWindow) async -> AudioInferenceDelta {
        count += 1
        return await withCheckedContinuation { continuation in
            pending.append((window,continuation))
            let ready = waiters.filter { $0.0 <= count }; waiters.removeAll { $0.0 <= count }
            ready.forEach { $0.1.resume() }
        }
    }
    func entered(_ target: Int) async {
        if count >= target { return }
        await withCheckedContinuation { waiters.append((target,$0)) }
    }
    func release() {
        let values = pending; pending = []
        for (window,continuation) in values { continuation.resume(returning:AudioProcessingCoordinatorSmoke.full(window)) }
    }
}
