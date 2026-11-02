import Foundation
import NaturalLanguage

private actor RetrievalTranslator: LocalQueryTranslating {
    enum Mode { case translated, missing, failed, delayed }
    let mode: Mode
    private(set) var calls = 0
    private var pending: CheckedContinuation<String, Never>?
    init(_ mode: Mode) { self.mode = mode }
    func translate(_ text: String, from: QueryTranslationLanguage, to: QueryTranslationLanguage) async throws -> String {
        calls += 1
        precondition(from == .english && to == .chinese)
        switch mode {
        // Deliberately changes kind/name/date: these must never become filters or evidence.
        case .translated: return "图片 昨天 凯特 合同预算"
        case .missing: throw LocalQueryTranslationFailure.resourcesNotInstalled
        case .failed: throw CocoaError(.fileReadUnknown)
        case .delayed: return await withCheckedContinuation { pending = $0 }
        }
    }
    func finish() { pending?.resume(returning: "合同预算"); pending = nil }
    var isWaiting: Bool { pending != nil }
}

func semanticTranslationSmoke(directory: URL, day: Date) async throws {
    for raw in AppleDaybookEmbedding.languages {
        let apple = AppleDaybookEmbedding.make(language: raw)
        let available = NLContextualEmbedding(language: NLLanguage(rawValue: raw))?.hasAvailableAssets == true
        precondition((apple != nil) == available, "contextual asset readiness must drive factory selection, without sentence fallback")
        if let apple { precondition(apple.space.pooling == "mean-token-l2-v1", "use the contextual model validated by the bilingual experiment") }
    }
    let db = try DaybookDatabase(url: directory.appendingPathComponent("translation.sqlite3"))
    let space = DaybookEmbeddingSpace(model: "translation-fixture", revision: 1, dimension: 3, language: "zh-Hans", pooling: "fixture")
    let model = FixtureEmbedding(space: space, available: true)
    let translator = RetrievalTranslator(.translated)
    let index = DaybookSemanticIndex(database: db, embedding: model, translator: translator)
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.dateFormat = "yyyy-MM-dd"
    let original = "Kate Bell budget 录音 \(formatter.string(from: day))"
    let match = DayRecord(id: UUID(), capturedAt: day, kind: .voice, title: "Kate Bell", text: "合同预算需要重新审核。")
    let distractor = DayRecord(id: UUID(), capturedAt: day, kind: .voice, title: "meal", text: "lunch")
    let image = DayRecord(id: UUID(), capturedAt: day, kind: .image, title: "denied", text: "合同预算")
    let yesterday = DayRecord(id: UUID(), capturedAt: day.addingTimeInterval(-1), kind: .voice, title: "old", text: "合同预算")
    let records = [match, distractor, image, yesterday]
    let end = day.addingTimeInterval(86400)
    let result = await index.search(query: original, records: records, dayStart: day, dayEnd: end, allowedKinds: [.voice, .image], limit: 1)
    precondition(result.hits.first?.id == match.id, "translated query must drive semantic ranking while original kind/date bound the candidates")
    precondition(result.query == original && result.keywords?.query == original && result.keywords?.terms.contains("kate") == true,
                 "history, fulltext, names and intent must retain the original question")
    precondition(result.status.contains("端上翻译"), "translation use is visible in retrieval diagnostics")
    let evidence = try DaybookRetrieval().prepare(question: original, records: records, selectedDate: day, allowedKinds: [.voice, .image], semantic: result)
    precondition(evidence.question == original && evidence.sources.contains { $0.id == match.id } && !evidence.context.contains("凯特") && !evidence.sources.contains { $0.id == image.id || $0.id == yesterday.id },
                 "translation never becomes source evidence or expands scope")
    let persisted = try db.query("SELECT snippet FROM semantic_chunks")
    precondition(!persisted.contains { $0["snippet"]?.string?.contains("凯特") == true }, "translated queries are not persisted as corpus")
    _ = await index.search(query: original, records: records, dayStart: day, dayEnd: end, allowedKinds: [.voice, .image], limit: 1)
    let reusedCalls = await translator.calls
    precondition(reusedCalls == 1, "incremental indexing reuses the successful query translation")
    index.invalidateResources()
    _ = await index.search(query: original, records: records, dayStart: day, dayEnd: end, allowedKinds: [.voice, .image], limit: 1)
    let refreshedCalls = await translator.calls
    precondition(refreshedCalls == 2, "resource changes invalidate translated query cache")
    _ = await index.search(query: "合同预算", records: records, dayStart: day, dayEnd: end, allowedKinds: [.voice], limit: 1)
    let sameLanguageCalls = await translator.calls
    precondition(sameLanguageCalls == 2, "same-language production queries skip translation")

    for mode in [RetrievalTranslator.Mode.missing, .failed] {
        let service = DaybookSemanticIndex(database: db, embedding: model, translator: RetrievalTranslator(mode))
        let fallback = await service.search(query: original, records: records, dayStart: day, dayEnd: end, allowedKinds: [.voice], limit: 1)
        precondition(fallback.keywords?.aiScores[match.id] != nil && fallback.query == original && fallback.status.contains("原问题"),
                     "translation failures retain useful original keyword retrieval and visible fallback")
    }
    for cancel in [false, true] {
        let raceDB = try DaybookDatabase(url: directory.appendingPathComponent("translation-race-\(cancel).sqlite3"))
        let delayed = RetrievalTranslator(.delayed)
        let service = DaybookSemanticIndex(database: raceDB, embedding: model, translator: delayed)
        let task = Task { await service.search(query: original, records: records, dayStart: day, dayEnd: end, allowedKinds: [.voice], limit: 1) }
        for _ in 0..<500 { if await delayed.isWaiting { break }; try await Task.sleep(for: .milliseconds(10)) }
        let waiting = await delayed.isWaiting
        precondition(waiting, "test must suspend inside translation")
        if cancel { task.cancel() } else { try await service.clear() }
        await delayed.finish()
        let late = await task.value
        precondition(late.hits.isEmpty && (cancel || !service.isCurrent(late)), "cancelled or invalidated translation cannot publish results")
        let rows = try raceDB.query("SELECT id FROM semantic_records")
        precondition(rows.isEmpty, "late translation cannot repopulate cleared vectors")
    }
    print("Production query translation: ranking, originals, scope, fallback, cache and cancellation passed")
    // Actor reentrancy: another query may replace this UUID's date projection while translation awaits.
    let scopedDB = try DaybookDatabase(url: directory.appendingPathComponent("translation-scope-race.sqlite3"))
    let paused = RetrievalTranslator(.delayed)
    let scopedIndex = DaybookSemanticIndex(database: scopedDB, embedding: model, translator: paused)
    var acrossMidnight = DayRecord(id: UUID(), capturedAt: day.addingTimeInterval(86390), kind: .voice,
        title: "跨夜录音", text: "合同预算 NEXT_DAY_PRIVATE", duration: 30,
        intervals: [DateInterval(start: day.addingTimeInterval(86390), duration: 30)])
    acrossMidnight.contentProvenance = .init(segmentID: acrossMidnight.id, sourceID: UUID(), sourceKind: "session", sourceRevision: 1, segmentRevision: 1,
        configurationKey: "fixture", contentSignature: "midnight", sourceDate: acrossMidnight.capturedAt,
        ranges: [.init(chunkID: UUID(), startFrame: 0, endFrame: 300, sampleRate: 10, sourceOffset: 0)],
        transcript: [.init(start: 1, end: 5, text: "合同预算"), .init(start: 15, end: 20, text: "NEXT_DAY_PRIVATE")])
    let narrowTask = Task { await scopedIndex.search(query: "budget", records: [acrossMidnight], dayStart: day, dayEnd: end, allowedKinds: [.voice]) }
    for _ in 0..<500 { if await paused.isWaiting { break }; try await Task.sleep(for: .milliseconds(10)) }
    let narrowWaiting = await paused.isWaiting
    precondition(narrowWaiting, "narrow query must suspend before broad query replaces projection")
    let broad = await scopedIndex.search(query: "合同预算", records: [acrossMidnight], dayStart: day, dayEnd: end.addingTimeInterval(86400), allowedKinds: [.voice])
    precondition(broad.hits.first?.snippet.contains("NEXT_DAY_PRIVATE") == true)
    await paused.finish()
    let narrow = await narrowTask.value
    precondition(narrow.hits.first?.snippet == "合同预算", "resumed narrow query must not consume broad same-UUID projection")
    print("Translation scope race: same-UUID narrow query rejects broader projection passed")
    if CommandLine.arguments.contains("--apple-live") {
        try await liveAppleRetrieval(directory: directory, day: day)
    }
}

private func liveAppleRetrieval(directory: URL, day: Date) async throws {
    guard #available(macOS 26.0, iOS 26.0, *),
          let model = AppleDaybookEmbedding.make(language: "zh-Hans") else {
        preconditionFailure("live acceptance requires Apple contextual resources and OS 26")
    }
    let state = await AppleQueryTranslator.resourceState(to: .chinese)
    precondition(state == .installed, "live acceptance requires installed Apple Translation resources")
    let db = try DaybookDatabase(url: directory.appendingPathComponent("translation-live.sqlite3"))
    let service = DaybookSemanticIndex(database: db, embedding: model, translator: AppleQueryTranslator())
    let budget = DayRecord(id: UUID(), capturedAt: day, kind: .voice, title: "项目会议", text: "我们决定削减项目预算，取消外包设计，把节省下来的费用留给核心研发团队。")
    let meal = DayRecord(id: UUID(), capturedAt: day, kind: .voice, title: "晚餐", text: "下班后和朋友去了意大利餐厅，点了披萨和蘑菇汤，聊起周末去公园散步。")
    let travel = DayRecord(id: UUID(), capturedAt: day, kind: .voice, title: "机场", text: "飞机落地后在机场乘出租车去公司，一路高速行驶，司机按导航前往办公楼。")
    let question = "What did the team decide about cutting the project budget?"
    let result = await service.search(query: question, records: [budget, meal, travel], dayStart: day,
                                     dayEnd: day.addingTimeInterval(86400), allowedKinds: [.voice], limit: 1)
    precondition(result.status.contains("已端上翻译") && result.hits.first?.id == budget.id && result.hits.first?.snippet == budget.text,
                 "real Apple Translation, contextual embedding and SQLite Vector must retrieve unchanged Chinese source text")
    print("Live Mac Apple Translation → contextual embedding → SQLite Vector: passed (English question, Chinese source)")
}
