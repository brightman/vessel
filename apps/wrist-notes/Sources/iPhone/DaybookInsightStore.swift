import Foundation

struct DaybookInsightKey: Codable, Equatable {
    let evidence: DaybookEvidenceSnapshot
    let language: String
    // Bump whenever prompt, validation, retrieval limits, or local provider policy changes.
    var generationVersion = 1
    var providerKey: String? = nil
}

struct DaybookInsightOutput: Codable, Equatable, Sendable {
    let observation: String
    let nextAction: String

    func validate(sources: [DaybookRetrieval.Source]) throws {
        let valid = Dictionary(sources.map { ($0.number, $0.id) }, uniquingKeysWith: { first, _ in first })
        func citations(_ text: String) throws -> Set<UUID> {
            let expression = try! NSRegularExpression(pattern: #"\[(\d+)\]"#)
            let numbers = try expression.matches(in: text, range: NSRange(text.startIndex..., in: text)).map { match -> Int in
                guard let range = Range(match.range(at: 1), in: text), let number = Int(text[range]) else { throw DaybookInsightFailure.invalid }
                return number
            }
            guard numbers.allSatisfy({ valid[$0] != nil }) else { throw DaybookInsightFailure.invalid }
            return Set(numbers.compactMap { valid[$0] })
        }
        guard !observation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              observation.count <= 1_200, nextAction.count <= 200, !reminderTitle.isEmpty,
              try citations(observation).count >= 2, try !citations(nextAction).isEmpty else { throw DaybookInsightFailure.invalid }
    }
    var reminderTitle: String {
        let plain = nextAction.replacingOccurrences(of: #"\[\d+\]"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        return String(plain.prefix(120))
    }
}

struct DaybookDailyInsight: Codable, Equatable {
    let output: DaybookInsightOutput
    let sources: [DaybookRetrieval.Source]
}

enum DaybookInsightFailure: Error {
    case unavailable, unsupportedLanguage, invalid, generation
    var message: String {
        switch self {
        case .unavailable: "Apple 本地模型不可用。请检查设备支持、Apple Intelligence 开关与模型下载状态；尚未生成洞察。"
        case .unsupportedLanguage: "Apple 本地模型暂不支持所选语言；尚未生成洞察。可以切换界面语言后重试。"
        case .invalid: "洞察未提供至少两条有效来源和有依据的行动建议，未显示结果。请重试。"
        case .generation: "本地洞察生成失败，未显示结果。请稍后重试。"
        }
    }
}

/// Bounded local archive includes unsuccessful attempts, so reopening cannot cause retry loops.
@MainActor final class DaybookInsightStore {
    struct Entry: Codable {
        let key: DaybookInsightKey
        var updatedAt: Date
        var result: DaybookDailyInsight?
        var message: String?
        var dismissed = false
    }
    private struct Budget: Codable { let day: Date; var attempts: Int }
    private struct Archive: Codable { var entries: [Entry] = []; var budgets: [Budget] = [] }
    private let defaults: UserDefaults
    private let storageKey = "daybook.insights.v1"
    private var database: DaybookDatabase?
    private var archive = Archive()
    private(set) var storageError: String?
    var entryCount: Int { archive.entries.count }

    init(defaults: UserDefaults = .standard, database: DaybookDatabase? = nil) {
        self.defaults = defaults; self.database = database
        do { try reload() } catch { storageError = Self.message(error) }
    }
    private func connection() throws -> DaybookDatabase {
        let db: DaybookDatabase
        if let database { db = database } else { db = try DaybookDatabase(); database = db }
        return db
    }
    static func message(_ error: Error) -> String { "本机洞察存储失败，尚未保存更改：\(error.localizedDescription)" }
    func reload() throws {
        do {
            let db = try connection()
            try db.migrate("insights") {
                guard let original = defaults.object(forKey: storageKey) else { return }
                guard let data = original as? Data else { throw DaybookDatabase.Failure(code: 11, detail: "洞察迁移数据格式错误，原数据已保留") }
                guard data.count <= 1_000_000 else { throw DaybookDatabase.Failure(code: 11, detail: "洞察迁移文件过大，原数据已保留") }
                let imported = try JSONDecoder().decode(Archive.self, from: data)
                try Self.validate(imported)
                try Self.write(imported, db: db)
            }
            // Insight payloads can contain HealthKit-derived evidence. Once the SQLite migration
            // commits in the backup-excluded Application Support tree, remove the old defaults copy.
            defaults.removeObject(forKey: storageKey)
            let loaded = try Self.read(db)
            try Self.validate(loaded)
            archive = loaded; storageError = nil
        } catch { storageError = Self.message(error); throw error }
    }
    /// Explicit domain reset leaves life sources, conversations and legacy bytes intact.
    func reset() throws {
        do {
            let db = try connection()
            try db.transaction {
                try Self.write(Archive(), db: db)
                try db.markMigrated("insights")
            }
            archive = Archive(); storageError = nil
        } catch { storageError = Self.message(error); throw error }
    }
    func entry(_ key: DaybookInsightKey) -> Entry? { archive.entries.first { $0.key == key } }
    func automaticAttempts(now: Date) -> Int {
        archive.budgets.first { $0.day == Calendar.current.startOfDay(for: now) }?.attempts ?? 0
    }
    func recordAttempt(_ key: DaybookInsightKey, automatic: Bool, now: Date) throws {
        try mutate { next in
            for index in next.entries.indices where next.entries[index].key.evidence.dayStart == key.evidence.dayStart {
                if next.entries[index].key != key { next.entries[index].result = nil }
            }
            next.entries.removeAll { $0.key == key }
            // A nil result/message is a deliberate attempt marker, including cancellation.
            next.entries.insert(Entry(key: key, updatedAt: now), at: 0)
            if automatic {
                let day = Calendar.current.startOfDay(for: now)
                if let index = next.budgets.firstIndex(where: { $0.day == day }) { next.budgets[index].attempts += 1 }
                else { next.budgets.insert(Budget(day: day, attempts: 1), at: 0) }
            }
        }
    }
    func finish(_ key: DaybookInsightKey, result: DaybookDailyInsight? = nil, message: String? = nil) throws {
        try mutate { next in
            guard let index = next.entries.firstIndex(where: { $0.key == key }) else { return }
            next.entries[index].result = result; next.entries[index].message = message
        }
    }
    func dismiss(_ key: DaybookInsightKey) throws {
        try mutate { next in
            guard let index = next.entries.firstIndex(where: { $0.key == key }) else { return }
            next.entries[index].dismissed = true; next.entries[index].result = nil
        }
    }
    func pruneStale(records: [DayRecord], allowedKinds: Set<DayRecord.Kind>) throws {
        // Avoid disk work on foreground ticks without cached generated content.
        guard archive.entries.contains(where: { $0.result != nil && !$0.key.evidence.isCurrent(records: records, allowedKinds: allowedKinds) }) else { return }
        try mutate { next in
            for index in next.entries.indices where next.entries[index].result != nil {
                if !next.entries[index].key.evidence.isCurrent(records: records, allowedKinds: allowedKinds) { next.entries[index].result = nil }
            }
        }
    }
    private func mutate(_ body: (inout Archive) throws -> Void) throws {
        do {
            // A load/import error requires retry or explicit reset before any mutation.
            guard storageError == nil else { throw DaybookDatabase.Failure(code: 11, detail: "请重试读取或明确重置本机洞察存储") }
            let db = try connection()
            let committed = try db.transaction {
                // Reload under the write lock so two instances cannot lose budget increments.
                var next = try Self.read(db)
                try body(&next)
                next.entries = Array(next.entries.prefix(30)); next.budgets = Array(next.budgets.prefix(30))
                try Self.validate(next)
                try Self.write(next, db: db)
                return next
            }
            archive = committed; storageError = nil
        } catch { storageError = Self.message(error); throw error }
    }
    private static func validate(_ archive: Archive) throws {
        guard archive.entries.count <= 30, archive.budgets.count <= 30,
              Set(archive.entries.map { identity($0.key) }).count == archive.entries.count,
              Set(archive.budgets.map(\.day)).count == archive.budgets.count,
              archive.budgets.allSatisfy({ $0.attempts >= 0 && $0.day.timeIntervalSinceReferenceDate.isFinite }),
              archive.entries.allSatisfy({ $0.updatedAt.timeIntervalSinceReferenceDate.isFinite && $0.key.evidence.dayStart < $0.key.evidence.dayEnd }),
              try JSONEncoder().encode(archive).count <= 1_000_000 else {
            throw DaybookDatabase.Failure(code: 11, detail: "洞察存储内容无效，原数据已保留")
        }
    }
    private static func identity(_ key: DaybookInsightKey) -> String {
        // Fingerprint covers record IDs/content; all other scope fields also identify a revision.
        let kinds = key.evidence.allowedKinds.map(\.rawValue).sorted().joined(separator: ",")
        return "\(key.evidence.dayStart.timeIntervalSinceReferenceDate)|\(key.evidence.dayEnd.timeIntervalSinceReferenceDate)|\(kinds)|\(key.evidence.fingerprint)|\(key.language.utf8.count):\(key.language)|\(key.generationVersion)|\(key.providerKey ?? "apple")"
    }
    private static func write(_ archive: Archive, db: DaybookDatabase) throws {
        try db.execute("DELETE FROM insight_entries")
        try db.execute("DELETE FROM insight_budgets")
        for (position, entry) in archive.entries.enumerated() {
            try db.execute("INSERT INTO insight_entries VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)", [.text(identity(entry.key)), .integer(Int64(position)), .real(entry.key.evidence.dayStart.timeIntervalSinceReferenceDate), .text(entry.key.language), .integer(Int64(entry.key.generationVersion)), try DaybookDatabase.json(entry.key.evidence), .real(entry.updatedAt.timeIntervalSinceReferenceDate), try entry.result.map { try DaybookDatabase.json($0) } ?? .null, entry.message.map { .text($0) } ?? .null, .integer(entry.dismissed ? 1 : 0), entry.key.providerKey.map { .text($0) } ?? .null])
        }
        for (position, budget) in archive.budgets.enumerated() { try db.execute("INSERT INTO insight_budgets VALUES (?, ?, ?)", [.real(budget.day.timeIntervalSinceReferenceDate), .integer(Int64(budget.attempts)), .integer(Int64(position))]) }
    }
    private static func read(_ db: DaybookDatabase) throws -> Archive {
        try db.transaction {
            let entries = try db.query("SELECT * FROM insight_entries ORDER BY position").map { row -> Entry in
                var key = DaybookInsightKey(evidence: try DaybookDatabase.decode(DaybookEvidenceSnapshot.self, row["evidence"]), language: try row.requiredString("language"))
                key.generationVersion = try row.requiredInt("generation_version")
                key.providerKey = row["provider_key"]?.string
                return Entry(key: key, updatedAt: Date(timeIntervalSinceReferenceDate: try row.requiredDouble("updated_at")), result: row["result"] == .null ? nil : try DaybookDatabase.decode(DaybookDailyInsight.self, row["result"]), message: row["message"]?.string, dismissed: row["dismissed"] == .integer(1))
            }
            let budgets = try db.query("SELECT * FROM insight_budgets ORDER BY position").map { row in Budget(day: Date(timeIntervalSinceReferenceDate: try row.requiredDouble("day")), attempts: try row.requiredInt("attempts")) }
            return Archive(entries: entries, budgets: budgets)
        }
    }
}
