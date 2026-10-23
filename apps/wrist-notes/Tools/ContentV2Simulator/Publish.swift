import Foundation
import CryptoKit

/// A simulator-only test publisher. Validates both model output and original
/// SQLite evidence before an atomic update to the app's normal content tables.
@main struct Publish {
    enum Failure: Error { case arguments, notLab, staleInput, manualEdits, badMedia, missingSpan, frameBoundary, invalidSegmentID, sourceConflict }
    static func main() {
        do { try run() }
        catch let error as Failure { print("publication_rejected \(error)"); exit(1) }
        catch { print("publication_rejected validation_or_database_error"); exit(1) }
    }
    static func run() throws {
        let args=CommandLine.arguments
        guard args.count == 6 else { throw Failure.arguments }
        let dbURL=URL(fileURLWithPath:args[1]).standardizedFileURL
        let device=args[5]
        guard UUID(uuidString:device) != nil,
              dbURL.path.contains("/CoreSimulator/Devices/\(device)/data/Containers/Data/Application/"),
              dbURL.lastPathComponent == "daybook.sqlite3" else { throw Failure.notLab }
        let deviceRoot=dbURL.path.components(separatedBy:"/data/")[0]
        let devicePlist=try PropertyListSerialization.propertyList(from:Data(contentsOf:URL(fileURLWithPath:deviceRoot).appendingPathComponent("device.plist")),format:nil) as? [String:Any]
        guard devicePlist?["name"] as? String == "WiseLife Content Lab", devicePlist?["UDID"] as? String == device else { throw Failure.notLab }
        let input=try JSONDecoder().decode(ContentSegmentationV2.Input.self,from:Data(contentsOf:URL(fileURLWithPath:args[2])))
        let output=try JSONDecoder().decode(ContentSegmentationV2.Output.self,from:Data(contentsOf:URL(fileURLWithPath:args[3])))
        let expectedPlan=try ContentSegmentationV2.prepare(input)
        guard output.sourceID == input.sourceID, output.plan == expectedPlan else { throw Failure.staleInput }
        guard output.segments.allSatisfy({ !$0.id.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty }),
              Set(output.segments.map(\.id)).count == output.segments.count else { throw Failure.invalidSegmentID }
        try ContentSegmentationV2.validateOutput(plan:expectedPlan,segments:output.segments,original:input.spans)
        let db=try DaybookDatabase(url:dbURL)
        guard let sourceRow=try db.query("SELECT * FROM audio_processing_sources WHERE source_key=?",[.text(input.sourceID)]).first,
              String(try sourceRow.requiredInt("revision")) == input.sourceRevision else { throw Failure.staleInput }
        let source=try DaybookDatabase.decode(AudioSourceSnapshot.self,sourceRow["descriptor"])
        let configurationKey=try sourceRow.requiredString("configuration_key")
        let resultRows=try db.query("SELECT result FROM audio_processing_jobs WHERE source_key=? AND active=1 AND configuration_key=? ORDER BY core_start,id",[.text(input.sourceID),.text(configurationKey)])
        let results=try resultRows.map { try DaybookDatabase.decode(AudioWindowResult.self,$0["result"]) }
        guard results.allSatisfy({ $0.asr == .success && $0.vad == .success }),
              results.flatMap(\.asrCoverage).map({ ContentSegmentationV2.Interval(start:$0.start,end:$0.end) }) == input.asrCoverage,
              results.flatMap(\.vadCoverage).map({ ContentSegmentationV2.Interval(start:$0.start,end:$0.end) }) == input.vadCoverage else { throw Failure.staleInput }
        let activityRows=try db.query("SELECT t.start,t.end,t.kind FROM audio_activity_intervals t JOIN audio_processing_jobs j ON j.id=t.job_id WHERE j.source_key=? AND j.active=1 AND j.configuration_key=? ORDER BY j.core_start,j.id,t.position",[.text(input.sourceID),.text(configurationKey)])
        let activities=try activityRows.map { row -> ContentSegmentationV2.Activity in
            guard let kind=ContentSegmentationV2.ActivityKind(rawValue:try row.requiredString("kind")) else { throw Failure.staleInput }
            return .init(start:try row.requiredDouble("start"),end:try row.requiredDouble("end"),kind:kind)
        }
        guard activities == input.activities else { throw Failure.staleInput }
        var mediaHashes: [URL:String]=[:]
        for range in source.ranges {
            let mediaURL=range.url.resolvingSymlinksInPath()
            guard FileManager.default.fileExists(atPath:range.url.path),
                  mediaURL.path.hasPrefix(deviceRoot+"/data/") else { throw Failure.badMedia }
            if mediaHashes[mediaURL] == nil { mediaHashes[mediaURL]=try fileHash(mediaURL) }
            guard mediaHashes[mediaURL] == range.contentHash.lowercased() else { throw Failure.badMedia }
        }
        let rows=try db.query("""
            SELECT t.*,j.id AS job_id FROM audio_transcript_spans t JOIN audio_processing_jobs j ON j.id=t.job_id
            WHERE j.source_key=? AND j.active=1 AND j.configuration_key=? ORDER BY t.start,t.end,j.id,t.position
            """,[.text(input.sourceID),.text(configurationKey)])
        var actual: [String:AudioTranscriptSpan]=[:]
        for row in rows {
            let id=try row.requiredString("job_id")+":"+String(try row.requiredInt("position"))
            actual[id] = .init(start:try row.requiredDouble("start"),end:try row.requiredDouble("end"),text:try row.requiredString("text"),speakerID:row["speaker_id"]?.string)
        }
        guard actual.count == input.spans.count else { throw Failure.staleInput }
        for span in input.spans {
            guard let value=actual[span.id], value.start == span.start, value.end == span.end, value.text == span.text else { throw Failure.staleInput }
        }
        try requireNoManualHistory(db,sourceID:input.sourceID)
        let previousRows=try db.query("SELECT * FROM content_segments WHERE source_key=? ORDER BY id",[.text(input.sourceID)])
        let previous=try previousRows.filter { try $0.requiredInt("deleted") == 0 }.map { try DaybookDatabase.decode(ContentSegment.self,$0["payload"]) }
        guard previous.allSatisfy({ !$0.isManual }) else { throw Failure.manualEdits }
        var prepared: [(ContentSegment,Data)]=[]
        for segment in output.segments {
            let ranges=try AudioWindowPlanner.slices(source.ranges,start:segment.start,end:segment.end)
            let spans=try segment.spanIDs.map { id -> AudioTranscriptSpan in
                guard let value=actual[id] else { throw Failure.missingSpan }; return value
            }
            // Frame rounding must not cut any assigned transcript interval.
            guard spans.allSatisfy({ span in ranges.contains { span.start >= $0.sessionStartOffset-0.000001 && span.end <= $0.end+0.000001 } }) else { throw Failure.frameBoundary }
            let hash=SHA256.hash(data:Data(segment.id.utf8)).map { String(format:"%02x",$0) }.joined()
            let uuidText=String(hash.prefix(8))+"-"+String(hash.dropFirst(8).prefix(4))+"-"+String(hash.dropFirst(12).prefix(4))+"-"+String(hash.dropFirst(16).prefix(4))+"-"+String(hash.dropFirst(20).prefix(12))
            let id=UUID(uuidString:uuidText)!
            let signature=AudioStableID.make([expectedPlan.inputFingerprint,segment.id,ContentSegmentationV2.algorithmVersion])
            let old=previous.first { $0.id == id }
            var value=ContentSegment(id:id,sourceID:source.id,sourceRevision:try sourceRow.requiredInt("revision"),ranges:ranges,
                title:segment.title,summary:segment.summary,revision:old?.revision ?? 1,isManual:false,isFinal:!segment.provisional,
                hasText:spans.contains { !$0.text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty },
                provenance:.init(algorithmVersion:ContentSegmentationV2.algorithmVersion,configurationKey:configurationKey,contentSignature:signature,semanticContentSignature:signature),
                editorial:.init(classification:segment.classification.rawValue,engineVersion:ContentSegmentationV2.algorithmVersion,model:args[4],evidenceBlockIDs:segment.evidenceBlockIDs))
            if let old, old != value { value.revision += 1 }
            prepared.append((value,try JSONEncoder().encode(spans)))
        }
        let jobRows=try db.query("SELECT window,result_hash FROM audio_processing_jobs WHERE source_key=? AND active=1 AND configuration_key=? ORDER BY core_start,id",[.text(input.sourceID),.text(configurationKey)])
        let jobs=try jobRows.map { (try DaybookDatabase.decode(AudioProcessingWindow.self,$0["window"]),$0["result_hash"]?.string ?? "") }
        let sourceSignature=AudioContentSnapshotIdentity.make(source:source,key:configurationKey,jobs:jobs)
        try requireNoSourceConflicts(db,ids:prepared.map { $0.0.id },sourceID:input.sourceID)
        // All expensive parsing and validation precedes this short writer transaction.
        try db.transaction {
            guard try db.query("SELECT * FROM audio_processing_sources WHERE source_key=?",[.text(input.sourceID)]).first == sourceRow,
                  try db.query("SELECT window,result_hash FROM audio_processing_jobs WHERE source_key=? AND active=1 AND configuration_key=? ORDER BY core_start,id",[.text(input.sourceID),.text(configurationKey)]) == jobRows else { throw Failure.staleInput }
            try requireNoManualHistory(db,sourceID:input.sourceID)
            try requireNoSourceConflicts(db,ids:prepared.map { $0.0.id },sourceID:input.sourceID)
            guard try db.query("SELECT * FROM content_segments WHERE source_key=? ORDER BY id",[.text(input.sourceID)]) == previousRows else { throw Failure.staleInput }
            let activeIDs=Set(prepared.map { $0.0.id })
            for old in previous where !activeIDs.contains(old.id) {
                try db.execute("UPDATE content_segments SET deleted=1 WHERE id=?",[.text(old.id.uuidString)])
            }
            for (value,transcript) in prepared {
                try db.execute("INSERT INTO content_segments(id,source_key,start,revision,deleted,payload) VALUES (?,?,?,?,0,?) ON CONFLICT(id) DO UPDATE SET start=excluded.start,revision=excluded.revision,deleted=0,payload=excluded.payload",[.text(value.id.uuidString),.text(input.sourceID),.real(value.ranges[0].sessionStartOffset),.integer(Int64(value.revision)),try DaybookDatabase.json(value)])
                try db.execute("DELETE FROM content_segment_ranges WHERE segment_id=?",[.text(value.id.uuidString)])
                for (position,range) in value.ranges.enumerated() {
                    try db.execute("INSERT INTO content_segment_ranges(segment_id,position,start,end,payload) VALUES (?,?,?,?,?)",[.text(value.id.uuidString),.integer(Int64(position)),.real(range.sessionStartOffset),.real(range.end),try DaybookDatabase.json(range)])
                }
                try db.execute("INSERT INTO content_segment_presentations(segment_id,content_signature,transcript) VALUES (?,?,?) ON CONFLICT(segment_id) DO UPDATE SET content_signature=excluded.content_signature,transcript=excluded.transcript",[.text(value.id.uuidString),.text(value.provenance.contentSignature),.blob(transcript)])
            }
            try db.execute("INSERT INTO content_segment_sources(source_key,signature,semantic_signature,state,epoch) VALUES (?,?,?,'processed',1) ON CONFLICT(source_key) DO UPDATE SET signature=excluded.signature,semantic_signature=excluded.semantic_signature,state=excluded.state",[.text(input.sourceID),.text(sourceSignature),.text(sourceSignature)])
        }
        print("published segments=\(prepared.count) meaningful=\(output.segments.filter { $0.classification == .meaningful }.count) original_rows=\(actual.count)")
    }

    private static func requireNoManualHistory(_ db:DaybookDatabase, sourceID:String) throws {
        for table in ["content_segment_suppression","content_segment_tombstones","content_segment_edits"] {
            let outstanding=table == "content_segment_edits" ? " AND undone=0" : ""
            guard try db.query("SELECT 1 FROM \(table) WHERE source_key=?\(outstanding) LIMIT 1",[.text(sourceID)]).isEmpty else { throw Failure.manualEdits }
        }
    }

    private static func requireNoSourceConflicts(_ db:DaybookDatabase, ids:[UUID], sourceID:String) throws {
        guard Set(ids).count == ids.count else { throw Failure.invalidSegmentID }
        for id in ids {
            if let row=try db.query("SELECT source_key FROM content_segments WHERE id=?",[.text(id.uuidString)]).first,
               try row.requiredString("source_key") != sourceID { throw Failure.sourceConflict }
        }
    }

    private static func fileHash(_ url:URL) throws -> String {
        let handle=try FileHandle(forReadingFrom:url)
        defer { try? handle.close() }
        var hash=SHA256()
        while let bytes=try handle.read(upToCount:1_048_576), !bytes.isEmpty { hash.update(data:bytes) }
        return hash.finalize().map { String(format:"%02x",$0) }.joined()
    }
}
