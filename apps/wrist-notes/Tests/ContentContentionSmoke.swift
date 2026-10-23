import Foundation
import SQLite3

/// Exercise real WAL connections while the actual derivation reads transcript rows.
/// The trace callback is test-only scheduling, not a mocked database/clock.
@main struct ContentContentionSmoke {
    final class DuringTranscriptRead {
        let action: () throws -> Void
        var fired = false
        var failure: Error?
        init(_ action: @escaping () throws -> Void) { self.action = action }
        func install(on db: DaybookDatabase) throws {
            _ = try db.withConnection { handle in
                sqlite3_trace_v2(handle, UInt32(SQLITE_TRACE_STMT), { _, context, rawStatement, _ in
                    guard let context, let rawStatement,
                          let sql = sqlite3_sql(OpaquePointer(rawStatement)) else { return 0 }
                    let probe = Unmanaged<DuringTranscriptRead>.fromOpaque(context).takeUnretainedValue()
                    guard !probe.fired, String(cString: sql).contains("FROM audio_transcript_spans") else { return 0 }
                    probe.fired = true
                    do { try probe.action() } catch { probe.failure = error }
                    return 0
                }, Unmanaged.passUnretained(self).toOpaque())
            }
        }
        func remove(from db: DaybookDatabase) throws {
            _ = try db.withConnection { sqlite3_trace_v2($0, 0, nil, nil) }
        }
    }
    static func check(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
        guard try value() else { throw NSError(domain: "ContentContentionSmoke", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
    }
    struct Fixture {
        let db: DaybookDatabase
        let other: DaybookDatabase
        let source: AudioSourceSnapshot
        let content: ContentSegmentRepository
        init(url: URL) throws {
            db = try DaybookDatabase(url: url)
            other = try DaybookDatabase(url: url)
            // Fail immediately if a long derivation owns the writer. Increasing a busy
            // timeout must never make this regression pass by blocking the main thread.
            _ = try other.withConnection { sqlite3_busy_timeout($0, 0) }
            let id = AudioSourceID(kind: .session, id: UUID())
            let range = try AudioSourceRange(range: .init(chunkID: UUID(), url: URL(fileURLWithPath: "/fixture/audio.m4a"), startFrame: 0, endFrame: 3000 * 16000, sampleRate: 16000), contentHash: String(repeating: "a", count: 64))
            source = try AudioSourceSnapshot(id: id, capturedAt: Date(timeIntervalSince1970: 100), title: "Fixture", ranges: [range], complete: true)
            try db.execute("INSERT INTO recording_sessions(id,created_at) VALUES (?,0)", [.text(id.id.uuidString)])
            let processing = AudioProcessingRepository(database: db)
            try processing.register(source: source, configurationKey: "fixture", windows: AudioWindowPlanner.plan(source: source, configurationKey: "fixture"))
            while let job = try processing.claimNext() {
                let a = job.window.coreStart, b = job.window.coreEnd
                try processing.commit(job: job, result: .init(spans: stride(from: a, to: b, by: 60).map { .init(start: $0, end: $0 + 10, text: "Evidence \($0)") }, activities: [.init(start: a, end: b, kind: .speech)], asr: .success, vad: .success, speaker: .notRequested, asrCoverage: [.init(start: a, end: b)], vadCoverage: [.init(start: a, end: b)]))
            }
            content = ContentSegmentRepository(database: db)
        }
        func forceDerivation() throws {
            try db.execute("UPDATE content_segment_sources SET signature='previous',semantic_signature='previous' WHERE source_key=?", [.text(source.id.key)])
        }
    }
    static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("content-contention-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        try unrelatedWriter(root.appendingPathComponent("status.sqlite3"))
        try dateSnapshotWriter(root.appendingPathComponent("date-snapshot.sqlite3"))
        try changedSource(root.appendingPathComponent("source.sqlite3"))
        try manualEdit(root.appendingPathComponent("manual.sqlite3"))
        print("Content contention passed: independent status writes during derivation and date snapshots; stale source and manual edits preserved")
    }
    static func unrelatedWriter(_ url: URL) throws {
        let f = try Fixture(url: url)
        let probe = DuringTranscriptRead {
            try f.other.transaction {
                try f.other.execute("INSERT INTO life_settings(source,enabled) VALUES ('health',1)")
            }
        }
        try probe.install(on: f.db)
        try f.content.reconcile(sourceID: f.source.id)
        try probe.remove(from: f.db)
        try check(probe.fired, "fixture must overlap real transcript derivation")
        try check(probe.failure == nil, "Status persistence was blocked during content derivation: \(String(describing: probe.failure))")
        try check(f.other.query("SELECT enabled FROM life_settings WHERE source='health'").first?["enabled"]?.double == 1, "status write is durable")
        try check(f.content.segments(sourceID: f.source.id).count == 2, "both content chapters commit")
        try check(f.db.query("SELECT count(*) AS n FROM audio_transcript_spans").first?["n"]?.double == 50, "raw transcript preserved")
    }
    static func dateSnapshotWriter(_ url: URL) throws {
        let f = try Fixture(url: url)
        try f.content.reconcile(sourceID: f.source.id)
        let probe = DuringTranscriptRead {
            try f.other.transaction {
                try f.other.execute("INSERT INTO life_settings(source,enabled) VALUES ('health',1)")
            }
        }
        try probe.install(on: f.db)
        let records = try ContentSegmentSnapshot.read(AudioProcessingRepository(database: f.db), scope: DateInterval(start: Date(timeIntervalSince1970: 0), duration: 86400))
        try probe.remove(from: f.db)
        try check(probe.fired && probe.failure == nil, "Status persistence was blocked during date snapshot: \(String(describing: probe.failure))")
        try check(records.count == 2 && records.reduce(0, { $0 + ($1.contentProvenance?.transcript.count ?? 0) }) == 50, "date snapshot retains complete chapter evidence")
        try check(f.other.query("SELECT enabled FROM life_settings WHERE source='health'").first?["enabled"]?.double == 1, "status written during date snapshot is durable")
    }
    static func changedSource(_ url: URL) throws {
        let f = try Fixture(url: url)
        let probe = DuringTranscriptRead { try AudioProcessingRepository(database: f.other).cancel(sourceID: f.source.id) }
        try probe.install(on: f.db)
        var stale = false
        do { try f.content.reconcile(sourceID: f.source.id) } catch ContentSegmentError.staleRevision { stale = true }
        try probe.remove(from: f.db)
        try check(probe.fired && probe.failure == nil, "concurrent source mutation commits without waiting for derivation")
        try check(stale && f.content.segments(sourceID: f.source.id).isEmpty, "source revision change rejects stale derived output")
        try f.content.reconcile(sourceID: f.source.id)
        try check(f.content.segments(sourceID: f.source.id).count == 2, "fresh retry derives retained committed evidence")
    }
    static func manualEdit(_ url: URL) throws {
        let f = try Fixture(url: url)
        try f.content.reconcile(sourceID: f.source.id)
        let original = try f.content.segments(sourceID: f.source.id)[0]
        try f.forceDerivation()
        var manualIDs: Set<UUID> = []
        let probe = DuringTranscriptRead {
            let edited = try ContentSegmentRepository(database: f.other).split(id: original.id, at: 600, expectedRevision: original.revision)
            manualIDs = Set(edited.map(\.id))
        }
        try probe.install(on: f.db)
        var stale = false
        do { try f.content.reconcile(sourceID: f.source.id) } catch ContentSegmentError.staleRevision { stale = true }
        try probe.remove(from: f.db)
        try check(probe.fired && probe.failure == nil && stale, "manual edit commits and invalidates pending derivation")
        try f.content.reconcile(sourceID: f.source.id)
        try check(Set(f.content.segments(sourceID: f.source.id).filter(\.isManual).map(\.id)) == manualIDs && manualIDs.count == 2, "fresh derivation preserves the concurrent manual split")
    }
}
