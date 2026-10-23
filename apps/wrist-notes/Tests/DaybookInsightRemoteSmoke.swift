import Foundation

private final class InsightSecrets: SecretStore {
    func read() throws -> String { "fixture-only" }
    func write(_ value: String) throws {}
}
@MainActor private final class RemoteInsight: DaybookInsightGenerating {
    var configurations: [AIConfiguration] = []
    var pending: [CheckedContinuation<DaybookInsightOutput, Error>] = []
    var current: (@MainActor () -> Bool)?
    func generate(_ evidence: DaybookRetrieval.Prepared, configuration: AIConfiguration, apiKey: String?, language: String, now: Date,
                  isCurrent: @escaping @MainActor () -> Bool) async throws -> DaybookInsightOutput {
        precondition(isCurrent() && apiKey == "fixture-only")
        configurations.append(configuration); current = isCurrent
        return try await withCheckedThrowingContinuation { pending.append($0) }
    }
    func finish() { pending.removeFirst().resume(returning: .init(observation: "种罗勒的想法 [1] 与种子记录 [2] 相呼应。", nextAction: "看看种子包装 [2]")) }
}

@main struct DaybookInsightRemoteSmoke {
    @MainActor static func main() async throws {
        let suite = "InsightRemote-\(UUID())", defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults, secrets: InsightSecrets())
        let preferences = DaybookPreferences(defaults: defaults); preferences.quietEnabled = false; preferences.dailySuggestionLimit = 5
        let firstConfig = AIConfiguration(mode: .custom, model: "first", baseURL: "https://example.invalid/v1")
        try settings.saveAI(firstConfig, apiKey: "fixture-only")
        let day = Date.now
        var records = [DayRecord(id: UUID(), capturedAt: day, kind: .thought, title: "想法", text: "想种罗勒。"),
                       DayRecord(id: UUID(), capturedAt: day, kind: .image, title: "种子", text: "买了一包种子。")]
        let db = try DaybookDatabase(inMemory: true), store = DaybookInsightStore(defaults: defaults, database: db), service = RemoteInsight()
        let model = DaybookInsightModel(store: store, service: service)
        func sync(capturing: Bool = false, foreground: Bool = true) {
            model.synchronize(records: records, selectedDate: day, preferences: preferences, language: settings.interfaceLanguage.rawValue,
                foreground: foreground, capturing: capturing, now: day, settings: settings)
        }
        func wait(line: UInt = #line, _ predicate: () -> Bool) async {
            for _ in 0..<10000 { if predicate() { return }; await Task.yield() }
            fatalError("State not reached at \(line)")
        }
        sync(); await Task.yield()
        precondition(service.configurations.isEmpty && store.automaticAttempts(now: day) == 0, "unapproved remote auto generation must not send or consume budget")
        model.refresh(now: day)
        let stale = model.remoteConfirmation!
        records[0].text += "放在窗边。"; sync()
        model.confirm(stale, rememberChoice: true)
        await Task.yield()
        precondition(service.configurations.isEmpty && settings.requiresRemoteAIConfirmation, "stale confirmation must not inherit opt-out or persist it")
        model.refresh(now: day)
        let once = model.remoteConfirmation!
        precondition(once.content.contains("放在窗边"), "confirmation previews current source excerpts")
        model.confirm(once, rememberChoice: false)
        await wait { service.pending.count == 1 }; service.finish(); await wait { !model.isPending }
        precondition(model.result?.provider == firstConfig.label && settings.requiresRemoteAIConfirmation, "one-time confirmation uses configured provider without opting out")
        records[0].text += "明天看看发芽没有。"; sync(); model.refresh(now: day)
        model.confirm(model.remoteConfirmation!, rememberChoice: true)
        await wait { service.pending.count == 1 }; service.finish(); await wait { !model.isPending }
        precondition(!settings.requiresRemoteAIConfirmation, "current confirmation can persist no-prompt preference")
        records[1].text += "包装上有种植说明。"; sync()
        await wait { service.pending.count == 1 }
        let secondConfig = AIConfiguration(mode: .custom, model: "second", baseURL: "https://example.invalid/v1")
        try settings.saveAI(secondConfig, apiKey: "fixture-only"); sync(capturing: true)
        precondition(service.current?() == false, "configuration change invalidates provider request immediately")
        service.finish(); await Task.yield()
        precondition(model.result == nil, "late first-provider output cannot be stored as second-provider output")
        sync(); await wait { service.pending.count == 1 }; service.finish(); await wait { !model.isPending }
        precondition(model.result?.provider == secondConfig.label && service.configurations.last == secondConfig)
        let reopened = DaybookInsightModel(store: DaybookInsightStore(defaults: defaults, database: db), service: service)
        var requestCount = service.configurations.count
        reopened.synchronize(records: records, selectedDate: day, preferences: preferences, language: settings.interfaceLanguage.rawValue,
            foreground: true, capturing: false, now: day, settings: settings)
        precondition(reopened.result?.provider == secondConfig.label && service.configurations.count == requestCount, "provider cache survives SQLite reload and suppresses duplicate generation")
        try settings.saveAI(firstConfig, apiKey: "fixture-only"); sync(); model.refresh(now: day)
        await wait { service.pending.count == 1 }; service.finish(); await wait { !model.isPending }
        requestCount = service.configurations.count
        try settings.saveAI(secondConfig, apiKey: "fixture-only"); sync()
        precondition(model.result?.provider == secondConfig.label && !model.isPending && service.configurations.count == requestCount,
                     "switching back restores the provider's valid cached result without a duplicate request")
        model.refresh(now: day); await wait { service.pending.count == 1 }
        settings.requiresRemoteAIConfirmation = true; sync(); service.finish(); await Task.yield()
        precondition(model.result == nil && !model.isPending, "restoring confirmation blocks late remote results")
        model.refresh(now: day); let beforePermission = model.remoteConfirmation!
        preferences.allowPhotos = false
        model.confirm(beforePermission, rememberChoice: true); await Task.yield()
        precondition(service.configurations.count == requestCount + 1 && settings.requiresRemoteAIConfirmation, "permission revoked before view synchronization invalidates confirmation")
        preferences.allowPhotos = true; sync(); model.refresh(now: day)
        model.confirm(model.remoteConfirmation!, rememberChoice: false)
        settings.requiresRemoteAIConfirmation = false
        for _ in 0..<30 { await Task.yield() }
        precondition(service.pending.isEmpty, "consent changed before scheduled task starts prevents sending")
        print("Daily insight remote consent, auto generation, provider isolation and stale completion tests passed")
    }
}
