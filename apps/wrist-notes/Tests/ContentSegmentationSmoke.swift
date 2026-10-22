import Foundation

@main struct ContentSegmentationSmoke {
    static func check(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
        guard try value() else { fatalError(message) }
    }
    static func rejects(_ body: () throws -> Void) { do { try body(); fatalError("invalid mutation accepted") } catch {} }
    static func range(_ start: Double, _ end: Double, gap: String? = nil) throws -> AudioSourceRange {
        let id = UUID()
        return try .init(range:.init(chunkID:id,url:URL(fileURLWithPath:"/synthetic/\(id).wav"),startFrame:0,endFrame:Int64((end-start)*16000),sampleRate:16000,sessionStartOffset:start,discontinuityBefore:gap),contentHash:String(repeating:"a",count:64))
    }
    static func source(_ ranges: [AudioSourceRange], complete: Bool = true, id: AudioSourceID = .init(kind:.session,id:UUID())) throws -> AudioSourceSnapshot {
        try .init(id:id,capturedAt:Date(timeIntervalSince1970:86390),title:"Synthetic",ranges:ranges,complete:complete)
    }
    static func main() throws {
        for (duration,count) in [(599.0,1),(600.0,2),(601.0,2)] {
            let s = try source([range(0,300),range(300,1000)])
            let output = try ContentSegmentation.build(source:s,reliableNoSpeech:[.init(start:20,end:20+duration)],successfulCoverage:[.init(start:0,end:1000)])
            try check(output.segments.count == count,"\(Int(duration)) second threshold")
            if count == 2 {
                try check(output.segments[0].ranges.last?.end == 22,"only two seconds tail padding")
                try check(output.segments[1].ranges.first?.sessionStartOffset == 18+duration,"only two seconds leading padding")
            }
        }
        let touching = try source([range(0,300),range(300,600)])
        try check(ContentSegmentation.build(source:touching,reliableNoSpeech:[],successfulCoverage:[.init(start:0,end:600)]).segments.count == 1,"physical file and midnight do not split content")
        let interrupted = try source([range(0,300),range(300,600,gap:"interrupted")])
        try check(ContentSegmentation.build(source:interrupted,reliableNoSpeech:[],successfulCoverage:[.init(start:0,end:600)]).segments.count == 2,"touching captured discontinuity splits")
        let missing = try source([range(0,100),range(200,300)])
        try check(ContentSegmentation.build(source:missing,reliableNoSpeech:[],successfulCoverage:[.init(start:0,end:300)]).segments.count == 2,"missing audio is a hard gap")
        let pending = try ContentSegmentation.build(source:touching,reliableNoSpeech:[],successfulCoverage:[.init(start:0,end:300)])
        try check(pending.state == .pending && !pending.segments[0].isFinal,"failed/unanalysed coverage is pending")
        let empty = try ContentSegmentation.build(source:touching,reliableNoSpeech:[.init(start:0,end:600)],successfulCoverage:[.init(start:0,end:600)])
        try check(empty.state == .processedNoSpeech && empty.segments.isEmpty,"processed ambient only recording remains explicitly accessible")
        try check(ContentSegmentation.build(source:source([]),reliableNoSpeech:[],successfulCoverage:[]).state == .pending,"empty input cannot prove no-speech")
        let short = try source([range(0,60)])
        try check(ContentSegmentation.build(source:short,reliableNoSpeech:[.init(start:0,end:60)],successfulCoverage:[.init(start:0,end:60)]).state == .processedNoSpeech,"short ambient recording has explicit no-speech state")
        try persistentFixtures()
        try coverageFixtures()
        try undoCausalityFixtures()
        print("Content intervals: 599/600/601, file/midnight continuity, gaps, padding, partial coverage passed")
    }
    static func persistentFixtures() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let db = try DaybookDatabase(url:root.appendingPathComponent("segments.sqlite3"))
        let processing = AudioProcessingRepository(database:db)
        let repository = ContentSegmentRepository(database:db)
        let s = try source([range(0,300),range(300,900)])
        try db.execute("INSERT INTO recording_sessions(id,created_at) VALUES (?,0)",[.text(s.id.id.uuidString)])
        func register(_ source: AudioSourceSnapshot, key: String = "v1") throws {
            try processing.register(source:source,configurationKey:key,windows:AudioWindowPlanner.plan(source:source,configurationKey:key))
        }
        try register(s)
        while let job = try processing.claimNext() {
            let a = job.window.coreStart, b = job.window.coreEnd
            let spans: [AudioTranscriptSpan] = a == 0 ? [.init(start:10,end:20,text:"again"),.init(start:299,end:300.5,text:"again")] : (a == 600 ? [.init(start:880,end:890,text:"again")] : [])
            // Neighbor's noSpeech must yield to a crossing word owned by the first core.
            let acts: [AudioActivityInterval] = a == 0 ? [.init(start:0,end:20,kind:.speech),.init(start:20,end:300,kind:.noSpeech)] : (a == 300 ? [.init(start:300,end:600,kind:.noSpeech)] : [.init(start:600,end:880,kind:.noSpeech),.init(start:880,end:900,kind:.speech)])
            try processing.commit(job:job,result:.init(spans:spans,activities:acts,asr:.success,vad:.success,speaker:.notRequested,asrCoverage:[.init(start:a,end:b)],vadCoverage:[.init(start:a,end:b)]))
        }
        // Crash boundary: inference committed, derivation never ran. A fresh connection recovers it.
        let recovery = ContentSegmentRepository(database:try DaybookDatabase(url:db.url))
        try check(recovery.segments(sourceID:s.id).isEmpty,"fixture has committed inference with no derived snapshot")
        try recovery.reconcile(sourceID:s.id)
        var segments = try repository.segments(sourceID:s.id)
        try check(segments.count == 1,"crossing text conservatively protects noSpeech boundary")
        let original = segments[0]
        try check(repository.spans(segmentID:original.id).count == 3,"same text at distinct source times retained")
        try repository.reconcile(sourceID:s.id)
        try check(repository.segment(id:original.id)?.revision == original.revision,"no-op reconciliation retains identity/revision")
        let parts = try repository.split(id:original.id,at:450,expectedRevision:original.revision)
        try check(parts.count == 2 && parts.allSatisfy(\.isManual),"manual split durable boundaries")
        rejects { _ = try repository.split(id:original.id,at:10,expectedRevision:original.revision) }
        let merged = try repository.merge(ids:parts.map(\.id),expectedRevisions:parts.map(\.revision))
        try check(merged.ranges.count >= 2,"merge retains physical ranges")
        try repository.delete(id:merged.id,expectedRevision:merged.revision)
        rejects { try repository.applyEnrichment(id:merged.id,expectedRevision:merged.revision,sourceRevision:merged.sourceRevision,title:"late",summary:"late") }
        try repository.undo(sourceID:s.id)
        let restored = try repository.segment(id:merged.id)!
        try check(restored.revision > merged.revision,"undo advances restored revision")
        rejects { try repository.applyEnrichment(id:merged.id,expectedRevision:merged.revision,sourceRevision:merged.sourceRevision,title:"stale",summary:"stale") }
        try repository.applyEnrichment(id:restored.id,expectedRevision:restored.revision,sourceRevision:restored.sourceRevision,title:"Saved",summary:"Local summary")
        rejects { try repository.undo(sourceID:s.id) }
        let reopened = ContentSegmentRepository(database:try DaybookDatabase(url:db.url))
        try check(reopened.segment(id:merged.id)?.title == "Saved","persistence reopen")
        let current = try reopened.segment(id:merged.id)!
        try reopened.delete(id:current.id,expectedRevision:current.revision)
        let appended = try source(s.ranges + [range(900,1200)],complete:false,id:s.id)
        try register(appended)
        try reopened.reconcile(sourceID:s.id)
        segments = try reopened.segments(sourceID:s.id)
        try check(segments.allSatisfy { $0.ranges.allSatisfy { $0.sessionStartOffset >= 900 } },"append cannot recreate manually hidden source ranges")
        try register(appended,key:"v2")
        try reopened.reconcile(sourceID:s.id)
        try check(reopened.segments(sourceID:s.id).allSatisfy { $0.ranges.allSatisfy { $0.sessionStartOffset >= 900 } },"suppression survives configuration change")
        try processing.delete(sourceID:s.id)
        rejects { try reopened.applyEnrichment(id:current.id,expectedRevision:current.revision,sourceRevision:current.sourceRevision,title:"late",summary:"") }
        try check(reopened.segments(sourceID:s.id).isEmpty,"source deletion wins")
        try check(db.query("SELECT sequence FROM content_segment_edits WHERE source_key=?",[.text(s.id.key)]).isEmpty,"source deletion clears derived history payloads")
        try check(!db.query("SELECT id FROM content_segment_tombstones WHERE source_key=?",[.text(s.id.key)]).isEmpty,"source deletion retains rejection tombstones")
        print("Content persistence: split/merge/delete/undo, revisions, suppression, reopen passed")
    }

    static func coverageFixtures() throws {
        let db = try DaybookDatabase(inMemory:true)
        let p = AudioProcessingRepository(database:db), r = ContentSegmentRepository(database:db)
        func register(_ s: AudioSourceSnapshot, _ key: String = "v1") throws {
            try db.execute("INSERT OR IGNORE INTO recording_sessions(id,created_at) VALUES (?,0)",[.text(s.id.id.uuidString)])
            try p.register(source:s,configurationKey:key,windows:AudioWindowPlanner.plan(source:s,configurationKey:key))
        }
        let s = try source([range(0,300),range(300,600),range(600,900)])
        try register(s)
        // Real SQLite stages: failed middle is not silence even with successful VAD.
        while let job = try p.claimNext() {
            let a = job.window.coreStart, b = job.window.coreEnd
            let failed = a == 300
            try p.commit(job:job,result:.init(spans:[],activities:[.init(start:a,end:b,kind:.noSpeech)],asr:failed ? .failed : .success,vad:.success,speaker:.notRequested,asrCoverage:failed ? [] : [.init(start:a,end:b)],vadCoverage:[.init(start:a,end:b)]))
        }
        try r.reconcile(sourceID:s.id)
        try check(r.state(sourceID:s.id) == .pending && r.segments(sourceID:s.id).count == 1,"failed ASR with successful VAD preserves pending content")
        try p.retryIncompleteStages(sourceID:s.id)
        // retry may request speaker work on earlier windows; preserve existing stage snapshots.
        while let job = try p.claimNext() {
            let a = job.window.coreStart, b = job.window.coreEnd
            let spans: [AudioTranscriptSpan] = a == 300 ? [.init(start:599,end:600.5,text:"crossing")] : []
            try p.commit(job:job,delta:.init(result:.init(spans:spans,activities:[],asr:.success,vad:.notRequested,speaker:.notRequested,asrCoverage:[.init(start:a,end:b)],vadCoverage:[]),speakerSpanUpdates:[]))
        }
        try r.reconcile(sourceID:s.id)
        try check(r.segments(sourceID:s.id).count == 1 && r.state(sourceID:s.id) == .processed,"ASR-only retry crossing neighbor prevents 600 second silence")
        let old = try r.segments(sourceID:s.id)[0]
        let pieces = try r.split(id:old.id,at:450,expectedRevision:old.revision)
        try register(s,"v2")
        try r.reconcile(sourceID:s.id)
        try check(r.segments(sourceID:s.id).map(\.id) == pieces.map(\.id),"reprocess preserves frozen manual boundaries")
        try check(db.query("SELECT sequence FROM content_segment_edits WHERE kind='reprocess'").count == 1,"reprocess is auditable")
        try check(r.segments(sourceID:s.id).allSatisfy { !$0.isFinal },"manual boundaries remain pending until new configuration succeeds")

        let silent = try source([range(0,900)])
        try register(silent)
        while let job = try p.claimNext() {
            let a = job.window.coreStart, b = job.window.coreEnd
            // Fill only this source; any queued previous source keeps speech/no-text visible.
            let kind: AudioActivityKind = job.window.sourceID == silent.id ? .noSpeech : .speech
            try p.commit(job:job,result:.init(spans:[],activities:[.init(start:a,end:b,kind:kind)],asr:.success,vad:.success,speaker:.notRequested,asrCoverage:[.init(start:a,end:b)],vadCoverage:[.init(start:a,end:b)]))
        }
        try r.reconcile(sourceID:silent.id)
        try check(r.state(sourceID:silent.id) == .processedNoSpeech && p.currentSource(silent.id) != nil,"ambient recording remains accessible")
        try r.reconcile(sourceID:s.id)
        try check(r.segments(sourceID:s.id).allSatisfy { !$0.hasText },"ASR empty + VAD speech keeps no-text manual content")

        let gapped = try source([range(0,100),range(200,300)])
        try register(gapped)
        while let job = try p.claimNext() {
            let a = job.window.coreStart, b = job.window.coreEnd
            try p.commit(job:job,result:.init(spans:[.init(start:a+10,end:a+11,text:"kept")],activities:[.init(start:a,end:b,kind:.speech)],asr:.success,vad:.success,speaker:.notRequested,asrCoverage:[.init(start:a,end:b)],vadCoverage:[.init(start:a,end:b)]))
        }
        try r.reconcile(sourceID:gapped.id)
        let before = try r.segments(sourceID:gapped.id)
        let merged = try r.merge(ids:before.map(\.id),expectedRevisions:before.map(\.revision))
        // A stray contextual span in the enclosing gap must never be returned in segment detail.
        let jobID = try db.query("SELECT id FROM audio_processing_jobs WHERE source_key=? LIMIT 1",[.text(gapped.id.key)])[0].requiredString("id")
        try db.execute("INSERT INTO audio_transcript_spans(job_id,position,start,end,text) VALUES (?,999,150,151,'gap')",[.text(jobID)])
        try check(r.spans(segmentID:merged.id,limit:1,offset:0)[0].start == 10 && r.spans(segmentID:merged.id,limit:1,offset:1)[0].start == 210 && r.spans(segmentID:merged.id,limit:1,offset:2).isEmpty,"manual gap merge pages actual ranges")
        try check(merged.ranges[0].end == 100 && merged.ranges[1].sessionStartOffset == 200,"visible gap retained")
        rejects { _ = try r.merge(ids:[merged.id,pieces[0].id],expectedRevisions:[merged.revision,pieces[0].revision]) }

        let automatic = try source([range(0,300)],complete:false)
        try register(automatic)
        try r.reconcile(sourceID:automatic.id)
        let automaticBefore = try r.segments(sourceID:automatic.id)[0]
        let automaticAppend = try source(automatic.ranges+[range(300,600)],complete:false,id:automatic.id)
        try register(automaticAppend)
        try r.reconcile(sourceID:automatic.id)
        let automaticAfter = try r.segments(sourceID:automatic.id)[0]
        try check(automaticAfter.id == automaticBefore.id && automaticAfter.revision > automaticBefore.revision && automaticAfter.ranges.last?.end == 600,"append updates draft tail with stable identity")
        try p.cancel(sourceID:automatic.id)
        try r.reconcile(sourceID:automatic.id)
        try check(r.traversal.reusedSnapshot && r.segments(sourceID:automatic.id)[0].revision == automaticAfter.revision,"progress-only revision does not churn content")
        rejects { try r.applyEnrichment(id:automaticAfter.id,expectedRevision:automaticAfter.revision,sourceRevision:automaticAfter.sourceRevision,title:"late",summary:"") }

        let growing = try source([range(0,300)],complete:false)
        try register(growing)
        try r.reconcile(sourceID:growing.id)
        let draft = try r.segments(sourceID:growing.id)[0]
        let split = try r.split(id:draft.id,at:150,expectedRevision:draft.revision)
        let longer = try source(growing.ranges+[range(300,600)],complete:false,id:growing.id)
        try register(longer)
        try r.reconcile(sourceID:growing.id)
        rejects { try r.undo(sourceID:growing.id) }
        try check(r.segments(sourceID:growing.id).prefix(2).map(\.id) == split.map(\.id),"append preserves manual ranges and conflicts with intervening undo")

        let large = try source([range(0,300)])
        try register(large)
        while let job = try p.claimNext() {
            let a = job.window.coreStart, b = job.window.coreEnd
            var activities: [AudioActivityInterval] = []
            if job.window.sourceID == large.id {
                for i in 0..<12000 { activities.append(.init(start:Double(i)/40,end:Double(i+1)/40,kind:i % 2 == 0 ? .noSpeech : .speech)) }
            } else { activities = [.init(start:a,end:b,kind:.speech)] }
            try p.commit(job:job,result:.init(spans:[],activities:activities,asr:.success,vad:.success,speaker:.notRequested,asrCoverage:[.init(start:a,end:b)],vadCoverage:[.init(start:a,end:b)]))
        }
        try r.reconcile(sourceID:large.id)
        let first = try r.segments(sourceID:large.id)
        try check(r.traversal.activityRows == 6000 && r.traversal.maximumPageRows <= 256,"single-window many intervals traverse bounded pages")
        try check(first.count == 1 && !first[0].hasText,"no-text speech retained")
        try r.reconcile(sourceID:large.id)
        try check(r.traversal.reusedSnapshot && r.traversal.activityRows == 0 && r.segments(sourceID:large.id)[0].id == first[0].id,"unchanged wakes skip raw intervals and retain identity")
        print("Content coverage: partial/retry/conflict/reprocess/gap paging/append undo/12000 intervals passed (max page 256)")
    }

    static func undoCausalityFixtures() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        var results: [String:Bool] = [:]
        for mode in ["append", "enrichment", "clean"] {
            let db = try DaybookDatabase(url:root.appendingPathComponent(mode+".sqlite3"))
            let p = AudioProcessingRepository(database:db), r = ContentSegmentRepository(database:db)
            let s = try source([range(0,300)],complete:false)
            try db.execute("INSERT INTO recording_sessions(id,created_at) VALUES (?,0)",[.text(s.id.id.uuidString)])
            try p.register(source:s,configurationKey:"v1",windows:AudioWindowPlanner.plan(source:s,configurationKey:"v1"))
            try r.reconcile(sourceID:s.id)
            let original = try r.segments(sourceID:s.id)[0]
            let parts = try r.split(id:original.id,at:150,expectedRevision:original.revision) // A
            let deleted: ContentSegment
            if mode == "append" {
                let appended = try source(s.ranges+[range(300,600)],complete:false,id:s.id)
                try p.register(source:appended,configurationKey:"v1",windows:AudioWindowPlanner.plan(source:appended,configurationKey:"v1"))
                try r.reconcile(sourceID:s.id)
                deleted = try r.segments(sourceID:s.id).last!
                try check(deleted.ranges[0].sessionStartOffset == 300,"causality fixture has appended automatic tail")
            } else {
                if mode == "enrichment" {
                    try r.applyEnrichment(id:parts[0].id,expectedRevision:parts[0].revision,sourceRevision:parts[0].sourceRevision,title:"Retain enrichment",summary:"Persisted between edits")
                }
                deleted = parts[1]
            }
            try r.delete(id:deleted.id,expectedRevision:deleted.revision) // B
            let reopened = ContentSegmentRepository(database:try DaybookDatabase(url:db.url))
            try reopened.undo(sourceID:s.id) // Undo B must restore its exact pre-edit content.
            let restored = try reopened.segments(sourceID:s.id)
            if mode == "clean" {
                try reopened.undo(sourceID:s.id)
                let final = try reopened.segments(sourceID:s.id)
                results[mode] = final.count == 1 && final[0].id == original.id && final[0].revision > original.revision
                continue
            }
            var rejected = false
            do { try reopened.undo(sourceID:s.id) } // Undo A must not discard the change between A and B.
            catch ContentSegmentError.undoConflict { rejected = true }
            let after = try reopened.segments(sourceID:s.id)
            try reopened.reconcile(sourceID:s.id) // Signature reuse must not mask content loss.
            let reconciled = try reopened.segments(sourceID:s.id)
            let preserved = after == restored && reconciled == restored
            FileHandle.standardOutput.write(Data("Undo causality \(mode): undoConflict=\(rejected), contentPreserved=\(preserved)\n".utf8))
            results[mode] = rejected && preserved
        }
        try check(results["append"] == true,"chained undo must preserve intervening append/reconcile")
        try check(results["enrichment"] == true,"chained undo must preserve intervening enrichment")
        try check(results["clean"] == true,"consecutive clean manual undos remain possible")
        print("Content undo causality: append/reconcile, enrichment, clean undo chain passed")
    }

}
