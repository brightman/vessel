import Foundation
import CryptoKit

/// Real SQLite fixtures, including the URL-dependent rows written before this fix.
@main struct AudioRelocationSmoke {
    static func check(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
        guard try value() else { fatalError(message) }
    }
    static func rejects(_ body: () throws -> Void) {
        do { try body(); fatalError("stale operation accepted") } catch {}
    }
    static func relocated(_ source: AudioSourceSnapshot, to directory: String, hash: String? = nil) throws -> AudioSourceSnapshot {
        try .init(id:source.id,capturedAt:source.capturedAt,title:source.title,origin:source.origin,location:source.location,
            ranges:source.ranges.map { range in
                try AudioSourceRange(range:.init(chunkID:range.chunkID,url:URL(fileURLWithPath:directory).appendingPathComponent(range.url.lastPathComponent),startFrame:range.startFrame,endFrame:range.endFrame,sampleRate:range.sampleRate,sessionStartOffset:range.sessionStartOffset,discontinuityBefore:range.discontinuityBefore),contentHash:hash ?? range.contentHash)
            },complete:source.complete)
    }
    static func source() throws -> AudioSourceSnapshot {
        try .init(id:.init(kind:.session,id:UUID()),capturedAt:Date(timeIntervalSinceReferenceDate:0),title:"Fixture",ranges:[
            .init(range:.init(chunkID:UUID(),url:URL(fileURLWithPath:"/old-container/audio.aac"),startFrame:0,endFrame:14_400_000,sampleRate:16000),contentHash:String(repeating:"a",count:64))
        ],complete:true)
    }
    static func legacyWindows(_ source: AudioSourceSnapshot) throws -> [AudioProcessingWindow] {
        try AudioWindowPlanner.plan(source:source,configurationKey:"v1").map { window in
            struct Identity: Encodable {
                let algorithm: String; let source: AudioSourceID; let config: String
                let coreStart: Double; let coreEnd: Double; let ranges: [AudioSourceRange]
            }
            let id = AudioStableID.make(Identity(algorithm:"frames-midpoint-v1",source:source.id,config:"v1",coreStart:window.coreStart,coreEnd:window.coreEnd,ranges:window.ranges))
            return .init(id:id,sourceID:source.id,configurationKey:"v1",coreStart:window.coreStart,coreEnd:window.coreEnd,ranges:window.ranges)
        }
    }
    static func seedLegacy(_ source: AudioSourceSnapshot, db: DaybookDatabase, completed: Int = 3, incompleteFirst: Bool = false) throws -> [AudioProcessingJob] {
        try db.execute("INSERT INTO recording_sessions(id,created_at) VALUES (?,0)",[.text(source.id.id.uuidString)])
        try db.execute("INSERT INTO audio_processing_sources(source_key,kind,source_id,session_id,descriptor,fingerprint,configuration_key) VALUES (?,'session',?,?,?,?, 'v1')",[.text(source.id.key),.text(source.id.id.uuidString),.text(source.id.id.uuidString),try DaybookDatabase.json(source),.text(AudioStableID.make(source.ranges))])
        var jobs: [AudioProcessingJob] = []
        for (index,window) in try legacyWindows(source).enumerated() {
            let job = AudioProcessingJob(window:window,lease:UUID()); jobs.append(job)
            try db.execute("INSERT INTO audio_processing_jobs(id,source_key,configuration_key,core_start,core_end,window,state,active,lease) VALUES (?,?,'v1',?,?,?,'running',1,?)",[.text(window.id),.text(source.id.key),.real(window.coreStart),.real(window.coreEnd),try DaybookDatabase.json(window),.text(job.lease.uuidString)])
            if index < completed {
                let output = incompleteFirst && index == 0 ? AudioWindowResult(spans:result(window).spans,activities:[],asr:.success,vad:.missingResource,speaker:.notRequested,asrCoverage:[.init(start:window.coreStart,end:window.coreEnd)],vadCoverage:[]) : result(window)
                try AudioProcessingRepository(database:db).commit(job:job,result:output)
            }
        }
        return jobs
    }
    static func result(_ window: AudioProcessingWindow) -> AudioWindowResult {
        .init(spans:[.init(start:window.coreStart+10,end:window.coreEnd-1,text:"fixture")],activities:[.init(start:window.coreStart,end:window.coreEnd,kind:.speech)],asr:.success,vad:.success,speaker:.notRequested,asrCoverage:[.init(start:window.coreStart,end:window.coreEnd)],vadCoverage:[.init(start:window.coreStart,end:window.coreEnd)])
    }
    static func register(_ source: AudioSourceSnapshot, in processing: AudioProcessingRepository, key: String = "v1") throws {
        try processing.register(source:source,configurationKey:key,windows:AudioWindowPlanner.plan(source:source,configurationKey:key))
    }
    static func legacySnapshotSignature(_ source: AudioSourceSnapshot, db: DaybookDatabase) throws -> String {
        let rows = try db.query("SELECT id,result_hash FROM audio_processing_jobs WHERE source_key=? AND active=1 ORDER BY core_start,id",[.text(source.id.key)])
        return AudioStableID.make([AudioStableID.make(source),"v1",ContentSegmentRepository.algorithmVersion,AudioStableID.make(rows.map { [$0["id"]?.string ?? "",$0["result_hash"]?.string ?? ""] })])
    }
    static func legacyContentSignature(_ segment: ContentSegment, processing: AudioProcessingRepository) throws -> String {
        var digest = SHA256()
        for range in segment.ranges {
            for span in try processing.spans(sourceID:segment.sourceID,overlapping:.init(start:range.sessionStartOffset,end:range.end)) {
                digest.update(data:Data(AudioStableID.make(span).utf8))
            }
        }
        return AudioStableID.make(["v1",AudioStableID.make(segment.ranges),digest.finalize().map { String(format:"%02x",$0) }.joined()])
    }
    static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let original = try source(), moved = try relocated(original,to:"/new-container")
        try check(original.fingerprint == moved.fingerprint,"relocation must not change source fingerprint")
        try check(AudioWindowPlanner.plan(source:original,configurationKey:"v1").map(\.id) == AudioWindowPlanner.plan(source:moved,configurationKey:"v1").map(\.id),"relocation must not change processing identity")
        try historyRecovery(original,moved:moved,url:root.appendingPathComponent("history.sqlite3"))
        try contentPreservation(original,moved:moved,url:root.appendingPathComponent("content.sqlite3"))
        try legacyTopicRecovery(original,moved:moved,url:root.appendingPathComponent("topics.sqlite3"))
        try runningLeaseRelocation(original,moved:moved,url:root.appendingPathComponent("leases.sqlite3"))
        try interruptedHistoricalRetry(original,moved:moved,url:root.appendingPathComponent("interrupted.sqlite3"))
        print("Audio relocation: stable identity, exact historical reuse, cancellation, leases, config/hash isolation, manual playback, topic/enrichment checkpoints and undo passed")
    }
    static func historyRecovery(_ original: AudioSourceSnapshot, moved: AudioSourceSnapshot, url: URL) throws {
        let db = try DaybookDatabase(url:url), p = AudioProcessingRepository(database:try DaybookDatabase(url:url))
        let jobs = try seedLegacy(original,db:db,completed:2)
        // Reproduce a later reinstall generation hiding completed rows and then manual cancel.
        try db.execute("UPDATE audio_processing_jobs SET active=0,lease=NULL,state=CASE WHEN state='running' THEN 'cancelled' ELSE state END")
        for (index,window) in try legacyWindows(moved).enumerated() {
            try db.execute("INSERT INTO audio_processing_jobs(id,source_key,configuration_key,core_start,core_end,window,state,active) VALUES (?,?,'v1',?,?,?,'cancelled',1)",[.text(window.id),.text(moved.id.key),.real(window.coreStart),.real(window.coreEnd),try DaybookDatabase.json(window)])
            if index == 0 {
                let failed = AudioWindowResult(spans:[],activities:[],asr:.failed,vad:.failed,speaker:.notRequested,asrCoverage:[],vadCoverage:[])
                try db.execute("UPDATE audio_processing_jobs SET state='completed',result=?,result_hash=? WHERE id=?",[try DaybookDatabase.json(failed),.text(AudioStableID.make(failed)),.text(window.id)])
            }
        }
        try db.execute("UPDATE audio_processing_sources SET descriptor=?,cancelled=1",[try DaybookDatabase.json(moved)])
        let previousRevision = try p.progress(sourceID:original.id).revision
        try register(moved,in:p)
        try check(p.results(sourceID:original.id).count == 2 && p.spans(sourceID:original.id).count == 2,"exact inactive completed results become visible once")
        try check(p.progress(sourceID:original.id).revision > previousRevision,"restored evidence revokes stale source snapshots even when descriptor is unchanged")
        try check(p.progress(sourceID:original.id).states[.completed] == 2 && p.progress(sourceID:original.id).states[.cancelled] == 1,"manual cancellation preserved for unfinished windows")
        try check(p.claimNext() == nil,"recovery cannot clear manual cancellation")
        try check(p.completedAnalyses(sourceID:original.id).allSatisfy { $0.window.ranges.allSatisfy { $0.url.deletingLastPathComponent().path == "/new-container" } },"retained jobs read relocated URLs")
        rejects { try p.commit(job:jobs[2],result:result(jobs[2].window)) }
        try register(moved,in:p)
        let reopened = AudioProcessingRepository(database:try DaybookDatabase(url:url))
        try check(reopened.spans(sourceID:original.id).count == 2 && reopened.claimNext() == nil,"reopen and rediscovery are idempotent")
        try register(relocated(moved,to:"/new-container",hash:String(repeating:"b",count:64)),in:p)
        try check(p.results(sourceID:original.id).isEmpty,"changed bytes cannot inherit results")
        try register(moved,in:p,key:"v2")
        try check(p.results(sourceID:original.id).isEmpty,"changed configuration cannot inherit results")
        try register(moved,in:p)
        try check(p.results(sourceID:original.id).count == 2,"exact original configuration can recover again")
        try p.delete(sourceID:original.id)
        rejects { try register(moved,in:p) }
    }
    static func runningLeaseRelocation(_ original: AudioSourceSnapshot, moved: AudioSourceSnapshot, url: URL) throws {
        let db = try DaybookDatabase(url:url), p = AudioProcessingRepository(database:db)
        try db.execute("INSERT INTO recording_sessions(id,created_at) VALUES (?,0)",[.text(original.id.id.uuidString)])
        try register(original,in:p)
        let old = try p.claimNext()!
        try register(moved,in:p)
        rejects { try p.commit(job:old,result:result(old.window)) }
        let fresh = try p.claimNext()!
        try check(fresh.window.coreStart == old.window.coreStart && fresh.window.ranges[0].url.path == "/new-container/audio.aac","relocated running work is reclaimable with fresh URLs")
        try p.commit(job:fresh,result:result(fresh.window))
    }
    static func interruptedHistoricalRetry(_ original: AudioSourceSnapshot, moved: AudioSourceSnapshot, url: URL) throws {
        let db = try DaybookDatabase(url:url), p = AudioProcessingRepository(database:db)
        _ = try seedLegacy(original,db:db,incompleteFirst:true)
        try p.retryIncompleteStages(sourceID:original.id,resourceOnly:true)
        let abandoned = try p.claimNext()!
        try db.execute("UPDATE audio_processing_jobs SET active=0,lease=NULL,state=CASE WHEN state='running' THEN 'cancelled' ELSE state END")
        for window in try legacyWindows(moved) {
            try db.execute("INSERT INTO audio_processing_jobs(id,source_key,configuration_key,core_start,core_end,window,state,active) VALUES (?,?,'v1',?,?,?,'pending',1)",[.text(window.id),.text(moved.id.key),.real(window.coreStart),.real(window.coreEnd),try DaybookDatabase.json(window)])
        }
        try db.execute("UPDATE audio_processing_sources SET descriptor=?",[try DaybookDatabase.json(moved)])
        try register(moved,in:p)
        guard let fresh = try p.claimNext() else { fatalError("obsolete cancelled lease must resume when source is not manually cancelled") }
        try check(fresh.window.id == abandoned.window.id && p.stages(for:fresh) == [.vad],"historical retry retains ASR and requests only missing VAD")
        rejects { try p.commit(job:abandoned,result:result(abandoned.window)) }
        try p.commit(job:fresh,delta:.init(result:result(fresh.window),speakerSpanUpdates:[]))
        try check(p.spans(sourceID:original.id).count == 3 && p.results(sourceID:original.id).allSatisfy { $0.asr == .success && $0.vad == .success },"stage-only retry completes without duplicating retained ASR")
    }
    static func contentPreservation(_ original: AudioSourceSnapshot, moved: AudioSourceSnapshot, url: URL) throws {
        let db = try DaybookDatabase(url:url), p = AudioProcessingRepository(database:db), c = ContentSegmentRepository(database:db)
        _ = try seedLegacy(original,db:db)
        try c.reconcile(sourceID:original.id)
        var segment = try c.segments(sourceID:original.id)[0]
        // Convert the segment to the pre-fix content identity without any new optional fields.
        let legacy = try legacyContentSignature(segment,processing:p)
        segment.provenance = .init(algorithmVersion:"confirmed-gap-600-padding-2-v1",configurationKey:"v1",contentSignature:legacy)
        try db.execute("UPDATE content_segments SET payload=? WHERE id=?",[try DaybookDatabase.json(segment),.text(segment.id.uuidString)])
        _ = try c.enrichment(.complete(segment,"legacy-model-cache","Saved title","Saved summary"))
        let saved = try c.segment(id:segment.id)!
        let signature = try legacySnapshotSignature(original,db:db)
        try db.execute("UPDATE content_segment_sources SET signature=?",[.text(signature)])
        // This column exists only after migration; drop it to exercise an actual v9 reopen.
        if try db.query("PRAGMA table_info(content_segment_sources)").contains(where: { $0["name"]?.string == "semantic_signature" }) {
            try db.execute("ALTER TABLE content_segment_sources DROP COLUMN semantic_signature")
        }
        try db.execute("PRAGMA user_version=9")
        let upgraded = try DaybookDatabase(url:url), migratedP = AudioProcessingRepository(database:upgraded), migratedC = ContentSegmentRepository(database:upgraded)
        try register(moved,in:migratedP)
        try migratedC.reconcile(sourceID:original.id)
        let retained = try migratedC.segment(id:segment.id)!
        try check(retained.revision == saved.revision && retained.title == "Saved title" && retained.summary == "Saved summary" && retained.provenance.contentSignature == legacy,"path migration preserves enriched identity and revision")
        if case let .text(hit) = try migratedC.enrichment(.cached("legacy-model-cache","complete")) { try check(hit != nil,"completed enrichment checkpoint remains valid") }
        else { fatalError("wrong checkpoint response") }
        try check(retained.ranges.allSatisfy { $0.url.path == "/new-container/audio.aac" },"automatic playback URLs refreshed on reused snapshot")
        // Store a real topic decision, then verify a second relocation retains its cache signature.
        guard case let .candidate(candidate) = try migratedC.enrichment(.candidate(original.id,10,310)), let candidate else { fatalError("missing topic candidate") }
        _ = try migratedC.enrichment(.topic(candidate,.newTopic,"topic-cache"))
        let topicParts = try migratedC.segments(sourceID:original.id)
        let third = try relocated(moved,to:"/third-container")
        try register(third,in:migratedP); try migratedC.reconcile(sourceID:original.id)
        try check(migratedC.segments(sourceID:original.id).map(\.id) == topicParts.map(\.id),"relocation preserves accepted topic boundaries")
        try check(upgraded.query("SELECT signature FROM content_topic_decisions").first?["signature"]?.string == candidate.sourceSignature,"topic cache signature remains usable")
        let split = try migratedC.split(id:topicParts[0].id,at:150,expectedRevision:topicParts[0].revision)
        let fourth = try relocated(third,to:"/fourth-container")
        try register(fourth,in:migratedP); try migratedC.reconcile(sourceID:original.id)
        try check(migratedC.segment(id:split[0].id)?.ranges[0].url.path == "/fourth-container/audio.aac","manual playback follows verified relocation")
        try migratedC.undo(sourceID:original.id)
        try check(migratedC.segments(sourceID:original.id).allSatisfy { $0.ranges.allSatisfy { $0.url.path == "/fourth-container/audio.aac" } },"undo cannot restore obsolete sandbox URLs")
        let toDelete = try migratedC.segments(sourceID:original.id)[0]
        try migratedC.delete(id:toDelete.id,expectedRevision:toDelete.revision)
        try register(relocated(fourth,to:"/fifth-container"),in:migratedP); try migratedC.reconcile(sourceID:original.id)
        try check(migratedC.segment(id:toDelete.id) == nil,"relocation cannot revive a manual tombstone")
    }
    static func legacyTopicRecovery(_ original: AudioSourceSnapshot, moved: AudioSourceSnapshot, url: URL) throws {
        let db = try DaybookDatabase(url:url), p = AudioProcessingRepository(database:db), c = ContentSegmentRepository(database:db)
        _ = try seedLegacy(original,db:db)
        try c.reconcile(sourceID:original.id)
        let signature = try legacySnapshotSignature(original,db:db)
        try db.execute("UPDATE content_segment_sources SET signature=?",[.text(signature)])
        guard case let .candidate(candidate) = try c.enrichment(.candidate(original.id,10,310)), let candidate else { fatalError("missing historical topic candidate") }
        _ = try c.enrichment(.topic(candidate,.newTopic,"legacy-topic-cache"))
        for (index,originalSegment) in try c.segments(sourceID:original.id).enumerated() {
            var segment = originalSegment
            segment.provenance = .init(algorithmVersion:"confirmed-gap-600-padding-2-v1",configurationKey:"v1",contentSignature:try legacyContentSignature(segment,processing:p))
            try db.execute("UPDATE content_segments SET payload=? WHERE id=?",[try DaybookDatabase.json(segment),.text(segment.id.uuidString)])
            _ = try c.enrichment(.complete(segment,"legacy-topic-summary-\(index)","Saved topic","Saved summary"))
        }
        let saved = try c.segments(sourceID:original.id)
        // v9 had already installed blank jobs for the new sandbox, but no content wake ran yet.
        try db.execute("UPDATE audio_processing_jobs SET active=0,lease=NULL")
        for window in try legacyWindows(moved) {
            try db.execute("INSERT INTO audio_processing_jobs(id,source_key,configuration_key,core_start,core_end,window,state,active) VALUES (?,?,'v1',?,?,?,'cancelled',1)",[.text(window.id),.text(moved.id.key),.real(window.coreStart),.real(window.coreEnd),try DaybookDatabase.json(window)])
        }
        try db.execute("UPDATE audio_processing_sources SET descriptor=?,cancelled=1",[try DaybookDatabase.json(moved)])
        try db.execute("ALTER TABLE content_segment_sources DROP COLUMN semantic_signature")
        try db.execute("PRAGMA user_version=9")
        let upgraded = try DaybookDatabase(url:url), recovered = AudioProcessingRepository(database:upgraded), content = ContentSegmentRepository(database:upgraded)
        try register(moved,in:recovered); try content.reconcile(sourceID:original.id)
        let actual = try content.segments(sourceID:original.id)
        try check(actual.map(\.id) == saved.map(\.id) && actual.map(\.revision) == saved.map(\.revision),"historical recovery preserves prior accepted topic segments")
        try check(actual.allSatisfy { $0.title == "Saved topic" && $0.summary == "Saved summary" && $0.ranges.allSatisfy { $0.url.path == "/new-container/audio.aac" } },"historical topic summaries and playback survive together")
        try check(upgraded.query("SELECT signature FROM content_topic_decisions").first?["signature"]?.string == signature,"historical topic decision retains its exact cache key")
        for index in saved.indices {
            guard case let .text(hit) = try content.enrichment(.cached("legacy-topic-summary-\(index)","complete")) else { fatalError("wrong checkpoint response") }
            try check(hit != nil,"historical topic summary completion remains installed")
        }
        try check(recovered.claimNext() == nil,"historical topic recovery still honors manual cancellation")
    }
}
