import Foundation

@main
struct DaybookRetrievalSmoke {
    @MainActor
    static func main() async throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        func date(_ value: String) -> Date { ISO8601DateFormatter().date(from: value)! }
        let now = date("2026-10-19T12:00:00+08:00")
        let selected = date("2026-10-17T08:00:00+08:00")
        let first = DayRecord(id: UUID(), capturedAt: date("2026-10-19T00:00:00+08:00"), kind: .voice,
                              title: "客户会议", text: "与客户讨论海风项目，约定周五发送报价。", duration: 95)
        let last = DayRecord(id: UUID(), capturedAt: date("2026-10-19T23:59:59+08:00"), kind: .image,
                             title: "购物小票", text: "苹果与牛奶")
        let yesterday = DayRecord(id: UUID(), capturedAt: date("2026-10-18T23:59:59+08:00"), kind: .thought,
                                  title: "昨天的想法", text: "散步时想到新的阅读计划", duration: 15)
        let tomorrow = DayRecord(id: UUID(), capturedAt: date("2026-10-20T00:00:00+08:00"), kind: .voice,
                                 title: "明天", text: "不应出现在今天", duration: 30)
        let historical = DayRecord(id: UUID(), capturedAt: selected, kind: .voice,
                                   title: "旧笔记", text: "过去的项目", duration: 10)
        let records = [tomorrow, first, yesterday, last, historical]
        let service = DaybookRetrieval(calendar: calendar)

        // Removing calendar boundaries would leak yesterday/tomorrow; today must ignore selected date.
        let today = try service.prepare(question: "今天有多少条记录？", records: records, selectedDate: selected, now: now)
        precondition(today.statistics.totalCount == 2)
        precondition(today.statistics.voiceCount == 1 && today.statistics.imageCount == 1)
        precondition(today.statistics.audioDuration == 95)
        precondition(today.directResponse != nil)
        let previous = try service.prepare(question: "昨天记录了什么？", records: records, selectedDate: selected, now: now)
        precondition(previous.sources.map(\.id) == [yesterday.id])
        let implicit = try service.prepare(question: "回顾这一天", records: records, selectedDate: selected, now: now)
        precondition(implicit.sources.map(\.id) == [historical.id])
        let followUp = try service.prepare(question: "这一天最值得跟进什么？", records: records, selectedDate: now, now: now)
        precondition(Set(followUp.sources.map(\.id)) == Set([first.id, last.id]) && followUp.directResponse == nil,
                     "The suggested follow-up prompt must retrieve the selected day's evidence")
        let imagePrompt = try service.prepare(question: "这一天的图片记录了什么？", records: records, selectedDate: now, now: now)
        precondition(imagePrompt.sources.map(\.id) == [last.id] && imagePrompt.directResponse == nil)
        let explicit = try service.prepare(question: "2026-10-18 记录了什么", records: records, selectedDate: selected, now: now)
        precondition(explicit.sources.map(\.id) == [yesterday.id])

        // Chinese retrieval must find a shared concept without whitespace, while excluding unrelated text.
        let match = try service.prepare(question: "今天客户说了什么？", records: records, selectedDate: selected, now: now)
        precondition(match.sources.map(\.id) == [first.id])
        precondition(match.context.contains(first.id.uuidString))
        precondition(!match.context.contains(last.text))
        let noMatch = try service.prepare(question: "今天羽毛球比赛怎么样？", records: records, selectedDate: selected, now: now)
        precondition(noMatch.sources.isEmpty && noMatch.directResponse != nil)
        let empty = try service.prepare(question: "回顾这一天", records: [], selectedDate: selected, now: now)
        precondition(empty.sources.isEmpty && empty.directResponse != nil && empty.statistics.totalCount == 0)
        let unreadable = DayRecord(id: UUID(), capturedAt: now, kind: .voice, title: "客户会议", text: " \n ")
        let withoutText = try service.prepare(question: "回顾这一天", records: [unreadable], selectedDate: now, now: now)
        precondition(withoutText.directResponse != nil, "A title without transcription must not cause model generation")
        let photoCount = try service.prepare(question: "今天拍了几张照片？", records: records, selectedDate: selected, now: now)
        precondition(photoCount.matchedCount == 1, "Taking photos is query scaffolding, not an OCR keyword")
        precondition(photoCount.directResponse?.contains("不表示照片张数") == true,
                     "Image moments must not be misrepresented as individual photo counts")

        // A per-source cap must preserve a late matching phrase; total stats cannot be based on a top-k subset.
        let large = (0..<12).map { index in
            DayRecord(id: UUID(), capturedAt: now.addingTimeInterval(Double(index)), kind: .voice,
                      title: "笔记 \(index)", text: String(repeating: "前面的普通内容。", count: 300) + "海风客户需要报价明细。",
                      duration: 10)
        }
        let limited = try DaybookRetrieval(calendar: calendar, limits: .init(maxSources: 3, maxSnippetCharacters: 120, maxContextCharacters: 700))
            .prepare(question: "今天海风客户的报价", records: large, selectedDate: selected, now: now)
        precondition(limited.context.count <= 700 && limited.sources.count <= 3)
        precondition(limited.sources.first?.snippet.contains("海风客户") == true)
        precondition(limited.statistics.totalCount == 12 && limited.statistics.audioDuration == 120)
        precondition(limited.sources.allSatisfy { $0.snippet.count <= 120 })

        // Deletion, text edits and source revocation must invalidate already prepared evidence.
        precondition(match.isCurrent(records: records, allowedKinds: [.voice, .thought, .image]))
        precondition(!match.isCurrent(records: records.filter { $0.id != first.id }, allowedKinds: [.voice, .thought, .image]))
        let edited = DayRecord(id: first.id, capturedAt: first.capturedAt, kind: .voice, title: first.title,
                               text: "客户取消了报价。", duration: first.duration)
        precondition(!match.isCurrent(records: records.map { $0.id == first.id ? edited : $0 }, allowedKinds: [.voice, .thought, .image]))
        precondition(!match.isCurrent(records: records, allowedKinds: [.image]))
        let privateOnly = try service.prepare(question: "今天有多少条记录", records: records, selectedDate: selected,
                                             now: now, allowedKinds: [.image])
        precondition(privateOnly.statistics.totalCount == 1 && privateOnly.statistics.audioDuration == 0)
        precondition(!privateOnly.context.contains(first.text))
        let noneAllowed = try service.prepare(question: "今天记录了什么", records: records, selectedDate: selected, now: now, allowedKinds: [])
        precondition(noneAllowed.sources.isEmpty && noneAllowed.statistics.totalCount == 0)

        // Day length follows the user's timezone, including DST rather than fixed 24-hour arithmetic.
        var dstCalendar = Calendar(identifier: .gregorian)
        dstCalendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        let dst = try DaybookRetrieval(calendar: dstCalendar).prepare(question: "回顾这一天", records: [],
            selectedDate: date("2026-03-08T12:00:00-07:00"), now: now)
        precondition(dst.dayEnd.timeIntervalSince(dst.dayStart) == 23 * 3600)

        let range = try service.prepare(question: "最近一周发生了什么", records: records, selectedDate: selected, now: now)
        precondition(range.directResponse != nil && range.sources.isEmpty)
        let cost = try service.prepare(question: "今天客户报价多少钱？", records: records, selectedDate: selected, now: now)
        precondition(cost.directResponse == nil, "Questions about monetary facts must not be answered as record counts")
        let requests = try service.prepare(question: "今天客户有几条需求？", records: records, selectedDate: selected, now: now)
        precondition(requests.directResponse == nil, "Counting customer requests is not a record-count question")
        do {
            _ = try service.prepare(question: "2026-02-30 有什么记录", records: records, selectedDate: selected, now: now)
            preconditionFailure("Invalid explicit dates must not silently use the selected day")
        } catch is DaybookRetrieval.Failure { }
        #if DAYBOOK_ASSISTANT_MODEL_TESTS
        try await assistantModelTests()
        #endif
        print("DaybookRetrievalSmoke passed: date boundaries, Chinese search, bounded snippets, complete-day counts, source invalidation, privacy, DST")
    }
}

#if DAYBOOK_ASSISTANT_MODEL_TESTS
// The only double is the unavailable/slow model boundary. Retrieval, invalidation and task state are real.
@MainActor
private final class DelayedDaybookAnswerService: DaybookAnswering {
    var calls = 0
    private var continuations: [CheckedContinuation<String, Error>] = []
    func answer(_ prepared: DaybookRetrieval.Prepared, configuration: AIConfiguration, apiKey: String?) async throws -> String {
        calls += 1
        return try await withCheckedThrowingContinuation { continuations.append($0) }
    }
    func finishOldest(_ text: String) { continuations.removeFirst().resume(returning: text) }
}

private final class DaybookTestSecrets: SecretStore {
    var reads = 0
    func read() throws -> String { reads += 1; return "not-a-real-secret" }
    func write(_ value: String) throws { }
}

@MainActor
private func assistantModelTests() async throws {
    let suiteName = "DaybookAssistantSmoke-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let secrets = DaybookTestSecrets()
    let settings = AppSettings(defaults: defaults, secrets: secrets)
    let service = DelayedDaybookAnswerService()
    let model = DaybookAssistantModel(answerService: service)
    let now = Date()
    let note = DayRecord(id: UUID(), capturedAt: now, kind: .voice, title: "客户会议", text: "客户明天需要报价", duration: 20)
    let all: Set<DayRecord.Kind> = [.voice, .thought, .image]
    func ask(_ question: String, records: [DayRecord] = []) {
        model.ask(question, records: records, selectedDate: now, allowedKinds: all, settings: settings)
    }
    func waitForCalls(_ count: Int) async {
        for _ in 0..<1_000 {
            if service.calls == count { return }
            await Task.yield()
        }
        preconditionFailure("Expected model request did not start")
    }
    ask("回顾这一天")
    precondition(model.answer?.generated == false && !model.isPending && service.calls == 0)
    ask("这一天有多少条记录？", records: [note])
    precondition(model.answer?.generated == false && service.calls == 0)

    // A deleted source must immediately clear evidence and must not reappear when generation returns.
    ask("客户说了什么？", records: [note])
    await waitForCalls(1)
    model.synchronize(records: [], selectedDate: now, allowedKinds: all, configuration: settings.ai)
    precondition(model.prepared == nil && model.answer == nil && !model.isPending)
    service.finishOldest("旧回答 [1]")
    for _ in 0..<20 { await Task.yield() }
    precondition(model.answer == nil)

    // A cancellation-ignoring old provider result cannot overwrite the newest question's answer.
    ask("客户说了什么？", records: [note])
    await waitForCalls(2)
    model.cancel()
    ask("回顾这一天", records: [note])
    await waitForCalls(3)
    service.finishOldest("被取消的旧回答 [1]")
    for _ in 0..<20 { await Task.yield() }
    precondition(model.answer == nil && model.isPending)
    service.finishOldest("客户需要报价 [1]")
    for _ in 0..<100 where model.isPending { await Task.yield() }
    precondition(model.answer?.text == "客户需要报价 [1]" && !model.isPending)
    model.synchronize(records: [note], selectedDate: now, allowedKinds: [.image], configuration: settings.ai)
    precondition(model.answer == nil && model.prepared == nil)

    // Remote credentials and generation are untouched until this exact text request is confirmed.
    var configuration = settings.ai
    configuration.mode = .custom; configuration.model = "test-model"; configuration.baseURL = "https://example.invalid/v1"
    try settings.saveAI(configuration, apiKey: "not-a-real-secret")
    ask("客户说了什么？", records: [note])
    precondition(model.remoteConfirmation != nil && !model.isPending && service.calls == 3 && secrets.reads == 0)
    model.confirmRemote(records: [], selectedDate: now, allowedKinds: all, settings: settings)
    precondition(model.remoteConfirmation == nil && service.calls == 3 && secrets.reads == 0)
    ask("客户说了什么？", records: [note])
    model.confirmRemote(records: [note], selectedDate: now, allowedKinds: all, settings: settings)
    await waitForCalls(4)
    precondition(secrets.reads == 1)
    service.finishOldest("客户需要报价 [1]")
    for _ in 0..<100 where model.isPending { await Task.yield() }
    precondition(model.answer?.generated == true && !model.isPending)
    print("DaybookAssistantModel smoke passed: no-data/count bypass, deletion, cancellation, late response, permissions, per-request remote confirmation")
}
#endif
