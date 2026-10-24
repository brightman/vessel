import Foundation

private func expect(_ condition: Bool, _ message: String) { if !condition { fatalError(message) } }
private struct InsightTestSecrets: SecretStore {
    func read() throws -> String { "" }
    func write(_ value: String) throws { }
}
@MainActor private final class SuspendedInsight: DaybookInsightGenerating {
    var pending: [CheckedContinuation<DaybookInsightOutput, Error>] = []
    var requests: [(DaybookRetrieval.Prepared, String)] = []
    func generate(_ evidence: DaybookRetrieval.Prepared, language: String, now: Date) async throws -> DaybookInsightOutput {
        requests.append((evidence, language))
        return try await withCheckedThrowingContinuation { pending.append($0) }
    }
    func finish(_ output: DaybookInsightOutput) { pending.removeFirst().resume(returning: output) }
}

@main struct DaybookInsightSmoke {
    @MainActor static func main() async throws {
        let suite = "insight-test-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let databaseURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("insights.sqlite3")
        defer { try? FileManager.default.removeItem(at: databaseURL.deletingLastPathComponent()) }
        let database = try DaybookDatabase(url: databaseURL)
        defaults.set(Data(#"{"entries":[],"budgets":[]}"#.utf8), forKey: "daybook.insights.v1")
        let migrated = DaybookInsightStore(defaults: defaults, database: database)
        expect(migrated.storageError == nil, "legacy insight archive migrates before cleanup")
        expect(defaults.object(forKey: "daybook.insights.v1") == nil, "migrated insight text is removed from backup-eligible preferences")
        let preferences = DaybookPreferences(defaults: defaults)
        preferences.quietEnabled = false
        preferences.dailySuggestionLimit = 2
        let now = Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 19, hour: 12))!
        let first = DayRecord(id: UUID(), capturedAt: now.addingTimeInterval(-120), kind: .voice, title: "garden", text: "I want to plant basil.")
        let second = DayRecord(id: UUID(), capturedAt: now.addingTimeInterval(-60), kind: .image, title: "seeds", text: "Basil seeds in the garden shop.")
        let blank = DayRecord(id: UUID(), capturedAt: now.addingTimeInterval(-180), kind: .voice, title: "blank", text: "")
        let records = [blank, first, second]
        let prepared = try DaybookInsightModel.prepare(records: records, selectedDate: now, allowedKinds: preferences.allowedKinds, now: now)
        expect(prepared.sources.count == 2, "generic daily selection includes unrelated source texts and excludes blank sources")
        expect(prepared.evidence.isCurrent(records: records, allowedKinds: preferences.allowedKinds), "full evidence includes even blank records")
        let output = DaybookInsightOutput(observation: "Your plan to plant basil [1] connects with the seeds you recorded [2].", nextAction: "Check the basil seed packet [2]")
        try output.validate(sources: prepared.sources)
        expect(output.reminderTitle == "Check the basil seed packet", "draft uses bounded generated action without citation markup")
        for invalid in [DaybookInsightOutput(observation: "One [1] repeated [1]", nextAction: "Check [1]"), DaybookInsightOutput(observation: "Invalid [1] [3]", nextAction: "Check [1]"), DaybookInsightOutput(observation: "Both [1] [2]", nextAction: "Uncited action"), DaybookInsightOutput(observation: "Both [1] [2] and invented [9999999999999999999999999999]", nextAction: "Check [1]")] {
            do { try invalid.validate(sources: prepared.sources); fatalError("invalid provenance accepted") } catch {}
        }
        let service = SuspendedInsight(), store = DaybookInsightStore(defaults: defaults, database: database)
        let model = DaybookInsightModel(store: store, service: service)
        func sync(_ records: [DayRecord] = records, day: Date? = nil, foreground: Bool = true, capture: Bool = false, language: String = "en") {
            model.synchronize(records: records, selectedDate: day ?? now, preferences: preferences, language: language, foreground: foreground, capturing: capture, now: now)
        }
        preferences.proactiveEnabled = false; sync(); expect(!model.isPending, "disabled gate")
        preferences.proactiveEnabled = true; sync(foreground: false); expect(!model.isPending, "background gate")
        sync(capture: true); expect(!model.isPending, "pending capture gate")
        preferences.quietEnabled = true; preferences.quietStartMinutes = 0; preferences.quietEndMinutes = 0
        sync(); expect(!model.isPending, "full day quiet gate")
        preferences.quietEnabled = false
        sync(day: now.addingTimeInterval(-86400)); expect(!model.isPending, "past day never automatic")
        sync([first]); expect(!model.isPending && model.result == nil, "minimum two usable distinct sources")
        sync(); expect(model.isPending, "foreground current day starts once")
        await Task.yield(); service.finish(output)
        for _ in 0..<10 { await Task.yield() }
        expect(model.result?.output == output, "valid result published")
        let reopened = DaybookInsightModel(store: DaybookInsightStore(defaults: defaults, database: database), service: service)
        reopened.synchronize(records: records, selectedDate: now, preferences: preferences, language: "en", foreground: true, capturing: false, now: now)
        expect(reopened.result?.output == output && !reopened.isPending, "current cache survives relaunch without new attempt")
        reopened.dismiss()
        let dismissed = DaybookInsightModel(store: DaybookInsightStore(defaults: defaults, database: database), service: service)
        dismissed.synchronize(records: records, selectedDate: now, preferences: preferences, language: "en", foreground: true, capturing: false, now: now)
        expect(dismissed.result == nil && !dismissed.isPending && dismissed.isDismissed, "exact revision dismissal persists")
        let changed = DayRecord(id: first.id, capturedAt: first.capturedAt, kind: .voice, title: first.title, text: first.text + " Changed.")
        sync([blank, changed, second]); expect(model.result == nil && model.isPending, "edit invalidates cache and permits second attempt")
        await Task.yield(); model.cancel(); service.finish(output)
        for _ in 0..<10 { await Task.yield() }
        expect(model.result == nil && !model.isPending, "cancel rejects late result")
        sync([blank, changed, second]); expect(!model.isPending, "cancelled revision does not auto loop")
        sync([blank, first, second], language: "ja"); expect(!model.isPending, "daily cap includes cancelled attempts and config changes")
        model.refresh(now: now); expect(model.isPending, "explicit refresh bypasses automatic cap")
        await Task.yield(); preferences.allowPhotos = false; sync(language: "ja"); service.finish(output)
        for _ in 0..<10 { await Task.yield() }
        expect(model.result == nil && !model.isPending, "permission revocation cancels and rejects late output")
        preferences.allowPhotos = true; sync(language: "ja"); model.refresh(now: now)
        await Task.yield(); sync(day: now.addingTimeInterval(-86400), language: "ja"); service.finish(output)
        for _ in 0..<10 { await Task.yield() }
        expect(model.result == nil && !model.isPending, "day switch rejects late response")
        // Failed attempt persists: unavailable local model never loops on foreground ticks or relaunch.
        sync(language: "en"); model.refresh(now: now); await Task.yield()
        service.pending.removeFirst().resume(throwing: DaybookInsightFailure.unavailable)
        for _ in 0..<10 { await Task.yield() }
        expect(model.message == DaybookInsightFailure.unavailable.message, "unavailable explanation is retained")
        let failed = DaybookInsightModel(store: DaybookInsightStore(defaults: defaults, database: database), service: service)
        failed.synchronize(records: records, selectedDate: now, preferences: preferences, language: "en", foreground: true, capturing: false, now: now)
        expect(!failed.isPending && failed.result == nil, "failed attempt survives relaunch")
        // Cache is bounded; old result cannot reappear with stale evidence or a different permission scope.
        for i in 0..<40 {
            let key = DaybookInsightKey(evidence: prepared.evidence, language: "test-\(i)")
            try store.recordAttempt(key, automatic: false, now: now)
        }
        expect(store.entryCount <= 30, "bounded revision archive")
        // Reservation failure must not call the model or publish an in-memory attempt.
        let failureDB = try DaybookDatabase(url: databaseURL.deletingLastPathComponent().appendingPathComponent("failure.sqlite3"))
        let failureStore = DaybookInsightStore(defaults: defaults, database: failureDB)
        let failureService = SuspendedInsight()
        let failureModel = DaybookInsightModel(store: failureStore, service: failureService)
        try failureDB.execute("CREATE TRIGGER fail_reservation BEFORE INSERT ON insight_budgets BEGIN SELECT RAISE(ABORT, 'no storage'); END")
        failureModel.synchronize(records: records, selectedDate: now, preferences: preferences, language: "en", foreground: true, capturing: false, now: now)
        await Task.yield()
        expect(failureModel.storageError != nil && !failureModel.isPending && failureService.pending.isEmpty && failureStore.entryCount == 0, "failed reservation prevents generation and memory publish")
        try failureDB.execute("DROP TRIGGER fail_reservation")
        failureModel.retryStorage()
        failureModel.synchronize(records: records, selectedDate: now, preferences: preferences, language: "en", foreground: true, capturing: false, now: now)
        await Task.yield()
        expect(failureModel.isPending && failureService.pending.count == 1, "explicit storage retry permits durable reservation")
        try failureDB.execute("CREATE TRIGGER fail_finish BEFORE INSERT ON insight_entries BEGIN SELECT RAISE(ABORT, 'no result storage'); END")
        failureService.finish(output)
        for _ in 0..<10 { await Task.yield() }
        expect(failureModel.result == nil && failureModel.storageError != nil && !failureModel.isPending, "failed result commit never publishes generated content")
        expect(failureStore.entryCount == 1 && failureStore.automaticAttempts(now: now) == 1, "committed attempt survives failed result save")
        // Storage recovery must use the current scope, including changes made while blocked.
        for recovery in ["reset", "retry"] {
            for change in ["permission", "deletion", "day-language"] {
                let recoveryDB = try DaybookDatabase(url: databaseURL.deletingLastPathComponent().appendingPathComponent("recovery-\(recovery)-\(change).sqlite3"))
                let recoveryStore = DaybookInsightStore(defaults: defaults, database: recoveryDB)
                let recoveryService = SuspendedInsight()
                let recoveryModel = DaybookInsightModel(store: recoveryStore, service: recoveryService)
                preferences.allowPhotos = true; preferences.proactiveEnabled = true
                try recoveryDB.execute("CREATE TRIGGER fail_recovery BEFORE INSERT ON insight_budgets BEGIN SELECT RAISE(ABORT, 'blocked storage'); END")
                recoveryModel.synchronize(records: records, selectedDate: now, preferences: preferences, language: "en", foreground: true, capturing: false, now: now)
                expect(recoveryModel.storageError != nil && recoveryModel.hasEnoughSources, "recovery setup has old scope but no durable reservation")
                let selectedDay = change == "day-language" ? now.addingTimeInterval(-86400) : now
                let language = change == "day-language" ? "zh-Hans" : "en"
                let newDayRecords = [
                    DayRecord(id: UUID(), capturedAt: selectedDay.addingTimeInterval(-60), kind: .voice, title: "Yesterday one", text: "Different day one"),
                    DayRecord(id: UUID(), capturedAt: selectedDay.addingTimeInterval(-30), kind: .voice, title: "Yesterday two", text: "Different day two")
                ]
                let currentRecords = change == "deletion" ? [first] : change == "day-language" ? newDayRecords : records
                preferences.allowPhotos = change != "permission"
                preferences.proactiveEnabled = false
                recoveryModel.synchronize(records: currentRecords, selectedDate: selectedDay, preferences: preferences, language: language, foreground: true, capturing: false, now: now)
                let current = try DaybookInsightModel.prepare(records: currentRecords, selectedDate: selectedDay, allowedKinds: preferences.allowedKinds, now: now)
                let enough = change == "day-language"
                expect(recoveryModel.hasEnoughSources == enough && recoveryModel.dateLabel == current.dateLabel, "blocked storage must update current sources/date eligibility")
                expect(recoveryModel.result == nil && !recoveryModel.isPending, "blocked storage hides generated content")
                try recoveryDB.execute("DROP TRIGGER fail_recovery")
                if recovery == "reset" { recoveryModel.resetStorage() } else { recoveryModel.retryStorage() }
                expect(recoveryModel.storageError == nil && recoveryModel.hasEnoughSources == enough, "recovery keeps current scope eligibility")
                recoveryModel.refresh(now: now)
                for _ in 0..<10 { await Task.yield() }
                if enough {
                    expect(recoveryService.requests.count == 1, "current manual scope may generate after recovery")
                    let request = recoveryService.requests[0]
                    expect(request.1 == language && request.0.evidence == current.evidence && Set(request.0.sources.map(\.id)) == Set(newDayRecords.map(\.id)), "recovery never sends old day/language/source context")
                    let activeKey = DaybookInsightKey(evidence: current.evidence, language: language)
                    expect(recoveryStore.entry(activeKey) != nil, "reserved key reflects current recovered scope")
                    recoveryModel.cancel()
                    recoveryService.pending.removeFirst().resume(throwing: CancellationError())
                } else {
                    expect(recoveryService.requests.isEmpty && recoveryStore.entryCount == 0, "reset/retry/refresh never sends revoked or deleted sources")
                }
            }
        }
        // The scheduled task must recheck permission values before handing text to the service.
        preferences.allowPhotos = true; preferences.proactiveEnabled = false
        let scheduledDB = try DaybookDatabase(url: databaseURL.deletingLastPathComponent().appendingPathComponent("scheduled-scope.sqlite3"))
        let scheduledService = SuspendedInsight()
        let scheduledModel = DaybookInsightModel(store: DaybookInsightStore(defaults: defaults, database: scheduledDB), service: scheduledService)
        scheduledModel.synchronize(records: records, selectedDate: now, preferences: preferences, language: "en", foreground: true, capturing: false, now: now)
        scheduledModel.refresh(now: now)
        preferences.allowPhotos = false
        for _ in 0..<10 { await Task.yield() }
        expect(scheduledService.requests.isEmpty && !scheduledModel.hasEnoughSources && !scheduledModel.isPending, "permission change before task entry never reaches generation service")
        let macSettings = AppSettings(defaults: defaults, secrets: InsightTestSecrets())
        var mac = AIConfiguration(); mac.mode = .nearbyMac; mac.nearbyMacServiceID = UUID().uuidString; mac.nearbyMacName = "合成测试 Mac"
        try macSettings.saveAI(mac, apiKey: ""); macSettings.requiresRemoteAIConfirmation = true
        let macService = SuspendedInsight()
        let macStore = DaybookInsightStore(defaults: defaults, database: try DaybookDatabase(inMemory: true))
        let macModel = DaybookInsightModel(store: macStore, service: macService)
        macModel.configure(settings: macSettings)
        let voice = DayRecord(id: UUID(), capturedAt: now.addingTimeInterval(-20), kind: .voice, title: "plants", text: "Basil needs a sunny spot.")
        preferences.proactiveEnabled = true; preferences.allowAudio = true; preferences.allowPhotos = true; preferences.quietEnabled = false
        macModel.synchronize(records: [first, voice, second], selectedDate: now, preferences: preferences, language: "en", foreground: true, capturing: false, now: now)
        expect(!macModel.isPending && macService.requests.isEmpty, "selected Mac never bypasses send confirmation for automatic insights")
        macModel.refresh(now: now)
        expect(macModel.remoteConfirmation?.prepared.sources.count == 2, "Mac insight preview includes permitted voice sources")
        expect(macModel.remoteConfirmation?.configuration.mode == .nearbyMac, "insight confirmation identifies selected Mac")
        var providerKey = DaybookInsightKey(evidence: macModel.remoteConfirmation!.prepared.evidence, language: "en")
        providerKey.providerKey = "synthetic-Mac-provider"
        try macStore.recordAttempt(providerKey, automatic: false, now: now)
        expect(macStore.entry(providerKey) != nil, "provider-specific insight keys are persisted")
        try macSettings.saveAI(AIConfiguration(), apiKey: "")
        macModel.configure(settings: macSettings)
        expect(macModel.remoteConfirmation == nil && macService.requests.isEmpty, "switching provider invalidates a pending Mac send")
        print("Daybook daily insight: local lifecycle, selected-Mac consent, provider-specific cache and stale confirmation passed")
    }
}
