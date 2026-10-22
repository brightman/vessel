import Foundation

private func expect(_ value: Bool, _ message: String) { precondition(value, message) }
@main struct SQLitePersistenceSmoke {
    @MainActor static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let db = try DaybookDatabase(url: root.appendingPathComponent("shared.sqlite3"))
        try db.execute("CREATE TABLE rollback_probe (id INTEGER PRIMARY KEY)")
        do {
            try db.transaction {
                try db.execute("INSERT INTO rollback_probe VALUES (?)", [.integer(1)])
                try db.execute("INSERT INTO rollback_probe VALUES (?)", [.integer(1)])
            }
            fatalError("constraint must fail")
        } catch {}
        expect(try db.query("SELECT * FROM rollback_probe").isEmpty, "constraint rolls back whole transaction")
        expect(try db.query("PRAGMA foreign_keys")[0]["foreign_keys"] == .integer(1), "foreign keys enabled")
        expect(try db.query("PRAGMA journal_mode")[0]["journal_mode"] == .text("wal"), "WAL enabled")
        let plan = try db.query("EXPLAIN QUERY PLAN SELECT * FROM life_records WHERE source = ? AND day = ? ORDER BY captured_at,id", [.text("calendar"), .real(0)])
        let planText = try plan.map { try $0.requiredString("detail") }.joined(separator: " ")
        expect(planText.contains("life_records_source_day") && !planText.contains("TEMP B-TREE"), "life snapshot lookup uses source/day index in record order")
        try db.execute("DROP INDEX life_records_source_day")
        let indexedReopen = try DaybookDatabase(url: db.url)
        let reopenedPlan = try indexedReopen.query("EXPLAIN QUERY PLAN SELECT * FROM life_records WHERE source = ? AND day = ? ORDER BY captured_at,id", [.text("calendar"), .real(0)])
        expect(try reopenedPlan.map { try $0.requiredString("detail") }.joined().contains("life_records_source_day"), "existing version-1 database receives additive lookup index")
        let day = Date(timeIntervalSinceReferenceDate: 814060800.1234567)
        let id = UUID()
        let record = DayRecord(id: id, capturedAt: day, kind: .calendar, title: "Meeting", text: "Read only")
        let lifeURL = root.appendingPathComponent("snapshots.json")
        let legacyLife = """
        {"enabled":{"calendar":true},"snapshots":[],"suppressed":[]}
        """
        try Data(legacyLife.utf8).write(to: lifeURL)
        let life = try LifeSourceStore(url: lifeURL, database: db)
        expect(life.isEnabled(.calendar), "legacy setting imports")
        try life.replace(source: .calendar, day: day, records: [record], refreshedAt: day)
        try life.markFailure(source: .calendar, day: day, status: .error, message: "offline")
        let reopened = try LifeSourceStore(url: lifeURL, database: db)
        expect(reopened.records.first?.id == id && reopened.records.first?.text.contains("旧快照") == true, "reopen retains stale record UUID")
        try reopened.delete(id)
        try reopened.replace(source: .calendar, day: day, records: [record], refreshedAt: day)
        expect(reopened.records.isEmpty, "suppression survives database roundtrip")
        expect(try Data(contentsOf: lifeURL) == Data(legacyLife.utf8), "original legacy file preserved")
        let suite = "sqlite-insights-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let evidence = DaybookEvidenceSnapshot(records: [record], dayStart: day, dayEnd: day.addingTimeInterval(86400), allowedKinds: [.calendar])
        let key = DaybookInsightKey(evidence: evidence, language: "en")
        let insights = DaybookInsightStore(defaults: defaults, database: db)
        try insights.recordAttempt(key, automatic: true, now: day)
        expect(insights.automaticAttempts(now: day) == 1 && insights.entry(key) != nil, "attempt and daily budget commit together")
        try db.execute("CREATE TRIGGER fail_budget BEFORE INSERT ON insight_budgets BEGIN SELECT RAISE(ABORT, 'budget failure'); END")
        let failedKey = DaybookInsightKey(evidence: evidence, language: "zh")
        do { try insights.recordAttempt(failedKey, automatic: true, now: day); fatalError("budget failure accepted") } catch {}
        expect(insights.entry(failedKey) == nil && insights.automaticAttempts(now: day) == 1, "failed reservation publishes no entry or budget")
        let freshInsights = DaybookInsightStore(defaults: defaults, database: db)
        expect(freshInsights.entry(failedKey) == nil && freshInsights.automaticAttempts(now: day) == 1, "failed reservation is not durable")
        try db.execute("DROP TRIGGER fail_budget")
        try insights.reload()
        let otherConnection = try DaybookDatabase(url: db.url)
        let otherInstance = DaybookInsightStore(defaults: defaults, database: otherConnection)
        try otherInstance.recordAttempt(failedKey, automatic: true, now: day)
        try insights.recordAttempt(key, automatic: true, now: day)
        expect(insights.automaticAttempts(now: day) == 3, "reservation reload prevents stale-instance budget loss")
        let corruptURL = root.appendingPathComponent("history.json"), original = Data("broken".utf8)
        try original.write(to: corruptURL)
        let conversations = DaybookConversationStore(url: corruptURL, database: db)
        do { _ = try conversations.load(); fatalError("corrupt source accepted") } catch {}
        expect(try db.query("SELECT * FROM storage_migrations WHERE domain = ?", [.text("conversations")]).isEmpty, "failed import is not complete")
        expect(try Data(contentsOf: corruptURL) == original, "corrupt source preserved")
        try conversations.reset()
        expect(try conversations.load().isEmpty, "explicit conversation reset resolves corrupt import")
        expect(try LifeSourceStore(url: lifeURL, database: db).isEnabled(.calendar), "conversation reset does not affect life")
        expect(DaybookInsightStore(defaults: defaults, database: db).automaticAttempts(now: day) == 3, "conversation reset does not affect budgets")
        expect(try Data(contentsOf: corruptURL) == original, "reset preserves legacy original too")
        // A valid source with a constraint failure after its first row must roll back completely.
        let importDB = try DaybookDatabase(url: root.appendingPathComponent("import.sqlite3"))
        let invalidLifeURL = root.appendingPathComponent("duplicate-life.json")
        let snapshot = LifeSourceSnapshot(source: .calendar, day: day, records: [record], status: .ready, refreshedAt: day, isStale: false)
        struct LifeArchive: Encodable { let enabled: [String: Bool]; let snapshots: [LifeSourceSnapshot]; let suppressed: Set<UUID> }
        let invalidLife = try JSONEncoder().encode(LifeArchive(enabled: ["calendar": true], snapshots: [snapshot, snapshot], suppressed: []))
        try invalidLife.write(to: invalidLifeURL)
        do { _ = try LifeSourceStore(url: invalidLifeURL, database: importDB); fatalError("duplicate import accepted") } catch {}
        expect(try importDB.query("SELECT * FROM life_records").isEmpty, "partially imported records roll back")
        expect(try importDB.query("SELECT * FROM storage_migrations WHERE domain = ?", [.text("life")]).isEmpty, "failed life import marker rolls back independently of additive schema migrations")
        expect(try importDB.query("SELECT * FROM life_moment_metadata").isEmpty, "failed import leaves no partial moment metadata")
        expect(try Data(contentsOf: invalidLifeURL) == invalidLife, "constraint import preserves source bytes")
        let repaired = try JSONEncoder().encode(LifeArchive(enabled: ["calendar": true], snapshots: [snapshot], suppressed: [id]))
        try repaired.write(to: invalidLifeURL)
        let migratedLife = try LifeSourceStore(url: invalidLifeURL, database: importDB)
        expect(migratedLife.records.isEmpty && migratedLife.snapshot(source: .calendar, day: day)?.records.first?.id == id, "migration preserves snapshot plus suppression")
        // Normal life mutations must not rewrite unrelated historical record rows.
        try importDB.execute("CREATE TABLE protected_life_record (id TEXT PRIMARY KEY)")
        try importDB.execute("INSERT INTO protected_life_record VALUES (?)", [.text(id.uuidString)])
        try importDB.execute("CREATE TRIGGER protect_life_delete BEFORE DELETE ON life_records WHEN OLD.id IN (SELECT id FROM protected_life_record) BEGIN SELECT RAISE(ABORT, 'unrelated historical delete'); END")
        try importDB.execute("CREATE TRIGGER protect_life_insert BEFORE INSERT ON life_records WHEN NEW.id IN (SELECT id FROM protected_life_record) BEGIN SELECT RAISE(ABORT, 'unrelated historical insert'); END")
        try migratedLife.setEnabled(false, source: .health)
        let nextDay = day.addingTimeInterval(86400)
        let nextRecord = DayRecord(id: UUID(), capturedAt: nextDay, kind: .calendar, title: "Tomorrow", text: "Second date")
        try migratedLife.replace(source: .calendar, day: nextDay, records: [nextRecord], refreshedAt: nextDay)
        try migratedLife.markFailure(source: .calendar, day: day, status: .error, message: "stale")
        expect(try importDB.query("SELECT id FROM life_records").count == 2, "settings/new-day/status changes preserve historical rows")
        do { try migratedLife.delete(id); fatalError("protected record delete accepted") } catch {}
        expect(migratedLife.snapshot(source: .calendar, day: day)?.records.first?.id == id, "failed incremental save does not publish snapshot deletion")
        try importDB.execute("DROP TRIGGER protect_life_delete")
        try importDB.execute("DROP TRIGGER protect_life_insert")
        // Valid conversation import retains all nested identity and date fields.
        let historyURL = root.appendingPathComponent("valid-history.json")
        let source = DaybookRetrieval.Source(id: id, number: 1, title: "Meeting", capturedAt: day, kind: .calendar, snippet: "Read only", truncated: false)
        let turn = DaybookConversationTurn(id: UUID(), question: "What about [1]?", text: "Meeting [1]", generated: true, provider: "local", evidence: evidence, sources: [source], scopeDescription: "date", questionReferenceIDs: [1: id])
        let thread = DaybookConversation(day: day, updatedAt: day, turns: [turn])
        struct ConversationArchive: Encodable { let version: Int; let conversations: [DaybookConversation] }
        let history = try JSONEncoder().encode(ConversationArchive(version: 1, conversations: [thread]))
        try history.write(to: historyURL)
        let migratedConversations = DaybookConversationStore(url: historyURL, database: importDB)
        var migratedTurn = turn; migratedTurn.createdAt = day
        let migratedThread = DaybookConversation(day: day, updatedAt: day, turns: [migratedTurn])
        expect(try migratedConversations.load() == [migratedThread], "conversation migration preserves identities, mapping, evidence, dates and derives missing send time")
        _ = try migratedConversations.save([])
        expect(try DaybookConversationStore(url: historyURL, database: importDB).load().isEmpty, "legacy history is imported exactly once")
        expect(try Data(contentsOf: historyURL) == history, "history original retained")
        // Insight migration preserves nil suppression markers, failed messages, dismissal and budget.
        struct InsightBudget: Encodable { let day: Date; let attempts: Int }
        struct InsightArchive: Encodable { let entries: [DaybookInsightStore.Entry]; let budgets: [InsightBudget] }
        let markerKey = DaybookInsightKey(evidence: evidence, language: "cancelled")
        var dismissed = DaybookInsightStore.Entry(key: key, updatedAt: day, result: nil, message: "failed")
        dismissed.dismissed = true
        let insightData = try JSONEncoder().encode(InsightArchive(entries: [dismissed, .init(key: markerKey, updatedAt: day)], budgets: [.init(day: Calendar.current.startOfDay(for: day), attempts: 2)]))
        defaults.set(insightData, forKey: "daybook.insights.v1")
        let migratedInsights = DaybookInsightStore(defaults: defaults, database: importDB)
        expect(migratedInsights.storageError == nil && migratedInsights.entry(markerKey) != nil, "nil suppression marker imports")
        expect(migratedInsights.entry(key)?.dismissed == true && migratedInsights.entry(key)?.message == "failed" && migratedInsights.automaticAttempts(now: day) == 2, "failed/dismissed state and budget import")
        expect(defaults.data(forKey: "daybook.insights.v1") == nil, "committed migration removes health-derived defaults from device backups")
        try migratedInsights.reset()
        expect(DaybookInsightStore(defaults: defaults, database: importDB).entryCount == 0, "insight explicit reset is not reimported")
        expect(defaults.data(forKey: "daybook.insights.v1") == nil, "reset does not restore the migrated defaults copy")
        expect(try LifeSourceStore(url: invalidLifeURL, database: importDB).isEnabled(.calendar), "insight reset keeps life settings")
        let corruptDB = try DaybookDatabase(url: root.appendingPathComponent("corrupt-insight.sqlite3"))
        let corruptDefaults = Data("invalid".utf8)
        defaults.set(corruptDefaults, forKey: "daybook.insights.v1")
        let failedInsightImport = DaybookInsightStore(defaults: defaults, database: corruptDB)
        expect(failedInsightImport.storageError != nil, "corrupt insight source surfaces load error")
        do { try failedInsightImport.recordAttempt(key, automatic: true, now: day); fatalError("write bypassed failed import") } catch {}
        expect(try corruptDB.query("SELECT * FROM storage_migrations").isEmpty, "corrupt insight import never marked complete")
        expect(defaults.data(forKey: "daybook.insights.v1") == corruptDefaults, "corrupt defaults preserved")
        // The reusable connection can be used off main without leaking statement/handle lifetime.
        let count = try await Task.detached { try db.query("SELECT count(*) AS count FROM insight_budgets")[0].requiredInt("count") }.value
        expect(count == 1, "worker-thread query returns owned values")
        print("SQLite persistence: rollback, WAL/FK, row roundtrip, once migration, corruption preservation, domain isolation, atomic reservation passed")
    }
}
