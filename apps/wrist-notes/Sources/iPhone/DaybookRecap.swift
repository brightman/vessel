import CryptoKit
import Foundation

enum DaybookRecapFailure: LocalizedError, Equatable {
    case unavailable, unsupportedLanguage, invalid, generation, storage, changed
    var errorDescription: String? {
        switch self {
        case .unavailable: "Apple 本地模型尚不可用。请检查 Apple Intelligence 设置，或选择其他 AI 模型后重试。"
        case .unsupportedLanguage: "当前 Apple 本地模型不支持所选语言，请更换语言或模型后重试。"
        case .invalid: "AI 未返回有效的回顾及来源，未保存此次结果。请重试。"
        case .generation: "回顾生成未完成，请稍后重试。"
        case .storage: "每日回顾未能读取或保存，请解锁设备并检查存储空间后重试。"
        case .changed: "记录或 AI 设置已更新，请查看最新资料后重试。"
        }
    }
}

/// A complete date manifest, separate from Ask AI's ranked top-k retrieval.
struct DaybookRecapInput: Equatable, Sendable {
    struct Reference: Codable, Equatable, Identifiable, Sendable {
        let id: UUID
        let number: Int?
        let title: String
        let kind: DayRecord.Kind
        let capturedAt: Date
        let digest: String
    }
    struct Source: Equatable, Sendable {
        let number: Int
        let content: String
    }
    let dayKey: String
    let scope: DateInterval
    let references: [Reference]
    let sources: [Source]
    let pendingCount: Int
    let excerptedCount: Int
    let fingerprint: String

    static func homeDay(selected: Date, now: Date, calendar: Calendar = .current) -> Date {
        let day = calendar.startOfDay(for: selected)
        return calendar.isDate(selected, inSameDayAs: now) ? calendar.date(byAdding: .day, value: -1, to: day)! : day
    }
    static func key(_ day: Date, calendar: Calendar = .current) -> String {
        let formatter = DateFormatter(); formatter.calendar = calendar; formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: day)
    }
    static func date(for key: String, calendar: Calendar = .current) -> Date? {
        let parts = key.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3, let date = calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2])),
              Self.key(date, calendar: calendar) == key else { return nil }
        return date
    }
    static func digest<T: Encodable>(_ value: T) -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        encoder.nonConformingFloatEncodingStrategy = .convertToString(positiveInfinity: "+Inf", negativeInfinity: "-Inf", nan: "NaN")
        return SHA256.hash(data: try! encoder.encode(value)).map { String(format: "%02x", $0) }.joined()
    }
    static func factDigest(_ record: DayRecord) -> String {
        struct Fact: Encodable {
            let id: UUID
            let capturedAt: Date
            let kind: DayRecord.Kind
            let text: String
            let provenance: DayRecord.ContentProvenance?
        }
        // Health refreshedAt/updatedAt, generated titles/summaries and unused capture metadata
        // are not new factual evidence. Freshness warnings already live in record.text.
        return digest(Fact(id: record.id, capturedAt: record.capturedAt, kind: record.kind, text: record.text, provenance: record.contentProvenance))
    }
    private static func sourceGroup(_ record: DayRecord) -> UUID {
        record.contentProvenance?.sourceID ?? record.recordingSessionID ?? record.parentRecordID ?? record.id
    }
    private static func evidenceRole(_ kind: DayRecord.Kind) -> String {
        switch kind {
        case .thought: "主动闪念：优先理解用户意图；区分设想、决定和已完成，引用他人不代表本人意图。"
        case .voice: "录音转写：说话人未确认，不默认属于用户；背景音仅作弱辅助线索，录音设备不提高内容权威性。"
        case .activity: "系统活动数据：对应测量范围内的优先事实依据；注意统计范围、缺失与延迟，不推断活动目的。"
        case .sleep: "系统睡眠数据：对应测量范围内的优先事实依据；属于测量或估算，不推断原因或诊断。"
        case .calendar: "日程安排：计划依据，不证明实际参加或完成。"
        case .location: "位置记录或派生变化：仅支持采集点及其变化；不证明完整行程、驾驶身份或停留时长，派生记录不算独立佐证。"
        case .image: "图片文字：只依据提供的文字；不能据此识别人或推断未描述的图片内容。"
        }
    }
    static func prepare(records: [DayRecord], day: Date, allowedKinds: Set<DayRecord.Kind>, calendar: Calendar = .current) -> Self {
        let scope = calendar.dateInterval(of: .day, for: day)!
        let records = DayRecord.evidenceRecords(LegacyAudioDeletionLedger.shared.filter(records), scope: scope).filter { allowedKinds.contains($0.kind) }
            .sorted { $0.capturedAt == $1.capturedAt ? $0.id.uuidString < $1.id.uuidString : $0.capturedAt < $1.capturedAt }
        var references: [Reference] = [], sources: [Source] = [], pending = 0, excerpted = 0
        var groups: [UUID: Int] = [:]
        let time = DateFormatter(); time.calendar = calendar; time.timeZone = calendar.timeZone
        time.locale = Locale(identifier: "en_US_POSIX"); time.dateFormat = "HH:mm"
        for record in records {
            let raw = record.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let ready = !raw.isEmpty || record.kind == .image
            let number = ready ? sources.count + 1 : nil
            references.append(Reference(id: record.id, number: number, title: String(record.title.prefix(100)), kind: record.kind,
                capturedAt: record.capturedAt, digest: factDigest(record)))
            guard let number else { pending += 1; continue }
            let body: String
            if raw.count > 600 {
                let middle = raw.index(raw.startIndex, offsetBy: (raw.count - 200) / 2)
                body = String(raw.prefix(200)) + "\n[…]\n" + String(raw[middle..<raw.index(middle, offsetBy: 200)]) + "\n[…]\n" + String(raw.suffix(200))
                excerpted += 1
            } else { body = raw.isEmpty ? "图片记录没有文字描述；无法判断图片内容。" : raw }
            // Titles, capture coordinates and device metadata are not factual input to the model.
            let groupID = sourceGroup(record)
            if groups[groupID] == nil { groups[groupID] = groups.count + 1 }
            sources.append(Source(number: number, content: "[\(number)] \(time.string(from: record.capturedAt)) · \(record.kind.rawValue) · 同源组 \(groups[groupID]!)\n证据说明：\(evidenceRole(record.kind))\n原文：\n\(body)"))
        }
        let key = key(day, calendar: calendar)
        return Self(dayKey: key, scope: scope, references: references, sources: sources, pendingCount: pending,
            excerptedCount: excerpted, fingerprint: digest([key, String(scope.start.timeIntervalSinceReferenceDate), String(scope.end.timeIntervalSinceReferenceDate)] + references.map(\.digest)))
    }
    var coverage: String {
        "\(dayKey) · \(sources.count) 条资料 · \(pendingCount) 条文字待就绪 · \(excerptedCount) 条长文本摘录"
    }
    var promptContext: String {
        "回顾日期：\(dayKey)。输入元信息（不要写入回顾正文）：已选资料 \(sources.count) 条；文字待就绪 \(pendingCount) 条；长文本摘录 \(excerptedCount) 条。资料不保证完整，同源组不是独立佐证。"
    }
    // Leave context space for authority rules and the final synthesis on the on-device model.
    var batches: [String] { Self.pack(sources.map(\.content), limit: 1800) }
    var preview: String { promptContext + "\n\n" + sources.map(\.content).joined(separator: "\n\n") }
    static func pack(_ pieces: [String], limit: Int) -> [String] {
        var batches: [String] = [], current = ""
        for piece in pieces {
            if !current.isEmpty && current.count + piece.count + 2 > limit { batches.append(current); current = "" }
            current += (current.isEmpty ? "" : "\n\n") + piece
        }
        if !current.isEmpty { batches.append(current) }; return batches
    }
    static func validate(_ text: String, sourceNumbers: Set<Int>) throws {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, text.count <= 1200 else { throw DaybookRecapFailure.invalid }
        let expression = try! NSRegularExpression(pattern: #"\[(\d+)\]"#)
        let matches = expression.matches(in: text, range: NSRange(text.startIndex..., in: text))
        guard !matches.isEmpty, matches.allSatisfy({ match in
            guard let range = Range(match.range(at: 1), in: text), let number = Int(text[range]) else { return false }
            return sourceNumbers.contains(number)
        }) else { throw DaybookRecapFailure.invalid }
    }
}

struct DaybookRecapEntry: Codable, Equatable, Identifiable {
    enum Relationship { case current, additions, invalid }
    let dayKey: String
    var scope: DateInterval
    var references: [DaybookRecapInput.Reference]
    var fingerprint: String
    var text: String?
    var generatedAt: Date?
    var provider = ""
    var language = ""
    var coverage = ""
    var attemptKey: String?
    var message: String?
    var id: String { dayKey }
    init(input: DaybookRecapInput) {
        dayKey = input.dayKey; scope = input.scope; references = input.references; fingerprint = input.fingerprint
    }
    func relationship(to input: DaybookRecapInput) -> Relationship {
        guard scope == input.scope else { return .invalid }
        if fingerprint == input.fingerprint { return .current }
        let current = Dictionary(uniqueKeysWithValues: input.references.map { ($0.id, $0.digest) })
        return references.allSatisfy { current[$0.id] == $0.digest } ? .additions : .invalid
    }
    func matches(_ query: String) -> Bool {
        let date = scope.start.formatted(.dateTime.year().month().day())
        let haystack = "\(dayKey) \(date) \(text ?? "")"
        return query.trimmingCharacters(in: .whitespacesAndNewlines).split(whereSeparator: \.isWhitespace)
            .allSatisfy { haystack.localizedStandardContains(String($0)) }
    }
}
