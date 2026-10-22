import Foundation
import Combine

struct FixtureEmbedding: DaybookEmbedding {
    let space: DaybookEmbeddingSpace
    let available: Bool
    func vector(_ text: String) throws -> [Float]? {
        guard available else { return nil }
        if text.contains("badvector") { return [Float.nan, 0, 0] }
        let vector: [Float]
        if text.contains("合同预算") || text.contains("denied") || text.hasPrefix("stress") { vector = [1, 0, 0] }
        else if text.contains("deadline") { vector = [0.8, 0.6, 0] }
        else { vector = [0, 0, 1] }
        return space.dimension == 4 ? vector + [0] : vector
    }
}

@main struct DaybookSemanticSmoke {
    static func main() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let db = try DaybookDatabase(url: directory.appendingPathComponent("test.sqlite3"))
        let day = Calendar.current.startOfDay(for: Date())
        let allowed = DayRecord(id: UUID(), capturedAt: day.addingTimeInterval(10), kind: .voice, title: "work", text: "deadline pressure")
        let denied = DayRecord(id: UUID(), capturedAt: day.addingTimeInterval(20), kind: .image, title: "denied", text: "denied")
        let old = DayRecord(id: UUID(), capturedAt: day.addingTimeInterval(-10), kind: .voice, title: "denied", text: "denied")
        let space = DaybookEmbeddingSpace(model: "fixture", revision: 1, dimension: 3, language: "en", pooling: "sentence")
        let model = FixtureEmbedding(space: space, available: true)
        let index = DaybookSemanticIndex(database: db, embedding: model)
        let tail = DayRecord(id: UUID(), capturedAt: day, kind: .voice, title: "会议", text: String(repeating: "普通记录。", count: 600) + "周五需要核对合同预算")
        let tailResult = await index.search(query: "合同预算", records: [tail], dayStart: day, dayEnd: day.addingTimeInterval(86400), allowedKinds: [.voice], limit: 1)
        let tailChunks = try db.query("SELECT snippet FROM semantic_chunks ORDER BY ordinal")
        precondition(tailChunks.contains { $0["snippet"]?.string?.contains("合同预算") == true }, "tail beyond 1800 characters must be indexed")
        precondition(tailResult.hits.first?.snippet.contains("合同预算") == true, "the best tail vector must be returned through public search")
        try await index.clear()
        let records = [denied, old, allowed]
        // Seed globally closer denied and historic vectors; the next scope must not lose the allowed candidate.
        _ = await index.search(query: "stress", records: records, dayStart: day, dayEnd: day.addingTimeInterval(86400), allowedKinds: [.voice, .image], limit: 1)
        _ = await index.search(query: "stress", records: records, dayStart: day.addingTimeInterval(-86400), dayEnd: day, allowedKinds: [.voice, .image], limit: 1)
        let globallyIndexed = try db.query("SELECT * FROM semantic_chunks")
        precondition(globallyIndexed.count == 3)
        let kindResult = await index.search(query: "stress录音", records: records, dayStart: day, dayEnd: day.addingTimeInterval(86400), allowedKinds: [.voice, .image], limit: 1)
        precondition(kindResult.hits.map(\.id) == [allowed.id], "requested source kind also filters before nearest limit")
        let result = await index.search(query: "stress", records: records, dayStart: day, dayEnd: day.addingTimeInterval(86400), allowedKinds: [.voice], limit: 1)
        precondition(result.hits.map(\.id) == [allowed.id], "date/permission filtering precedes real extension nearest selection")
        let rows = try db.query("SELECT vector, model_key FROM semantic_chunks")
        precondition(rows.count == 2 && rows[0]["vector"]?.data?.count == 12, "Float32 vectors persist with compatible space only")
        let initial = try db.query("SELECT fingerprint FROM semantic_records").first
        _ = await index.search(query: "stress", records: records, dayStart: day, dayEnd: day.addingTimeInterval(86400), allowedKinds: [.voice], limit: 1)
        let unchanged = try db.query("SELECT fingerprint FROM semantic_records").first
        precondition(unchanged == initial)
        // A trigger rejects unnecessary re-embedding writes; unchanged records must remain searchable.
        try db.execute("CREATE TRIGGER no_rewrite BEFORE INSERT ON semantic_chunks BEGIN SELECT RAISE(ABORT, 'unchanged rewrite'); END")
        let cached = await index.search(query: "stress", records: records, dayStart: day, dayEnd: day.addingTimeInterval(86400), allowedKinds: [.voice], limit: 1)
        precondition(cached.hits.map(\.id) == [allowed.id])
        let summarized = DayRecord(id: allowed.id, capturedAt: allowed.capturedAt, kind: allowed.kind, title: allowed.title, text: allowed.text, summary: "badvector generated text")
        let summaryOnly = await index.search(query: "stress", records: [summarized, old, denied], dayStart: day, dayEnd: day.addingTimeInterval(86400), allowedKinds: [.voice], limit: 1)
        precondition(summaryOnly.hits.first?.id == allowed.id, "generated summaries never become embedding input or cause reindex")
        try db.execute("DROP TRIGGER no_rewrite")
        let edited = DayRecord(id: allowed.id, capturedAt: allowed.capturedAt, kind: .voice, title: "meal", text: "lunch")
        let changed = await index.search(query: "stress", records: [edited], dayStart: day, dayEnd: day.addingTimeInterval(86400), allowedKinds: [.voice], limit: 1)
        precondition(changed.hits.first?.snippet.contains("lunch") == true && !changed.hits.contains { $0.snippet.contains("deadline") })
        let revoked = await index.search(query: "stress", records: [edited], dayStart: day, dayEnd: day.addingTimeInterval(86400), allowedKinds: [], limit: 1)
        precondition(revoked.hits.isEmpty)
        let emptyRows1 = try db.query("SELECT * FROM semantic_records")
        precondition(emptyRows1.isEmpty)
        _ = await index.search(query: "stress", records: [allowed], dayStart: day, dayEnd: day.addingTimeInterval(86400), allowedKinds: [.voice], limit: 1)
        let newSpace = DaybookEmbeddingSpace(model: "fixture", revision: 2, dimension: 4, language: "en", pooling: "sentence")
        let newer = DaybookSemanticIndex(database: db, embedding: FixtureEmbedding(space: newSpace, available: true))
        _ = await newer.search(query: "stress", records: [allowed], dayStart: day, dayEnd: day.addingTimeInterval(86400), allowedKinds: [.voice], limit: 1)
        let keys = try db.query("SELECT DISTINCT model_key FROM semantic_chunks")
        precondition(keys.count == 1 && keys.first?["model_key"]?.string == newSpace.key, "revision/dimension replacement cannot mix spaces")
        let resized = try db.query("SELECT vector FROM semantic_chunks")
        precondition(resized.first?["vector"]?.data?.count == 16)
        _ = await newer.search(query: "stress", records: [], dayStart: day, dayEnd: day.addingTimeInterval(86400), allowedKinds: [.voice], limit: 1)
        let emptyRows2 = try db.query("SELECT * FROM semantic_chunks")
        precondition(emptyRows2.isEmpty, "deletions reconcile durable snippets")
        let unavailable = DaybookSemanticIndex(database: db, embedding: FixtureEmbedding(space: space, available: false))
        let fallback = await unavailable.search(query: "stress", records: [allowed], dayStart: day, dayEnd: day.addingTimeInterval(86400), allowedKinds: [.voice], limit: 1)
        precondition(fallback.hits.isEmpty && !fallback.status.isEmpty)
        let bad = DayRecord(id: UUID(), capturedAt: allowed.capturedAt, kind: .voice, title: "badvector", text: "badvector")
        let invalid = await index.search(query: "stress", records: [bad], dayStart: day, dayEnd: day.addingTimeInterval(86400), allowedKinds: [.voice], limit: 1)
        precondition(invalid.hits.isEmpty && !invalid.status.isEmpty)
        let manual = DaybookRetrieval.libraryRecords(query: "denied", records: records, dayStart: day, dayEnd: day.addingTimeInterval(86400), allowedKinds: [.voice], semantic: result)
        precondition(manual.contains { $0.id == denied.id }, "manual literal search retains records excluded from AI permission")
        let semanticOnly = DaybookRetrieval.libraryRecords(query: "stress", records: records, dayStart: day, dayEnd: day.addingTimeInterval(86400), allowedKinds: [.voice], semantic: result)
        precondition(semanticOnly.map(\.id) == [allowed.id])
        let secondRecord = DayRecord(id: UUID(), capturedAt: allowed.capturedAt, kind: .voice, title: "meal", text: "lunch")
        let rankingEvidence = DaybookEvidenceSnapshot(records: [allowed, secondRecord], dayStart: day, dayEnd: day.addingTimeInterval(86400), allowedKinds: [.voice])
        let rankedMatches = DaybookSemanticMatches(hits: [.init(id: secondRecord.id, snippet: secondRecord.text), .init(id: allowed.id, snippet: allowed.text)], status: "fixture", evidence: rankingEvidence, generation: 0)
        let rankedLibrary = DaybookRetrieval.libraryRecords(query: "stress", records: [allowed, secondRecord], dayStart: day, dayEnd: day.addingTimeInterval(86400), allowedKinds: [.voice], semantic: rankedMatches)
        precondition(rankedLibrary.map(\.id) == [secondRecord.id, allowed.id], "library semantic additions preserve nearest-first rank")
        let staleLibrary = DaybookRetrieval.libraryRecords(query: "stress", records: [edited], dayStart: day, dayEnd: day.addingTimeInterval(86400), allowedKinds: [.voice], semantic: result)
        precondition(staleLibrary.isEmpty, "edited evidence cannot reappear through cached library IDs")
        // A write error must leave current lexical evidence usable without cached semantic snippets.
        try db.execute("CREATE TRIGGER fail_index BEFORE INSERT ON semantic_records BEGIN SELECT RAISE(ABORT, 'synthetic index failure'); END")
        let failed = await index.search(query: "deadline", records: [allowed], dayStart: day, dayEnd: day.addingTimeInterval(86400), allowedKinds: [.voice], limit: 1)
        precondition(failed.hits.isEmpty)
        precondition(DaybookRetrieval.libraryRecords(query: "deadline", records: [allowed], dayStart: day, dayEnd: day.addingTimeInterval(86400), allowedKinds: [.voice], semantic: failed).map(\.id) == [allowed.id])
        try db.execute("DROP TRIGGER fail_index")
        let long = DayRecord(id: UUID(), capturedAt: allowed.capturedAt, kind: .voice, title: "work", text: String(repeating: "deadline ", count: 500))
        let bounded = await index.search(query: "stress", records: [long], dayStart: day, dayEnd: day.addingTimeInterval(86400), allowedKinds: [.voice], limit: 1)
        let chunks = try db.query("SELECT snippet FROM semantic_chunks")
        precondition(chunks.count > 3 && chunks.allSatisfy { ($0["snippet"]?.string?.count ?? 1000) <= 600 })
        precondition(bounded.coverage?.pending == 0 && bounded.coverage?.finished == chunks.count)
        try db.execute("CREATE TRIGGER fail_clear BEFORE DELETE ON semantic_records BEGIN SELECT RAISE(ABORT, 'synthetic clear failure'); END")
        var clearFailed = false
        do { try await index.clear() } catch { clearFailed = true }
        precondition(clearFailed && !index.isCurrent(bounded), "failed clear is reported and invalidates previous results")
        try db.execute("DROP TRIGGER fail_clear")
        try await index.clear()
        let emptyRows3 = try db.query("SELECT * FROM semantic_chunks")
        precondition(emptyRows3.isEmpty)
        try await fullTextChunksSmoke(directory: directory, day: day, space: space)
        try await incrementalCoverage(directory: directory, day: day, space: space)
        try await fullRangeVectorSmoke(directory: directory, day: day, space: space)
        try await tokenizerFallbackSmoke(directory: directory, day: day, space: space)
        try await unavailableAndMigrationSmoke(directory: directory, day: day, space: space)
        try await cancelRace(directory: directory, day: day, record: allowed, space: space)
        await foregroundPasses(day: day, record: allowed)
        await resourceLifecycle(day: day, record: allowed)
        await libraryResume(day: day, record: allowed)
        await libraryRaces(day: day, record: allowed)
        try await clearRace(directory: directory, day: day, record: allowed, space: space)
        print("Daybook semantic SQLite Vector: passed")
    }
}

private final class BlockingEmbedding: DaybookEmbedding, @unchecked Sendable {
    let space: DaybookEmbeddingSpace
    let entered = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    init(space: DaybookEmbeddingSpace) { self.space = space }
    func waitUntilEntered() -> Bool { entered.wait(timeout: .now() + 5) == .success }
    func vector(_ text: String) throws -> [Float]? {
        if text.contains("deadline") { entered.signal(); release.wait() }
        return [1, 0, 0]
    }
}
private func clearRace(directory: URL, day: Date, record: DayRecord, space: DaybookEmbeddingSpace) async throws {
    let db = try DaybookDatabase(url: directory.appendingPathComponent("race.sqlite3"))
    let embedding = BlockingEmbedding(space: space)
    let index = DaybookSemanticIndex(database: db, embedding: embedding)
    let searching = Task { await index.search(query: "stress", records: [record], dayStart: day, dayEnd: day.addingTimeInterval(86400), allowedKinds: [.voice], limit: 1) }
    // This blocks only a test worker, with a bounded timeout; no model/device assets are involved.
    let entered = await Task.detached { embedding.waitUntilEntered() }.value
    precondition(entered)
    let clearing = Task { try await index.clear() }
    // A sentinel search result exposes the generation, without reaching into the worker implementation.
    let sentinel = DaybookSemanticMatches(hits: [], status: "", evidence: DaybookEvidenceSnapshot(records: [record], dayStart: day, dayEnd: day.addingTimeInterval(86400), allowedKinds: [.voice]), generation: 0)
    for _ in 0..<1000 { if !index.isCurrent(sentinel) { break }; await Task.yield() }
    precondition(!index.isCurrent(sentinel), "clear invalidates an active embedding before waiting for its worker")
    embedding.release.signal()
    let late = await searching.value
    try await clearing.value
    precondition(late.hits.isEmpty && !index.isCurrent(late))
    let rows = try db.query("SELECT * FROM semantic_records")
    precondition(rows.isEmpty, "late indexing cannot undo clear")
}

private actor LibraryDelayedSemantic: DaybookSemanticSearching {
    private var pending: [CheckedContinuation<DaybookSemanticMatches, Never>?] = []
    private var requests: [DaybookSemanticMatches] = []
    private var resourceReady: Bool?
    func setResourceReady(_ ready: Bool) { resourceReady = ready }
    func search(query: String, records: [DayRecord], dayStart: Date, dayEnd: Date, allowedKinds: Set<DayRecord.Kind>, limit: Int) async -> DaybookSemanticMatches {
        let number = requests.count + 1
        requests.append(DaybookSemanticMatches(hits: records.map { .init(id: $0.id, snippet: $0.text) }, status: resourceReady.map { $0 ? "ready \(number)" : "missing \(number)" } ?? "request \(number)", evidence: DaybookEvidenceSnapshot(records: records, dayStart: dayStart, dayEnd: dayEnd, allowedKinds: allowedKinds), generation: 0))
        return await withCheckedContinuation { pending.append($0) }
    }
    func count() -> Int { pending.count }
    func finish(_ index: Int, coverage: DaybookSemanticMatches.Coverage? = nil) {
        var result = requests[index]; result.coverage = coverage
        pending[index]?.resume(returning: result); pending[index] = nil
    }
}
@MainActor private func waitForRequests(_ service: LibraryDelayedSemantic, _ count: Int) async {
    for _ in 0..<1000 { if await service.count() >= count { return }; await Task.yield() }
}
@MainActor private func settleLibrary() async { for _ in 0..<100 { await Task.yield() } }
@MainActor private func libraryResume(day: Date, record: DayRecord) async {
    let delayed = LibraryDelayedSemantic()
    let model = DaybookSemanticSearchModel(search: delayed, debounce: .zero)
    model.synchronize(query: "stress", records: [record], date: day, allowedKinds: [.voice])
    await waitForRequests(delayed, 1); await delayed.finish(0); await settleLibrary()
    precondition(model.result != nil)
    model.cancel()
    model.synchronize(query: "stress", records: [record], date: day, allowedKinds: [.voice])
    await waitForRequests(delayed, 2)
    let count = await delayed.count()
    precondition(count == 2, "same-input cancel/resume must start a new semantic request")
    await delayed.finish(1); await settleLibrary()
    precondition(model.result?.status == "request 2", "resumed same-query semantic additions publish")
}
@MainActor private func libraryRaces(day: Date, record: DayRecord) async {
    for change in 0..<4 {
        let delayed = LibraryDelayedSemantic()
        let model = DaybookSemanticSearchModel(search: delayed, debounce: .zero)
        model.synchronize(query: "stress", records: [record], date: day, allowedKinds: [.voice])
        await waitForRequests(delayed, 1)
        let edited = DayRecord(id: record.id, capturedAt: record.capturedAt, kind: record.kind, title: record.title, text: "changed original")
        let query = change == 0 ? "other query" : "stress"
        let date = change == 1 ? day.addingTimeInterval(86400) : day
        let kinds: Set<DayRecord.Kind> = change == 2 ? [] : [.voice]
        let records = change == 3 ? [edited] : [record]
        model.synchronize(query: query, records: records, date: date, allowedKinds: kinds)
        await waitForRequests(delayed, 2)
        await delayed.finish(0); await settleLibrary()
        precondition(model.result == nil && model.isSearching, "synchronization rejects the old request while the new request remains active")
        await delayed.finish(1); await settleLibrary()
        precondition(model.validated(query: query, records: records, date: date, allowedKinds: kinds)?.status == "request 2", "latest query/date/permission/edit request eventually publishes without explicit cancellation")
        if change == 3 { precondition(model.result?.hits.first?.snippet == "changed original") }
    }
}

private func incrementalCoverage(directory: URL, day: Date, space: DaybookEmbeddingSpace) async throws {
    let db = try DaybookDatabase(url: directory.appendingPathComponent("incremental.sqlite3"))
    let index = DaybookSemanticIndex(database: db, embedding: FixtureEmbedding(space: space, available: true))
    let records = (0..<129).map { number in
        DayRecord(id: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012x", number))!, capturedAt: day.addingTimeInterval(100), kind: .voice, title: "work", text: "deadline")
    }
    _ = await index.search(query: "stress", records: records, dayStart: day, dayEnd: day.addingTimeInterval(86400), allowedKinds: [.voice], limit: 1)
    let first = try db.query("SELECT * FROM semantic_chunks WHERE state='ready'")
    precondition(first.count == 64, "first request bounds expensive embeddings")
    _ = await index.search(query: "stress", records: records, dayStart: day, dayEnd: day.addingTimeInterval(86400), allowedKinds: [.voice], limit: 1)
    _ = await index.search(query: "stress", records: records, dayStart: day, dayEnd: day.addingTimeInterval(86400), allowedKinds: [.voice], limit: 1)
    let second = try db.query("SELECT * FROM semantic_chunks WHERE state='ready'")
    precondition(second.count == 129, "cached records must not starve remaining unindexed records on subsequent requests")
}

@MainActor private func resourceLifecycle(day: Date, record: DayRecord) async {
    let delayed = LibraryDelayedSemantic()
    await delayed.setResourceReady(false)
    let model = DaybookSemanticSearchModel(search: delayed, debounce: .zero)
    var active = false
    let subscription = NotificationCenter.default.publisher(for: .daybookSemanticChanged).sink { notification in
        guard let change = notification.object as? DaybookSemanticResourceChange else { return }
        model.resourcesChanged(change, active: active)
    }
    defer { subscription.cancel() }
    model.synchronize(query: "stress", records: [record], date: day, allowedKinds: [.voice], active: false)
    await settleLibrary()
    let inactiveCount = await delayed.count()
    precondition(inactiveCount == 0 && !model.isSearching, "inactive input synchronization does not schedule embeddings")
    active = true
    model.synchronize(query: "stress", records: [record], date: day, allowedKinds: [.voice], active: true)
    await waitForRequests(delayed, 1); await delayed.finish(0); await settleLibrary()
    precondition(model.result?.status == "missing 1")
    await delayed.setResourceReady(true)
    active = false
    DaybookSemanticResourceChange.refreshed.publish()
    await settleLibrary()
    let refreshedInactiveCount = await delayed.count()
    precondition(refreshedInactiveCount == 1 && model.result == nil && !model.isSearching, "resource refresh invalidates the negative cache without inactive work")
    active = true
    model.synchronize(query: "stress", records: [record], date: day, allowedKinds: [.voice], active: true, resume: true)
    await waitForRequests(delayed, 2); await delayed.finish(1); await settleLibrary()
    precondition(model.result?.status == "ready 2", "foreground same-input search observes newly ready resources")
    for (offset, change) in [DaybookSemanticResourceChange.downloadCompleted, .rebuilt, .languageChanged, .refreshed].enumerated() {
        change.publish()
        let number = offset + 3
        await waitForRequests(delayed, number)
        await delayed.finish(number - 1); await settleLibrary()
        precondition(model.result?.status == "ready \(number)", "download/rebuild/language/refresh update the current eligible query")
    }
    // Clear also cancels a pending resource retry; finishing that older request cannot repopulate.
    DaybookSemanticResourceChange.refreshed.publish()
    await waitForRequests(delayed, 7)
    DaybookSemanticResourceChange.resetStarted.publish()
    model.synchronize(query: "stress", records: [record], date: day, allowedKinds: [.voice], active: true, resume: true)
    await settleLibrary()
    let resettingCount = await delayed.count()
    precondition(resettingCount == 7 && model.result == nil && !model.isSearching, "foreground/submit cannot restart while clear/rebuild is still in progress")
    await delayed.finish(6); await settleLibrary()
    DaybookSemanticResourceChange.cleared.publish()
    model.synchronize(query: "stress", records: [record], date: day, allowedKinds: [.voice], active: true)
    let edited = DayRecord(id: record.id, capturedAt: record.capturedAt, kind: record.kind, title: record.title, text: "changed while cleared")
    model.synchronize(query: "stress", records: [edited], date: day, allowedKinds: [.voice], active: true)
    await settleLibrary()
    let clearedCount = await delayed.count()
    precondition(clearedCount == 7 && model.result == nil && !model.isSearching, "deliberate clear survives incidental same-query/source synchronization without silent reindexing")
    model.synchronize(query: "stress", records: [edited], date: day, allowedKinds: [.voice], active: true, resume: true)
    await waitForRequests(delayed, 8); await delayed.finish(7); await settleLibrary()
    precondition(model.result?.status == "ready 8" && model.result?.hits.first?.snippet == "changed while cleared", "later explicit search/foreground resume remains eligible after clear")
}

@MainActor private func foregroundPasses(day: Date, record: DayRecord) async {
    let delayed = LibraryDelayedSemantic()
    let model = DaybookSemanticSearchModel(search: delayed, debounce: .zero)
    model.synchronize(query: "stress", records: [record], date: day, allowedKinds: [.voice])
    await waitForRequests(delayed, 1)
    let partial = DaybookSemanticMatches.Coverage(total: 130, finished: 64, unavailable: 0, attempted: 64, resourcesAvailable: true, modelWindowLimited: false)
    await delayed.finish(0, coverage: partial)
    await waitForRequests(delayed, 2)
    precondition(model.result?.coverage?.finished == 64 && model.isSearching, "publish the first partial result before completion")
    await delayed.finish(1, coverage: partial)
    await settleLibrary()
    let stopped = await delayed.count()
    precondition(stopped == 2 && !model.isSearching, "no-progress results stop foreground continuation")
    model.synchronize(query: "stress", records: [record], date: day, allowedKinds: [.voice], resume: true)
    await waitForRequests(delayed, 3)
    model.synchronize(query: "stress", records: [record], date: day, allowedKinds: [.voice], active: false)
    model.resourcesChanged(.downloadCompleted, active: false)
    await delayed.finish(2, coverage: partial); await settleLibrary()
    let inactive = await delayed.count()
    precondition(inactive == 3 && model.result == nil && !model.isSearching, "leaving Library and receiving an inactive resource event must not restart continuation")
    model.synchronize(query: "stress", records: [record], date: day, allowedKinds: [.voice])
    await waitForRequests(delayed, 4)
    await delayed.finish(3, coverage: .init(total: 130, finished: 64, unavailable: 0, attempted: 0, resourcesAvailable: false, modelWindowLimited: false))
    await settleLibrary()
    let unavailable = await delayed.count()
    precondition(unavailable == 4 && model.result?.status == "request 4" && !model.isSearching, "same-query Library re-entry resumes without explicit resume, then unavailable resources stop continuation")
}

private func cancelRace(directory: URL, day: Date, record: DayRecord, space: DaybookEmbeddingSpace) async throws {
    let db = try DaybookDatabase(url: directory.appendingPathComponent("cancel.sqlite3"))
    let embedding = BlockingEmbedding(space: space)
    let index = DaybookSemanticIndex(database: db, embedding: embedding)
    let searching = Task { await index.search(query: "stress", records: [record], dayStart: day, dayEnd: day.addingTimeInterval(86400), allowedKinds: [.voice], limit: 1) }
    let entered = await Task.detached { embedding.waitUntilEntered() }.value
    precondition(entered)
    searching.cancel(); embedding.release.signal()
    let cancelled = await searching.value
    let rows = try db.query("SELECT * FROM semantic_chunks WHERE state='ready'")
    precondition(cancelled.hits.isEmpty && rows.isEmpty, "cancel during inference cannot write a late vector")
}
