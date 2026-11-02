import Foundation

@main struct FlashCaptureSmoke {
    static func expect(_ condition: @autoclosure () throws -> Bool, _ message: String = "Assertion failed") rethrows { let result = try condition(); precondition(result, message) }
    static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let db = try DaybookDatabase(url: root.appendingPathComponent("test.sqlite"))
        let repo = try FlashCaptureRepository(database: db)
        let recorded = ISO8601DateFormatter().date(from: "2026-10-31T08:00:00Z")!
        let source = ActionSource(id: UUID(), title: "闪念", quote: "记个想法，按人回顾。今天午餐花了35元人民币。帮我加个待办，画草图。", capturedAt: recorded, timeZoneID: "Asia/Shanghai", recordingKind: "thought", timeZoneKnown: true)
        let json = #"{"items":[{"kind":"idea","title":"按人回顾","text":"按人回顾","quote":"记个想法，按人回顾。"},{"kind":"expense","title":"午餐","quote":"今天午餐花了35元人民币。","direction":"expense","amount":"35","currency":"CNY","category":"餐饮","date":"2026-10-31"},{"kind":"todo","title":"画草图","quote":"帮我加个待办，画草图。","explicitCommand":true}]}"#
        let extraction = try FlashCaptureParser.parse(json, source: source, now: recorded)
        precondition(extraction.assets.count == 2 && extraction.actions.count == 1)
        try repo.commit(extraction, source: source)
        try repo.commit(extraction, source: source)
        let rows = try repo.assets()
        precondition(rows.count == 2, "Repeated extraction must not duplicate assets")
        let actions = try ActionRepository(database: db).load()
        precondition(actions.count == 1 && actions[0].sync == .pending, "Action intent must be durable before execution")
        var idea = rows.first { $0.kind == .idea }!
        let stale = idea
        idea.text = "用户编辑后的想法"
        idea = try repo.save(idea)
        do { _ = try repo.save(stale); preconditionFailure("Stale edits must fail") } catch ActionFailure.changed {}
        idea.revoked = true; idea = try repo.save(idea)
        try repo.commit(extraction, source: source)
        let reopened = try FlashCaptureRepository(database: DaybookDatabase(url: db.url))
        let recovered = try reopened.assets().first { $0.id == idea.id }!
        precondition(recovered.revoked && recovered.text == "用户编辑后的想法")
        var independent = source; independent.id = UUID()
        let usd = FlashAsset(kind: .expense, title: "美元测试收入", text: "测试收入", source: independent, direction: .income, amountMinor: 1234, currency: "USD", date: "2026-10-31")
        _ = try repo.save(usd)
        let mixedTotals = try repo.totals()
        precondition(mixedTotals == [.init(currency: "CNY", income: 0, expense: 3500), .init(currency: "USD", income: 1234, expense: 0)], "Do not add currencies together")
        var revokedUSD = try repo.assets().first { $0.id == usd.id }!; revokedUSD.revoked = true; _ = try repo.save(revokedUSD)
        var expense = rows.first { $0.kind == .expense }!
        try expect(try repo.totals() == [FlashCurrencyTotal(currency: "CNY", income: 0, expense: 3500)])
        expense.revoked = true; expense = try repo.save(expense)
        try expect(try repo.totals().isEmpty)
        expense.revoked = false; expense.amountMinor = nil; _ = try repo.save(expense)
        try expect(try repo.totals().isEmpty, "Incomplete expense must never enter totals")
        try expect(try FlashMoney.minorUnits("12.34", currency: "CNY") == 1234)
        try expect(try FlashMoney.minorUnits("125", currency: "JPY") == 125)
        try expect(try FlashMoney.minorUnits("1.234", currency: "KWD") == 1234)
        do { _ = try FlashMoney.minorUnits("1.1", currency: "JPY"); preconditionFailure("No silent currency rounding") } catch is ActionFailure {}
        let negative = source.quote.replacingOccurrences(of: "帮我加个待办", with: "不要帮我加个待办")
        var negSource = source; negSource.quote = negative
        let negJSON = json.replacingOccurrences(of: "帮我加个待办", with: "不要帮我加个待办")
        try expect(try FlashCaptureParser.parse(negJSON, source: negSource, now: recorded).actions.isEmpty)
        do { _ = try FlashCaptureParser.parse(json.replacingOccurrences(of: "今天午餐花了35元人民币。", with: "捏造的原话"), source: source, now: recorded); preconditionFailure("Ungrounded output must not persist") } catch is ActionFailure {}
        let history = UUID()
        try repo.seedHistory([history])
        try expect(try repo.batch(history)?.state == .historical)
        let unknown = ActionSource(id: UUID(), title: "旧闪念", quote: "明天九点提醒我打电话", capturedAt: recorded, timeZoneID: "Asia/Shanghai", recordingKind: "thought")
        let reminderJSON = #"{"items":[{"kind":"reminder","title":"打电话","quote":"明天九点提醒我打电话","explicitCommand":true,"start":"2026-11-01T09:00:00+08:00"}]}"#
        let unknownResult = try FlashCaptureParser.parse(reminderJSON, source: unknown, now: recorded)
        precondition(unknownResult.actions.first?.start == nil && unknownResult.actions.first?.sync == .failed, "Missing recording timezone must not guess a notification time")
        var reported = unknown; reported.quote = "他说，明天九点提醒我打电话"
        try expect(try FlashCaptureParser.parse(reminderJSON, source: reported, now: recorded).actions.isEmpty)
        var invalidSource = source; invalidSource.id = UUID()
        var invalidAsset = usd; invalidAsset.id = UUID(); invalidAsset.text = ""
        let countBefore = try repo.assets().count
        var validAsset = usd; validAsset.id = UUID()
        do { try repo.commit(.init(assets: [validAsset, invalidAsset]), source: invalidSource); preconditionFailure("Invalid batch must roll back") } catch is ActionFailure {}
        try expect(try repo.assets().count == countBefore)
        try expect(try repo.batch(invalidSource.id) == nil)
        try verifyTimeline(source: source, assets: rows, actions: actions, now: recorded)
        print("FlashCapture: grounded extraction, durable dedup, edit conflicts, revocation, money and history passed")
    }
    static func verifyTimeline(source: ActionSource, assets: [FlashAsset], actions: [ActionItem], now: Date) throws {
        let group = FlashTimelineGroup(sourceID: source.id, assets: assets, actions: actions)
        precondition(group.hasResults && group.assets.count == 2 && group.commands.count == 1)
        precondition(!FlashTimelineGroup(sourceID: UUID(), assets: assets, actions: actions).hasResults, "Other sources must not leak into a group")
        var action = actions[0]
        precondition(FlashCommandState(item: action, now: now) == .pending, "Persisted intent alone is not execution success")
        action.sync = .local
        precondition(FlashCommandState(item: action, now: now) == .created)
        action.title = "Revised sketch 草图二版"; action.status = .completed
        precondition(FlashCommandState(item: action, now: now) == .completed)
        let edited = FlashTimelineGroup(sourceID: source.id, assets: [], actions: [action])
        precondition(edited.matches("revised SKETCH") && edited.matches("草图二版"), "Search current edits, including mixed languages")
        action.kind = .event; action.status = .cancelled; action.sync = .failed
        precondition(FlashCommandState(item: action, now: now) == .cancelFailed, "Failed system cancellation is not a revoked event")
        action.sync = .local
        precondition(FlashCommandState(item: action, now: now) == .revoked)
        action.deleted = true
        precondition(FlashTimelineGroup(sourceID: source.id, assets: [], actions: [action]).commands.count == 1, "Keep durable cancellation evidence after deletion")
        action.deleted = false; action.status = .active; action.kind = .reminder; action.start = nil; action.sync = .failed
        precondition(FlashCommandState(item: action, now: now) == .needsDetails)
        action.start = now.addingTimeInterval(3600)
        precondition(FlashCommandState(item: action, now: now) == .failed)
        action.sync = .local
        precondition(FlashCommandState(item: action, now: now) == .scheduled)
        action.dedupKey = nil
        precondition(!FlashTimelineGroup(sourceID: source.id, assets: [], actions: [action]).hasResults, "Ordinary suggestions are not automatic flash results")
    }

}
