import Foundation
import SQLite3

@main struct ContentSegmentPresentationSmoke {
    final class RawReadProbe {
        var reads = 0
        func install(_ db: DaybookDatabase) throws {
            _ = try db.withConnection { handle in
                sqlite3_trace_v2(handle, UInt32(SQLITE_TRACE_STMT), { _, context, statement, _ in
                    guard let context, let statement, let sql = sqlite3_sql(OpaquePointer(statement)) else { return 0 }
                    if String(cString: sql).contains("FROM audio_transcript_spans") {
                        Unmanaged<RawReadProbe>.fromOpaque(context).takeUnretainedValue().reads += 1
                    }
                    return 0
                }, Unmanaged.passUnretained(self).toOpaque())
            }
        }
        func remove(_ db: DaybookDatabase) throws { _ = try db.withConnection { sqlite3_trace_v2($0, 0, nil, nil) } }
    }
    @MainActor static func main() async throws {
        let fieldSource = AudioSourceID(kind:.session,id:UUID())
        func fieldSegment(_ classification:String?,title:String,summary:String,hasText:Bool = true,isFinal:Bool = true) -> ContentSegment {
            var segment=ContentSegment(id:UUID(),sourceID:fieldSource,sourceRevision:1,ranges:[],title:title,summary:summary,
                revision:1,isManual:false,isFinal:isFinal,boundaryReady:true,hasText:hasText,
                provenance:.init(algorithmVersion:"test",configurationKey:"test",contentSignature:UUID().uuidString))
            if let classification { segment.editorial = .init(classification:classification,engineVersion:"test",model:"test",evidenceBlockIDs:[]) }
            return segment
        }
        let fieldSegments=(0..<4).map { _ in fieldSegment("meaningful",title:"标题",summary:"摘要") } +
            (0..<3).map { _ in fieldSegment("lowInformation",title:"",summary:"") } +
            [fieldSegment(nil,title:"",summary:""),fieldSegment("meaningful",title:"",summary:"",hasText:false),
             fieldSegment("meaningful",title:"",summary:"",isFinal:false)]
        let fieldCounts=ContentSegmentPresentation.fieldGenerationCounts(fieldSegments)
        precondition(fieldCounts.eligible == 5 && fieldCounts.complete == 4,
            "title/summary progress must exclude low-information, empty-text, and non-final segments while including unclassified short recordings")

        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(secondsFromGMT: 0)!
        let day = cal.startOfDay(for: Date(timeIntervalSince1970: 1_700_000_000))
        let origin = day.addingTimeInterval(86_390), id = UUID(), parentID = UUID()
        var child = DayRecord(id:id,capturedAt:origin,kind:.voice,title:"whole title",text:"yesterday tomorrow",summary:"whole summary",duration:30,intervals:[DateInterval(start:origin,duration:30)])
        child.contentProvenance = .init(segmentID:id,sourceID:parentID,sourceKind:"session",sourceRevision:4,segmentRevision:2,configurationKey:"v1",contentSignature:"sig",sourceDate:origin,ranges:[.init(chunkID:UUID(),startFrame:0,endFrame:300,sampleRate:10,sourceOffset:0)],transcript:[.init(start:0,end:5,text:"yesterday"),.init(start:5,end:15,text:"before midnight / after midnight"),.init(start:15,end:20,text:"tomorrow")])
        var confirmedJSON = try JSONSerialization.jsonObject(with:JSONEncoder().encode(child)) as! [String:Any]
        var confirmedProvenance = confirmedJSON["contentProvenance"] as! [String:Any]
        confirmedProvenance["isFinal"] = true; confirmedProvenance["classification"] = "meaningful"
        confirmedJSON["contentProvenance"] = confirmedProvenance
        child = try JSONDecoder().decode(DayRecord.self,from:JSONSerialization.data(withJSONObject:confirmedJSON))
        let first = child.recordingProjection(on:day,calendar:cal)!
        let second = child.recordingProjection(on:day.addingTimeInterval(86400),calendar:cal)!
        precondition(first.id == second.id && first.duration == 10 && second.duration == 20,"same identity, daily audio")
        precondition(first.text == "yesterday" && second.text == "tomorrow" && first.summary.isEmpty,"day grounded original and summary")
        precondition(first.contentProvenance?.ranges.first?.endFrame == 100 && second.contentProvenance?.ranges.first?.startFrame == 100,"exact clipped frames")
        // Fractional audio durations are not exactly representable at absolute Date
        // magnitudes. A whole in-day segment must not lose its generated description.
        let fractionalOrigin=day.addingTimeInterval(123.12137)
        let fractionalDuration=1059.4
        var fractional=DayRecord(id:UUID(),capturedAt:fractionalOrigin,kind:.voice,title:"specific event",text:"full transcript",summary:"saved summary",duration:fractionalDuration,intervals:[DateInterval(start:fractionalOrigin,duration:fractionalDuration)])
        fractional.contentProvenance = .init(segmentID:fractional.id,sourceID:UUID(),sourceKind:"legacyNote",sourceRevision:1,segmentRevision:1,configurationKey:"test",contentSignature:"fractional",sourceDate:fractionalOrigin,ranges:[.init(chunkID:UUID(),startFrame:0,endFrame:16950400,sampleRate:16000,sourceOffset:0)],transcript:[.init(start:0,end:fractionalDuration,text:"full transcript")])
        let fractionalDay=fractional.recordingProjection(on:day,calendar:cal)!
        precondition(fractionalDay.title == fractional.title && fractionalDay.summary == fractional.summary && fractionalDay.duration == fractionalDuration && fractionalDay.text == fractional.text,"same-day fractional audio preserves generated title, summary, duration and full transcript")
        let fractionalRepeat=fractionalDay.recordingProjection(on:day,calendar:cal)!
        precondition(fractionalRepeat == fractionalDay,"same-day projection is stable across repeated reads")
        var offsetFractional=fractional
        offsetFractional.capturedAt=fractionalOrigin.addingTimeInterval(0.3)
        offsetFractional.intervals=[DateInterval(start:offsetFractional.capturedAt,duration:0.6)]
        offsetFractional.contentProvenance?.ranges=[.init(chunkID:UUID(),startFrame:300,endFrame:900,sampleRate:1000,sourceOffset:0.3)]
        offsetFractional.contentProvenance?.transcript=[.init(start:0.4,end:0.9,text:"final punctuation。")]
        precondition(offsetFractional.recordingProjection(on:day,calendar:cal)?.text == "final punctuation。","fractional source offset preserves transcript exactly ending at the audio boundary")
        var parent = DayRecord(id:parentID,capturedAt:origin,kind:.voice,title:"parent",text:"parent secret",duration:3600,intervals:[DateInterval(start:origin,duration:3600)])
        parent.recordingSessionID = parentID
        let scope = DateInterval(start:day,duration:86400)
        let records = DayRecord.evidenceRecords([parent,child],scope:scope)
        precondition(records.count == 1 && records.first?.id == id,"children replace parents")
        let rawOnly = DaybookRetrieval.originalRecordingRecords(query:"",records:[parent,child],dayStart:day,dayEnd:day.addingTimeInterval(86400))
        precondition(rawOnly.map(\.id) == [parentID],"original recording filter includes complete parent audio only")
        precondition(rawOnly.first?.duration == 3600,"original recording list preserves the full long recording duration")
        let rawSearch = DaybookRetrieval.originalRecordingRecords(query:"parent secret",records:[parent,child],dayStart:day,dayEnd:day.addingTimeInterval(86400))
        precondition(rawSearch.map(\.id) == [parentID],"original recording search stays within raw full recordings")
        var tomorrowChild = child
        tomorrowChild.intervals = [DateInterval(start:day.addingTimeInterval(86400),duration:20)]
        let fallback = DayRecord.evidenceRecords([parent,tomorrowChild],scope:scope)
        precondition(fallback.map(\.id) == [parentID],"out of scope child must preserve parent fallback")
        var blank = child; blank.text = " \n "; blank.summary = ""; blank.title = "录音片段"
        let thought = DayRecord(id:UUID(),capturedAt:origin,kind:.thought,title:"闪念",text:"Keep flash thoughts")
        precondition(ContentSegmentPresentation.timelineRecords([parent,child,blank,thought]).map(\.id) == [child.id,thought.id],"timeline shows meaningful segments and thoughts, never raw long audio or blank segments")
        precondition(ContentSegmentPresentation.timelineRecords([parent]).isEmpty,"pending processing never falls back to a raw timeline recording")
        confirmedProvenance["isFinal"] = false; confirmedProvenance["classification"] = "meaningful"
        confirmedJSON["contentProvenance"] = confirmedProvenance
        let nonFinal = try JSONDecoder().decode(DayRecord.self,from:JSONSerialization.data(withJSONObject:confirmedJSON))
        precondition(ContentSegmentPresentation.timelineRecords([nonFinal]).isEmpty,"covered but nonfinal segment stays off the timeline")
        confirmedProvenance["isFinal"] = true; confirmedProvenance.removeValue(forKey:"classification")
        confirmedJSON["contentProvenance"] = confirmedProvenance
        let unclassified = try JSONDecoder().decode(DayRecord.self,from:JSONSerialization.data(withJSONObject:confirmedJSON))
        precondition(ContentSegmentPresentation.timelineRecords([unclassified]).isEmpty,"legacy segment without persisted classification stays off the timeline")
        // Nonempty navigation fragments must obey the saved editorial classification.
        // Decode a payload as older databases do; dropping this field must reveal the bug.
        var classifiedJSON = try JSONSerialization.jsonObject(with: JSONEncoder().encode(child)) as! [String:Any]
        var classifiedProvenance = classifiedJSON["contentProvenance"] as! [String:Any]
        classifiedProvenance["classification"] = "lowInformation"
        classifiedJSON["contentProvenance"] = classifiedProvenance
        let lowInformation = try JSONDecoder().decode(DayRecord.self, from: JSONSerialization.data(withJSONObject:classifiedJSON))
        precondition(ContentSegmentPresentation.timelineRecords([lowInformation,thought]).map(\.id) == [thought.id],"persisted low-information text stays in the library, outside the timeline")
        classifiedProvenance["classification"] = "pendingConfirmation"
        classifiedJSON["contentProvenance"] = classifiedProvenance
        let pendingConfirmation = try JSONDecoder().decode(DayRecord.self, from: JSONSerialization.data(withJSONObject:classifiedJSON))
        precondition(ContentSegmentPresentation.timelineRecords([pendingConfirmation]).isEmpty,"uncertain classification must not masquerade as meaningful")
        let prepared = try DaybookRetrieval(calendar:cal).prepare(question:"有哪些录音",records:[parent,child],selectedDate:day)
        precondition(prepared.statistics.audioDuration == 10 && prepared.statistics.totalCount == 1,"statistics count child only")
        let answer = try DaybookRetrieval(calendar:cal).prepare(question:"yesterday",records:[parent,child],selectedDate:day)
        precondition(answer.sources.first?.provenance?.segmentID == id && answer.sources.first?.provenance?.ranges.first?.endFrame == 100,"citation carries local real ranges")
        precondition(!answer.context.contains("tomorrow") && !answer.context.contains("file:"),"no other day or URL in prompt")
        precondition(!answer.isCurrent(records:[parent],allowedKinds:[.voice,.thought,.image]),"deleted child invalidates evidence")
        var revised = child; revised.contentProvenance?.segmentRevision += 1
        precondition(!answer.isCurrent(records:[parent,revised],allowedKinds:[.voice,.thought,.image]),"revision invalidates evidence")
        let combined = DayRecord.evidenceRecords([child],scope:DateInterval(start:day,duration:172800))
        precondition(combined.count == 1 && combined[0].text.contains("tomorrow") && combined[0].text.contains("before midnight / after midnight"),"multi day combined unique row")
        let chunkA = DayRecord.ContentProvenance.AudioRange(chunkID:UUID(),startFrame:0,endFrame:3000,sampleRate:10,sourceOffset:0)
        let chunkB = DayRecord.ContentProvenance.AudioRange(chunkID:UUID(),startFrame:0,endFrame:3000,sampleRate:10,sourceOffset:300)
        var crossingChunks = DayRecord(id:UUID(),capturedAt:day,kind:.voice,title:"contiguous",text:"chunk boundary speech",duration:600,intervals:[DateInterval(start:day,duration:600)])
        crossingChunks.contentProvenance = .init(segmentID:crossingChunks.id,sourceID:UUID(),sourceKind:"session",sourceRevision:1,segmentRevision:1,configurationKey:"v1",contentSignature:"contiguous",sourceDate:day,ranges:[chunkB,chunkA],transcript:[.init(start:299,end:301,text:"chunk boundary speech")])
        let sameDayChunks = crossingChunks.recordingProjection(on:day,calendar:cal)!
        let combinedChunks = crossingChunks.recordingProjection(from:day,to:day.addingTimeInterval(172800))!
        precondition(sameDayChunks.text == "chunk boundary speech" && combinedChunks.text == "chunk boundary speech","continuous union preserves speech crossing physical chunk boundary")
        var crossingGap = crossingChunks
        crossingGap.contentProvenance?.ranges = [chunkA,.init(chunkID:chunkB.chunkID,startFrame:0,endFrame:2990,sampleRate:10,sourceOffset:301)]
        crossingGap.contentProvenance?.transcript = [.init(start:299,end:302,text:"must not bridge missing audio")]
        precondition(crossingGap.recordingProjection(on:day,calendar:cal)?.text.isEmpty == true,"continuous union must reject genuine audio gap")
        let midnightSource = day.addingTimeInterval(86100)
        var midnightChunks = crossingChunks
        midnightChunks.capturedAt = midnightSource
        midnightChunks.intervals = [DateInterval(start:midnightSource,duration:600)]
        midnightChunks.contentProvenance = .init(segmentID:crossingChunks.id,sourceID:UUID(),sourceKind:"session",sourceRevision:1,segmentRevision:1,configurationKey:"v1",contentSignature:"midnight-contiguous",sourceDate:midnightSource,ranges:[chunkA,chunkB],transcript:[.init(start:299,end:301,text:"before midnight / after midnight")])
        precondition(midnightChunks.recordingProjection(on:day,calendar:cal)?.text.isEmpty == true && midnightChunks.recordingProjection(on:day.addingTimeInterval(86400),calendar:cal)?.text.isEmpty == true,"continuous union cannot override strict date containment")
        precondition(midnightChunks.recordingProjection(from:day,to:day.addingTimeInterval(172800))?.text == "before midnight / after midnight","combined date scope keeps contiguous chunk boundary span")
        let gap = DayRecord.ContentProvenance.AudioRange(chunkID:UUID(),startFrame:500,endFrame:600,sampleRate:10,sourceOffset:100)
        let gapped = [child.contentProvenance!.ranges[0],gap]
        precondition(ContentSegmentPresentation.sourceTime(at:35,ranges:gapped) == 105,"compact time maps after gap")
        precondition(ContentSegmentPresentation.playbackTime(at:105,ranges:gapped) == 35,"citation source seek maps after gap")
        let old = try JSONSerialization.data(withJSONObject:["id":UUID().uuidString,"capturedAt":0,"kind":"voice","title":"old","text":"kept","summary":"","duration":0])
        let decoded = try JSONDecoder().decode(DayRecord.self,from:old)
        precondition(decoded.contentProvenance == nil,"old archives decode")
        let db = try DaybookDatabase(inMemory:true)
        let processing = AudioProcessingRepository(database:db)
        let sourceID = AudioSourceID(kind:.session,id:parentID)
        let audio = try AudioSourceRange(range:.init(chunkID:UUID(),url:URL(fileURLWithPath:"/nonexistent-fixture.wav"),startFrame:0,endFrame:300,sampleRate:10),contentHash:String(repeating:"a",count:64))
        let source = try AudioSourceSnapshot(id:sourceID,capturedAt:origin,title:"fixture",ranges:[audio],complete:true)
        try db.execute("INSERT INTO audio_processing_sources(source_key,kind,source_id,descriptor,fingerprint,configuration_key,revision) VALUES (?,?,?,?,?,?,?)",[.text(sourceID.key),.text("session"),.text(parentID.uuidString),try DaybookDatabase.json(source),.text(source.fingerprint),.text("v1"),.integer(1)])
        for _ in 0..<121 {
            let segment = ContentSegment(id:UUID(),sourceID:sourceID,sourceRevision:1,ranges:[audio],title:"fixture",summary:"",revision:1,isManual:false,isFinal:true,hasText:false,provenance:.init(algorithmVersion:"test",configurationKey:"v1",contentSignature:"signature"))
            try db.execute("INSERT INTO content_segments(id,source_key,start,revision,payload) VALUES (?,?,?,?,?)",[.text(segment.id.uuidString),.text(sourceID.key),.real(0),.integer(1),try DaybookDatabase.json(segment)])
            try db.execute("INSERT INTO content_segment_ranges(segment_id,position,start,end,payload) VALUES (?,0,0,30,?)",[.text(segment.id.uuidString),try DaybookDatabase.json(audio)])
        }
        let repository = ContentSegmentRepository(database:db)
        try repository.preparePresentations(sourceID:sourceID)
        let probe = RawReadProbe()
        try probe.install(db)
        let oldDateSnapshot = try ContentSegmentSnapshot.read(processing,scope:scope)
        try probe.remove(db)
        precondition(oldDateSnapshot.count == 121 && oldDateSnapshot.allSatisfy { $0.duration == 10 },"complete requested old day beyond UI and SQL page")
        precondition(probe.reads == 0,"timeline date reads must consume persisted content instead of rescanning raw ASR")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let notes = try NoteRepository(root:root,database:db)
        let legacyID = UUID(), incoming = root.appendingPathComponent("synthetic.m4a")
        try Data([1,2,3]).write(to:incoming)
        _ = try notes.importRecording(id:legacyID,from:incoming,kind:.long,capturedAt:origin,duration:30)
        let legacySourceID = AudioSourceID(kind:.legacyNote,id:legacyID)
        let legacySource = try AudioSourceSnapshot(id:legacySourceID,capturedAt:origin,title:"fixture",ranges:[audio],complete:true)
        try processing.register(source:legacySource,configurationKey:"v1",windows:AudioWindowPlanner.plan(source:legacySource,configurationKey:"v1"))
        let segment = ContentSegment(id:UUID(),sourceID:legacySourceID,sourceRevision:try processing.progress(sourceID:legacySourceID).revision,ranges:[audio],title:"fixture",summary:"",revision:1,isManual:false,isFinal:true,hasText:false,provenance:.init(algorithmVersion:"test",configurationKey:"v1",contentSignature:"signature"))
        try db.execute("INSERT INTO content_segments(id,source_key,start,revision,payload) VALUES (?,?,?,?,?)",[.text(segment.id.uuidString),.text(legacySourceID.key),.real(0),.integer(1),try DaybookDatabase.json(segment)])
        try db.execute("INSERT INTO content_segment_ranges(segment_id,position,start,end,payload) VALUES (?,0,0,30,?)",[.text(segment.id.uuidString),try DaybookDatabase.json(audio)])
        let job = try AudioWindowPlanner.plan(source:legacySource,configurationKey:"v1")[0]
        let result = AudioWindowResult(spans:[],activities:[],asr:.success,vad:.notRequested,speaker:.notRequested,asrCoverage:[.init(start:0,end:30)],vadCoverage:[])
        try db.execute("UPDATE audio_processing_jobs SET state='completed',result=? WHERE id=?",[try DaybookDatabase.json(result),.text(job.id)])
        for (position,span) in child.contentProvenance!.transcript.enumerated() {
            try db.execute("INSERT INTO audio_transcript_spans(job_id,position,start,end,text) VALUES (?,?,?,?,?)",[.text(job.id),.integer(Int64(position)),.real(span.start),.real(span.end),.text(span.text)])
        }
        try repository.preparePresentations(sourceID:legacySourceID)
        let cached = try ContentSegmentSnapshot.read(processing,scope:scope).filter { $0.contentProvenance?.sourceID == legacyID }
        precondition(cached.count == 1 && cached[0].text == "yesterday","real SQLite snapshot excludes boundary-straddling factual text")
        let secondSnapshot = try ContentSegmentSnapshot.read(processing,scope:DateInterval(start:day.addingTimeInterval(86400),duration:86400)).filter { $0.contentProvenance?.sourceID == legacyID }
        let combinedSnapshot = try ContentSegmentSnapshot.read(processing,scope:DateInterval(start:day,duration:172800)).filter { $0.contentProvenance?.sourceID == legacyID }
        precondition(secondSnapshot.first?.text == "tomorrow" && combinedSnapshot.first?.text.contains("before midnight / after midnight") == true,"combined snapshot preserves whole original span while individual dates exclude it")
        // A changed range/content signature cannot display the previous finished artifact.
        try db.execute("UPDATE content_segment_presentations SET content_signature='old' WHERE segment_id=?",[.text(segment.id.uuidString)])
        let partial = try ContentSegmentSnapshot.read(processing,scope:scope,requireComplete:false)
        precondition(!partial.contains(where:{ $0.id == segment.id }),"stale content is hidden until its replacement is persisted")
        var rejectedIncomplete = false
        do { _ = try ContentSegmentSnapshot.read(processing,scope:scope) }
        catch ContentSegmentError.staleRevision { rejectedIncomplete = true }
        precondition(rejectedIncomplete,"AI evidence must reject an incomplete processed snapshot")
        try repository.preparePresentations(sourceID:legacySourceID)
        try notes.update(id:legacyID) { $0.transcript = "legacy original fallback" }
        let originalLegacyParents = notes.notes.map(DaybookPlaces.voice)
        let requestedA = ContentSegmentPresentation.evidenceRecords(legacyParents:originalLegacyParents,sessionParents:[],derived:[],scope:scope)
        precondition(requestedA.map(\.id) == [legacyID] && requestedA.first?.text == "legacy original fallback","actual scope assembly retains original legacy A fallback when only selected B has a child")
        let scopeB = DateInterval(start:day.addingTimeInterval(86400),duration:86400)
        let selectedB = ContentSegmentPresentation.evidenceRecords(legacyParents:originalLegacyParents,sessionParents:[],derived:secondSnapshot,scope:scopeB)
        precondition(selectedB.map(\.id) == [segment.id] && selectedB[0].duration == 20,"actual scope assembly counts only child on B")
        let cache = ContentSegmentCache()
        cache.publish(records:cached,library:[segment],dates:[day])
        let previousRevision = cache.revision
        try notes.delete(id:legacyID)
        for _ in 0..<100 where cache.revision == previousRevision { await Task.yield() }
        precondition(cache.records.isEmpty && cache.library.isEmpty && cache.calendarDates.isEmpty && cache.revision > previousRevision,"durable legacy deletion promptly invalidates real presentation cache")
        let deletedRows = try db.query("SELECT id FROM content_segments WHERE id=?",[.text(segment.id.uuidString)])
        precondition(deletedRows.isEmpty,"durable source deletion cascades derived rows")
        let deletedArtifacts = try db.query("SELECT segment_id FROM content_segment_presentations WHERE segment_id=?",[.text(segment.id.uuidString)])
        precondition(deletedArtifacts.isEmpty,"source deletion also removes processed artifacts")
        let deletedAssemblyA = ContentSegmentPresentation.evidenceRecords(legacyParents:originalLegacyParents,sessionParents:[],derived:secondSnapshot,scope:scope)
        let deletedAssemblyB = ContentSegmentPresentation.evidenceRecords(legacyParents:originalLegacyParents,sessionParents:[],derived:secondSnapshot,scope:scopeB)
        precondition(deletedAssemblyA.isEmpty && deletedAssemblyB.isEmpty,"actual scope assembly fences deleted original and child inputs")
        cache.publish(records:cached,library:[segment],dates:[])
        precondition(cache.records.isEmpty && cache.library.isEmpty,"late cached source snapshots cannot resurrect deleted material")
        let failedStages = AudioProcessingPresentation(states:[.completed:1],asr:.init(failed:1),vad:.init(failed:1),speaker:.init(missingResource:1))
        precondition(failedStages.completedWindows == 1 && failedStages.totalWindows == 1 && failedStages.messages.contains(where: { $0.contains("语音转写") && $0.contains("失败") }) && failedStages.messages.contains(where: { $0.contains("语音活动检测") && $0.contains("失败") }) && failedStages.messages.contains(where: { $0.contains("说话人分析") && $0.contains("资源") }),"completed windows must expose independent stage failures and missing speaker resource")
        let skippedSpeaker = AudioProcessingPresentation(states:[.completed:1],asr:.init(success:1),vad:.init(success:1),speaker:.init(notRequested:1))
        precondition(skippedSpeaker.messages.contains(where:{ $0.contains("说话人分析尚未执行") && $0.contains("时长未知") }),"unrequested speaker analysis is explained without claiming success")
        let cancelledStage = AudioProcessingPresentation(states:[.completed:1],asr:.init(cancelled:1),vad:.init(),speaker:.init())
        precondition(cancelledStage.messages.contains(where:{ $0.contains("语音转写") && $0.contains("取消") }),"stage cancellation remains visible independently of job state")
        print("Content presentation: boundary-straddling text/frames, scoped parent fallback, durable cache deletion, stage failure/missing/skip, citations, combined scope, gaps and old archives passed")
        if CommandLine.arguments.count == 2 { try auditPreparedDatabase(URL(fileURLWithPath:CommandLine.arguments[1])) }
    }

    /// Optional local copied database audit. The caller supplies a disposable backup,
    /// never the live phone/container database. Prints counts/timing, never user text.
    static func auditPreparedDatabase(_ url: URL) throws {
        let db = try DaybookDatabase(url:url)
        let repository = ContentSegmentRepository(database:db)
        let sources = try db.query("SELECT descriptor FROM audio_processing_sources").map { try DaybookDatabase.decode(AudioSourceSnapshot.self,$0["descriptor"]) }
        let start = Date()
        for source in sources { try repository.preparePresentations(sourceID:source.id) }
        print("Prepared database artifacts in \(Date().timeIntervalSince(start)) seconds")
        // Reopen through a separate connection: UI success cannot depend on worker memory.
        let reopened = try DaybookDatabase(url:url)
        let probe = RawReadProbe(); try probe.install(reopened)
        let readStart = Date()
        let records = try ContentSegmentSnapshot.read(.init(database:reopened),scope:DateInterval(start:Date(timeIntervalSinceReferenceDate:0),end:Date(timeIntervalSinceReferenceDate:2_000_000_000)))
        try probe.remove(reopened)
        precondition(probe.reads == 0,"restart must read only durable processed artifacts")
        print("Reloaded \(records.count) segments, \(ContentSegmentPresentation.timelineRecords(records).count) meaningful, \(records.reduce(0){$0+($1.contentProvenance?.transcript.count ?? 0)}) spans in \(Date().timeIntervalSince(readStart)) seconds; raw ASR queries: \(probe.reads)")
    }
}
