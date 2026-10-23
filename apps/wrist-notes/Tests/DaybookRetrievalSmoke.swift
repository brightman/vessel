import Foundation
import SQLite3

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

        // Automatic Ask AI is independent of the homepage date, keeps hard time boundaries,
        // and only expands a soft "recent" scope when requested by the loader.
        let autoAll = try service.prepare(question: "项目说了什么？", records: records, selectedDate: selected, now: now, automatic: true)
        precondition(Set(autoAll.sources.map(\.id)) == Set([first.id, historical.id]))
        let autoRecent = try service.prepare(question: "最近有哪些记录？", records: records, selectedDate: selected, now: now, automatic: true)
        precondition(autoRecent.statistics.totalCount == 4 && !autoRecent.sources.contains { $0.id == tomorrow.id })
        let autoMonth = try service.prepare(question: "上个月有哪些记录？", records: records, selectedDate: selected, now: now, automatic: true)
        precondition(calendar.component(.month, from: autoMonth.dayStart) == 9 && autoMonth.statistics.totalCount == 0)
        let autoRange = try service.prepare(question: "10月17日到10月18日有哪些记录？", records: records, selectedDate: now, now: now, automatic: true)
        precondition(Set(autoRange.sources.map(\.id)) == Set([historical.id, yesterday.id]))
        precondition(autoRange.context.contains("2026-10-17") && autoRange.context.contains("2026-10-18"))
        let autoDenied = try service.prepare(question: "项目说了什么？", records: records, selectedDate: selected, now: now, allowedKinds: [.image], automatic: true)
        precondition(autoDenied.sources.isEmpty)

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
        try await automaticScopeLoadingTests()
        try await requestedContentScopeTests()
        try await durableSourceDeletionTests()
        try await remoteConfirmationPreferenceTests()
        try await historyReviewRegressions()
        try await historyRetentionTests()
        try await historyPagingTests()
        try sqlPayloadFreshness()
        try await semanticAssistantTests()
        try await assistantModelTests()
        try await conversationTests()
        try await conversationPersistenceTests()
        #endif
        print("DaybookRetrievalSmoke passed: date boundaries, Chinese search, bounded snippets, complete-day counts, source invalidation, privacy, DST")
    }
}

#if DAYBOOK_ASSISTANT_MODEL_TESTS
@MainActor
private func automaticScopeLoadingTests() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at:root) }
    let suite = "AutoScope-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName:suite)!
    defer { defaults.removePersistentDomain(forName:suite) }
    let settings = AppSettings(defaults:defaults,secrets:DaybookTestSecrets())
    let now = Date.now
    let old = Calendar.current.date(byAdding:.day,value:-40,to:now)!
    let record = DayRecord(id:UUID(),capturedAt:old,kind:.voice,title:"旧录音",text:"客户项目记录",duration:10)
    let model = DaybookAssistantModel(store:DaybookConversationStore(url:root.appendingPathComponent("auto.json")))
    var scopes: [DateInterval] = []
    model.scopeLoader = { scope in scopes.append(scope); return scope.contains(old) ? [record] : [] }
    model.ask("最近有多少条记录？",records:[],selectedDate:old,allowedKinds:[.voice],settings:settings)
    for _ in 0..<2000 { if !model.isPending && model.answer != nil { break }; await Task.yield() }
    precondition(scopes.count == 2 && scopes[0].duration < 8*86400 && scopes[1].contains(old), "Soft recent query must load again before expanding evidence")
    precondition(model.answer?.sources.first?.id == record.id && model.answer?.scopeDescription.contains("扩大") == true)
    scopes = []
    model.ask("过去7天有多少条记录？",records:[],selectedDate:old,allowedKinds:[.voice],settings:settings)
    for _ in 0..<2000 { if !model.isPending && model.answer != nil { break }; await Task.yield() }
    precondition(scopes.count == 1 && model.answer?.sources.isEmpty == true, "Explicit durations cannot silently expand")
    scopes = []
    model.ask("昨天有多少条记录？",records:[],selectedDate:old,allowedKinds:[.voice],settings:settings)
    for _ in 0..<2000 { if !model.isPending && model.answer != nil { break }; await Task.yield() }
    precondition(scopes.count == 1 && scopes[0].duration <= 25*3600 && !scopes[0].contains(old))
    print("Automatic scope loading: soft expansion, hard duration/date boundaries passed")
}

@MainActor
private func requestedContentScopeTests() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at:root) }
    let suite = "ContentScope-\(UUID())"
    let defaults = UserDefaults(suiteName:suite)!
    defer { defaults.removePersistentDomain(forName:suite) }
    let settings = AppSettings(defaults:defaults,secrets:DaybookTestSecrets())
    let selected = Calendar.current.startOfDay(for:Date())
    let target = Calendar.current.date(from:DateComponents(year:2001,month:1,day:1))!
    let scopeStore = DaybookConversationStore(url:root.appendingPathComponent("history.json"))
    let model = DaybookAssistantModel(store:scopeStore)
    let rows = (0..<121).map { _ in DayRecord(id:UUID(),capturedAt:target,kind:.voice,title:"old",text:"scope",duration:1) }
    var requested: DateInterval?
    model.scopeLoader = { scope in requested = scope; return rows }
    model.ask("2001-01-01 有多少条记录？",records:[],selectedDate:selected,allowedKinds:[.voice],settings:settings)
    for _ in 0..<1000 { if !model.isPending && model.answer != nil { break }; await Task.yield() }
    precondition(requested?.start == target && model.prepared?.statistics.totalCount == 121,"explicit old date loads complete evidence independently of UI selection")
    precondition(model.prepared?.isCurrent(records:model.recordsForEvidence([]),allowedKinds:[.voice]) == true,"loaded evidence stays current through UI base")
    model.scopeLoader = { _ in throw URLError(.cannotLoadFromNetwork) }
    model.ask("2001-01-01 有多少条记录？",records:[],selectedDate:selected,allowedKinds:[.voice],settings:settings)
    for _ in 0..<1000 { if !model.isPending { break }; await Task.yield() }
    precondition(model.errorMessage != nil,"incomplete scope reports failure rather than a complete empty day")
    var continuation: CheckedContinuation<[DayRecord],Never>?
    model.scopeLoader = { _ in await withCheckedContinuation { continuation = $0 } }
    model.ask("2001-01-01 有多少条记录？",records:[],selectedDate:selected,allowedKinds:[.voice],settings:settings)
    for _ in 0..<1000 { if continuation != nil { break }; await Task.yield() }
    let pendingScope = try scopeStore.loadPage().turns.last
    precondition(pendingScope?.completionState == .pending,"question persisted before scope read completes")
    model.invalidateLoadedScope(); continuation?.resume(returning:rows)
    for _ in 0..<100 { await Task.yield() }
    precondition(model.prepared == nil && !model.isPending,"mutation rejects late scope load")
    let sameSource = UUID()
    var parent = DayRecord(id:sameSource,capturedAt:target,kind:.voice,title:"fallback",text:"old parent",duration:selected.timeIntervalSince(target)+10,intervals:[DateInterval(start:target,end:selected.addingTimeInterval(10))])
    parent.recordingSessionID = sameSource
    let childID = UUID()
    var uiChild = DayRecord(id:childID,capturedAt:selected,kind:.voice,title:"selected",text:"selected child",duration:10,intervals:[DateInterval(start:selected,duration:10)])
    uiChild.contentProvenance = .init(segmentID:childID,sourceID:sameSource,sourceKind:"session",sourceRevision:1,segmentRevision:1,configurationKey:"v1",contentSignature:"sig",sourceDate:target,ranges:[],transcript:[])
    model.scopeLoader = { _ in [parent] }
    model.ask("2001-01-01 有多少条记录？",records:[uiChild],selectedDate:selected,allowedKinds:[.voice],settings:settings)
    for _ in 0..<1000 where model.isPending { await Task.yield() }
    precondition(model.prepared?.statistics.totalCount == 1 && model.prepared?.statistics.audioDuration == 86400,"selected-date child cannot suppress same-source parent loaded for explicit earlier date")
    print("Requested content scope: old date, 121 rows, read failure and late invalidation passed")
}

@MainActor
private func durableSourceDeletionTests() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at:root) }
    let suite = "DurableSourceDeletion-\(UUID())"
    let defaults = UserDefaults(suiteName:suite)!
    defer { defaults.removePersistentDomain(forName:suite) }
    let settings = AppSettings(defaults:defaults,secrets:DaybookTestSecrets())
    try settings.saveAI(AIConfiguration(mode:.custom,model:"fixture",baseURL:"https://example.invalid/v1"),apiKey:"fixture-key")
    let notes = try NoteRepository(root:root)
    let selected = Calendar.current.startOfDay(for:Date())
    let target = Calendar.current.date(from:DateComponents(year:2001,month:1,day:1))!
    func fixture() throws -> DayRecord {
        let id = UUID(), incoming = root.appendingPathComponent("\(UUID()).m4a")
        try Data([1,2,3]).write(to:incoming)
        _ = try notes.importRecording(id:id,from:incoming,kind:.long,capturedAt:target,duration:10)
        let segmentID = UUID()
        var record = DayRecord(id:segmentID,capturedAt:target,kind:.voice,title:"客户",text:"客户需要报价",duration:10,intervals:[DateInterval(start:target,duration:10)])
        record.contentProvenance = .init(segmentID:segmentID,sourceID:id,sourceKind:"legacyNote",sourceRevision:1,segmentRevision:1,configurationKey:"fixture",contentSignature:"fixture",sourceDate:target,ranges:[.init(chunkID:id,startFrame:0,endFrame:100,sampleRate:10,sourceOffset:0)],transcript:[.init(start:0,end:10,text:"客户需要报价")])
        return record
    }
    let loadingRecord = try fixture(), loadingService = DelayedDaybookAnswerService()
    let loading = DaybookAssistantModel(answerService:loadingService,store:DaybookConversationStore(url:root.appendingPathComponent("loading.json")))
    var continuation: CheckedContinuation<[DayRecord],Never>?
    loading.scopeLoader = { _ in await withCheckedContinuation { continuation = $0 } }
    loading.ask("2001-01-01 客户说了什么？",records:[],selectedDate:selected,allowedKinds:[.voice],settings:settings)
    for _ in 0..<1000 where continuation == nil { await Task.yield() }
    precondition(continuation != nil && loading.isPending)
    try notes.delete(id:loadingRecord.contentProvenance!.sourceID)
    for _ in 0..<1000 where loading.isPending { await Task.yield() }
    precondition(!loading.isPending,"actual durable deletion cancels outstanding scope load")
    continuation?.resume(returning:[loadingRecord])
    for _ in 0..<100 { await Task.yield() }
    precondition(loading.prepared == nil && loading.remoteConfirmation == nil && loading.recordsForEvidence([loadingRecord]).isEmpty,"late loader and old UI snapshots stay fenced after deletion")
    let record = try fixture(), service = DelayedDaybookAnswerService()
    let model = DaybookAssistantModel(answerService:service,store:DaybookConversationStore(url:root.appendingPathComponent("remote.json")))
    model.scopeLoader = { _ in [record] }
    model.ask("2001-01-01 客户说了什么？",records:[],selectedDate:selected,allowedKinds:[.voice],settings:settings)
    for _ in 0..<1000 where model.remoteConfirmation == nil { await Task.yield() }
    precondition(model.remoteConfirmation != nil && model.recordsForEvidence([]).count == 1)
    try notes.delete(id:record.contentProvenance!.sourceID)
    for _ in 0..<1000 where model.remoteConfirmation != nil { await Task.yield() }
    precondition(model.prepared == nil && model.remoteConfirmation == nil && model.recordsForEvidence([record]).isEmpty,"durable delete clears loaded evidence and prepared remote confirmation")
    model.confirmRemote(records:[record],selectedDate:selected,allowedKinds:[.voice],settings:settings,doNotAskAgain:true)
    precondition(service.calls == 0 && settings.requiresRemoteAIConfirmation,"deleted source cannot send or persist confirmation preference")
    print("Durable legacy deletion: cache fence, pending loader and prepared remote send invalidation passed")
}

@MainActor
private func remoteConfirmationPreferenceTests() async throws {
    let suite = "RemoteAIConfirmation-\(UUID())"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let secrets = DaybookTestSecrets()
    var settings = AppSettings(defaults: defaults, secrets: secrets)
    precondition(settings.requiresRemoteAIConfirmation, "Existing and new installs must keep confirmation enabled")
    precondition(!settings.authorizeRemoteAISend(confirmationIsCurrent: nil, rememberChoice: true), "An absent confirmation cannot save a checkbox choice")
    precondition(settings.requiresRemoteAIConfirmation)
    try settings.saveAI(AIConfiguration(mode: .custom, model: "fixture", baseURL: "https://example.invalid/v1"), apiKey: "fixture-key")
    let service = DelayedDaybookAnswerService()
    let model = DaybookAssistantModel(answerService: service, store: DaybookConversationStore(url: root.appendingPathComponent("history.json")))
    let day = Date()
    let note = DayRecord(id: UUID(), capturedAt: day, kind: .voice, title: "客户会议", text: "客户明天需要报价")
    func ask() { model.ask("客户说了什么？", records: [note], selectedDate: day, allowedKinds: [.voice], settings: settings) }
    func finish(_ expectedCalls: Int) async {
        for _ in 0..<1000 where service.calls < expectedCalls { await Task.yield() }
        precondition(service.calls == expectedCalls)
        service.finishOldest("客户需要报价 [1]")
        for _ in 0..<1000 where model.isPending { await Task.yield() }
        precondition(model.answer?.text == "客户需要报价 [1]" && !model.isPending)
    }
    ask()
    precondition(model.remoteConfirmation != nil && !model.isPending && secrets.reads == 0)
    model.dismissRemoteConfirmation()
    precondition(settings.requiresRemoteAIConfirmation && service.calls == 0, "Cancel must not remember a choice or send")
    ask()
    model.confirmRemote(records: [], selectedDate: day, allowedKinds: [.voice], settings: settings, doNotAskAgain: true)
    precondition(settings.requiresRemoteAIConfirmation && service.calls == 0, "Stale confirmation must neither send nor save the checkbox")
    ask()
    model.confirmRemote(records: [note], selectedDate: day, allowedKinds: [.voice], settings: settings)
    await finish(1)
    precondition(settings.requiresRemoteAIConfirmation, "Unchecked send must retain future prompts")
    ask()
    precondition(model.remoteConfirmation != nil)
    model.confirmRemote(records: [note], selectedDate: day, allowedKinds: [.voice], settings: settings, doNotAskAgain: true)
    await finish(2)
    settings = AppSettings(defaults: defaults, secrets: secrets)
    precondition(!settings.requiresRemoteAIConfirmation, "Confirmed choice must survive settings reload")
    precondition(!settings.authorizeRemoteAISend(confirmationIsCurrent: false, rememberChoice: true), "Saved opt-out must never authorize a stale preview")
    ask()
    precondition(model.remoteConfirmation == nil && model.isPending, "Saved do-not-ask choice must start the next remote answer without a confirmation sheet")
    await finish(3)
    ask()
    model.synchronize(records: [note], selectedDate: day, allowedKinds: [], configuration: settings.ai, configurationRevision: settings.aiRevision)
    for _ in 0..<1000 { await Task.yield() }
    precondition(service.calls == 3 && !model.isPending, "Opt-out must still honor data revocation before provider task entry")
    settings.requiresRemoteAIConfirmation = true
    settings = AppSettings(defaults: defaults, secrets: secrets)
    ask()
    precondition(model.remoteConfirmation != nil && service.calls == 3 && settings.requiresRemoteAIConfirmation, "Restoring the setting must reinstate the next prompt and persist")
    model.dismissRemoteConfirmation()
    try settings.saveAI(AIConfiguration(), apiKey: "")
    ask()
    precondition(model.remoteConfirmation == nil && model.isPending, "Local AI must not show an external send confirmation")
    await finish(4)
    print("Remote AI confirmation preference: default, cancel, stale preview, unchecked/checked send, reload, skip, restore, data revocation and local AI passed")
}

// The only double is the unavailable/slow model boundary. Retrieval, invalidation and task state are real.
@MainActor
private final class DelayedDaybookAnswerService: DaybookAnswering {
    var calls = 0
    var requests: [DaybookRetrieval.Prepared] = []
    private var continuations: [CheckedContinuation<String, Error>] = []
    func answer(_ prepared: DaybookRetrieval.Prepared, configuration: AIConfiguration, apiKey: String?) async throws -> String {
        calls += 1
        requests.append(prepared)
        return try await withCheckedThrowingContinuation { continuations.append($0) }
    }
    func finishOldest(_ text: String) { continuations.removeFirst().resume(returning: text) }
    func failOldest() { continuations.removeFirst().resume(throwing: NSError(domain: "fixture", code: 1, userInfo: [NSLocalizedDescriptionKey: "测试模型不可用"])) }
}

@MainActor
private func historyRetentionTests() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let suite = "DaybookHistoryRetention-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let settings = AppSettings(defaults: defaults, secrets: DaybookTestSecrets())
    let url = root.appendingPathComponent("history.json")
    let store = DaybookConversationStore(url: url)
    let model = DaybookAssistantModel(store: store)
    let day = Calendar.current.startOfDay(for: Date())
    let note = DayRecord(id: UUID(), capturedAt: day, kind: .voice, title: "记录", text: "原始内容")
    let added = DayRecord(id: UUID(), capturedAt: day.addingTimeInterval(60), kind: .image, title: "新照片", text: "后来加入")
    let allowed: Set<DayRecord.Kind> = [.voice, .image]
    model.ask("这一天有多少条记录？", records: [note], selectedDate: day, allowedKinds: allowed, settings: settings)
    let first = model.turns.first!
    model.synchronize(records: [note, added], selectedDate: day, allowedKinds: allowed, configuration: settings.ai)
    precondition(model.turns.contains { $0.id == first.id && $0.question == first.question && $0.text == first.text },
                 "Adding a record must preserve completed chat history")
    let archived = try store.load().flatMap(\.turns)
    precondition(archived.contains { $0.id == first.id }, "A data refresh must not delete SQLite history")
    let restored = DaybookAssistantModel(store: DaybookConversationStore(url: url))
    restored.synchronize(records: [], selectedDate: day.addingTimeInterval(86400), allowedKinds: allowed, configuration: settings.ai)
    precondition(restored.validatedTurns(records: [], selectedDate: day.addingTimeInterval(86400), allowedKinds: allowed).contains { $0.id == first.id },
                 "History must survive reopen, temporarily absent sources, and selected-day changes")
    let edited = DayRecord(id: note.id, capturedAt: day, kind: .voice, title: note.title, text: "修改后的原始内容")
    let historical = DaybookConversationTurn(id: first.id, question: first.question, text: "旧结论不应进入新请求", generated: true,
        provider: "测试", evidence: first.evidence, sources: first.sources, scopeDescription: first.scopeDescription)
    let fresh = try DaybookRetrieval().prepare(question: "回顾这一天", records: [edited, added], selectedDate: day, allowedKinds: allowed, priorTurns: [historical])
    precondition(!fresh.context.contains("旧结论不应进入新请求") && fresh.context.contains("修改后的原始内容"),
                 "Keep old chat visible without treating its answer as current grounding")
    print("Conversation retention: new records, SQLite reopen, absent sources and date changes passed")
}

private final class DaybookTestSecrets: SecretStore {
    var reads = 0
    func read() throws -> String { reads += 1; return "not-a-real-secret" }
    func write(_ value: String) throws { }
}

@MainActor private func historyReviewRegressions() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let suite = "HistoryReview-\(UUID().uuidString)"; let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let settings = AppSettings(defaults: defaults, secrets: DaybookTestSecrets())
    let today = Calendar.current.startOfDay(for: Date())
    let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: today)!
    let allowed: Set<DayRecord.Kind> = [.voice]
    let note = DayRecord(id: UUID(), capturedAt: yesterday, kind: .voice, title: "客户", text: "客户需要报价")
    let evidence = try DaybookRetrieval().prepare(question: "昨天客户说了什么？", records: [note], selectedDate: today, allowedKinds: allowed)
    let store = DaybookConversationStore(url: root.appendingPathComponent("scope.json"))
    try store.saveTurn(DaybookConversationTurn(id: UUID(), question: evidence.question, text: "客户需要报价 [1]", generated: true, provider: "测试", evidence: evidence.evidence, sources: evidence.sources, scopeDescription: evidence.scopeDescription, state: .completed, createdAt: .now), day: today)
    let service = DelayedDaybookAnswerService()
    let model = DaybookAssistantModel(answerService: service, store: store)
    model.ask("那接下来呢？", records: [note], selectedDate: today, allowedKinds: allowed, settings: settings)
    precondition(model.prepared?.dayStart == yesterday, "Restart must preserve the selected day's previous evidence scope")
    for _ in 0..<1_000 { if service.calls == 1 { break }; await Task.yield() }
    precondition(service.calls == 1)
    service.failOldest()
    for _ in 0..<500 { await Task.yield() }
    precondition(model.turns.last?.completionState == .failed && model.prepared?.sources.first?.id == note.id && model.preparedTurnID == model.turns.last?.id,
                 "Local fallback evidence must remain bound to the failed question")
    let url = root.appendingPathComponent("retry.json")
    let db = try DaybookDatabase(url: DaybookDatabase.url(forLegacy: url))
    let paged = DaybookConversationStore(url: url, database: db)
    let empty = DaybookEvidenceSnapshot(records: [], dayStart: today, dayEnd: today.addingTimeInterval(86400), allowedKinds: allowed)
    for index in 0..<11 {
        try paged.saveTurn(DaybookConversationTurn(id: UUID(), question: "旧问题", text: "旧回答", generated: false, provider: "本地", evidence: empty, sources: [], scopeDescription: "", state: .completed, createdAt: .now.addingTimeInterval(Double(index - 20))), day: today)
    }
    let retry = DaybookAssistantModel(store: paged)
    try db.execute("CREATE TRIGGER fail_answer BEFORE UPDATE ON conversation_turns WHEN NEW.state = 'completed' BEGIN SELECT RAISE(ABORT, 'answer failure'); END")
    retry.ask("有多少条记录？", records: [], selectedDate: today, allowedKinds: allowed, settings: settings)
    precondition(retry.storageError != nil && retry.turns.last?.completionState == .pending)
    _ = try db.withConnection { sqlite3_set_authorizer($0, { _, action, table, _, _, _ in
        action == SQLITE_READ && table.map { String(cString: $0) } == "conversation_turns" ? SQLITE_DENY : SQLITE_OK
    }, nil) }
    retry.loadMoreHistory()
    _ = try db.withConnection { sqlite3_set_authorizer($0, nil, nil) }
    try db.execute("DROP TRIGGER fail_answer")
    retry.retryPersistence()
    precondition(retry.storageError == nil && retry.turns.last?.completionState == .completed,
                 "One retry must recover a transient history read before retrying its pending write")
    print("Conversation review regressions: restored follow-up date, local evidence fallback and combined read/write recovery passed")
}

@MainActor
private func assistantModelTests() async throws {
    let suiteName = "DaybookAssistantSmoke-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let secrets = DaybookTestSecrets()
    let settings = AppSettings(defaults: defaults, secrets: secrets)
    let service = DelayedDaybookAnswerService()
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let model = DaybookAssistantModel(answerService: service, store: DaybookConversationStore(url: root.appendingPathComponent("history.json")))
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
    ask("那接下来呢？", records: [note])
    precondition(model.remoteConfirmation?.context.contains("客户需要报价") == true,
                 "A follow-up must carry the preceding grounded answer context")
    print("DaybookAssistantModel smoke passed: no-data/count bypass, deletion, cancellation, late response, permissions, per-request remote confirmation")
}
#endif

#if DAYBOOK_ASSISTANT_MODEL_TESTS
@MainActor
private func conversationTests() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("history.json")
    let suite = "DaybookConversation-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let secrets = DaybookTestSecrets()
    let settings = AppSettings(defaults: defaults, secrets: secrets)
    let service = DelayedDaybookAnswerService()
    let model = DaybookAssistantModel(answerService: service, store: DaybookConversationStore(url: url))
    let today = Calendar.current.startOfDay(for: Date())
    let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: today)!
    let note = DayRecord(id: UUID(), capturedAt: yesterday.addingTimeInterval(3600), kind: .voice, title: "客户会议", text: "客户需要三份报价", duration: 20)
    let other = DayRecord(id: UUID(), capturedAt: yesterday.addingTimeInterval(7200), kind: .image, title: "路线", text: "沿海路线")
    let records = [note, other]
    let all: Set<DayRecord.Kind> = [.voice, .thought, .image]
    func sync(_ date: Date = today, _ data: [DayRecord]? = nil, _ kinds: Set<DayRecord.Kind>? = nil) {
        model.synchronize(records: data ?? records, selectedDate: date, allowedKinds: kinds ?? all, configuration: settings.ai)
    }
    func ask(_ question: String, _ date: Date = today) {
        model.ask(question, records: records, selectedDate: date, allowedKinds: all, settings: settings)
    }
    func wait(_ count: Int) async {
        for _ in 0..<1_000 { if service.calls == count { return }; await Task.yield() }
        preconditionFailure("Request did not start")
    }
    func settle() async { for _ in 0..<500 { await Task.yield() } }
    // Keeping only the current answer would lose the completed thread on restart/tab changes.
    ask("昨天客户说了什么？")
    await wait(1); service.finishOldest("客户需要三份报价 [1]"); await settle()
    precondition(model.turns.count == 1)
    let restored = DaybookAssistantModel(answerService: service, store: DaybookConversationStore(url: url))
    precondition(restored.turns.isEmpty, "Unvalidated private storage must not be exposed")
    restored.synchronize(records: records, selectedDate: today, allowedKinds: all, configuration: settings.ai)
    precondition(restored.turns.count == 1 && restored.turns[0].text == "客户需要三份报价 [1]")
    sync(yesterday); precondition(model.turns.count == 1, "Selected date changes the evidence scope, not chat history")
    sync(); precondition(model.turns.count == 1)

    // Actual evidence date follows a pronoun; old 昨天 words must never be resolved again.
    ask("那接下来呢？")
    await wait(2)
    let followup = service.requests.last!
    precondition(followup.dayStart == yesterday && followup.sources.contains { $0.id == note.id })
    precondition(followup.context.contains("客户需要三份报价") && followup.context.contains("昨天客户说了什么"))
    precondition(followup.context.contains("先前引用已移除"))
    service.finishOldest("应先整理三份报价 [1]"); await settle()
    precondition(model.turns.count == 2)
    ask("今天有哪些记录？")
    let formatter = DateFormatter(); formatter.dateFormat = "yyyy-MM-dd"
    precondition(model.answer?.text.contains(formatter.string(from: today)) == true)
    precondition(model.turns.last?.evidence.dayStart == today)

    // A scope edit must preserve completed chat; new answers re-ground against current records.
    let edited = DayRecord(id: other.id, capturedAt: other.capturedAt, kind: .image, title: other.title, text: "路线已取消")
    sync(today, [note, edited]); precondition(model.turns.count == 3)
    let validated = DaybookAssistantModel(answerService: service, store: DaybookConversationStore(url: url))
    validated.synchronize(records: [note, edited], selectedDate: today, allowedKinds: all, configuration: settings.ai)
    precondition(validated.turns.count == 3)
    ask("昨天客户说了什么？"); await wait(3)
    model.clearHistory()
    service.finishOldest("不能重新出现 [1]"); await settle()
    precondition(model.turns.isEmpty && model.answer == nil)
    let cleared = DaybookAssistantModel(answerService: service, store: DaybookConversationStore(url: url))
    cleared.synchronize(records: records, selectedDate: today, allowedKinds: all, configuration: settings.ai)
    precondition(cleared.turns.isEmpty)

    // Preview is the identical bounded context passed to the provider, including history.
    var configuration = settings.ai
    configuration.mode = .custom; configuration.model = "test-model"; configuration.baseURL = "https://example.invalid/v1"
    try settings.saveAI(configuration, apiKey: "not-a-real-secret")
    ask("昨天客户说了什么？")
    let preview = model.remoteConfirmation!
    precondition(secrets.reads == 0 && service.calls == 3)
    model.confirmRemote(records: records, selectedDate: today, allowedKinds: all, settings: settings)
    await wait(4)
    precondition(service.requests.last?.context == preview.context && service.requests.last?.question == preview.question)
    service.finishOldest("客户需要三份报价 [1]"); await settle()
    ask("那接下来呢？")
    let followPreview = model.remoteConfirmation!
    precondition(followPreview.context.contains("客户需要三份报价"))
    model.confirmRemote(records: records, selectedDate: today, allowedKinds: all, settings: settings)
    await wait(5)
    precondition(service.requests.last?.context == followPreview.context && secrets.reads == 2)
    model.synchronize(records: records, selectedDate: today, allowedKinds: [.image], configuration: settings.ai)
    precondition(model.turns.allSatisfy { $0.completionState == .redacted } && model.remoteConfirmation == nil && !model.isPending)
    service.finishOldest("被撤权的内容 [1]"); await settle()
    precondition(model.turns.allSatisfy { $0.completionState == .redacted })
    ask("昨天客户说了什么？")
    configuration.model = "changed-model"; try settings.saveAI(configuration, apiKey: "not-a-real-secret")
    model.confirmRemote(records: records, selectedDate: today, allowedKinds: all, settings: settings)
    precondition(model.remoteConfirmation == nil && secrets.reads == 2 && service.calls == 5)

    ask("昨天客户说了什么？")
    try settings.saveAI(configuration, apiKey: "replacement-test-secret")
    model.confirmRemote(records: records, selectedDate: today, allowedKinds: all, settings: settings)
    precondition(model.remoteConfirmation == nil && secrets.reads == 2 && service.calls == 5,
                 "Saving a replacement credential with identical configuration must invalidate consent")

    // Corrupt archives remain byte-for-byte intact until explicit reset.
    let corruptURL = root.appendingPathComponent("corrupt.json")
    let corrupt = Data("broken archive".utf8); try corrupt.write(to: corruptURL)
    let damaged = DaybookAssistantModel(answerService: service, store: DaybookConversationStore(url: corruptURL))
    damaged.synchronize(records: [], selectedDate: today, allowedKinds: all, configuration: settings.ai)
    precondition(damaged.storageError != nil)
    damaged.ask("有哪些记录？", records: [], selectedDate: today, allowedKinds: all, settings: settings)
    let preserved = try Data(contentsOf: corruptURL)
    precondition(preserved == corrupt)
    damaged.resetStorage()
    let reset = try DaybookConversationStore(url: corruptURL).load()
    precondition(damaged.storageError == nil && reset.isEmpty)

    // Failed saves are visible and retryable; failed reads never silently become an empty saved file.
    let blocker = root.appendingPathComponent("file-not-directory")
    try Data().write(to: blocker)
    let unwritable = DaybookAssistantModel(answerService: service, store: DaybookConversationStore(url: blocker.appendingPathComponent("history.json")))
    unwritable.ask("有哪些记录？", records: [], selectedDate: today, allowedKinds: all, settings: settings)
    precondition(unwritable.storageError != nil)
    try FileManager.default.removeItem(at: blocker)
    unwritable.retryPersistence()
    precondition(unwritable.storageError == nil)

    // Page size is not a storage limit: retain every turn across dates and reopen.
    let boundedURL = root.appendingPathComponent("bounded.json")
    let bounded = DaybookAssistantModel(answerService: service, store: DaybookConversationStore(url: boundedURL))
    for index in 0..<35 {
        let date = Calendar.current.date(byAdding: .day, value: -index, to: today)!
        for _ in 0..<(index == 0 ? 25 : 1) { bounded.ask("有哪些记录？", records: [], selectedDate: date, allowedKinds: all, settings: settings) }
    }
    let archive = try DaybookConversationStore(url: boundedURL).load()
    precondition(archive.count == 35 && archive.flatMap(\.turns).count == 59)
    // The previous [2] must become a fresh [1], without borrowing history's old numbering.
    let full = try DaybookRetrieval().prepare(question: "回顾这一天", records: records, selectedDate: yesterday, allowedKinds: all)
    let oldTurn = DaybookConversationTurn(id: UUID(), question: "[2] 的详细信息是什么？", text: "沿海路线 [2]", generated: true, provider: "测试",
        evidence: full.evidence, sources: full.sources, scopeDescription: full.scopeDescription, questionReferenceIDs: [2: other.id])
    let remapped = try DaybookRetrieval().prepare(question: "[2]提到客户吗？", records: records, selectedDate: yesterday, allowedKinds: all, priorTurns: [oldTurn])
    precondition(remapped.sources.first?.id == other.id && remapped.sources.first?.number == 1)
    precondition(remapped.sources.contains { $0.id == note.id })
    precondition(!remapped.context.contains("沿海路线 [2]"))
    precondition(!remapped.context.contains("用户：[2] 的详细信息是什么？"),
                 "Retained user references must not alias a different fresh source")
    precondition(remapped.question == "[2]提到客户吗？", "Keep the original UI question")
    precondition(remapped.providerQuestion == "（本次[1]）提到客户吗？")
    precondition(remapped.context.contains("用户：（本次[1]） 的详细信息是什么？"))
    precondition(remapped.questionReferenceIDs[2] == other.id)
    precondition(remapped.sources.first(where: { $0.number == 2 })?.id == note.id)

    // Each retained question's mapping belongs to its input, even after that turn renumbered sources.
    let mappedTurn = DaybookConversationTurn(id: UUID(), question: remapped.question, text: "路线没有提到客户 [1]", generated: true,
        provider: "测试", evidence: remapped.evidence, sources: remapped.sources, scopeDescription: remapped.scopeDescription,
        questionReferenceIDs: remapped.questionReferenceIDs)
    let repeated = try DaybookRetrieval().prepare(question: "[1] 的详细信息是什么？", records: records,
        selectedDate: yesterday, allowedKinds: all, priorTurns: [mappedTurn])
    precondition(repeated.providerQuestion == "（本次[1]） 的详细信息是什么？")
    precondition(repeated.sources.first?.id == other.id)
    precondition(repeated.context.contains("用户：（本次[1]）提到客户吗？"),
                 "Retained original [2] must use the saved input map, not that turn's fresh customer [2]")

    // An old archive has no input map: its question cannot borrow its own renumbered answer labels.
    let legacyFirst = DaybookConversationTurn(id: UUID(), question: "回顾这一天", text: "沿海路线 [2]", generated: true,
        provider: "测试", evidence: full.evidence, sources: full.sources, scopeDescription: full.scopeDescription)
    let legacySecond = DaybookConversationTurn(id: UUID(), question: "[2]提到客户吗？", text: "路线没有提到客户 [1]", generated: true,
        provider: "测试", evidence: remapped.evidence, sources: remapped.sources, scopeDescription: remapped.scopeDescription)
    let legacyURL = root.appendingPathComponent("legacy-reference.json")
    let legacyStore = DaybookConversationStore(url: legacyURL)
    try legacyStore.save([DaybookConversation(day: yesterday, updatedAt: today, turns: [legacyFirst, legacySecond])])
    let legacyHistory = try DaybookConversationStore(url: legacyURL).load()[0].turns
    precondition(legacyHistory.allSatisfy { $0.questionReferenceIDs == nil })
    let legacyFollowup = try DaybookRetrieval().prepare(question: "客户", records: records,
        selectedDate: yesterday, allowedKinds: all, priorTurns: legacyHistory)
    precondition(legacyFollowup.context.contains("用户：（先前引用2不可用）提到客户吗？"),
                 "A legacy question without an input map must remain unresolved")
    precondition(!legacyFollowup.context.contains("用户：（本次[1]）提到客户吗？"))
    let legacyNewReference = try DaybookRetrieval().prepare(question: "[1] 的详细信息是什么？", records: records,
        selectedDate: yesterday, allowedKinds: all, priorTurns: legacyHistory)
    precondition(legacyNewReference.providerQuestion == "（本次[1]） 的详细信息是什么？")
    precondition(legacyNewReference.sources.first?.id == other.id,
                 "A new question can still reference the last displayed answer's actual source map")

    // Deletion, revocation, unmatched labels and context-budget exclusion cannot fall through to another source.
    let deletedReference = try DaybookRetrieval().prepare(question: "[2]提到客户吗？", records: [note],
        selectedDate: yesterday, allowedKinds: all, priorTurns: [oldTurn])
    precondition(deletedReference.directResponse?.contains("先前来源目前不可用") == true)
    precondition(deletedReference.providerQuestion == "（先前引用2不可用）提到客户吗？")
    precondition(!deletedReference.context.contains("用户：[2]"))
    let revokedReference = try DaybookRetrieval().prepare(question: "[2]提到客户吗？", records: records,
        selectedDate: yesterday, allowedKinds: [.voice], priorTurns: [oldTurn])
    precondition(revokedReference.directResponse != nil && revokedReference.providerQuestion.contains("引用2不可用"))
    precondition(!revokedReference.sources.contains { $0.id == other.id })
    let unknownReference = try DaybookRetrieval().prepare(question: "[99]提到客户吗？", records: records,
        selectedDate: yesterday, allowedKinds: all, priorTurns: [oldTurn])
    precondition(unknownReference.directResponse != nil && !unknownReference.providerQuestion.contains("[99]"))
    let excludedReference = try DaybookRetrieval(limits: .init(maxSources: 0)).prepare(question: "[2]提到客户吗？", records: records,
        selectedDate: yesterday, allowedKinds: all, priorTurns: [oldTurn])
    precondition(excludedReference.directResponse != nil && excludedReference.providerQuestion.contains("引用2不可用"))

    // The exact transformed question is previewed and sent, while persisted UI intent keeps its identity map.
    let referenceURL = root.appendingPathComponent("references.json")
    let referenceStore = DaybookConversationStore(url: referenceURL)
    try referenceStore.save([DaybookConversation(day: yesterday, updatedAt: today, turns: [oldTurn])])
    let referenceService = DelayedDaybookAnswerService()
    let referenceModel = DaybookAssistantModel(answerService: referenceService, store: referenceStore)
    referenceModel.ask("[2]提到客户吗？", records: records, selectedDate: yesterday, allowedKinds: all, settings: settings)
    let referencePreview = referenceModel.remoteConfirmation!
    precondition(referencePreview.message.contains("问题：（本次[1]）提到客户吗？"))
    precondition(!referencePreview.message.contains("问题：[2]提到客户吗？"))
    referenceModel.confirmRemote(records: records, selectedDate: yesterday, allowedKinds: all, settings: settings)
    for _ in 0..<1_000 { if referenceService.calls == 1 { break }; await Task.yield() }
    let sentReference = referenceService.requests.last!
    precondition(referencePreview.message == CustomAISummarizer.answerContent(question: sentReference.providerQuestion, context: sentReference.context))
    precondition(sentReference.sources.first?.id == other.id)
    referenceService.finishOldest("路线没有提到客户 [1]"); await settle()
    let referenceArchive = try DaybookConversationStore(url: referenceURL).load()
    precondition(referenceArchive.first?.turns.last?.question == "[2]提到客户吗？")
    precondition(referenceArchive.first?.turns.last?.questionReferenceIDs?[2] == other.id)
    let referenceRestart = DaybookAssistantModel(answerService: referenceService, store: DaybookConversationStore(url: referenceURL))
    referenceRestart.ask("[1] 的详细信息是什么？", records: records, selectedDate: yesterday, allowedKinds: all, settings: settings)
    precondition(referenceRestart.remoteConfirmation?.message.contains("用户：（本次[1]）提到客户吗？") == true)
    referenceRestart.cancel()
    precondition(!model.validatedTurns(records: [], selectedDate: today, allowedKinds: all).isEmpty)
    let revision = DaybookEvidenceSnapshot(records: [], dayStart: today, dayEnd: today.addingTimeInterval(86400), allowedKinds: all)
    let largeThreads = (0..<30).map { offset in
        DaybookConversation(day: today.addingTimeInterval(Double(offset) * 86400), updatedAt: today.addingTimeInterval(Double(offset)),
            turns: (0..<20).map { _ in DaybookConversationTurn(id: UUID(), question: "回顾", text: String(repeating: "字", count: 8_000), generated: true,
                provider: "测试", evidence: revision, sources: [], scopeDescription: "测试范围") })
    }
    let byteURL = root.appendingPathComponent("bytes.json")
    let byteStore = DaybookConversationStore(url: byteURL)
    try byteStore.save(largeThreads)
    precondition(!FileManager.default.fileExists(atPath: byteURL.path), "New writes use SQLite without creating a legacy archive")
    let byteReloaded = try DaybookConversationStore(url: byteURL).load()
    precondition(byteReloaded.flatMap(\.turns).count == 600)
    print("DaybookConversation smoke passed: restart, cross-date history, follow-up re-grounding/date retention, edits, clear race, permissions, exact remote preview, config invalidation, corrupt storage, save retry, unpruned storage")
}
#endif

#if DAYBOOK_ASSISTANT_MODEL_TESTS
private actor DelayedSemantic: DaybookSemanticSearching {
    var continuation: CheckedContinuation<DaybookSemanticMatches, Never>?
    var request: (records: [DayRecord], start: Date, end: Date, allowed: Set<DayRecord.Kind>)?
    func search(query: String, records: [DayRecord], dayStart: Date, dayEnd: Date, allowedKinds: Set<DayRecord.Kind>, limit: Int) async -> DaybookSemanticMatches {
        request = (records, dayStart, dayEnd, allowedKinds)
        return await withCheckedContinuation { continuation = $0 }
    }
    func ready() -> Bool { continuation != nil }
    func finish() {
        guard let request, let record = request.records.first else { return }
        continuation?.resume(returning: DaybookSemanticMatches(hits: [.init(id: record.id, snippet: record.text)], status: "semantic", evidence: DaybookEvidenceSnapshot(records: request.records, dayStart: request.start, dayEnd: request.end, allowedKinds: request.allowed), generation: 0))
        continuation = nil
    }
}
@MainActor private func semanticAssistantTests() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let semantic = DelayedSemantic()
    let settings = AppSettings(defaults: UserDefaults(suiteName: UUID().uuidString)!, secrets: DaybookTestSecrets())
    var config = settings.ai; config.mode = .custom; config.baseURL = "https://example.test"; config.model = "fixture"
    try settings.saveAI(config, apiKey: "fixture-not-a-key")
    let provider = DelayedDaybookAnswerService()
    let model = DaybookAssistantModel(answerService: provider, store: DaybookConversationStore(url: root.appendingPathComponent("history.json")), semanticSearch: semantic)
    let day = Calendar.current.startOfDay(for: Date())
    let note = DayRecord(id: UUID(), capturedAt: day.addingTimeInterval(100), kind: .voice, title: "work", text: "deadline pressure")
    func wait() async { for _ in 0..<1000 { if await semantic.ready() { return }; await Task.yield() }; preconditionFailure("semantic request not started") }
    func settle() async { for _ in 0..<1000 { await Task.yield() } }
    model.ask("stress", records: [note], selectedDate: day, allowedKinds: [.voice], settings: settings)
    await wait(); await semantic.finish(); await settle()
    precondition(model.remoteConfirmation?.context.contains("deadline pressure") == true, "semantic candidates reach exact remote preview grounded in original UUID")
    precondition(model.prepared?.sources.first?.id == note.id)
    model.confirmRemote(records: [note], selectedDate: day, allowedKinds: [.voice], settings: settings)
    model.synchronize(records: [note], selectedDate: day, allowedKinds: [], configuration: settings.ai, configurationRevision: settings.aiRevision)
    await settle()
    precondition(provider.calls == 0, "revocation before provider task entry must not send text")
    model.ask("stress", records: [note], selectedDate: day, allowedKinds: [.voice], settings: settings)
    await wait()
    model.synchronize(records: [note], selectedDate: day, allowedKinds: [], configuration: settings.ai, configurationRevision: settings.aiRevision)
    await semantic.finish(); await settle()
    precondition(model.remoteConfirmation == nil && model.prepared == nil, "late permission-revoked retrieval is rejected before preview")
    model.ask("stress", records: [note], selectedDate: day, allowedKinds: [.voice], settings: settings)
    await wait()
    model.synchronize(records: [note], selectedDate: day.addingTimeInterval(86400), allowedKinds: [.voice], configuration: settings.ai, configurationRevision: settings.aiRevision)
    await semantic.finish(); await settle()
    precondition(model.remoteConfirmation != nil && model.prepared?.sources.first?.id == note.id,
                 "Homepage day changes must not replace the automatically chosen evidence scope")
    model.cancel()
    settings.requiresRemoteAIConfirmation = false
    model.ask("stress", records: [note], selectedDate: day, allowedKinds: [.voice], settings: settings)
    await wait(); await semantic.finish(); await settle()
    precondition(model.remoteConfirmation == nil && provider.calls == 1 && model.isPending, "Semantic retrieval must also respect saved opt-out")
    provider.finishOldest("deadline pressure [1]"); await settle()
    precondition(model.answer?.text == "deadline pressure [1]")
    print("Daybook semantic Ask races and remembered confirmation: passed")
}
#endif

#if DAYBOOK_ASSISTANT_MODEL_TESTS
@MainActor
private func conversationPersistenceTests() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let suite = "DaybookTransaction-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let settings = AppSettings(defaults: defaults, secrets: DaybookTestSecrets())
    let day = Calendar.current.startOfDay(for: Date())
    let note = DayRecord(id: UUID(), capturedAt: day.addingTimeInterval(3600), kind: .voice, title: "客户会议", text: "客户需要新报价")
    let allowed: Set<DayRecord.Kind> = [.voice]
    func settle() async { for _ in 0..<500 { await Task.yield() } }
    func wait(_ service: DelayedDaybookAnswerService, _ count: Int) async {
        for _ in 0..<1_000 { if service.calls == count { return }; await Task.yield() }
        preconditionFailure("Persistence request did not start")
    }
    for operation in ["answer", "clear", "reset", "privacy"] {
        let url = root.appendingPathComponent("\(operation).json")
        let db = try DaybookDatabase(url: DaybookDatabase.url(forLegacy: url))
        let store = DaybookConversationStore(url: url, database: db)
        let service = DelayedDaybookAnswerService()
        let model = DaybookAssistantModel(answerService: service, store: store)
        func sync(_ kinds: Set<DayRecord.Kind> = allowed) {
            model.synchronize(records: [note], selectedDate: day, allowedKinds: kinds, configuration: settings.ai)
        }
        model.ask("客户说了什么？", records: [note], selectedDate: day, allowedKinds: allowed, settings: settings)
        let draft = try store.load().flatMap(\.turns)
        precondition(draft.count == 1 && draft[0].completionState == .pending && draft[0].question == "客户说了什么？",
                     "Persist the question before awaiting the model")
        await wait(service, 1)
        if operation == "answer" {
            try db.execute("CREATE TRIGGER fail_mutation BEFORE UPDATE OF text ON conversation_turns WHEN NEW.state = 'completed' BEGIN SELECT RAISE(ABORT, 'answer failure'); END")
        }
        service.finishOldest("已提交的建议 [1]"); await settle()
        if operation == "answer" {
            let durable = try store.load().flatMap(\.turns)
            precondition(model.storageError != nil && durable[0].completionState == .pending && durable[0].text.isEmpty,
                         "Failed answer update keeps the committed question and rolls back answer text")
            try db.execute("DROP TRIGGER fail_mutation")
            model.retryPersistence()
            let retried = try store.load().flatMap(\.turns)
            precondition(retried.count == 1 && retried[0].id == draft[0].id && retried[0].text == "已提交的建议 [1]" && model.storageError == nil)
        } else if operation == "privacy" {
            try db.execute("CREATE TRIGGER fail_mutation BEFORE UPDATE ON conversation_turns WHEN NEW.state = 'redacted' BEGIN SELECT RAISE(ABORT, 'privacy failure'); END")
            sync([])
            precondition(model.storageError != nil && model.turns.count == 1 && model.turns[0].completionState == .redacted)
            precondition(model.turns[0].question == "客户说了什么？" && !model.turns[0].text.contains("已提交的建议") && model.turns[0].sources.isEmpty)
            sync()
            precondition(model.turns[0].completionState == .redacted, "Restored permissions cannot reveal failed-cleanup content")
            try db.execute("DROP TRIGGER fail_mutation")
            model.retryPersistence()
            let durable = try store.load().flatMap(\.turns)
            precondition(durable.count == 1 && durable[0].completionState == .redacted && model.storageError == nil)
        } else {
            if operation == "clear" {
                try db.execute("CREATE TRIGGER fail_mutation BEFORE DELETE ON conversations BEGIN SELECT RAISE(ABORT, 'clear failure'); END")
                model.clearHistory()
            } else {
                try db.execute("CREATE TRIGGER fail_mutation BEFORE INSERT ON storage_migrations WHEN NEW.domain = 'conversations' BEGIN SELECT RAISE(ABORT, 'reset failure'); END")
                model.resetStorage()
            }
            let durable = try store.load().flatMap(\.turns)
            precondition(model.storageError != nil && durable.count == 1 && model.turns == durable, "Failed clear/reset retains committed history")
            try db.execute("DROP TRIGGER fail_mutation")
            model.retryPersistence()
            let cleared = try store.load().flatMap(\.turns)
            precondition(model.storageError == nil && model.turns.isEmpty && cleared.isEmpty)
        }
    }
    // A failed first write must not send an unsaved question; retry preserves the question.
    do {
        let url = root.appendingPathComponent("first-write.json")
        let db = try DaybookDatabase(url: DaybookDatabase.url(forLegacy: url))
        let store = DaybookConversationStore(url: url, database: db)
        let service = DelayedDaybookAnswerService()
        let model = DaybookAssistantModel(answerService: service, store: store)
        try db.execute("CREATE TRIGGER fail_mutation BEFORE INSERT ON conversation_turns BEGIN SELECT RAISE(ABORT, 'question failure'); END")
        model.ask("客户说了什么？", records: [note], selectedDate: day, allowedKinds: allowed, settings: settings)
        await settle()
        precondition(service.calls == 0 && model.storageError != nil && model.turns.isEmpty)
        try db.execute("DROP TRIGGER fail_mutation")
        model.retryPersistence()
        precondition(model.turns.count == 1 && model.turns[0].question == "客户说了什么？" && model.turns[0].completionState == .cancelled)
    }
    // Terminal states retain the question and update one UUID; later provider replies cannot resurrect it.
    do {
        let url = root.appendingPathComponent("states.json")
        let store = DaybookConversationStore(url: url)
        let service = DelayedDaybookAnswerService()
        let model = DaybookAssistantModel(answerService: service, store: store)
        model.ask("客户说了什么？", records: [note], selectedDate: day, allowedKinds: allowed, settings: settings)
        await wait(service, 1); model.cancel(); service.finishOldest("迟到的结果"); await settle()
        precondition(model.turns.count == 1 && model.turns[0].completionState == .cancelled && !model.turns[0].text.contains("迟到"))
        model.ask("客户需要什么？", records: [note], selectedDate: day, allowedKinds: allowed, settings: settings)
        await wait(service, 2); service.failOldest(); await settle()
        precondition(model.turns.count == 2 && model.turns.last?.completionState == .failed)
        model.ask("2026-02-30 发生什么？", records: [note], selectedDate: day, allowedKinds: allowed, settings: settings)
        precondition(model.turns.count == 3 && model.turns.last?.completionState == .failed, "Preparation errors also retain the submitted question")
        let reopened = DaybookAssistantModel(store: DaybookConversationStore(url: url))
        reopened.synchronize(records: [], selectedDate: day, allowedKinds: allowed, configuration: settings.ai)
        precondition(reopened.turns.count == 3)
        let evidence = DaybookEvidenceSnapshot(records: [note], dayStart: day, dayEnd: day.addingTimeInterval(86400), allowedKinds: allowed)
        let interrupted = DaybookConversationTurn(id: UUID(), question: "退出前的问题", text: "", generated: false, provider: "", evidence: evidence, sources: [], scopeDescription: "", state: .pending, createdAt: .now)
        try store.saveTurn(interrupted, day: day)
        let afterCrash = DaybookAssistantModel(store: DaybookConversationStore(url: url))
        afterCrash.synchronize(records: [note], selectedDate: day, allowedKinds: allowed, configuration: settings.ai)
        precondition(afterCrash.turns.last?.id == interrupted.id && afterCrash.turns.last?.completionState == .cancelled)
    }
    // Retried answers cannot become valid again after changing day, model configuration or evidence.
    for change in ["day", "configuration", "evidence"] {
        let url = root.appendingPathComponent("pending-\(change).json")
        let db = try DaybookDatabase(url: DaybookDatabase.url(forLegacy: url))
        let store = DaybookConversationStore(url: url, database: db)
        let service = DelayedDaybookAnswerService()
        let model = DaybookAssistantModel(answerService: service, store: store)
        model.ask("客户说了什么？", records: [note], selectedDate: day, allowedKinds: allowed, settings: settings)
        await wait(service, 1)
        try db.execute("CREATE TRIGGER fail_mutation BEFORE UPDATE ON conversation_turns WHEN NEW.state = 'completed' BEGIN SELECT RAISE(ABORT, 'answer failure'); END")
        service.finishOldest("未提交的建议 [1]"); await settle()
        var config = settings.ai
        if change == "configuration" { config.model = "changed" }
        model.synchronize(records: change == "evidence" ? [] : [note], selectedDate: change == "day" ? day.addingTimeInterval(86400) : day, allowedKinds: allowed, configuration: config)
        try db.execute("DROP TRIGGER fail_mutation")
        model.retryPersistence()
        let durable = try store.load().flatMap(\.turns)
        precondition(durable.count == 1 && durable[0].question == "客户说了什么？")
        if change == "day" {
            precondition(durable[0].completionState == .completed && durable[0].text.contains("未提交的建议"), "Homepage date does not invalidate independent Ask AI evidence")
        } else {
            precondition(durable[0].completionState == .cancelled && !durable[0].text.contains("未提交的建议"))
        }
    }
    print("Conversation lifecycle: question-first commit, success/failure/cancel/interruption, write rollback/retry, privacy redaction and stale retries passed")
}

@MainActor
private func historyPagingTests() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("pages.json")
    let db = try DaybookDatabase(url: DaybookDatabase.url(forLegacy: url))
    let store = DaybookConversationStore(url: url, database: db)
    let day = Calendar.current.startOfDay(for: Date())
    let evidence = DaybookEvidenceSnapshot(records: [], dayStart: day, dayEnd: day.addingTimeInterval(86400), allowedKinds: [.voice])
    func turn(_ index: Int) -> DaybookConversationTurn {
        DaybookConversationTurn(id: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", index))!, question: "问题 \(index)", text: "回答 \(index)", generated: false, provider: "本地", evidence: evidence, sources: [], scopeDescription: "", state: .completed, createdAt: day.addingTimeInterval(Double(index / 5)))
    }
    for index in 1...35 { try store.saveTurn(turn(index), day: day.addingTimeInterval(Double(index % 2) * 86400)) }
    let first = try store.loadPage()
    precondition(first.turns.map(\.question) == (26...35).map { "问题 \($0)" } && first.hasMore)
    var cursor = first.cursor
    var collected = first.turns
    try store.saveTurn(turn(36), day: day)
    // Updating an existing row must preserve its send ordering and never rewrite other rows.
    try db.execute("CREATE TRIGGER protect_other BEFORE DELETE ON conversation_turns BEGIN SELECT RAISE(ABORT, 'unexpected archive rewrite'); END")
    try store.saveTurn(turn(3).replacing(text: "更新的回答", state: .completed), day: day.addingTimeInterval(86400))
    for expectedCount in [10, 10, 5] {
        let page = try DaybookConversationStore(url: url).loadPage(before: cursor)
        precondition(page.turns.count == expectedCount)
        collected.insert(contentsOf: page.turns, at: 0); cursor = page.cursor
        if expectedCount == 5 { precondition(!page.hasMore) }
    }
    precondition(collected.map(\.question) == (1...35).map { "问题 \($0)" }, "Keyset pagination must not skip/duplicate ties or shift when a new question is inserted")
    let latest = try store.loadPage()
    precondition(latest.turns.last?.question == "问题 36")
    let all = try store.load().flatMap(\.turns)
    precondition(all.count == 36)
    let plan = try db.query("EXPLAIN QUERY PLAN SELECT * FROM conversation_turns WHERE (created_at,id) < (?,?) ORDER BY created_at DESC,id DESC LIMIT 11", [.real(day.timeIntervalSinceReferenceDate), .text("z")])
    precondition(plan.contains { $0["detail"]?.string?.contains("conversation_turns_history") == true })
    let suite = "PagingUI-\(UUID().uuidString)"; let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let settings = AppSettings(defaults: defaults, secrets: DaybookTestSecrets())
    let model = DaybookAssistantModel(store: DaybookConversationStore(url: url))
    model.synchronize(records: [], selectedDate: day, allowedKinds: [.voice], configuration: settings.ai)
    precondition(model.turns.count == 10 && model.hasMoreHistory)
    model.loadMoreHistory(); precondition(model.turns.count == 20)
    model.loadMoreHistory(); precondition(model.turns.count == 30)
    model.loadMoreHistory(); precondition(model.turns.count == 36 && !model.hasMoreHistory)
    // Migrate the pre-existing SQLite table, not only a fresh store or a JSON archive.
    let legacyURL = root.appendingPathComponent("legacy-sqlite.json")
    let legacyDB = try DaybookDatabase(url: DaybookDatabase.url(forLegacy: legacyURL))
    try legacyDB.execute("INSERT INTO storage_migrations(domain,imported_at) VALUES ('conversations',0)")
    try legacyDB.execute("INSERT INTO conversations VALUES (?,?)", [.real(day.timeIntervalSinceReferenceDate), .real(day.timeIntervalSinceReferenceDate)])
    let legacyTurn = turn(1)
    try legacyDB.execute("INSERT INTO conversation_turns VALUES (?,?,?,?,?,?,?,?,?,?,?)", [.text(legacyTurn.id.uuidString), .real(day.timeIntervalSinceReferenceDate), .integer(0), .text(legacyTurn.question), .text(legacyTurn.text), .integer(0), .text(legacyTurn.provider), try DaybookDatabase.json(evidence), try DaybookDatabase.json([DaybookRetrieval.Source]()), .text(""), .null])
    let migrated = try DaybookConversationStore(url: legacyURL, database: legacyDB).loadPage()
    precondition(migrated.turns.count == 1 && migrated.turns[0].id == legacyTurn.id && migrated.turns[0].completionState == .completed && migrated.turns[0].createdAt == day)
    print("Conversation paging: SQL 10/10/10/5, timestamp ties, insert/update during pagination, reopen and indexed cursor passed")
}

#endif

private func sqlPayloadFreshness() throws {
    let day = Calendar.current.startOfDay(for: Date())
    let end = Calendar.current.date(byAdding: .day, value: 1, to: day)!
    let record = DayRecord(id: UUID(), capturedAt: day, kind: .voice, title: "会议", text: "合同预算")
    let denied = DayRecord(id: UUID(), capturedAt: day, kind: .image, title: "照片", text: "旧标记")
    let records = [record, denied]
    let keywords = DaybookSemanticMatches.Keywords(query: "合同预算", terms: DaybookRetrieval.keywords("合同预算"), libraryIDs: [record.id], aiScores: [record.id: 20], libraryEvidence: .init(records: records, dayStart: day, dayEnd: end, allowedKinds: DaybookSemanticMatches.Keywords.allKinds), usesFTS: true)
    let cached = DaybookSemanticMatches(hits: [.init(id: record.id, snippet: "不在原文的过期文本")], status: "SQL", evidence: .init(records: records, dayStart: day, dayEnd: end, allowedKinds: [.voice]), generation: 0, keywords: keywords, query: "合同预算")
    let grounded = try DaybookRetrieval().prepare(question: "合同预算", records: records, selectedDate: day, allowedKinds: [.voice], semantic: cached)
    precondition(grounded.sources.first?.snippet == "合同预算", "SQL-ranked sources re-ground excerpts in current original text")
    let other = try DaybookRetrieval().prepare(question: "旅游计划", records: records, selectedDate: day, allowedKinds: [.voice], semantic: cached)
    precondition(other.sources.isEmpty, "query changes cannot reuse SQL scores or semantic candidates")
    let editedDenied = DayRecord(id: denied.id, capturedAt: day, kind: .image, title: denied.title, text: "合同预算")
    let freshLibrary = DaybookRetrieval.libraryRecords(query: "合同预算", records: [record, editedDenied], dayStart: day, dayEnd: end, allowedKinds: [.voice], semantic: cached)
    precondition(Set(freshLibrary.map(\.id)) == Set([record.id, denied.id]), "denied source edits invalidate the library snapshot independently of AI evidence")
    print("Daybook SQL payload freshness and live grounding: passed")
}
