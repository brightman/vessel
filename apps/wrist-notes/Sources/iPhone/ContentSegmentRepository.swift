import Foundation
import CryptoKit

/// Synchronous derived work on the processing worker; transactions never await.
final class ContentSegmentRepository {
    enum ContentV2PublishError: Error {
        case protectedHistory, emptyGeneratedRange, spanOutsideGeneratedRange(String), invalidGeneratedID
    }
    static let algorithmVersion = AudioContentSnapshotIdentity.algorithmVersion
    private let db: DaybookDatabase
    private let processing: AudioProcessingRepository
    private(set) var traversal = ContentSegmentationTraversal()
    private let pageSize = 256
    init(database: DaybookDatabase) { db = database; processing = .init(database:database) }

    func state(sourceID: AudioSourceID) throws -> ContentProcessingState {
        guard try source(sourceID) != nil else { return .pending }
        return try db.query("SELECT state FROM content_segment_sources WHERE source_key=?",[.text(sourceID.key)]).first?["state"]?.string.flatMap(ContentProcessingState.init) ?? .pending
    }
    /// Snapshot all successful transcript/coverage evidence for the production V2 planner.
    /// An unresolved or failed ASR job blocks semantic publication; failed VAD remains an
    /// explicit coverage hole and makes only dependent chapters provisional.
    func contentV2Input(sourceID: AudioSourceID) throws -> ContentSegmentationV2.Input? {
        guard let descriptor = try source(sourceID) else { return nil }
        let sourceDuration=descriptor.ranges.reduce(0) { $0 + $1.duration }
        guard sourceDuration > AudioInferenceStagePolicy.topicSplittingThreshold else { return nil }
        let progress = try processing.progress(sourceID:sourceID)
        guard let configurationKey = progress.configurationKey else { return nil }
        let jobs = try db.query("SELECT id,window,result,result_hash,state FROM audio_processing_jobs WHERE source_key=? AND active=1 AND configuration_key=? ORDER BY core_start,id",[.text(sourceID.key),.text(configurationKey)])
        guard !jobs.isEmpty else { return nil }
        var results: [(String,AudioProcessingWindow,AudioWindowResult)] = []
        for row in jobs {
            guard row["result"] != .null, let data = row["result"]?.data,
                  let state = row["state"]?.string, state == AudioJobState.completed.rawValue else { return nil }
            let result = try DaybookDatabase.decode(AudioWindowResult.self,.blob(data))
            guard result.asr == .success else { return nil }
            results.append((try row.requiredString("id"),try DaybookDatabase.decode(AudioProcessingWindow.self,row["window"]),result))
        }
        guard sourceDuration.isFinite, sourceDuration > AudioInferenceStagePolicy.topicSplittingThreshold else { return nil }
        var spans: [ContentSegmentationV2.Span] = []
        for (jobID,_,_) in results {
            for row in try db.query("SELECT position,start,end,text FROM audio_transcript_spans WHERE job_id=? ORDER BY position",[.text(jobID)]) {
                spans.append(.init(id:jobID+":"+String(try row.requiredInt("position")),start:try row.requiredDouble("start"),end:try row.requiredDouble("end"),text:try row.requiredString("text")))
            }
        }
        spans.sort { $0.start == $1.start ? ($0.end == $1.end ? $0.id < $1.id : $0.end < $1.end) : $0.start < $1.start }
        var asr: [ContentSegmentationV2.Interval] = [], vad: [ContentSegmentationV2.Interval] = []
        for (_,_,result) in results {
            asr += result.asrCoverage.map { .init(start:$0.start,end:$0.end) }
            vad += result.vadCoverage.map { .init(start:$0.start,end:$0.end) }
        }
        let resultHashes = Dictionary(uniqueKeysWithValues:try jobs.map { (try $0.requiredString("id"),$0["result_hash"]?.string ?? "") })
        let jobIdentity = results.flatMap { [$0.0,$0.1.contentIdentity,resultHashes[$0.0] ?? ""] }
        // Lease/progress revisions are not content. Bind checkpoints to the
        // actual ASR rows and analysis evidence so no-op wakes and file relocation
        // can resume them, while changed text/coverage still invalidates them.
        let inputRevision = AudioStableID.make(["content-v2-input-evidence-v1",configurationKey,descriptor.contentIdentity,AudioStableID.make(spans)]+jobIdentity)
        let activityRows = try db.query("SELECT t.start,t.end,t.kind FROM audio_activity_intervals t JOIN audio_processing_jobs j ON j.id=t.job_id WHERE j.source_key=? AND j.active=1 AND j.configuration_key=? ORDER BY t.start,t.end,j.id,t.position",[.text(sourceID.key),.text(configurationKey)])
        let activities = try activityRows.map { row -> ContentSegmentationV2.Activity in
            guard let kind = AudioActivityKind(rawValue:try row.requiredString("kind")) else { throw AudioProcessingError.invalidInput }
            let mapped: ContentSegmentationV2.ActivityKind = switch kind {
            case .speech: .speech
            case .uncertain: .uncertain
            case .noSpeech: .noSpeech
            }
            return .init(start:try row.requiredDouble("start"),end:try row.requiredDouble("end"),kind:mapped)
        }
        var boundaries: [ContentSegmentationV2.Boundary] = []
        for pair in zip(descriptor.ranges,descriptor.ranges.dropFirst()) where pair.1.sessionStartOffset > pair.0.end + ContentSegmentationV2.epsilon {
            boundaries.append(.init(start:pair.0.end,end:pair.1.sessionStartOffset,kind:.discontinuity))
        }
        // The legacy content pass may be visible as a draft. A finalized/manual action or
        // suppression must never be replaced by a fresh automatic plan.
        if try !db.query("SELECT 1 FROM content_segment_edits WHERE source_key=? AND undone=0 AND kind IN ('split','merge','delete') LIMIT 1",[.text(sourceID.key)]).isEmpty { throw ContentSegmentError.invalidEdit }
        if try !db.query("SELECT 1 FROM content_segment_suppression WHERE source_key=? LIMIT 1",[.text(sourceID.key)]).isEmpty { throw ContentSegmentError.invalidEdit }
        if try allSegments(sourceID).contains(where: { $0.isManual || $0.titleManuallyEdited == true }) { throw ContentSegmentError.invalidEdit }
        return .init(sourceID:sourceID.key,sourceRevision:inputRevision,duration:sourceDuration,spans:spans,
            asrCoverage:asr,vadCoverage:vad,activities:activities,boundaries:boundaries)
    }

    func contentV2Checkpoint(sourceID:AudioSourceID,key:String) throws -> Data? {
        guard let value = try db.query("SELECT text FROM content_enrichment_checkpoints WHERE source_key=? AND cache_key=? AND unit='content-v2'",[.text(sourceID.key),.text(key)]).first?["text"]?.string else { return nil }
        return Data(base64Encoded:value)
    }
    func saveContentV2Checkpoint(sourceID:AudioSourceID,key:String,data:Data) throws {
        try db.execute("INSERT INTO content_enrichment_checkpoints(cache_key,unit,source_key,text,segment_id,accepted_revision) VALUES (?,'content-v2',?,?,NULL,NULL) ON CONFLICT(cache_key,unit) DO UPDATE SET source_key=excluded.source_key,text=excluded.text,segment_id=NULL,accepted_revision=NULL",[.text(key),.text(sourceID.key),.text(data.base64EncodedString())])
    }

    /// Avoid re-publishing the same V2 segmentation whenever the app foregrounds.
    /// This marker is tied to the exact transcript/coverage snapshot, model identity,
    /// algorithm, and long-recording policy; field enrichment does not invalidate it.
    func hasPublishedContentV2(sourceID:AudioSourceID,input:ContentSegmentationV2.Input,modelIdentity:String,topicSplitting:Bool) throws -> Bool {
        let key=contentV2CompletionKey(input:input,modelIdentity:modelIdentity,topicSplitting:topicSplitting)
        let rows=try db.query("SELECT 1 FROM content_enrichment_checkpoints WHERE source_key=? AND cache_key=? AND unit='content-v2-complete' LIMIT 1",[.text(sourceID.key),.text(key)])
        return !rows.isEmpty
    }
    private func contentV2CompletionKey(input:ContentSegmentationV2.Input,modelIdentity:String,topicSplitting:Bool) -> String {
        AudioStableID.make([input.sourceID,input.sourceRevision,ContentSegmentationV2.algorithmVersion,modelIdentity,topicSplitting ? "split-topics" : "single-topic"])
    }

    /// Recheck the exact ASR/VAD snapshot, manual state, and all output ownership before
    /// replacing automatic drafts in one bounded transaction.
    func publishContentV2(sourceID:AudioSourceID,input:ContentSegmentationV2.Input,output:ContentSegmentationV2.Output,model:String,modelIdentity:String,topicSplitting:Bool) throws {
        try ContentSegmentationV2.validateOutput(plan:output.plan,segments:output.segments,original:input.spans)
        guard input.sourceID == sourceID.key, let descriptor=try source(sourceID),
              let key=try processing.progress(sourceID:sourceID).configurationKey else { throw ContentSegmentError.staleRevision }
        let previous=try allSegments(sourceID)
        try ensureAutomaticV2ReplacementAllowed(sourceID,segments:previous)
        let prepared=try prepareContentV2Segments(sourceID:sourceID,input:input,output:output,model:model,key:key,descriptor:descriptor,previous:previous)
        let activeIDs=Set(prepared.map { $0.0.id })
        let jobs=try jobRows(sourceID:sourceID,columns:"j.window,j.result_hash").map { (try DaybookDatabase.decode(AudioProcessingWindow.self,$0["window"]),$0["result_hash"]?.string ?? "") }
        let sourceSignature=AudioContentSnapshotIdentity.make(source:descriptor,key:key,jobs:jobs)
        try db.transaction {
            guard input.sourceID == sourceID.key, try contentV2Input(sourceID:sourceID) == input else { throw ContentSegmentError.staleRevision }
            let current=try allSegments(sourceID)
            guard current == previous else { throw ContentSegmentError.staleRevision }
            try ensureAutomaticV2ReplacementAllowed(sourceID,segments:current)
            for old in current where !activeIDs.contains(old.id) { try tombstone(old) }
            for (value,transcript) in prepared {
                try save(value)
                try db.execute("INSERT INTO content_segment_presentations(segment_id,content_signature,transcript) VALUES (?,?,?) ON CONFLICT(segment_id) DO UPDATE SET content_signature=excluded.content_signature,transcript=excluded.transcript",[.text(value.id.uuidString),.text(value.provenance.contentSignature),.blob(transcript)])
            }
            try db.execute("INSERT INTO content_segment_sources(source_key,signature,semantic_signature,state,epoch) VALUES (?,?,?,'processed',1) ON CONFLICT(source_key) DO UPDATE SET signature=excluded.signature,semantic_signature=excluded.semantic_signature,state='processed',epoch=epoch+1",[.text(sourceID.key),.text(sourceSignature),.text(sourceSignature)])
            let completionKey=contentV2CompletionKey(input:input,modelIdentity:modelIdentity,topicSplitting:topicSplitting)
            try db.execute("INSERT INTO content_enrichment_checkpoints(cache_key,unit,source_key,text,segment_id,accepted_revision) VALUES (?,'content-v2-complete',?,?,NULL,NULL) ON CONFLICT(cache_key,unit) DO UPDATE SET source_key=excluded.source_key,text=excluded.text,segment_id=NULL,accepted_revision=NULL",[.text(completionKey),.text(sourceID.key),.text(input.sourceRevision)])
        }
    }
    private func ensureAutomaticV2ReplacementAllowed(_ sourceID:AudioSourceID,segments:[ContentSegment]) throws {
        guard segments.allSatisfy({ !$0.isManual && $0.titleManuallyEdited != true }),
              try db.query("SELECT 1 FROM content_segment_edits WHERE source_key=? AND undone=0 AND kind IN ('split','merge','delete') LIMIT 1",[.text(sourceID.key)]).isEmpty,
              try db.query("SELECT 1 FROM content_segment_suppression WHERE source_key=? LIMIT 1",[.text(sourceID.key)]).isEmpty else { throw ContentV2PublishError.protectedHistory }
    }
    private func prepareContentV2Segments(sourceID:AudioSourceID,input:ContentSegmentationV2.Input,output:ContentSegmentationV2.Output,model:String,key:String,descriptor:AudioSourceSnapshot,previous:[ContentSegment]) throws -> [(ContentSegment,Data)] {
        let spanByID=Dictionary(uniqueKeysWithValues:input.spans.map { ($0.id,$0) })
        let allJobIDs=Set(input.spans.compactMap { $0.id.split(separator:":",maxSplits:1).first.map(String.init) })
        let sourceRevision=try processing.progress(sourceID:sourceID).revision
        var prepared:[(ContentSegment,Data)]=[]
        for segment in output.segments {
            let ranges=try AudioWindowPlanner.slices(descriptor.ranges,start:segment.start,end:segment.end)
            guard !ranges.isEmpty else { throw ContentV2PublishError.emptyGeneratedRange }
            let owned=try segment.spanIDs.map { id -> AudioTranscriptSpan in
                guard let span=spanByID[id],let separator=id.firstIndex(of:":") else { throw ContentSegmentError.staleRevision }
                let jobID=String(id[..<separator])
                guard allJobIDs.contains(jobID) else { throw ContentSegmentError.staleRevision }
                return .init(start:span.start,end:span.end,text:span.text)
            }
            if let failure=owned.compactMap({ Self.spanCoverageFailure(start:$0.start,end:$0.end,ranges:ranges) }).first {
                throw ContentV2PublishError.spanOutsideGeneratedRange(failure)
            }
            let digest=SHA256.hash(data:Data(segment.id.utf8)).map { String(format:"%02x",$0) }.joined()
            let uuidText=String(digest.prefix(8))+"-"+String(digest.dropFirst(8).prefix(4))+"-"+String(digest.dropFirst(12).prefix(4))+"-"+String(digest.dropFirst(16).prefix(4))+"-"+String(digest.dropFirst(20).prefix(12))
            guard let id=UUID(uuidString:uuidText) else { throw ContentV2PublishError.invalidGeneratedID }
            let signature=AudioStableID.make([output.plan.inputFingerprint,segment.id,ContentSegmentationV2.algorithmVersion])
            let isFinal = !segment.provisional && ContentSegmentationV2.covers(input.asrCoverage,segment.start,segment.end) && ContentSegmentationV2.covers(input.vadCoverage,segment.start,segment.end)
            let editorial=ContentSegmentEditorial(classification:segment.classification.rawValue,engineVersion:ContentSegmentationV2.algorithmVersion,model:model,evidenceBlockIDs:segment.evidenceBlockIDs)
            let prior=previous.first { $0.id == id }
            var value=ContentSegment(id:id,sourceID:sourceID,sourceRevision:sourceRevision,ranges:ranges,
                title:segment.title,summary:segment.summary,revision:prior?.revision ?? 1,isManual:false,isFinal:isFinal,boundaryReady:isFinal,
                hasText:owned.contains { !$0.text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty },
                provenance:.init(algorithmVersion:ContentSegmentationV2.algorithmVersion,configurationKey:key,contentSignature:signature,semanticContentSignature:signature),editorial:editorial)
            if let prior,prior != value { value.revision += 1 }
            prepared.append((value,try JSONEncoder().encode(owned)))
        }
        return prepared
    }
    /// ASR windows may own a word whose timestamp straddles two adjacent audio files.
    /// Check coverage by the ordered union of ranges, rather than requiring one file
    /// to contain the whole word. A real discontinuity still blocks cross-gap ownership.
    static func spanIsCoveredByRanges(start:Double,end:Double,ranges:[AudioSourceRange]) -> Bool {
        spanCoverageFailure(start:start,end:end,ranges:ranges) == nil
    }
    static func spanCoverageFailure(start:Double,end:Double,ranges:[AudioSourceRange]) -> String? {
        guard start.isFinite,end.isFinite,end > start else { return "invalidBounds" }
        // ASR timestamps are floating-point seconds while slice endpoints are snapped
        // to whole PCM frames. Permit only the timestamp rounding envelope of one frame.
        let epsilon=max(0.000001,(ranges.map { 1.5 / $0.sampleRate }.max() ?? 0))
        var cursor=start
        for range in ranges.sorted(by:{$0.sessionStartOffset < $1.sessionStartOffset}) where range.end > cursor + epsilon {
            guard range.sessionStartOffset <= cursor + epsilon else { return "sourceGap" }
            if cursor > start + epsilon, range.discontinuityBefore != nil { return "discontinuity" }
            cursor=max(cursor,range.end)
            if cursor >= end - epsilon { return nil }
        }
        return "coverageEndsEarly"
    }
    func segments(sourceID: AudioSourceID, limit: Int = 200, offset: Int = 0) throws -> [ContentSegment] {
        try validatePage(limit,offset)
        guard try source(sourceID) != nil else { return [] }
        return try db.query("SELECT payload FROM content_segments WHERE source_key=? AND deleted=0 ORDER BY start,id LIMIT ? OFFSET ?",[.text(sourceID.key),.integer(Int64(limit)),.integer(Int64(offset))]).map { try DaybookDatabase.decode(ContentSegment.self,$0["payload"]) }
    }
    func segment(id: UUID) throws -> ContentSegment? {
        guard let row = try db.query("SELECT payload FROM content_segments WHERE id=? AND deleted=0",[.text(id.uuidString)]).first else { return nil }
        let value = try DaybookDatabase.decode(ContentSegment.self,row["payload"])
        return try source(value.sourceID) == nil ? nil : value
    }
    /// EXISTS against actual ordered ranges prevents a manually merged gap leaking transcript.
    func spans(segmentID: UUID, limit: Int = 200, offset: Int = 0) throws -> [AudioTranscriptSpan] {
        try validatePage(limit,offset)
        guard let value = try segment(id:segmentID) else { return [] }
        guard let low = value.ranges.map(\.sessionStartOffset).min(), let high = value.ranges.map(\.end).max() else { return [] }
        // Owned spans may extend beyond a core into its two-second input context.
        // Bounds use both indexes without dropping those boundary-straddling spans;
        // EXISTS still excludes gaps inside manually merged segments.
        return try db.query("SELECT t.* FROM audio_transcript_spans t JOIN audio_processing_jobs j ON j.id=t.job_id JOIN audio_processing_sources s ON s.source_key=j.source_key WHERE j.source_key=? AND j.active=1 AND j.configuration_key=s.configuration_key AND j.result IS NOT NULL AND j.core_start<? AND j.core_end>? AND t.start<? AND t.end>? AND EXISTS (SELECT 1 FROM content_segment_ranges r WHERE r.segment_id=? AND t.end>r.start AND t.start<r.end) ORDER BY t.start,t.end,j.id,t.position LIMIT ? OFFSET ?",[.text(value.sourceID.key),.real(high+2),.real(low-2),.real(high),.real(low),.text(segmentID.uuidString),.integer(Int64(limit)),.integer(Int64(offset))]).map {
            .init(start:try $0.requiredDouble("start"),end:try $0.requiredDouble("end"),text:try $0.requiredString("text"),speakerID:$0["speaker_id"]?.string)
        }
    }

    /// Processing prepares the display/evidence artifact once. Date navigation only reads it.
    /// Never hold the WAL writer while collecting a long transcript.
    func preparePresentations(sourceID: AudioSourceID) throws {
        let ids = try allSegments(sourceID).map(\.id)
        for id in ids {
            try Task.checkCancellation()
            let prepared: (ContentSegment, AudioSourceSnapshot, Data)? = try db.readTransaction {
                guard let value = try segment(id:id), let descriptor = try source(sourceID) else { return nil }
                let signature = value.provenance.semanticContentSignature ?? value.provenance.contentSignature
                if try db.query("SELECT content_signature FROM content_segment_presentations WHERE segment_id=?",[.text(id.uuidString)]).first?["content_signature"]?.string == signature { return nil }
                var result: [AudioTranscriptSpan] = [], offset = 0
                while true {
                    try Task.checkCancellation()
                    let page = try spans(segmentID:id,limit:1000,offset:offset)
                    result += page; offset += page.count
                    if page.count < 1000 { break }
                }
                return (value,descriptor,try JSONEncoder().encode(result))
            }
            guard let (value,descriptor,transcript) = prepared else { continue }
            try db.transaction {
                guard try segment(id:id) == value, try source(sourceID) == descriptor,
                      try processing.progress(sourceID:sourceID).revision == value.sourceRevision else { throw ContentSegmentError.staleRevision }
                let signature = value.provenance.semanticContentSignature ?? value.provenance.contentSignature
                try db.execute("INSERT INTO content_segment_presentations(segment_id,content_signature,transcript) VALUES (?,?,?) ON CONFLICT(segment_id) DO UPDATE SET content_signature=excluded.content_signature,transcript=excluded.transcript",[.text(id.uuidString),.text(signature),.blob(transcript)])
            }
        }
    }
    private struct DerivationPlan {
        let source: AudioSourceSnapshot
        let sourceRevision: Int
        let previous: DaybookDatabase.Row?
        let signature: String
        let semanticSignature: String
        var saved: [ContentSegment] = []
        var removed: [ContentSegment] = []
        var state: ContentProcessingState?
        var epoch = 0
        var before: EditSnapshot?
        var editKind: String?
    }

    /// Heavy scans use a WAL read snapshot, never the database's single writer.
    /// Publish only if audio evidence and derived/manual state still match that snapshot.
    func reconcile(sourceID: AudioSourceID) throws {
        try reconcileSegments(sourceID:sourceID)
        try preparePresentations(sourceID:sourceID)
    }
    private func reconcileSegments(sourceID: AudioSourceID) throws {
        guard let plan = try db.readTransaction({ try prepareDerivation(sourceID: sourceID) }) else { return }
        if plan.state == nil, plan.saved.isEmpty, plan.previous?["semantic_signature"]?.string == plan.semanticSignature { return }
        try db.transaction {
            guard try source(sourceID) == plan.source,
                  try processing.progress(sourceID: sourceID).revision == plan.sourceRevision,
                  try db.query("SELECT * FROM content_segment_sources WHERE source_key=?", [.text(sourceID.key)]).first == plan.previous else {
                throw ContentSegmentError.staleRevision
            }
            for value in plan.saved { try save(value) }
            for value in plan.removed { try tombstone(value) }
            if let state = plan.state {
                try db.execute("DELETE FROM content_topic_decisions WHERE source_key=? AND signature<>?", [.text(sourceID.key), .text(plan.signature)])
                try db.execute("INSERT INTO content_segment_sources(source_key,signature,semantic_signature,state,epoch) VALUES (?,?,?,?,?) ON CONFLICT(source_key) DO UPDATE SET signature=excluded.signature,semantic_signature=excluded.semantic_signature,state=excluded.state,epoch=excluded.epoch", [.text(sourceID.key), .text(plan.signature), .text(plan.semanticSignature), .text(state.rawValue), .integer(Int64(plan.epoch))])
                if let before = plan.before, let kind = plan.editKind {
                    try db.execute("INSERT INTO content_segment_edits(source_key,kind,before_payload,after_epoch) VALUES (?,?,?,?)", [.text(sourceID.key), .text(kind), try DaybookDatabase.json(before), .integer(Int64(plan.epoch))])
                }
            } else {
                try db.execute("UPDATE content_segment_sources SET semantic_signature=? WHERE source_key=?", [.text(plan.semanticSignature), .text(sourceID.key)])
            }
        }
    }

    private func prepareDerivation(sourceID: AudioSourceID) throws -> DerivationPlan? {
        traversal = .init()
        guard let source = try source(sourceID) else { return nil }
        let effectiveDuration=source.ranges.reduce(0) { $0 + $1.duration }
        let keepAsSingleRecording=effectiveDuration <= AudioInferenceStagePolicy.topicSplittingThreshold
        let progress = try processing.progress(sourceID:sourceID)
        guard let key = progress.configurationKey else { return nil }
        let jobs = try jobRows(sourceID:sourceID,columns:"j.window,j.result_hash").map {
            (try DaybookDatabase.decode(AudioProcessingWindow.self,$0["window"]),$0["result_hash"]?.string ?? "")
        }
        let semanticSignature = AudioContentSnapshotIdentity.make(source:source,key:key,jobs:jobs)
        let previous = try db.query("SELECT * FROM content_segment_sources WHERE source_key=?",[.text(sourceID.key)]).first
        let requiresTopicMigration = try allSegments(sourceID).contains { $0.isFinal && !$0.isManual && $0.boundaryReady == nil }
        let sameContent = !requiresTopicMigration && (previous?["semantic_signature"]?.string == semanticSignature || previous?["signature"]?.string == semanticSignature || previous?["signature"]?.string == AudioContentSnapshotIdentity.make(source:source,key:key,jobs:jobs,legacy:true))
        // Preserve an older cache key after exact input equivalence was proven at registration.
        let signature = sameContent ? (previous?["signature"]?.string ?? semanticSignature) : semanticSignature
        var plan = DerivationPlan(source: source, sourceRevision: progress.revision, previous: previous, signature: signature, semanticSignature: semanticSignature)
        if sameContent {
            traversal.reusedSnapshot = true
            // Source revision is a lease guard; progress alone must not invalidate content checkpoints.
            for old in try allSegments(sourceID) {
                var value = try upgradedContentIdentity(old)
                value.sourceRevision = progress.revision
                value.ranges = try value.ranges.map { try $0.relocated(in: source) }
                if value != old { plan.saved.append(value) }
            }
            return plan
        }
        var covered: [AudioTimeRange] = [], asrCovered: [AudioTimeRange] = [], silence: [AudioTimeRange] = []
        var carry: AudioTimeRange?
        var reliableSeconds = 0.0
        func feed(_ interval: AudioTimeRange) {
            reliableSeconds += interval.end-interval.start
            if let old = carry, interval.start <= old.end + 0.0000001 { carry = .init(start:old.start,end:max(old.end,interval.end)) }
            else {
                if let old = carry, old.end-old.start >= 600 { silence.append(old) }
                carry = interval
            }
        }
        // Window metadata is paged; activity/transcript rows are independently paged even in one window.
        var jobOffset = 0
        while true {
            let jobs = try db.query("SELECT j.id,j.result FROM audio_processing_jobs j JOIN audio_processing_sources s ON s.source_key=j.source_key WHERE j.source_key=? AND j.active=1 AND j.configuration_key=s.configuration_key AND j.result IS NOT NULL ORDER BY j.core_start,j.id LIMIT ? OFFSET ?",[.text(sourceID.key),.integer(Int64(pageSize)),.integer(Int64(jobOffset))])
            traversal.maximumPageRows = max(traversal.maximumPageRows,jobs.count)
            for job in jobs {
                let result = try DaybookDatabase.decode(AudioWindowResult.self,job["result"])
                if result.asr == .success {
                    asrCovered = ContentSegmentation.normalized(asrCovered+result.asrCoverage)
                    if keepAsSingleRecording && result.vad != .success {
                        // For short recordings, successful ASR coverage itself proves
                        // the whole-source boundary. New short jobs skip VAD; when
                        // retained historical VAD exists, the normal evidence path below
                        // still preserves its prior blank/speech distinctions.
                        covered = ContentSegmentation.normalized(covered+result.asrCoverage)
                        continue
                    }
                }
                guard result.asr == .success && result.vad == .success else { continue }
                let valid = ContentSegmentation.intersect(ContentSegmentation.normalized(result.asrCoverage),ContentSegmentation.normalized(result.vadCoverage))
                covered = ContentSegmentation.normalized(covered + valid)
                var offset = 0
                while true {
                    let rows = try db.query("SELECT start,end FROM audio_activity_intervals WHERE job_id=? AND kind='noSpeech' ORDER BY start,position LIMIT ? OFFSET ?",[.text(try job.requiredString("id")),.integer(Int64(pageSize)),.integer(Int64(offset))])
                    traversal.activityRows += rows.count
                    traversal.maximumPageRows = max(traversal.maximumPageRows,rows.count)
                    for row in rows {
                        let interval = AudioTimeRange(start:try row.requiredDouble("start"),end:try row.requiredDouble("end"))
                        for clipped in ContentSegmentation.intersect([interval],valid) {
                            // Current source-wide ASR protects boundary-spanning words after ASR-only retries.
                            var cursor = clipped.start, spanOffset = 0
                            while true {
                                let spans = try processing.spans(sourceID:sourceID,overlapping:clipped,limit:pageSize,offset:spanOffset)
                                traversal.spanRows += spans.count
                                traversal.maximumPageRows = max(traversal.maximumPageRows,spans.count)
                                for span in spans {
                                    if span.start > cursor { feed(.init(start:cursor,end:min(clipped.end,span.start))) }
                                    cursor = max(cursor,span.end)
                                }
                                spanOffset += spans.count
                                if spans.count < pageSize { break }
                            }
                            if cursor < clipped.end { feed(.init(start:cursor,end:clipped.end)) }
                        }
                    }
                    offset += rows.count
                    if rows.count < pageSize { break }
                }
            }
            jobOffset += jobs.count
            if jobs.count < pageSize { break }
        }
        if let carry, carry.end-carry.start >= 600 { silence.append(carry) }
        // Retain the explicit no-speech state even for a short all-ambient source.
        if abs(reliableSeconds-source.ranges.reduce(0,{ $0+$1.duration })) < 0.0000001 {
            silence = source.ranges.map { .init(start:$0.sessionStartOffset,end:$0.end) }
        }
        var transcriptRanges: [AudioTimeRange] = [], spanOffset=0
        while true {
            let page=try processing.spans(sourceID:sourceID,limit:pageSize,offset:spanOffset)
            traversal.spanRows += page.count
            traversal.maximumPageRows=max(traversal.maximumPageRows,page.count)
            transcriptRanges += page.map { .init(start:$0.start,end:$0.end) }
            spanOffset += page.count
            if page.count < pageSize { break }
        }
        let asrEmpty=ContentSegmentation.subtract(asrCovered,transcriptRanges+silence)
        let built = try ContentSegmentation.build(source:source,reliableNoSpeech:silence,successfulCoverage:covered,asrEmpty:asrEmpty,transcriptRanges:transcriptRanges,
                                                   keepAsSingleRecording:keepAsSingleRecording)
        // Accepted automatic cuts belong to an exact derivation input. Configuration/text/source
        // changes discard them; progress-only wakes retain them via the fast path above.
        let cuts = try db.query("SELECT position FROM content_topic_decisions WHERE source_key=? AND signature=? AND decision='newTopic' ORDER BY position",[.text(sourceID.key),.text(signature)]).map { try $0.requiredDouble("position") }
        let drafts:[ContentSegmentDraft]
        if keepAsSingleRecording { drafts=built.segments }
        else { drafts=try ContentSegmentation.applyingTopicCuts(cuts,to:built.segments) }
        var old = try allSegments(sourceID).map { try upgradedContentIdentity($0) }
        // Prior versions used isFinal for ASR/VAD coverage alone. Without the new
        // boundaryReady marker, an automatic final has no proof that topic AI ran.
        for index in old.indices where old[index].isFinal && !old[index].isManual && old[index].boundaryReady == nil {
            old[index].isFinal = false
        }
        let masks = try suppression(sourceID)
        // Final ranges are durable locks. Keep them out of automatic overlap matching;
        // appended or reprocessed audio is reconciled only around their exact ranges.
        let locked = old.filter(\.isFinal)
        let lockedMasks = locked.flatMap(\.ranges).map { AudioTimeRange(start:$0.sessionStartOffset,end:$0.end) }
        var remaining = old.filter { !$0.isManual && !$0.isFinal }
        let before = EditSnapshot(segments:old,suppression:masks,beforeEpoch:nil)
        var changed = false
        for var manual in old where manual.isManual {
            let content = try contentSignature(sourceID,ranges:manual.ranges,key:key)
            let contentChanged = (manual.provenance.semanticContentSignature ?? manual.provenance.contentSignature) != content.signature
            let boundaryReady = manual.ranges.allSatisfy { ContentSegmentation.covers(covered,start:$0.sessionStartOffset,end:$0.end) } && (source.complete || manual.boundaryReady == true || manual.isFinal)
            if contentChanged || manual.boundaryReady != boundaryReady {
                manual.boundaryReady = boundaryReady
                manual.hasText = content.hasText
                if contentChanged {
                    manual.editorial = nil
                    if manual.titleManuallyEdited != true { manual.title = "" }
                    manual.summary = ""
                }
                manual.provenance = .init(algorithmVersion:Self.algorithmVersion,configurationKey:key,contentSignature:content.signature,semanticContentSignature:content.signature)
                manual.revision += 1; changed = true
            }
            manual.ranges = try manual.ranges.map { try $0.relocated(in:source) }
            manual.sourceRevision = progress.revision
            plan.saved.append(manual)
        }
        for var final in locked {
            let content = try contentSignature(sourceID,ranges:final.ranges,key:key)
            let contentChanged = (final.provenance.semanticContentSignature ?? final.provenance.contentSignature) != content.signature
            if contentChanged {
                final.hasText = content.hasText
                final.editorial = nil
                if final.titleManuallyEdited != true { final.title = "" }
                final.summary = ""
                final.provenance = .init(algorithmVersion:Self.algorithmVersion,configurationKey:key,contentSignature:content.signature,semanticContentSignature:content.signature)
                final.revision += 1; changed = true
            }
            final.ranges = try final.ranges.map { try $0.relocated(in:source) }
            final.sourceRevision = progress.revision
            plan.saved.append(final)
        }
        for draft in drafts {
            let pieces = ContentSegmentation.subtract(draft.ranges.map { .init(start:$0.sessionStartOffset,end:$0.end) },masks+lockedMasks)
            guard !pieces.isEmpty else { continue }
            let ranges = try pieces.flatMap { try AudioWindowPlanner.slices(draft.ranges,start:$0.start,end:$0.end) }
            let content = try contentSignature(sourceID,ranges:ranges,key:key)
            let exact = remaining.firstIndex { $0.ranges.map(\.contentIdentity) == ranges.map(\.contentIdentity) }
            let match = exact ?? remaining.firstIndex { old in old.ranges.contains { a in ranges.contains { b in a.chunkID == b.chunkID && a.sessionStartOffset < b.end && b.sessionStartOffset < a.end } } }
            var segment: ContentSegment
            let directFinal=keepAsSingleRecording && draft.boundaryReady && content.hasText
            if let match { segment = remaining.remove(at:match) }
            else { segment = .init(id:UUID(),sourceID:sourceID,sourceRevision:progress.revision,ranges:ranges,title:"",summary:"",revision:0,isManual:false,isFinal:directFinal,boundaryReady:draft.boundaryReady,hasText:content.hasText,provenance:.init(algorithmVersion:Self.algorithmVersion,configurationKey:key,contentSignature:content.signature)) }
            let mutated = segment.revision == 0 || segment.ranges.map(\.contentIdentity) != ranges.map(\.contentIdentity) || segment.isFinal != directFinal || segment.boundaryReady != draft.boundaryReady || (segment.provenance.semanticContentSignature ?? segment.provenance.contentSignature) != content.signature
            if mutated {
                segment.ranges = ranges; segment.isFinal = directFinal; segment.boundaryReady = draft.boundaryReady; segment.hasText = content.hasText
                segment.provenance = .init(algorithmVersion:Self.algorithmVersion,configurationKey:key,contentSignature:content.signature,semanticContentSignature:content.signature)
                segment.editorial = nil
                if segment.titleManuallyEdited != true { segment.title = "" }
                segment.summary = ""; segment.revision += 1; changed = true
            }
            segment.ranges = ranges
            segment.sourceRevision = progress.revision
            plan.saved.append(segment)
        }
        plan.removed = remaining
        if !remaining.isEmpty { changed = true }
        let epoch = (try previous?.requiredInt("epoch") ?? 0) + (changed ? 1 : 0)
        plan.state = built.state
        plan.epoch = epoch
        if changed || old.contains(where: { $0.provenance.configurationKey != key }) {
            plan.editKind = old.contains(where: { $0.provenance.configurationKey != key }) ? "reprocess" : "reconcile"
            plan.before = before
        }
        return plan
    }

    func split(id: UUID, at position: Double, expectedRevision: Int) throws -> [ContentSegment] {
        try db.transaction {
            let original = try checked(id,expectedRevision)
            guard !original.isFinal, position.isFinite, original.ranges.contains(where: { position >= $0.sessionStartOffset && position <= $0.end }) else { throw ContentSegmentError.invalidEdit }
            let left = try original.ranges.flatMap { range in
                position > range.sessionStartOffset ? try AudioWindowPlanner.slices([range],start:range.sessionStartOffset,end:min(position,range.end)) : []
            }
            let right = try original.ranges.flatMap { range in
                position < range.end ? try AudioWindowPlanner.slices([range],start:max(position,range.sessionStartOffset),end:range.end) : []
            }
            guard !left.isEmpty, !right.isEmpty else { throw ContentSegmentError.invalidEdit }
            return try edit(original.sourceID,kind:"split") {
                try suppress(original)
                try tombstone(original)
                return try [left,right].map { ranges in
                    var part = original
                    part = .init(id:UUID(),sourceID:original.sourceID,sourceRevision:original.sourceRevision,ranges:ranges,title:"",summary:"",revision:1,isManual:true,isFinal:false,boundaryReady:original.boundaryReady,hasText:original.hasText,provenance:original.provenance)
                    let content = try contentSignature(original.sourceID,ranges:ranges,key:original.provenance.configurationKey)
                    part.hasText = content.hasText
                    part.provenance = .init(algorithmVersion:Self.algorithmVersion,configurationKey:original.provenance.configurationKey,contentSignature:content.signature,semanticContentSignature:content.signature)
                    try save(part); return part
                }
            }
        }
    }
    func merge(ids: [UUID], expectedRevisions: [Int]) throws -> ContentSegment {
        let result=try db.transaction {
            guard ids.count >= 2, ids.count == expectedRevisions.count, Set(ids).count == ids.count else { throw ContentSegmentError.invalidEdit }
            let values = try zip(ids,expectedRevisions).map { try checked($0,$1) }.sorted { $0.ranges[0].sessionStartOffset < $1.ranges[0].sessionStartOffset }
            let sourceID = values[0].sourceID
            guard values.allSatisfy({ $0.sourceID == sourceID && $0.isFinal }) else { throw ContentSegmentError.invalidEdit }
            let all = try allSegments(sourceID)
            let indices = all.indices.filter { ids.contains(all[$0].id) }
            guard indices.count == ids.count, indices.last!-indices.first!+1 == ids.count else { throw ContentSegmentError.invalidEdit }
            return try edit(sourceID,kind:"merge") {
                for value in values { try suppress(value); try tombstone(value) }
                let ranges = values.flatMap(\.ranges)
                let content = try contentSignature(sourceID,ranges:ranges,key:try processing.progress(sourceID:sourceID).configurationKey ?? "")
                let value = ContentSegment(id:UUID(),sourceID:sourceID,sourceRevision:try processing.progress(sourceID:sourceID).revision,ranges:ranges,title:"",summary:"",revision:1,isManual:true,isFinal:true,boundaryReady:true,hasText:content.hasText,provenance:.init(algorithmVersion:Self.algorithmVersion,configurationKey:try processing.progress(sourceID:sourceID).configurationKey ?? "",contentSignature:content.signature))
                try save(value); return value
            }
        }
        try preparePresentations(sourceID:result.sourceID)
        return result
    }
    func delete(id: UUID, expectedRevision: Int) throws {
        try db.transaction {
            let value = try checked(id,expectedRevision)
            try edit(value.sourceID,kind:"delete") { try suppress(value); try tombstone(value) }
        }
    }
    func undo(sourceID: AudioSourceID) throws {
        try db.transaction {
            guard let source = try source(sourceID) else { throw AudioProcessingError.deletedSource }
            guard let row = try db.query("SELECT * FROM content_segment_edits WHERE source_key=? AND undone=0 AND kind IN ('split','merge','delete') ORDER BY sequence DESC LIMIT 1",[.text(sourceID.key)]).first else { throw ContentSegmentError.notFound }
            guard try epoch(sourceID) == row.requiredInt("after_epoch") else { throw ContentSegmentError.undoConflict }
            let before = try DaybookDatabase.decode(EditSnapshot.self,row["before_payload"])
            let revision = try processing.progress(sourceID:sourceID).revision
            for value in try allSegments(sourceID) { try tombstone(value) }
            for var value in before.segments {
                let stored = try db.query("SELECT revision FROM content_segments WHERE id=?",[.text(value.id.uuidString)]).first
                let dead = try db.query("SELECT revision FROM content_segment_tombstones WHERE id=?",[.text(value.id.uuidString)]).first
                value.revision = max(value.revision,max(try stored?.requiredInt("revision") ?? 0,try dead?.requiredInt("revision") ?? 0))+1
                value.sourceRevision = revision
                value = try upgradedContentIdentity(value)
                value.ranges = try value.ranges.map { try $0.relocated(in:source) }
                try save(value)
            }
            try db.execute("DELETE FROM content_segment_suppression WHERE source_key=?",[.text(sourceID.key)])
            for range in before.suppression { try addSuppression(sourceID,range) }
            try bump(sourceID)
            try db.execute("UPDATE content_segment_edits SET undone=1 WHERE sequence=?",[.integer(Int64(try row.requiredInt("sequence")))])
            // Only reconnect a clean manual chain. An automatic/enrichment change between
            // edits is part of the restored state and must never authorize an older snapshot.
            if let beforeEpoch = before.beforeEpoch {
                let newEpoch = try epoch(sourceID)
                try db.execute("UPDATE content_segment_edits SET after_epoch=? WHERE sequence=(SELECT max(sequence) FROM content_segment_edits WHERE source_key=? AND undone=0 AND kind IN ('split','merge','delete')) AND after_epoch=?",[.integer(Int64(newEpoch)),.text(sourceID.key),.integer(Int64(beforeEpoch))])
            }
        }
    }
    func applyEnrichment(id: UUID, expectedRevision: Int, sourceRevision: Int, title: String, summary: String, titleIsManual: Bool = false, overwriteManualTitle: Bool = false) throws {
        try db.transaction {
            var value = try checked(id,expectedRevision)
            let progress = try processing.progress(sourceID:value.sourceID)
            guard progress.revision == sourceRevision, value.sourceRevision == sourceRevision,
                  progress.configurationKey == value.provenance.configurationKey else { throw ContentSegmentError.staleRevision }
            if titleIsManual {
                value.title=String(title.prefix(40)); value.titleManuallyEdited=true
            } else if overwriteManualTitle {
                value.title=String(title.prefix(40)); value.titleManuallyEdited=false
            } else if value.titleManuallyEdited != true {
                value.title=String(title.prefix(40))
            }
            value.summary = String(summary.prefix(220)); value.revision += 1
            try save(value); try bump(value.sourceID)
        }
    }

    /// This command boundary is called on the existing processing worker. No database value crosses await.
    func enrichment(_ command: ContentEnrichmentCommand) throws -> ContentEnrichmentReply {
        switch command {
        case let .segments(id,offset): return .segments(try segments(sourceID:id,limit:16,offset:offset))
        case let .spans(id,offset): return .spans(try processing.spans(sourceID:id,limit:16,offset:offset))
        case let .segmentSpans(id,offset): return .spans(try spans(segmentID:id,limit:16,offset:offset))
        case let .candidate(id,leftStart,position): return .candidate(try topicCandidate(id,leftStart:leftStart,position:position))
        case let .context(snapshot):
            _ = try checkedEnrichment(snapshot)
            return .text(try enrichmentContext(snapshot))
        case let .cached(key,unit):
            guard let row=try db.query("SELECT text,segment_id,accepted_revision FROM content_enrichment_checkpoints WHERE cache_key=? AND unit=?",[.text(key),.text(unit)]).first else { return .text(nil) }
            if unit == "complete" {
                // History proves completed inference, not that its output is still installed. A -> B -> A
                // may retain the ID/content key while reconciliation clears current title and summary.
                guard let id=row["segment_id"]?.string.flatMap(UUID.init(uuidString:)),
                      let current=try segment(id:id), current.revision == (try row.requiredInt("accepted_revision")) else { return .text(nil) }
            }
            return .text(row["text"]?.string)
        case let .checkpoint(snapshot,key,unit,text,context):
            try db.transaction {
                _ = try checkedEnrichment(snapshot)
                if let context, try enrichmentContext(snapshot) != context { throw ContentSegmentError.staleRevision }
                try checkpoint(snapshot,key:key,unit:unit,text:String(text.prefix(220)),revision:nil)
            }
        case let .complete(snapshot,key,title,summary,context):
            try completeEnrichment(snapshot,key:key,title:title,summary:summary,context:context,overwriteManualTitle:false)
        case let .completeTogether(snapshot,key,title,summary,context):
            try completeEnrichment(snapshot,key:key,title:title,summary:summary,context:context,overwriteManualTitle:true)
        case let .field(snapshot,field,value,context):
            _ = try applyGeneratedField(snapshot,field:field,value:value,context:context)
        case let .topic(candidate,decision,key):
            try applyTopic(candidate,decision:decision,key:key)
            try preparePresentations(sourceID:candidate.left.sourceID)
        case let .classification(snapshot,classification,model,engineVersion,evidenceID):
            return .segment(try applyClassification(snapshot,classification:classification,model:model,engineVersion:engineVersion,evidenceID:evidenceID))
        case let .finalizeTopics(sourceID,expectedSourceRevision):
            try finalizeTopicPass(sourceID,expectedSourceRevision:expectedSourceRevision)
        }
        return .accepted
    }
    private func completeEnrichment(_ snapshot: ContentSegment, key: String, title: String, summary: String, context: String?, overwriteManualTitle: Bool) throws {
        try db.transaction {
            _ = try checkedEnrichment(snapshot)
            if let context, try enrichmentContext(snapshot) != context { throw ContentSegmentError.staleRevision }
            try applyEnrichment(id:snapshot.id,expectedRevision:snapshot.revision,sourceRevision:snapshot.sourceRevision,
                title:title,summary:summary,overwriteManualTitle:overwriteManualTitle)
            // Completion and the exact revision it produced commit atomically with title/summary.
            try checkpoint(snapshot,key:key,unit:"complete",text:"",revision:snapshot.revision+1)
        }
    }
    private func applyClassification(_ snapshot: ContentSegment, classification: String, model: String, engineVersion: String, evidenceID: String) throws -> ContentSegment {
        try db.transaction {
            var value=try checkedEnrichment(snapshot)
            guard value.isFinal,value.hasText,
                  ContentSegmentClassification(rawValue:classification) != nil,
                  evidenceID == AudioStableID.make([value.id.uuidString,value.provenance.contentSignature,"segment-transcript"]) else { throw ContentSegmentError.invalidEdit }
            let editorial=ContentSegmentEditorial(classification:classification,engineVersion:engineVersion,model:model,evidenceBlockIDs:[evidenceID])
            if value.editorial != editorial {
                value.editorial=editorial
                value.revision += 1
                try save(value); try bump(value.sourceID)
            }
            return value
        }
    }
    private func applyGeneratedField(_ snapshot: ContentSegment, field: ContentEnrichmentField, value: String, context: String) throws -> ContentSegment {
        try db.transaction {
            var current=try checkedEnrichment(snapshot)
            guard current.isFinal,current.hasText,try enrichmentContext(snapshot) == context else { throw ContentSegmentError.staleRevision }
            let cleaned=String(value.trimmingCharacters(in:.whitespacesAndNewlines).prefix(field == .title ? 40 : 220))
            guard !cleaned.isEmpty else { throw ContentSegmentError.invalidEdit }
            if field == .title {
                current.title=cleaned
                current.titleManuallyEdited=false
            } else { current.summary=cleaned }
            current.revision += 1
            try save(current); try bump(current.sourceID)
            return current
        }
    }
    private func finalizeTopicPass(_ sourceID: AudioSourceID, expectedSourceRevision: Int) throws {
        try db.transaction {
            guard try source(sourceID) != nil else { throw AudioProcessingError.deletedSource }
            guard try processing.progress(sourceID:sourceID).revision == expectedSourceRevision else { throw ContentSegmentError.staleRevision }
            var changed = false
            for var value in try allSegments(sourceID) where value.sourceRevision == expectedSourceRevision {
                guard !value.isFinal, value.boundaryReady == true else { continue }
                value.isFinal = true
                value.revision += 1
                try save(value)
                changed = true
            }
            guard try allSegments(sourceID).allSatisfy({ $0.sourceRevision == expectedSourceRevision }) else { throw ContentSegmentError.staleRevision }
            if changed { try bump(sourceID) }
        }
    }
    private func checkedEnrichment(_ snapshot: ContentSegment) throws -> ContentSegment {
        let current = try checked(snapshot.id,snapshot.revision)
        let progress = try processing.progress(sourceID:current.sourceID)
        guard current.sourceRevision == snapshot.sourceRevision, progress.revision == snapshot.sourceRevision,
              current.provenance == snapshot.provenance, progress.configurationKey == snapshot.provenance.configurationKey else { throw ContentSegmentError.staleRevision }
        return current
    }
    private func checkpoint(_ value: ContentSegment, key: String, unit: String, text: String, revision: Int?) throws {
        try db.execute("INSERT INTO content_enrichment_checkpoints(cache_key,unit,source_key,segment_id,text,accepted_revision) VALUES (?,?,?,?,?,?) ON CONFLICT(cache_key,unit) DO UPDATE SET text=excluded.text,accepted_revision=excluded.accepted_revision",[.text(key),.text(unit),.text(value.sourceID.key),.text(value.id.uuidString),.text(text),revision.map { .integer(Int64($0)) } ?? .null])
    }
    private func topicCandidate(_ id: AudioSourceID, leftStart: Double, position: Double) throws -> ContentTopicCandidate? {
        guard let descriptor=try source(id), position.isFinite, leftStart < position else { return nil }
        let all=try allSegments(id)
        guard let left=all.first(where:{ $0.ranges.contains { leftStart >= $0.sessionStartOffset && leftStart < $0.end } }),
              let right=all.first(where:{ $0.ranges.contains { position >= $0.sessionStartOffset && position < $0.end } }),
              !left.isFinal, !right.isFinal, left.boundaryReady == true, right.boundaryReady == true,
              !left.isManual, !right.isManual, left.hasText, right.hasText,
              left.provenance.configurationKey == right.provenance.configurationKey else { return nil }
        if left.id != right.id {
            guard let end=left.ranges.last?.end, let start=right.ranges.first?.sessionStartOffset,
                  abs(end-start) < 0.0000001, abs(start-position) < 0.0000001,
                  let li=all.firstIndex(where:{ $0.id == left.id }), let ri=all.firstIndex(where:{ $0.id == right.id }), ri == li+1,
                  right.ranges.last!.end-left.ranges.first!.sessionStartOffset <= 2400 else { return nil }
        } else {
            // Compatibility for persisted pre-chapter decisions. Automatic orchestration
            // submits only adjacent chapter boundaries, never arbitrary transcript pauses.
            let neighbors=try db.query("SELECT t.start,t.end FROM audio_transcript_spans t JOIN audio_processing_jobs j ON j.id=t.job_id JOIN audio_processing_sources s ON s.source_key=j.source_key WHERE j.source_key=? AND j.active=1 AND j.configuration_key=s.configuration_key AND j.result IS NOT NULL AND t.start<=? ORDER BY t.start DESC,t.end DESC LIMIT 2",[.text(id.key),.real(position)])
            guard neighbors.count == 2, try neighbors[0].requiredDouble("start") == position,
                  position - (try neighbors[1].requiredDouble("end")) >= 1,
                  position - (try neighbors[1].requiredDouble("end")) < 180 else { return nil }
        }
        let a=left.ranges.first!.sessionStartOffset, b=right.ranges.last!.end
        let interval=descriptor.ranges.filter { $0.end > a && $0.sessionStartOffset < b }
        guard !interval.isEmpty else { return nil }
        for (index,range) in interval.enumerated() where index > 0 {
            guard range.discontinuityBefore == nil, abs(interval[index-1].end-range.sessionStartOffset) < 0.0000001 else { return nil }
        }
        // Missing/failed inference may produce pending chapters, never permission to join.
        var covered: [AudioTimeRange] = []
        for row in try jobRows(sourceID:id,columns:"j.result") where row["result"] != .null {
            let result=try DaybookDatabase.decode(AudioWindowResult.self,row["result"])
            if result.asr == .success && result.vad == .success {
                covered += ContentSegmentation.intersect(ContentSegmentation.normalized(result.asrCoverage),ContentSegmentation.normalized(result.vadCoverage))
            }
        }
        guard ContentSegmentation.covers(ContentSegmentation.normalized(covered),start:a,end:b) else { return nil }
        guard let signature=try db.query("SELECT signature FROM content_segment_sources WHERE source_key=?",[.text(id.key)]).first?["signature"]?.string else { return nil }
        let lc=try enrichmentContext(left), rc=try enrichmentContext(right)
        let context="Evidence digest: "+AudioStableID.make([lc,rc])+"\n"+String(lc.prefix(520))+"\n"+String(rc.prefix(520))
        return .init(left:left,right:right,position:position,sourceSignature:signature,context:String(context.prefix(1200)),leftExcerpt:try topicExcerpt(id,start:a,end:position,backwards:true),rightExcerpt:try topicExcerpt(id,start:position,end:b,backwards:false))
    }
    private func topicExcerpt(_ id: AudioSourceID, start: Double, end: Double, backwards: Bool) throws -> String {
        var text="", offset=0
        let bounds=backwards ? "t.end>? AND t.end<=?" : "t.start>=? AND t.start<?"
        let order=backwards ? "t.end DESC,t.start DESC,j.id,t.position DESC" : "t.start,t.end,j.id,t.position"
        while text.count < 650 {
            let rows=try db.query("SELECT t.text FROM audio_transcript_spans t JOIN audio_processing_jobs j ON j.id=t.job_id JOIN audio_processing_sources s ON s.source_key=j.source_key WHERE j.source_key=? AND j.active=1 AND j.configuration_key=s.configuration_key AND j.result IS NOT NULL AND \(bounds) AND length(trim(t.text))>0 ORDER BY \(order) LIMIT 64 OFFSET ?",[.text(id.key),.real(start),.real(end),.integer(Int64(offset))])
            for row in rows {
                let value=row["text"]?.string ?? ""
                text=backwards ? String((value+(text.isEmpty ? "" : "\n"+text)).suffix(650)) : String((text+(text.isEmpty ? "" : "\n")+value).prefix(650))
                if text.count == 650 { return text }
            }
            offset += rows.count
            if rows.count < 64 { break }
        }
        return text
    }

    /// Context is derived independently from ASR identity. Late observations invalidate
    /// text checkpoints and leases without scheduling audio inference again.
    private func enrichmentContext(_ segment: ContentSegment) throws -> String {
        guard let source=try source(segment.sourceID) else { throw AudioProcessingError.deletedSource }
        let formatter=DateFormatter()
        formatter.locale=Locale(identifier:"en_US_POSIX"); formatter.timeZone=TimeZone.current
        formatter.dateFormat="yyyy-MM-dd HH:mm:ss ZZZZZ"
        let times=segment.ranges.map { "\(formatter.string(from:source.capturedAt.addingTimeInterval($0.sessionStartOffset)))–\(formatter.string(from:source.capturedAt.addingTimeInterval($0.end)))" }.joined(separator:"; ")
        var observations: [String] = [], payloads: [String] = []
        func describe(_ location: CaptureLocation, label: String) -> String {
            let measured=location.measuredAt.map { formatter.string(from:$0) } ?? "unknown"
            let accuracy=location.accuracy.map { String(format:"%.1fm",$0) } ?? "unknown"
            let address=location.address.map { " cached address="+String($0.text.prefix(100)) } ?? ""
            return "\(label): observed \(location.title), fix=\(measured), accuracy=\(accuracy), device=\(location.source.rawValue)\(address)"
        }
        if let location=source.location { observations.append(describe(location,label:"Source-start point only")); payloads.append(AudioStableID.make(location)) }
        if source.id.kind == .session {
            let hasAddressCache = !(try db.query("SELECT name FROM sqlite_master WHERE type='table' AND name='recording_location_addresses'")).isEmpty
            let sql = hasAddressCache ? "SELECT s.payload,a.payload AS address_payload FROM recording_location_samples s LEFT JOIN recording_location_addresses a ON a.sample_id=s.id WHERE s.session_id=? ORDER BY s.session_offset,s.id" : "SELECT payload FROM recording_location_samples WHERE session_id=? ORDER BY session_offset,id"
            let rows=try db.query(sql,[.text(source.id.id.uuidString)])
            for row in rows {
                let sample=try DaybookDatabase.decode(RecordingLocationSample.self,row["payload"])
                guard segment.ranges.contains(where:{ sample.sessionOffset >= $0.sessionStartOffset && sample.sessionOffset <= $0.end }) else { continue }
                payloads.append(AudioStableID.make(sample))
                var location=sample.location
                if let payload=row["address_payload"], payload != .null {
                    let address=try DaybookDatabase.decode(CaptureAddress.self,payload)
                    location.address=address; payloads.append(AudioStableID.make(address))
                }
                observations.append(describe(location,label:"Sample +\(Int(sample.sessionOffset))s, device=\(sample.sourceDevice), requested=\(formatter.string(from:sample.requestedAt))"))
            }
        }
        let digest=AudioStableID.make([AudioStableID.make(segment.ranges.map(\.contentIdentity)),AudioStableID.make(payloads),String(source.capturedAt.timeIntervalSince1970),TimeZone.current.identifier])
        let header="Evidence digest: "+digest+"\nLocal source ranges: "+String(times.prefix(300))+"\nSparse observations only; do not infer a route, home, company, airport or unsampled venue.\n"
        // Keep first/central/latest observations while the digest covers every input.
        let selected=observations.count <= 3 ? observations : [observations[0],observations[observations.count/2],observations.last!]
        return String((header+(selected.isEmpty ? "No sampled place evidence." : selected.map { String($0.prefix(220)) }.joined(separator:"\n"))).prefix(1200))
    }
    func enrichmentContextForAuthorization(segmentID: UUID) throws -> String? {
        guard let value=try segment(id:segmentID),value.isFinal,value.hasText else { return nil }
        return try enrichmentContext(value)
    }
    private func applyTopic(_ candidate: ContentTopicCandidate, decision: ContentTopicDecision, key: String) throws {
        try db.transaction {
            _ = try checkedEnrichment(candidate.left)
            _ = try checkedEnrichment(candidate.right)
            // Re-read all exclusions and source signature after inference; an advisory timestamp alone has no authority.
            guard let first=candidate.left.ranges.first?.sessionStartOffset,
                  let valid=try topicCandidate(candidate.left.sourceID,leftStart:first,position:candidate.position),
                  valid.sourceSignature == candidate.sourceSignature, valid.context == candidate.context, valid.left.id == candidate.left.id, valid.right.id == candidate.right.id else { throw ContentSegmentError.staleRevision }
            let id=candidate.left.sourceID
            if decision == .newTopic && candidate.left.id == candidate.right.id {
                let original=candidate.left
                let parts=try ContentSegmentation.applyingTopicCuts([candidate.position],to:[.init(ranges:original.ranges,boundaryReady:original.boundaryReady == true)])
                guard parts.count == 2 else { throw ContentSegmentError.invalidEdit }
                try tombstone(original)
                for part in parts { try saveAutomatic(part,sourceID:id,sourceRevision:original.sourceRevision,key:original.provenance.configurationKey) }
                try bump(id)
            } else if decision == .sameTopic && candidate.left.id != candidate.right.id {
                try tombstone(candidate.left); try tombstone(candidate.right)
                try saveAutomatic(.init(ranges:candidate.left.ranges+candidate.right.ranges,boundaryReady:candidate.left.boundaryReady == true && candidate.right.boundaryReady == true),sourceID:id,sourceRevision:candidate.left.sourceRevision,key:candidate.left.provenance.configurationKey,id:candidate.left.id,revision:max(candidate.left.revision,candidate.right.revision)+1)
                try bump(id)
            }
            // Uncertain keeps an already accepted cut intact; no output can erase a hard/manual boundary.
            // `uncertain` is a terminal conservative keep-boundary outcome, not a retry loop.
            try db.execute("INSERT INTO content_topic_decisions(source_key,signature,position,decision,model_key) VALUES (?,?,?,?,?) ON CONFLICT(source_key,signature,position) DO UPDATE SET decision=excluded.decision,model_key=excluded.model_key",[.text(id.key),.text(candidate.sourceSignature),.real(candidate.position),.text(decision.rawValue),.text(key)])
            try checkpoint(candidate.left,key:key,unit:"topic",text:decision.rawValue,revision:candidate.left.revision)
        }
    }
    private func saveAutomatic(_ draft: ContentSegmentDraft, sourceID: AudioSourceID, sourceRevision: Int, key: String, id: UUID = UUID(), revision: Int = 1) throws {
        let content=try contentSignature(sourceID,ranges:draft.ranges,key:key)
        try save(.init(id:id,sourceID:sourceID,sourceRevision:sourceRevision,ranges:draft.ranges,title:"",summary:"",revision:revision,isManual:false,isFinal:false,boundaryReady:draft.boundaryReady,hasText:content.hasText,provenance:.init(algorithmVersion:Self.algorithmVersion,configurationKey:key,contentSignature:content.signature)))
    }

    private struct EditSnapshot: Codable {
        let segments: [ContentSegment]
        let suppression: [AudioTimeRange]
        // Optional for pre-fix history: missing evidence conservatively forbids chain reconnection.
        let beforeEpoch: Int?
    }
    private func edit<T>(_ sourceID: AudioSourceID, kind: String, _ mutation: () throws -> T) throws -> T {
        let snapshot = EditSnapshot(segments:try allSegments(sourceID),suppression:try suppression(sourceID),beforeEpoch:try epoch(sourceID))
        let value = try mutation()
        try bump(sourceID)
        try db.execute("INSERT INTO content_segment_edits(source_key,kind,before_payload,after_epoch) VALUES (?,?,?,?)",[.text(sourceID.key),.text(kind),try DaybookDatabase.json(snapshot),.integer(Int64(try epoch(sourceID)))])
        return value
    }
    private func checked(_ id: UUID, _ revision: Int) throws -> ContentSegment {
        guard let value = try segment(id:id) else { throw ContentSegmentError.notFound }
        guard value.revision == revision else { throw ContentSegmentError.staleRevision }
        return value
    }
    private func source(_ id: AudioSourceID) throws -> AudioSourceSnapshot? {
        guard try db.query("SELECT source_key FROM audio_source_tombstones WHERE source_key=?",[.text(id.key)]).isEmpty else { return nil }
        if id.kind == .session {
            guard try db.query("SELECT session_id FROM recording_session_tombstones WHERE session_id=?",[.text(id.id.uuidString)]).isEmpty else { return nil }
        } else {
            guard try db.query("SELECT id FROM media_tombstones WHERE kind='voice' AND id=?",[.text(id.id.uuidString)]).isEmpty else { return nil }
        }
        return try processing.currentSource(id)
    }
    private func allSegments(_ id: AudioSourceID) throws -> [ContentSegment] {
        try db.query("SELECT payload FROM content_segments WHERE source_key=? AND deleted=0 ORDER BY start,id",[.text(id.key)]).map { try DaybookDatabase.decode(ContentSegment.self,$0["payload"]) }
    }
    private func save(_ value: ContentSegment) throws {
        try db.execute("INSERT INTO content_segments(id,source_key,start,revision,deleted,payload) VALUES (?,?,?,?,0,?) ON CONFLICT(id) DO UPDATE SET start=excluded.start,revision=excluded.revision,deleted=0,payload=excluded.payload",[.text(value.id.uuidString),.text(value.sourceID.key),.real(value.ranges[0].sessionStartOffset),.integer(Int64(value.revision)),try DaybookDatabase.json(value)])
        try db.execute("DELETE FROM content_segment_ranges WHERE segment_id=?",[.text(value.id.uuidString)])
        for (position,range) in value.ranges.enumerated() {
            try db.execute("INSERT INTO content_segment_ranges(segment_id,position,start,end,payload) VALUES (?,?,?,?,?)",[.text(value.id.uuidString),.integer(Int64(position)),.real(range.sessionStartOffset),.real(range.end),try DaybookDatabase.json(range)])
        }
    }
    private func tombstone(_ value: ContentSegment) throws {
        try db.execute("UPDATE content_segments SET deleted=1,revision=revision+1 WHERE id=?",[.text(value.id.uuidString)])
        try db.execute("INSERT INTO content_segment_tombstones(id,source_key,revision) VALUES (?,?,?) ON CONFLICT(id) DO UPDATE SET revision=max(revision,excluded.revision)",[.text(value.id.uuidString),.text(value.sourceID.key),.integer(Int64(value.revision+1))])
    }
    private func suppression(_ id: AudioSourceID) throws -> [AudioTimeRange] {
        ContentSegmentation.normalized(try db.query("SELECT start,end FROM content_segment_suppression WHERE source_key=? ORDER BY start",[.text(id.key)]).map { .init(start:try $0.requiredDouble("start"),end:try $0.requiredDouble("end")) })
    }
    private func suppress(_ value: ContentSegment) throws {
        for range in value.ranges { try addSuppression(value.sourceID,.init(start:range.sessionStartOffset,end:range.end)) }
    }
    private func addSuppression(_ id: AudioSourceID, _ range: AudioTimeRange) throws {
        try db.execute("INSERT INTO content_segment_suppression(source_key,start,end) VALUES (?,?,?)",[.text(id.key),.real(range.start),.real(range.end)])
    }
    private func epoch(_ id: AudioSourceID) throws -> Int {
        try db.query("SELECT epoch FROM content_segment_sources WHERE source_key=?",[.text(id.key)]).first?.requiredInt("epoch") ?? 0
    }
    private func bump(_ id: AudioSourceID) throws {
        try db.execute("UPDATE content_segment_sources SET epoch=epoch+1 WHERE source_key=?",[.text(id.key)])
    }
    private func upgradedContentIdentity(_ original: ContentSegment) throws -> ContentSegment {
        guard original.provenance.semanticContentSignature == nil else { return original }
        let content = try contentSignature(original.sourceID,ranges:original.ranges,key:original.provenance.configurationKey)
        guard original.provenance.contentSignature == content.signature || original.provenance.contentSignature == content.legacySignature else { return original }
        var value = original
        value.provenance.semanticContentSignature = content.signature
        return value
    }
    private func jobRows(sourceID: AudioSourceID, columns: String) throws -> [DaybookDatabase.Row] {
        try db.query("SELECT \(columns) FROM audio_processing_jobs j JOIN audio_processing_sources s ON s.source_key=j.source_key WHERE j.source_key=? AND j.active=1 AND j.configuration_key=s.configuration_key ORDER BY j.core_start,j.id",[.text(sourceID.key)])
    }
    private func contentSignature(_ id: AudioSourceID, ranges: [AudioSourceRange], key: String) throws -> (signature:String,legacySignature:String,hasText:Bool) {
        // Hash actual transcript rows in bounded pages; include source time so repeated words survive.
        var digest = SHA256(), hasText = false
        for range in ranges {
            var offset = 0
            while true {
                let page = try processing.spans(sourceID:id,overlapping:.init(start:range.sessionStartOffset,end:range.end),limit:pageSize,offset:offset)
                traversal.spanRows += page.count
                traversal.maximumPageRows = max(traversal.maximumPageRows,page.count)
                for span in page { digest.update(data:Data(AudioStableID.make(span).utf8)); hasText = hasText || !span.text.isEmpty }
                offset += page.count
                if page.count < pageSize { break }
            }
        }
        let textHash = digest.finalize().map { String(format:"%02x",$0) }.joined()
        return (AudioStableID.make([key,AudioStableID.make(ranges.map(\.contentIdentity)),textHash]),AudioStableID.make([key,AudioStableID.make(ranges),textHash]),hasText)
    }
    private func validatePage(_ limit: Int, _ offset: Int) throws {
        guard limit > 0, limit <= 1000, offset >= 0 else { throw AudioProcessingError.invalidInput }
    }
}
