import Foundation

private final class RecapSecrets: SecretStore {
    func read() throws -> String { "fixture-only" }
    func write(_ value: String) throws {}
}
@MainActor private final class RecapGenerator: DaybookRecapGenerating {
    var requests: [DaybookRecapInput] = []
    var waiting: [CheckedContinuation<String, Error>] = []
    func generate(_ input: DaybookRecapInput, configuration: AIConfiguration, apiKey: String?, language: String,
                  isCurrent: @escaping @MainActor () -> Bool) async throws -> String {
        precondition(isCurrent()); requests.append(input)
        return try await withCheckedThrowingContinuation { waiting.append($0) }
    }
    func finish(_ text: String = "记下了种植罗勒的想法。[1]") { waiting.removeFirst().resume(returning: text) }
}
@MainActor private final class CountingRecapGenerator: DaybookRecapGenerating {
    var requests = 0
    func generate(_ input: DaybookRecapInput, configuration: AIConfiguration, apiKey: String?, language: String,
                  isCurrent: @escaping @MainActor () -> Bool) async throws -> String {
        precondition(isCurrent()); requests += 1
        return "昨天整理了花园。[1]"
    }
}
@main struct DaybookRecapModelSmoke {
    @MainActor static func main() async throws {
        let suite = "Recap-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults, secrets: RecapSecrets())
        try settings.saveAI(.init(mode: .custom, model: "fixture", baseURL: "https://example.invalid/v1"), apiKey: "fixture-only")
        let db = try DaybookDatabase(inMemory: true), store = DaybookRecapStore(database: db), service = RecapGenerator()
        let model = DaybookRecapModel(store: store, service: service)
        let day = Calendar.current.startOfDay(for: .now).addingTimeInterval(-86400)
        var records = [DayRecord(id: UUID(), capturedAt: day.addingTimeInterval(3600), kind: .thought, title: "罗勒", text: "想种植罗勒。")]
        var loaderFails = false
        var loaderChangesRemaining = 0
        model.scopeLoader = { _ in
            if loaderFails { throw DaybookRecapFailure.storage }
            if loaderChangesRemaining > 0 { loaderChangesRemaining -= 1; throw DaybookRecapFailure.changed }
            return records
        }
        func sync(active: Bool = true, capturing: Bool = false, allowed: Set<DayRecord.Kind> = [.thought]) {
            model.synchronize(day: day, records: records, revisions: [], settings: settings, allowedKinds: allowed, foreground: active, capturing: capturing)
        }
        func wait(line: UInt = #line, _ predicate: () -> Bool) async {
            for _ in 0..<10000 { if predicate() { return }; await Task.yield() }
            fatalError("State not reached at \(line)")
        }
        sync(); await wait { !model.isLoading }
        precondition(service.requests.isEmpty && model.canGenerate, "external auto generation waits for send confirmation")
        loaderChangesRemaining = 1; model.reload(); await wait { !model.isLoading }
        precondition(model.storageError == nil && model.canGenerate && service.requests.isEmpty, "concurrent evidence update retries its read without reporting database failure or invoking AI")
        loaderChangesRemaining = 10; model.reload(); await wait { !model.isLoading }
        precondition(loaderChangesRemaining == 7 && model.storageError == DaybookRecapFailure.changed.localizedDescription && service.requests.isEmpty, "continuously changing evidence has bounded read retries and never starts AI")
        loaderChangesRemaining = 0; model.reload(); await wait { !model.isLoading }
        let stale = model.remoteRequest()!
        records[0].text += "放在窗边。"; sync(); await wait { !model.isLoading }
        model.generate(confirmation: stale, rememberChoice: true)
        await wait { !model.isGenerating && !model.isLoading }
        precondition(settings.requiresRemoteAIConfirmation && service.requests.isEmpty, "stale preview cannot save opt-out or send")
        model.generate(confirmation: model.remoteRequest())
        await wait { service.waiting.count == 1 }; service.finish()
        await wait { !model.isGenerating }
        precondition(model.current?.text != nil && settings.requiresRemoteAIConfirmation, "one-time consent saves recap without changing preference")
        sync(); await wait { !model.isLoading }
        precondition(service.requests.count == 1, "exact successful revision is not regenerated")
        records.append(DayRecord(id: UUID(), capturedAt: day.addingTimeInterval(7200), kind: .thought, title: "花园", text: "买了一包种子。"))
        sync(); await wait { !model.isLoading }
        precondition(model.current?.text != nil && model.isStale, "additions keep old version explicitly pending")
        model.generate(confirmation: model.remoteRequest(), rememberChoice: true)
        await wait { service.waiting.count == 1 }
        precondition(!settings.requiresRemoteAIConfirmation, "remembered consent applies only after current preview validation")
        records.removeFirst(); sync(capturing: true)
        service.finish(); await wait { !model.isLoading && !model.isGenerating }
        precondition(model.current?.text == nil, "source deletion rejects late output and removes earlier claims")
        let beforeDeleteRetry = service.requests.count
        sync(); await wait { !model.isLoading }
        precondition(service.requests.count == beforeDeleteRetry, "source deletion never automatically starts another recap")
        model.generate(); await wait { service.waiting.count == 1 }
        service.waiting.removeFirst().resume(throwing: DaybookRecapFailure.generation)
        await wait { !model.isGenerating }
        let requests = service.requests.count
        sync(); await wait { !model.isLoading }
        precondition(service.requests.count == requests, "failed revision never auto-loops")
        let relaunched = DaybookRecapModel(store: DaybookRecapStore(database: db), service: service)
        relaunched.scopeLoader = model.scopeLoader
        relaunched.synchronize(day: day, records: records, revisions: [], settings: settings, allowedKinds: [.thought], foreground: true, capturing: false)
        await wait { !relaunched.isLoading }
        precondition(service.requests.count == requests, "attempt marker survives relaunch")
        model.generate(); await wait { service.waiting.count == 1 }
        sync(active: false); service.finish(); await wait { !model.isGenerating }
        precondition(model.current?.text == nil, "background cancellation rejects result")
        sync(); await wait { !model.isLoading }
        precondition(service.requests.count == requests + 1, "interrupted generation does not resume automatically")
        model.generate(); await wait { service.waiting.count == 1 }
        service.finish(); await wait { !model.isGenerating }
        precondition(model.current?.text != nil, "interrupted generation can be retried manually")
        model.generate(); await wait { service.waiting.count == 1 }
        loaderFails = true; service.finish(); await wait { !model.isGenerating }
        precondition(model.entries.isEmpty && model.storageError != nil, "post-send source read failure hides unverified old prose")
        let afterSendReadFailure = try store.load()
        precondition(afterSendReadFailure.first?.text != nil, "post-send read failure preserves durable old recap for recovery")
        loaderFails = false; model.reload(); await wait { !model.isLoading }
        loaderFails = true; model.reload(); await wait { !model.isLoading }
        precondition(model.entries.isEmpty && model.storageError != nil, "failed validation never displays unverified private prose")
        let afterFailure = try store.load()
        precondition(afterFailure.first?.text != nil, "failed read does not delete persisted recap")
        loaderFails = false; sync(allowed: []); await wait { !model.isLoading }
        let afterRevocation = try store.load()
        precondition(afterRevocation.first?.text == nil, "permission revocation purges saved recap")

        // A completed yesterday recap is generated automatically once, then source changes wait
        // for an explicit refresh. The once-per-day guard must survive model recreation.
        let localSuite = suite + "-local"
        let localDefaults = UserDefaults(suiteName: localSuite)!
        defer { localDefaults.removePersistentDomain(forName: localSuite) }
        let localSettings = AppSettings(defaults: localDefaults, secrets: RecapSecrets())
        let localStore = DaybookRecapStore(database: try DaybookDatabase(inMemory: true))
        let localService = RecapGenerator()
        let localModel = DaybookRecapModel(store: localStore, service: localService)
        var localRecords = [DayRecord(id: UUID(), capturedAt: day.addingTimeInterval(3600), kind: .thought, title: "早晨", text: "整理了花园。")]
        localModel.scopeLoader = { _ in localRecords }
        func syncLocal(revision: Int = 0) {
            localModel.synchronize(day: day, records: localRecords, revisions: [revision], settings: localSettings,
                allowedKinds: [.thought], foreground: true, capturing: false)
        }
        syncLocal(); await wait { localService.waiting.count == 1 }
        localService.finish("昨天整理了花园。[1]"); await wait { !localModel.isGenerating }
        precondition(localModel.current?.text != nil && localService.requests.count == 1, "yesterday recap generates automatically once")
        localRecords.append(DayRecord(id: UUID(), capturedAt: day.addingTimeInterval(7200), kind: .thought, title: "计划", text: "今天给花园浇水。"))
        syncLocal(revision: 1); await wait { !localModel.isLoading }
        precondition(localModel.current?.text != nil && localModel.isStale, "new records preserve the earlier recap as stale")
        precondition(!localModel.isGenerating && localService.requests.count == 1, "new records never trigger another automatic recap")
        let localRelaunched = DaybookRecapModel(store: localStore, service: localService)
        localRelaunched.scopeLoader = { _ in localRecords }
        localRelaunched.synchronize(day: day, records: localRecords, revisions: [1], settings: localSettings,
            allowedKinds: [.thought], foreground: true, capturing: false)
        await wait { !localRelaunched.isLoading }
        precondition(localService.requests.count == 1, "once-per-day automatic generation survives relaunch")
        localModel.generate(); await wait { localService.waiting.count == 1 }
        precondition(localService.requests.count == 2, "manual refresh can regenerate the stale recap")
        localService.finish("整理了花园，也计划浇水。[1]"); await wait { !localModel.isGenerating }
        precondition(!localModel.isStale && localModel.current?.text != nil, "manual refresh replaces the stale recap")

        // A cross-midnight segment retains one ID, with a different projection for each date.
        settings.requiresRemoteAIConfirmation = true
        let scopedStore = DaybookRecapStore(database: try DaybookDatabase(inMemory: true))
        let scoped = DaybookRecapModel(store: scopedStore, service: service)
        let sharedID = UUID(), previous = Calendar.current.date(byAdding: .day, value: -1, to: day)!
        func datedRecord(_ date: Date) -> DayRecord { DayRecord(id: sharedID, capturedAt: date.addingTimeInterval(3600), kind: .voice, title: "跨日片段", text: DaybookRecapInput.key(date)) }
        for date in [day, previous] {
            try scopedStore.save(DaybookRecapEntry(input: DaybookRecapInput.prepare(records: [datedRecord(date)], day: date, allowedKinds: [.voice])))
        }
        scoped.scopeLoader = { [datedRecord($0.start)] }
        scoped.synchronize(day: day, records: [], revisions: [], settings: settings, allowedKinds: [.voice], foreground: true, capturing: false)
        await wait { !scoped.isLoading }
        precondition(scoped.record(sharedID)?.capturedAt == day.addingTimeInterval(3600), "source navigation must resolve selected date, not oldest projection of same ID")
        scoped.generate(confirmation: scoped.remoteRequest()); await wait { service.waiting.count == 1 }
        try settings.saveAI(.init(mode: .custom, model: "changed", baseURL: "https://example.invalid/v1"), apiKey: "fixture-only")
        scoped.synchronize(day: day, records: [], revisions: [], settings: settings, allowedKinds: [.voice], foreground: true, capturing: false)
        service.finish(); await wait { !scoped.isGenerating && !scoped.isLoading }
        precondition(scoped.current?.text == nil, "changed provider configuration rejects late result")

        // Two view/model lifetimes can finish their initial read from the same empty
        // archive. Only a durable, atomic per-date claim may start automatic inference.
        let claimRoot = FileManager.default.temporaryDirectory.appendingPathComponent("recap-claim-\(UUID())")
        defer { try? FileManager.default.removeItem(at: claimRoot) }
        let claimURL = claimRoot.appendingPathComponent("daybook.sqlite3")
        let firstStore = DaybookRecapStore(database: try DaybookDatabase(url: claimURL))
        let secondStore = DaybookRecapStore(database: try DaybookDatabase(url: claimURL))
        let counting = CountingRecapGenerator()
        let firstModel = DaybookRecapModel(store: firstStore, service: counting)
        let secondModel = DaybookRecapModel(store: secondStore, service: counting)
        let claimRecords = [DayRecord(id: UUID(), capturedAt: day.addingTimeInterval(3600), kind: .thought, title: "花园", text: "整理了花园。")]
        var initialReads = 2
        var gates: [CheckedContinuation<[DayRecord], Error>] = []
        let load: @MainActor (DateInterval) async throws -> [DayRecord] = { _ in
            if initialReads > 0 {
                initialReads -= 1
                return try await withCheckedThrowingContinuation { gates.append($0) }
            }
            return claimRecords
        }
        for model in [firstModel, secondModel] {
            model.scopeLoader = load
            model.synchronize(day: day, records: claimRecords, revisions: [], settings: localSettings,
                allowedKinds: [.thought], foreground: true, capturing: false)
        }
        await wait { gates.count == 2 }
        for gate in gates { gate.resume(returning: claimRecords) }
        await wait { !firstModel.isLoading && !secondModel.isLoading && !firstModel.isGenerating && !secondModel.isGenerating }
        precondition(counting.requests == 1, "automatic recap must be claimed atomically across model lifetimes")

        // Clearing/replacing an archive projection must never restore automatic budget.
        try firstStore.remove(DaybookRecapInput.key(day))
        let recovered = DaybookRecapModel(store: DaybookRecapStore(database: try DaybookDatabase(url: claimURL)), service: counting)
        recovered.scopeLoader = { _ in claimRecords }
        recovered.synchronize(day: day, records: claimRecords, revisions: [], settings: localSettings,
            allowedKinds: [.thought], foreground: true, capturing: false)
        await wait { !recovered.isLoading && !recovered.isGenerating }
        precondition(counting.requests == 1, "automatic attempt survives archive replacement and relaunch")
        recovered.generate()
        await wait { !recovered.isGenerating }
        precondition(counting.requests == 2 && recovered.current?.text != nil, "manual request can regenerate after automatic budget is consumed")
        print("Daily recap coordinator consent, stale output, retry and privacy tests passed")
    }
}
