import Foundation

/// Synchronous worker-owned API; each lease/result transition is one SQLite transaction.
final class AudioProcessingRepository {
    private let db: DaybookDatabase
    /// Worker-confined derived repository construction only. Never retain across actors.
    var derivedDatabase: DaybookDatabase { db }
    init(database: DaybookDatabase) { db = database }

    func register(source: AudioSourceSnapshot, configurationKey: String, windows: [AudioProcessingWindow]) throws {
        let planned = try AudioWindowPlanner.plan(source: source, configurationKey: configurationKey)
        guard windows == planned else { throw AudioProcessingError.invalidInput }
        try db.transaction {
            guard try !isDeleted(source.id) else { throw AudioProcessingError.deletedSource }
            let parent = source.id.kind == .session ? "recording_sessions" : "voice_notes"
            guard try !db.query("SELECT id FROM \(parent) WHERE id=?", [.text(source.id.id.uuidString)]).isEmpty else { throw AudioProcessingError.deletedSource }
            let previous = try sourceRow(source.id)
            let oldConfiguration = previous?["configuration_key"]?.string
            let cancelled = previous?["cancelled"]?.double == 1
            if previous == nil {
                try db.execute("INSERT INTO audio_processing_sources(source_key,kind,source_id,session_id,note_id,descriptor,fingerprint,configuration_key) VALUES (?,?,?,?,?,?,?,?)", [
                    .text(source.id.key), .text(source.id.kind.rawValue), .text(source.id.id.uuidString),
                    source.id.kind == .session ? .text(source.id.id.uuidString) : .null,
                    source.id.kind == .legacyNote ? .text(source.id.id.uuidString) : .null,
                    try DaybookDatabase.json(source), .text(source.fingerprint), .text(configurationKey)])
            } else {
                let materialChange = (try? DaybookDatabase.decode(AudioSourceSnapshot.self, previous?["descriptor"])) != source || oldConfiguration != configurationKey
                try db.execute("UPDATE audio_processing_sources SET descriptor=?,fingerprint=?,configuration_key=?,revision=revision+? WHERE source_key=?", [try DaybookDatabase.json(source), .text(source.fingerprint), .text(configurationKey), .integer(materialChange ? 1 : 0), .text(source.id.key)])
            }
            // Remove membership without deleting historical results. Leases of obsolete inputs are revoked.
            let newIDs = Set(windows.map(\.id))
            for row in try db.query("SELECT id FROM audio_processing_jobs WHERE source_key=? AND active=1", [.text(source.id.key)]) {
                let id = try row.requiredString("id")
                if !newIDs.contains(id) {
                    try db.execute("UPDATE audio_processing_jobs SET active=0,lease=NULL,state=CASE WHEN state='running' THEN 'cancelled' ELSE state END WHERE id=?", [.text(id)])
                }
            }
            for window in windows {
                try db.execute("INSERT OR IGNORE INTO audio_processing_jobs(id,source_key,configuration_key,core_start,core_end,window,state,active) VALUES (?,?,?,?,?,?,?,1)", [.text(window.id), .text(source.id.key), .text(configurationKey), .real(window.coreStart), .real(window.coreEnd), try DaybookDatabase.json(window), .text(cancelled ? "cancelled" : "pending")])
                try db.execute("UPDATE audio_processing_jobs SET active=1 WHERE id=?", [.text(window.id)])
            }
        }
    }

    func claimNext() throws -> AudioProcessingJob? {
        try db.transaction {
            guard let row = try db.query("SELECT j.* FROM audio_processing_jobs j JOIN audio_processing_sources s ON s.source_key=j.source_key WHERE j.state='pending' AND j.active=1 AND s.cancelled=0 AND j.configuration_key=s.configuration_key ORDER BY s.source_key,j.core_start,j.id LIMIT 1").first else { return nil }
            let window = try DaybookDatabase.decode(AudioProcessingWindow.self, row["window"])
            guard try !isDeleted(window.sourceID) else { throw AudioProcessingError.deletedSource }
            let lease = UUID()
            try db.execute("UPDATE audio_processing_jobs SET state='running',lease=?,message=NULL WHERE id=?", [.text(lease.uuidString), .text(window.id)])
            try bump(window.sourceID)
            return AudioProcessingJob(window: window, lease: lease)
        }
    }

    func commit(job: AudioProcessingJob, result: AudioWindowResult) throws {
        try db.transaction {
            let row = try valid(job)
            try validate(result: result, window: job.window)
            let hash = AudioStableID.make(result)
            if row["state"]?.string == "completed" {
                guard row["result_hash"]?.string == hash else { throw AudioProcessingError.staleJob }
                return
            }
            guard row["state"]?.string == "running" else { throw AudioProcessingError.staleJob }
            let window = job.window
            try db.execute("DELETE FROM audio_transcript_spans WHERE job_id=?", [.text(window.id)])
            try db.execute("DELETE FROM audio_activity_intervals WHERE job_id=?", [.text(window.id)])
            let spans = try AudioWindowPlanner.ownedSpans(result.spans, window: window)
            for (index, span) in spans.enumerated() {
                try db.execute("INSERT INTO audio_transcript_spans(job_id,position,start,end,text,speaker_id) VALUES (?,?,?,?,?,?)", [.text(window.id), .integer(Int64(index)), .real(span.start), .real(span.end), .text(span.text), span.speakerID.map(DaybookDatabase.Value.text) ?? .null])
            }
            for (index, activity) in result.activities.enumerated() {
                let start = max(window.coreStart, activity.start), end = min(window.coreEnd, activity.end)
                guard end > start else { continue }
                try db.execute("INSERT INTO audio_activity_intervals(job_id,position,start,end,kind) VALUES (?,?,?,?,?)", [.text(window.id), .integer(Int64(index)), .real(start), .real(end), .text(activity.kind.rawValue)])
            }
            // Per-window metadata stays bounded. Transcript/activity rows are never a growing JSON document.
            let metadata = AudioWindowResult(spans: [], activities: [], asr: result.asr, vad: result.vad, speaker: result.speaker, asrCoverage: result.asrCoverage, vadCoverage: result.vadCoverage, speakerFeatures: result.speakerFeatures)
            try db.execute("UPDATE audio_processing_jobs SET state='completed',result=?,result_hash=?,message=NULL WHERE id=?", [try DaybookDatabase.json(metadata), .text(hash), .text(window.id)])
            try db.execute("DELETE FROM audio_processing_stage_requests WHERE job_id=?",[.text(window.id)])
            try bump(window.sourceID)
        }
    }

    /// Stage retries never replace a previously successful stage. Retained snapshots remain readable.
    func stages(for job: AudioProcessingJob) throws -> AudioInferenceStages {
        let row = try valid(job)
        guard row["result"] != .null, row["result"] != nil else { return .all }
        let old = try DaybookDatabase.decode(AudioWindowResult.self, row["result"])
        var stages: AudioInferenceStages = []
        if old.asr != .success && old.asr != .notRequested { stages.insert(.asr) }
        if old.vad != .success && old.vad != .notRequested { stages.insert(.vad) }
        if old.speaker != .success && old.speaker != .notRequested { stages.insert(.speaker) }
        if let requested = try db.query("SELECT stages FROM audio_processing_stage_requests WHERE job_id=?",[.text(job.window.id)]).first {
            stages.formUnion(AudioInferenceStages(rawValue:try requested.requiredInt("stages")))
        }
        return stages
    }

    func retryIncompleteStages(sourceID: AudioSourceID, resourceOnly: Bool = false) throws {
        try db.transaction {
            guard let source = try sourceRow(sourceID), try !isDeleted(sourceID) else { throw AudioProcessingError.deletedSource }
            // Resource availability never overrides explicit user cancellation.
            if resourceOnly && source["cancelled"]?.double == 1 { return }
            if !resourceOnly { try retry(sourceID: sourceID) }
            for row in try db.query("SELECT id,result,state FROM audio_processing_jobs WHERE source_key=? AND active=1 AND configuration_key=?", [.text(sourceID.key), .text(try source.requiredString("configuration_key"))]) {
                let state = row["state"]?.string
                guard state != "running" else { continue }
                var incomplete = resourceOnly ? state == "missingResource" : ["missingResource","failed","cancelled"].contains(state ?? "")
                if row["result"] != nil && row["result"] != .null {
                    let result = try DaybookDatabase.decode(AudioWindowResult.self, row["result"])
                    // A revoked running lease is resumable independently of the older snapshot.
                    incomplete = incomplete || [result.asr,result.vad,result.speaker].contains { resourceOnly ? $0 == .missingResource : [.missingResource,.failed,.cancelled].contains($0) }
                    if !resourceOnly && result.speaker == .notRequested {
                        let snapshot = try DaybookDatabase.decode(AudioSourceSnapshot.self,source["descriptor"])
                        if snapshot.complete && AudioSpeakerMapping.permitsAnalysis(sourceDuration:snapshot.ranges.last?.end) {
                            try db.execute("INSERT OR REPLACE INTO audio_processing_stage_requests(job_id,stages) VALUES (?,?)",[.text(try row.requiredString("id")),.integer(Int64(AudioInferenceStages.speaker.rawValue))])
                            incomplete = true
                        }
                    }
                }
                if incomplete { try db.execute("UPDATE audio_processing_jobs SET state='pending',lease=NULL,message=NULL WHERE id=?", [.text(try row.requiredString("id"))]) }
            }
            try bump(sourceID)
        }
    }

    /// Merge under the original lease/config/fingerprint guard, including exact retained ASR rows.
    func commit(job: AudioProcessingJob, delta: AudioInferenceDelta) throws {
        try db.transaction {
            let row = try valid(job)
            let old = row["result"] != nil && row["result"] != .null ? try DaybookDatabase.decode(AudioWindowResult.self,row["result"]) : nil
            let fresh = delta.result
            let retained = try windowSpans(job.window.id)
            var spans = old?.asr == .success ? retained : fresh.spans
            var features = old?.speaker == .success ? old!.speakerFeatures : fresh.speakerFeatures
            if old?.speaker != .success && fresh.speaker == .success {
                let mapping = try mapSpeakers(job:job,features:fresh.speakerFeatures)
                if old?.asr == .success {
                    guard delta.speakerSpanUpdates.count == retained.count,
                          zip(retained,delta.speakerSpanUpdates).allSatisfy({ $0.start == $1.start && $0.end == $1.end && $0.text == $1.text }) else { throw AudioProcessingError.staleJob }
                    spans = delta.speakerSpanUpdates.map { span in var copy = span; copy.speakerID = span.speakerID.flatMap { mapping[$0] }; return copy }
                } else {
                    spans = spans.map { span in var copy = span; copy.speakerID = span.speakerID.flatMap { mapping[$0] }; return copy }
                }
                features = fresh.speakerFeatures
            }
            var activities = old?.vad == .success ? try windowActivities(job.window.id) : fresh.activities
            let vadOutcome = old?.vad == .success ? AudioAnalysisOutcome.success : fresh.vad
            let vadCoverage = old?.vad == .success ? old!.vadCoverage : fresh.vadCoverage
            if vadOutcome == .success {
                var context: [AudioTranscriptSpan] = [], offset = 0
                while true {
                    let page = try self.spans(sourceID:job.window.sourceID,overlapping:.init(start:job.window.inputStart,end:job.window.inputEnd),limit:1000,offset:offset)
                    context += page; offset += page.count
                    if page.count < 1000 { break }
                }
                activities = AudioActivityReconciler.reconcile(start:job.window.coreStart,end:job.window.coreEnd,
                    detections:activities,coverage:vadCoverage,spans:spans+context)
            }
            let merged = AudioWindowResult(spans:spans,activities:activities,
                asr:old?.asr == .success ? .success : fresh.asr,
                vad:vadOutcome,
                speaker:old?.speaker == .success ? .success : fresh.speaker,
                asrCoverage:old?.asr == .success ? old!.asrCoverage : fresh.asrCoverage,
                vadCoverage:vadCoverage,speakerFeatures:features)
            try commit(job:job,result:merged)
        }
    }

    private func mapSpeakers(job: AudioProcessingJob, features: [AudioSpeakerFeature]) throws -> [String:String] {
        var candidates: [String:AudioSpeakerFeature] = [:]
        for row in try db.query("SELECT m.canonical_id,m.feature FROM audio_speaker_mappings m JOIN audio_processing_jobs j ON j.id=m.job_id WHERE j.source_key=? AND j.configuration_key=? AND j.active=1 AND j.result IS NOT NULL AND m.canonical_id IS NOT NULL ORDER BY j.core_start,j.id,m.local_id", [.text(job.window.sourceID.key),.text(job.window.configurationKey)]) {
            let id = try row.requiredString("canonical_id")
            if candidates[id] == nil { candidates[id] = try DaybookDatabase.decode(AudioSpeakerFeature.self,row["feature"]) }
        }
        let initialEvidence = candidates.isEmpty
        var mapping: [String:String] = [:]
        try db.execute("DELETE FROM audio_speaker_mappings WHERE job_id=?", [.text(job.window.id)])
        for feature in features {
            guard let normalized = AudioSpeakerMapping.normalized(feature.vector) else { throw AudioProcessingError.invalidInput }
            let canonical = AudioSpeakerMapping.match(feature,candidates:candidates) ?? (initialEvidence ? "speaker:" + AudioStableID.make([job.window.sourceID.key,job.window.configurationKey,job.window.id,feature.localSpeakerID]) : nil)
            let evidence = AudioSpeakerFeature(localSpeakerID:feature.localSpeakerID,modelVersion:feature.modelVersion,vector:normalized)
            try db.execute("INSERT INTO audio_speaker_mappings(job_id,local_id,canonical_id,feature) VALUES (?,?,?,?)", [.text(job.window.id),.text(feature.localSpeakerID),canonical.map(DaybookDatabase.Value.text) ?? .null,try DaybookDatabase.json(evidence)])
            if let canonical { mapping[feature.localSpeakerID] = canonical }
        }
        return mapping
    }
    private func windowSpans(_ id: String) throws -> [AudioTranscriptSpan] {
        try db.query("SELECT * FROM audio_transcript_spans WHERE job_id=? ORDER BY position",[.text(id)]).map {
            AudioTranscriptSpan(start:try $0.requiredDouble("start"),end:try $0.requiredDouble("end"),text:try $0.requiredString("text"),speakerID:$0["speaker_id"]?.string)
        }
    }
    private func windowActivities(_ id: String) throws -> [AudioActivityInterval] {
        try db.query("SELECT * FROM audio_activity_intervals WHERE job_id=? ORDER BY position",[.text(id)]).map {
            guard let kind = AudioActivityKind(rawValue:try $0.requiredString("kind")) else { throw AudioProcessingError.invalidInput }
            return AudioActivityInterval(start:try $0.requiredDouble("start"),end:try $0.requiredDouble("end"),kind:kind)
        }
    }
    func sources() throws -> [AudioSourceSnapshot] {
        try db.query("SELECT descriptor FROM audio_processing_sources ORDER BY source_key").map { try DaybookDatabase.decode(AudioSourceSnapshot.self,$0["descriptor"]) }
    }
    func spans(sourceID: AudioSourceID, overlapping range: AudioTimeRange, limit: Int = 200, offset: Int = 0) throws -> [AudioTranscriptSpan] {
        try range.validate()
        guard limit > 0, limit <= 1000, offset >= 0 else { throw AudioProcessingError.invalidInput }
        return try db.query("SELECT t.* FROM audio_transcript_spans t JOIN audio_processing_jobs j ON j.id=t.job_id JOIN audio_processing_sources s ON s.source_key=j.source_key WHERE j.source_key=? AND j.active=1 AND j.configuration_key=s.configuration_key AND j.result IS NOT NULL AND t.end>? AND t.start<? ORDER BY t.start,t.end,j.id,t.position LIMIT ? OFFSET ?", [.text(sourceID.key),.real(range.start),.real(range.end),.integer(Int64(limit)),.integer(Int64(offset))]).map {
            AudioTranscriptSpan(start:try $0.requiredDouble("start"),end:try $0.requiredDouble("end"),text:try $0.requiredString("text"),speakerID:$0["speaker_id"]?.string)
        }
    }

    /// Revoke an in-flight lease for process shutdown, retaining committed stage snapshots.
    func deferInterrupted(job: AudioProcessingJob) throws {
        try db.transaction {
            let row = try valid(job)
            guard row["state"]?.string == "running" else { throw AudioProcessingError.staleJob }
            try db.execute("UPDATE audio_processing_jobs SET state='pending',lease=NULL WHERE id=?",[.text(job.window.id)])
            try bump(job.window.sourceID)
        }
    }
    func fail(job: AudioProcessingJob, state: AudioJobState, message: String? = nil) throws {
        guard [.missingResource, .failed, .cancelled].contains(state) else { throw AudioProcessingError.invalidInput }
        try db.transaction {
            let row = try valid(job)
            guard row["state"]?.string == "running" else { throw AudioProcessingError.staleJob }
            // Adapter messages may contain private text/paths. Persist only this fixed safe status.
            try db.execute("UPDATE audio_processing_jobs SET state=?,message=?,lease=NULL WHERE id=?", [.text(state.rawValue), .text(state.rawValue), .text(job.window.id)])
            try bump(job.window.sourceID)
        }
    }
    func retry(sourceID: AudioSourceID) throws {
        try db.transaction {
            guard try sourceRow(sourceID) != nil, try !isDeleted(sourceID) else { throw AudioProcessingError.deletedSource }
            try db.execute("UPDATE audio_processing_sources SET cancelled=0 WHERE source_key=?", [.text(sourceID.key)])
            try db.execute("UPDATE audio_processing_jobs SET state='pending',lease=NULL,message=NULL WHERE source_key=? AND active=1 AND state IN ('missingResource','failed','cancelled')", [.text(sourceID.key)])
            try bump(sourceID)
        }
    }
    func cancel(sourceID: AudioSourceID) throws {
        try db.transaction {
            try db.execute("UPDATE audio_processing_sources SET cancelled=1 WHERE source_key=?", [.text(sourceID.key)])
            try db.execute("UPDATE audio_processing_jobs SET state='cancelled',lease=NULL WHERE source_key=? AND active=1 AND state<>'completed'", [.text(sourceID.key)])
            try bump(sourceID)
        }
    }
    func delete(sourceID: AudioSourceID) throws {
        try db.transaction {
            try db.execute("INSERT OR IGNORE INTO audio_source_tombstones(source_key,deleted_at) VALUES (?,?)", [.text(sourceID.key), .real(Date.now.timeIntervalSinceReferenceDate)])
            try db.execute("DELETE FROM audio_processing_sources WHERE source_key=?", [.text(sourceID.key)])
        }
    }
    /// Call once before starting a new serial worker, never while another worker is processing.
    func recoverInterrupted() throws {
        try db.transaction {
            let sources = try db.query("SELECT DISTINCT source_key FROM audio_processing_jobs WHERE state='running'")
            try db.execute("UPDATE audio_processing_jobs SET state=CASE WHEN active=1 AND EXISTS(SELECT 1 FROM audio_processing_sources s WHERE s.source_key=audio_processing_jobs.source_key AND s.cancelled=0 AND s.configuration_key=audio_processing_jobs.configuration_key) THEN 'pending' ELSE 'cancelled' END,lease=NULL WHERE state='running'")
            for row in sources { try db.execute("UPDATE audio_processing_sources SET revision=revision+1 WHERE source_key=?", [.text(try row.requiredString("source_key"))]) }
        }
    }
    func progress(sourceID: AudioSourceID) throws -> AudioProcessingProgress {
        let source = try sourceRow(sourceID)
        var states: [AudioJobState: Int] = [:]
        for row in try db.query("SELECT j.state,count(*) AS count FROM audio_processing_jobs j JOIN audio_processing_sources s ON s.source_key=j.source_key WHERE j.source_key=? AND j.active=1 AND j.configuration_key=s.configuration_key GROUP BY j.state", [.text(sourceID.key)]) {
            guard let state = AudioJobState(rawValue: try row.requiredString("state")) else { throw AudioProcessingError.invalidInput }
            states[state] = try row.requiredInt("count")
        }
        return AudioProcessingProgress(states: states, revision: try source?.requiredInt("revision") ?? 0, configurationKey: source?["configuration_key"]?.string)
    }
    func spans(sourceID: AudioSourceID, limit: Int = 200, offset: Int = 0) throws -> [AudioTranscriptSpan] {
        guard limit > 0, limit <= 1000, offset >= 0 else { throw AudioProcessingError.invalidInput }
        return try db.query("SELECT t.* FROM audio_transcript_spans t JOIN audio_processing_jobs j ON j.id=t.job_id JOIN audio_processing_sources s ON s.source_key=j.source_key WHERE j.source_key=? AND j.active=1 AND j.configuration_key=s.configuration_key AND j.result IS NOT NULL ORDER BY t.start,t.end,j.id,t.position LIMIT ? OFFSET ?", [.text(sourceID.key), .integer(Int64(limit)), .integer(Int64(offset))]).map { row in
            AudioTranscriptSpan(start: try row.requiredDouble("start"), end: try row.requiredDouble("end"), text: try row.requiredString("text"), speakerID: row["speaker_id"]?.string)
        }
    }
    func activities(sourceID: AudioSourceID) throws -> [AudioActivityInterval] {
        try db.query("SELECT t.* FROM audio_activity_intervals t JOIN audio_processing_jobs j ON j.id=t.job_id JOIN audio_processing_sources s ON s.source_key=j.source_key WHERE j.source_key=? AND j.active=1 AND j.configuration_key=s.configuration_key AND j.result IS NOT NULL ORDER BY t.start,t.end,j.id,t.position", [.text(sourceID.key)]).map { row in
            guard let kind = AudioActivityKind(rawValue: try row.requiredString("kind")) else { throw AudioProcessingError.invalidInput }
            return AudioActivityInterval(start: try row.requiredDouble("start"), end: try row.requiredDouble("end"), kind: kind)
        }
    }
    /// Explicit ASR/VAD coverage and outcomes in core order; spans are paged separately.
    func results(sourceID: AudioSourceID) throws -> [AudioWindowResult] {
        try db.query("SELECT j.result FROM audio_processing_jobs j JOIN audio_processing_sources s ON s.source_key=j.source_key WHERE j.source_key=? AND j.active=1 AND j.configuration_key=s.configuration_key AND j.result IS NOT NULL ORDER BY j.core_start,j.id", [.text(sourceID.key)]).map { try DaybookDatabase.decode(AudioWindowResult.self, $0["result"]) }
    }
    func completedAnalyses(sourceID: AudioSourceID) throws -> [AudioCompletedAnalysis] {
        try db.query("SELECT j.window,j.result FROM audio_processing_jobs j JOIN audio_processing_sources s ON s.source_key=j.source_key WHERE j.source_key=? AND j.active=1 AND j.configuration_key=s.configuration_key AND j.result IS NOT NULL ORDER BY j.core_start,j.id", [.text(sourceID.key)]).map {
            AudioCompletedAnalysis(window: try DaybookDatabase.decode(AudioProcessingWindow.self, $0["window"]), result: try DaybookDatabase.decode(AudioWindowResult.self, $0["result"]))
        }
    }
    func currentSource(_ sourceID: AudioSourceID) throws -> AudioSourceSnapshot? {
        guard let row = try sourceRow(sourceID) else { return nil }
        let source = try DaybookDatabase.decode(AudioSourceSnapshot.self, row["descriptor"])
        try source.validate()
        return source
    }

    private func sourceRow(_ sourceID: AudioSourceID) throws -> DaybookDatabase.Row? {
        try db.query("SELECT * FROM audio_processing_sources WHERE source_key=?", [.text(sourceID.key)]).first
    }
    private func isDeleted(_ sourceID: AudioSourceID) throws -> Bool {
        if try !db.query("SELECT source_key FROM audio_source_tombstones WHERE source_key=?", [.text(sourceID.key)]).isEmpty { return true }
        if sourceID.kind == .session {
            return try !db.query("SELECT session_id FROM recording_session_tombstones WHERE session_id=?", [.text(sourceID.id.uuidString)]).isEmpty
        }
        return try !db.query("SELECT id FROM media_tombstones WHERE kind='voice' AND id=?", [.text(sourceID.id.uuidString)]).isEmpty
    }
    private func valid(_ job: AudioProcessingJob) throws -> DaybookDatabase.Row {
        guard try !isDeleted(job.window.sourceID), let source = try sourceRow(job.window.sourceID),
              source["configuration_key"]?.string == job.window.configurationKey, source["cancelled"]?.double == 0,
              let row = try db.query("SELECT * FROM audio_processing_jobs WHERE id=? AND source_key=? AND active=1", [.text(job.window.id), .text(job.window.sourceID.key)]).first,
              row["lease"]?.string == job.lease.uuidString,
              try DaybookDatabase.decode(AudioProcessingWindow.self, row["window"]) == job.window else { throw AudioProcessingError.staleJob }
        return row
    }
    private func bump(_ sourceID: AudioSourceID) throws {
        try db.execute("UPDATE audio_processing_sources SET revision=revision+1 WHERE source_key=?", [.text(sourceID.key)])
    }
    private func validate(result: AudioWindowResult, window: AudioProcessingWindow) throws {
        func coverage(_ intervals: [AudioTimeRange], outcome: AudioAnalysisOutcome) throws {
            guard outcome == .success || intervals.isEmpty else { throw AudioProcessingError.invalidInput }
            var end = window.coreStart
            for interval in intervals {
                try interval.validate()
                guard interval.start >= end, interval.end <= window.coreEnd else { throw AudioProcessingError.invalidInput }
                end = interval.end
            }
        }
        try coverage(result.asrCoverage, outcome: result.asr)
        try coverage(result.vadCoverage, outcome: result.vad)
        guard result.asr == .success || result.spans.isEmpty else { throw AudioProcessingError.invalidInput }
        guard result.vad == .success || result.activities.allSatisfy({ $0.kind == .uncertain }) else { throw AudioProcessingError.invalidInput }
        for span in result.spans { try AudioTimeRange(start: span.start, end: span.end).validate() }
        var activityEnd = window.inputStart
        for activity in result.activities {
            try AudioTimeRange(start: activity.start, end: activity.end).validate()
            guard activity.start >= activityEnd, activity.start >= window.inputStart, activity.end <= window.inputEnd else { throw AudioProcessingError.invalidInput }
            activityEnd = activity.end
            if activity.kind != .uncertain {
                let clippedStart = max(window.coreStart, activity.start), clippedEnd = min(window.coreEnd, activity.end)
                // Reconciliation may coalesce identical activity across adjacent adaptive cores.
                // Walk the sorted continuous union; even a small real gap ends coverage.
                var coveredEnd = clippedStart
                for interval in result.vadCoverage where interval.end > coveredEnd {
                    if interval.start > coveredEnd { break }
                    coveredEnd = interval.end
                    if coveredEnd >= clippedEnd { break }
                }
                guard clippedEnd <= clippedStart || coveredEnd >= clippedEnd else { throw AudioProcessingError.invalidInput }
            }
        }
        for feature in result.speakerFeatures {
            guard result.speaker == .success, !feature.localSpeakerID.isEmpty, !feature.modelVersion.isEmpty,
                  !feature.vector.isEmpty, feature.vector.allSatisfy(\.isFinite) else { throw AudioProcessingError.invalidInput }
        }
    }
}
