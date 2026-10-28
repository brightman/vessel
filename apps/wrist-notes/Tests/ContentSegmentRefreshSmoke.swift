import Foundation
import Combine

// Replace only the UIKit/inference facade; use the real model, cache and SQLite reads.
@MainActor final class AudioProcessingModel {
    static let contentDidChange = Notification.Name("WiseLife.ContentSegmentsDidChange")
    let repository: AudioProcessingRepository
    var reads = 0
    var completedReads = 0
    var blockNextRead = false
    var continuation: CheckedContinuation<Void,Never>?
    init(_ database: DaybookDatabase) { repository = .init(database:database) }
    func withRepository<T:Sendable>(_ body: @escaping @Sendable (AudioProcessingRepository) throws -> T) async throws -> T {
        reads += 1
        defer { completedReads += 1 }
        if blockNextRead {
            blockNextRead = false
            await withCheckedContinuation { continuation = $0 }
        }
        return try body(repository)
    }
    func rebuildContent(_ id: AudioSourceID) { }
    func release() { continuation?.resume(); continuation = nil }
}
@main struct ContentSegmentRefreshSmoke {
    @MainActor static func wait(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(5)
        while !condition(), Date() < deadline { try await Task.sleep(nanoseconds:1_000_000) }
        precondition(condition(), "refresh must finish without starving behind repeated events")
    }
    @MainActor static func main() async throws {
        let db = try DaybookDatabase(inMemory:true)
        let day = Calendar.current.startOfDay(for:.now)
        let scope = Calendar.current.dateInterval(of:.day,for:day)!
        let sourceID = AudioSourceID(kind:.session,id:UUID())
        let audio = try AudioSourceRange(range:.init(chunkID:UUID(),url:URL(fileURLWithPath:"/synthetic/audio.m4a"),startFrame:0,endFrame:300,sampleRate:10),contentHash:String(repeating:"a",count:64))
        let source = try AudioSourceSnapshot(id:sourceID,capturedAt:day.addingTimeInterval(60),title:"fixture",ranges:[audio],complete:true)
        try db.execute("INSERT INTO audio_processing_sources(source_key,kind,source_id,descriptor,fingerprint,configuration_key,revision) VALUES (?,?,?,?,?,?,1)", [.text(sourceID.key),.text("session"),.text(sourceID.id.uuidString),try DaybookDatabase.json(source),.text(source.fingerprint),.text("v1")])
        var segment = ContentSegment(id:UUID(),sourceID:sourceID,sourceRevision:1,ranges:[audio],title:"Saved title",summary:"Saved summary",revision:1,isManual:false,isFinal:true,hasText:true,provenance:.init(algorithmVersion:"test",configurationKey:"v1",contentSignature:"content"))
        try db.execute("INSERT INTO content_segments(id,source_key,start,revision,payload) VALUES (?,?,0,1,?)", [.text(segment.id.uuidString),.text(sourceID.key),try DaybookDatabase.json(segment)])
        try db.execute("INSERT INTO content_segment_ranges(segment_id,position,start,end,payload) VALUES (?,0,0,30,?)", [.text(segment.id.uuidString),try DaybookDatabase.json(audio)])
        try db.execute("INSERT INTO content_segment_presentations(segment_id,content_signature,transcript) VALUES (?,'content',?)", [.text(segment.id.uuidString),try DaybookDatabase.json([AudioTranscriptSpan(start:0,end:30,text:"Saved transcript")])])
        let processing = AudioProcessingModel(db)
        let model = ContentSegmentModel(processing:processing)
        model.selectDay(day)
        precondition(model.loading, "first date read must be distinguishable from an empty date")
        try await wait { !model.loading && processing.completedReads == 2 }
        precondition(model.records.first?.summary == "Saved summary")

        let initialReads = processing.reads
        processing.blockNextRead = true
        model.refresh()
        precondition(!model.loading, "background refresh must not show a first-load spinner")
        try await wait { processing.continuation != nil }
        precondition(model.records.first?.summary == "Saved summary", "keep the visible snapshot during refresh")
        var publications = 0
        let observation = model.$records.dropFirst().sink { _ in publications += 1 }
        defer { observation.cancel() }
        segment.summary = "Updated persisted summary"; segment.revision += 1
        try db.execute("UPDATE content_segments SET payload=?,revision=2 WHERE id=?", [try DaybookDatabase.json(segment),.text(segment.id.uuidString)])
        for _ in 0..<20 { model.refresh() }
        processing.release()
        try await wait { model.records.first?.summary == "Updated persisted summary" && processing.completedReads >= initialReads+3 }
        precondition(processing.reads == initialReads+3, "coalesce repeated events into one follow-up read")
        precondition(publications == 1, "only publish a changed day snapshot once")
        precondition(!model.loading)

        let loadedReads = processing.reads
        model.selectDay(day.addingTimeInterval(300))
        model.selectMonth(day)
        for _ in 0..<10 { await Task.yield() }
        precondition(processing.reads == loadedReads, "selecting the already loaded day/month must not reload")
        model.refresh()
        try await wait { processing.completedReads == loadedReads+2 }
        precondition(publications == 1, "unchanged persisted data must not republish records")

        let notifiedReads = processing.reads, revision = model.revision
        processing.blockNextRead = true
        model.refresh()
        try await wait { processing.continuation != nil }
        for _ in 0..<20 { NotificationCenter.default.post(name:AudioProcessingModel.contentDidChange,object:nil) }
        try await wait { model.revision == revision+20 }
        precondition(!model.loading && model.records.first?.summary == "Updated persisted summary")
        processing.release()
        try await wait { !model.refreshing }
        precondition(processing.reads == notifiedReads+3 && publications == 1, "real content notifications must coalesce without republishing unchanged data")

        let nextDay = scope.end
        model.selectDay(nextDay)
        precondition(model.loading, "a different unread date must show loading")
        try await wait { !model.loading && model.records.isEmpty }
        let emptyReads = processing.reads
        model.refresh()
        precondition(!model.loading, "a loaded empty date is still a loaded date")
        try await wait { processing.completedReads >= emptyReads+2 && !model.refreshing }

        processing.blockNextRead = true
        model.selectDay(day)
        try await wait { processing.continuation != nil }
        model.selectDay(nextDay)
        processing.release()
        try await wait { !model.refreshing }
        precondition(model.records.isEmpty && !model.loading, "an old in-flight date read must not replace the newly selected date")

        // Complete-date AI evidence still reads persisted data independently of UI date.
        let evidence = try await model.load(scope:scope)
        precondition(evidence.count == 1 && evidence[0].summary == "Updated persisted summary")
        print("Content refresh: initial/date loading, quiet updates, burst coalescing, unchanged snapshots, empty dates and complete evidence passed")
    }
}
