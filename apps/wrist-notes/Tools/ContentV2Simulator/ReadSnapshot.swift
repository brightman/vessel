import Foundation

/// Exercise the real SQLite -> cached presentation -> timeline projection path.
/// Does not invoke any speech or text inference.
@main struct ReadSnapshot {
    static func main() throws {
        let args=CommandLine.arguments
        guard args.count == 4 else { throw ContentSegmentError.invalidEdit }
        let db=try DaybookDatabase(url:URL(fileURLWithPath:args[1]))
        let sourceKey=args[2]
        guard let row=try db.query("SELECT descriptor FROM audio_processing_sources WHERE source_key=?",[.text(sourceKey)]).first else { throw ContentSegmentError.notFound }
        let source=try DaybookDatabase.decode(AudioSourceSnapshot.self,row["descriptor"])
        var calendar=Calendar(identifier:.gregorian); calendar.timeZone=TimeZone(identifier:"Asia/Shanghai")!
        let scope=calendar.dateInterval(of:.day,for:source.capturedAt)!
        let snapshot=try ContentSegmentSnapshot.read(AudioProcessingRepository(database:db),scope:scope)
        let timeline=ContentSegmentPresentation.timelineRecords(snapshot).filter { $0.contentProvenance?.sourceID == source.id.id }
        let segments=try ContentSegmentRepository(database:db).segments(sourceID:source.id)
        let expected=segments.filter { $0.editorial?.classification == "meaningful" && $0.hasText }
        let encoder=JSONEncoder(); encoder.outputFormatting=[.prettyPrinted,.sortedKeys]
        try encoder.encode(timeline).write(to:URL(fileURLWithPath:args[3]),options:.atomic)
        precondition(Set(timeline.map(\.id)) == Set(expected.map(\.id)),"timeline must equal persisted meaningful subset")
        precondition(timeline.allSatisfy { !$0.title.isEmpty && !$0.summary.isEmpty && !$0.text.isEmpty && $0.duration <= 2400.0001 },"complete usable bounded content")
        print("sqlite_snapshot segments=\(segments.count) timeline=\(timeline.count) cached_transcript_rows=\(snapshot.reduce(0) { $0+($1.contentProvenance?.transcript.count ?? 0) })")
    }
}
