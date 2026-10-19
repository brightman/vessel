import Foundation

struct HeartRatePoint: Codable, Equatable, Identifiable {
    let id: UUID // HealthKit sample UUID, shared by repeated queries.
    let start: Date
    let end: Date
    let bpm: Double
    let sourceName: String
    let sourceBundle: String
    let productType: String
    let deviceName: String?
    var motionContext: Int? = nil

    var motionLabel: String {
        switch motionContext {
        case 1: "此前至少 5 分钟静止"
        case 2: "采样时活动中"
        default: "活动状态未知"
        }
    }

    func offset(in note: VoiceNote) -> TimeInterval { start.timeIntervalSince(note.capturedAt) }
}

struct HRVPoint: Codable, Equatable, Identifiable {
    let id: UUID
    let start: Date
    let end: Date
    let sdnnMilliseconds: Double
    let sourceName: String
    let sourceBundle: String
    let productType: String
    let deviceName: String?

    var valueLabel: String { String(format: "%.1f ms", sdnnMilliseconds) }

    func overlap(in note: VoiceNote) -> ClosedRange<Double>? {
        let lower = start.timeIntervalSince(note.capturedAt)
        let upper = end.timeIntervalSince(note.capturedAt)
        guard lower.isFinite, upper.isFinite, note.duration.isFinite, note.duration > 0,
              upper >= lower, lower < note.duration, upper >= 0,
              (upper > 0 || lower == upper) else { return nil }
        return max(0, lower)...min(note.duration, upper)
    }

    func crossesBoundary(of note: VoiceNote) -> Bool {
        start < note.capturedAt || end > note.capturedAt.addingTimeInterval(note.duration)
    }

    func windowLabel(in note: VoiceNote) -> String {
        func label(_ date: Date) -> String {
            let offset = date.timeIntervalSince(note.capturedAt)
            if offset < 0 { return "录音前 " + RecordingFormat.duration(-offset) }
            if offset > note.duration { return "结束后 " + RecordingFormat.duration(offset - note.duration) }
            return RecordingFormat.duration(offset)
        }
        return label(start) + "–" + label(end)
    }
}

struct StateOfMindPoint: Codable, Equatable, Identifiable {
    enum Kind: Int, Codable { case momentaryEmotion = 1, dailyMood = 2 }
    let id: UUID
    let date: Date
    let kind: Kind
    let valence: Double
    let classification: Int
    let labels: [Int]
    let associations: [Int]
    let sourceName: String
    let sourceBundle: String
    // Daily reflections are background for these calendar boundaries, never instantaneous evidence.
    var dayStart: Date? = nil
    var dayEnd: Date? = nil
    var timeZoneIdentifier: String? = nil

    var kindLabel: String { kind == .momentaryEmotion ? "当下感受" : "全天心情（背景）" }
    var feelingLabel: String {
        let names = ["很不愉快", "不愉快", "有些不愉快", "中性", "有些愉快", "愉快", "很愉快"]
        return (1...7).contains(classification) ? names[classification - 1] : "未识别的愉悦程度"
    }
    var labelsText: String { labels.isEmpty ? "未选感受标签" : labels.map { Self.labelNames[$0] ?? "未识别标签" }.joined(separator: "、") }
    var associationsText: String { associations.isEmpty ? "未选关联因素" : associations.map { Self.associationNames[$0] ?? "未识别关联因素" }.joined(separator: "、") }
    var backgroundDayLabel: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = timeZoneIdentifier.flatMap(TimeZone.init(identifier:)) ?? .current
        return formatter.string(from: date) + "（" + (timeZoneIdentifier ?? "当前时区") + "）"
    }

    func isRelevant(to note: VoiceNote) -> Bool {
        guard date.timeIntervalSinceReferenceDate.isFinite, valence.isFinite, (-1...1).contains(valence),
              (1...7).contains(classification), note.duration.isFinite, note.duration > 0 else { return false }
        let end = note.capturedAt.addingTimeInterval(note.duration)
        if kind == .momentaryEmotion { return date >= note.capturedAt && date < end }
        guard let dayStart, let dayEnd, dayStart.timeIntervalSinceReferenceDate.isFinite,
              dayEnd.timeIntervalSinceReferenceDate.isFinite, dayEnd > dayStart,
              dayStart <= date, date < dayEnd else { return false }
        return dayStart < end && dayEnd > note.capturedAt
    }

    func timeLabel(in note: VoiceNote) -> String {
        let offset = date.timeIntervalSince(note.capturedAt)
        if offset < 0 { return "录音前 " + RecordingFormat.duration(-offset) }
        if offset >= note.duration { return "结束后 " + RecordingFormat.duration(offset - note.duration) }
        return RecordingFormat.duration(offset)
    }

    // Raw HealthKit enum values are preserved, including future values; presentation is separate.
    private static let labelNames = Dictionary(uniqueKeysWithValues: [
        "惊叹", "觉得有趣", "愤怒", "焦虑", "羞愧", "勇敢", "平静", "满足", "失望", "气馁", "厌恶", "尴尬",
        "兴奋", "受挫", "感激", "内疚", "开心", "绝望", "烦躁", "嫉妒", "喜悦", "孤独", "充满热情", "安宁",
        "自豪", "如释重负", "悲伤", "害怕", "有压力", "惊讶", "担心", "恼怒", "自信", "精疲力竭", "有希望", "无动于衷", "不堪重负", "满意"
    ].enumerated().map { ($0.offset + 1, $0.element) })
    private static let associationNames = Dictionary(uniqueKeysWithValues: [
        "社区", "时事", "约会", "教育", "家庭", "健身", "朋友", "健康", "爱好", "身份认同", "金钱", "伴侣", "自我关怀", "精神信仰", "任务", "旅行", "工作", "天气"
    ].enumerated().map { ($0.offset + 1, $0.element) })
}

struct MeetingAnalysis: Codable, Equatable {
    let text: String
    let model: String
    let generatedAt: Date
    let inputRevision: UUID
    let transcript: String
    let summary: String
}

struct NoteTimeline: Codable, Equatable {
    var schemaVersion = 4
    var revision = UUID()
    var points: [HeartRatePoint] = []
    var segments: [TranscriptSegment] = []
    var segmentTranscript: String?
    var refreshedAt: Date?
    var analysis: MeetingAnalysis?
    var hrvPoints: [HRVPoint] = []
    var hrvRefreshedAt: Date?
    var statesOfMind: [StateOfMindPoint] = []
    var stateOfMindRefreshedAt: Date?
    var words: [TranscriptSegment] = []
    var diarization: SpeakerDiarization?

    init() {}

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, revision, points, segments, segmentTranscript, refreshedAt, analysis, hrvPoints, hrvRefreshedAt
        case statesOfMind, stateOfMindRefreshedAt
        case words, diarization
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let version = try values.decode(Int.self, forKey: .schemaVersion)
        guard (1...4).contains(version) else { throw TimelineError.unsupportedVersion }
        revision = try values.decode(UUID.self, forKey: .revision)
        points = try values.decode([HeartRatePoint].self, forKey: .points)
        segments = try values.decode([TranscriptSegment].self, forKey: .segments)
        segmentTranscript = try values.decodeIfPresent(String.self, forKey: .segmentTranscript)
        refreshedAt = try values.decodeIfPresent(Date.self, forKey: .refreshedAt)
        hrvPoints = try values.decodeIfPresent([HRVPoint].self, forKey: .hrvPoints) ?? []
        hrvRefreshedAt = try values.decodeIfPresent(Date.self, forKey: .hrvRefreshedAt)
        statesOfMind = try values.decodeIfPresent([StateOfMindPoint].self, forKey: .statesOfMind) ?? []
        stateOfMindRefreshedAt = try values.decodeIfPresent(Date.self, forKey: .stateOfMindRefreshedAt)
        words = try values.decodeIfPresent([TranscriptSegment].self, forKey: .words) ?? []
        diarization = try values.decodeIfPresent(SpeakerDiarization.self, forKey: .diarization)
        analysis = try values.decodeIfPresent(MeetingAnalysis.self, forKey: .analysis)
        // Older reports did not consider motion context and subjective records.
        if version < 3 { invalidate() }
    }

    mutating func replacePoints(_ incoming: [HeartRatePoint], for note: VoiceNote) {
        // Replace the entire bounded window so HealthKit deletions and revoked read access disappear, too.
        var unique: [UUID: HeartRatePoint] = [:]
        for point in incoming where point.bpm.isFinite && point.bpm >= 1 && point.bpm <= 1_000
            && point.start >= note.capturedAt && point.end >= point.start
            && point.end <= note.capturedAt.addingTimeInterval(note.duration) {
            unique[point.id] = point
        }
        let replacement = unique.values.sorted {
            $0.start == $1.start ? $0.id.uuidString < $1.id.uuidString : $0.start < $1.start
        }
        if replacement != points { points = replacement; invalidate() }
        refreshedAt = .now
    }

    mutating func invalidate() { revision = UUID(); analysis = nil }

    mutating func replaceHRVPoints(_ incoming: [HRVPoint], for note: VoiceNote) {
        var unique: [UUID: HRVPoint] = [:]
        for point in incoming where point.sdnnMilliseconds.isFinite && point.sdnnMilliseconds >= 0
            && point.sdnnMilliseconds <= 10_000 && point.overlap(in: note) != nil {
            unique[point.id] = point
        }
        let replacement = unique.values.sorted {
            $0.start == $1.start ? $0.id.uuidString < $1.id.uuidString : $0.start < $1.start
        }
        if replacement != hrvPoints { hrvPoints = replacement; invalidate() }
        hrvRefreshedAt = .now
    }

    mutating func replaceStatesOfMind(_ incoming: [StateOfMindPoint], for note: VoiceNote) {
        var unique: [UUID: StateOfMindPoint] = [:]
        for point in incoming where point.isRelevant(to: note) { unique[point.id] = point }
        let replacement = unique.values.sorted { $0.date == $1.date ? $0.id.uuidString < $1.id.uuidString : $0.date < $1.date }
        if replacement != statesOfMind { statesOfMind = replacement; invalidate() }
        stateOfMindRefreshedAt = .now
    }

    var motionStatistics: String {
        let still = points.filter { $0.motionContext == 1 }.count
        let active = points.filter { $0.motionContext == 2 }.count
        return "心率样本运动上下文：\(active) 个采样时活动中，\(still) 个此前至少5分钟静止，\(points.count - still - active) 个未知。只描述各采样点，不代表整个区间，也不能识别说话或聆听。"
    }

    func alignedSegments(for note: VoiceNote) -> [TranscriptSegment] {
        guard segmentTranscript == note.transcript else { return [] }
        return segments.filter { $0.start.isFinite && $0.end.isFinite && $0.start >= 0 && $0.end > $0.start && $0.end <= note.duration + 1 }
    }

    func currentAnalysis(for note: VoiceNote) -> MeetingAnalysis? {
        guard let analysis, analysis.inputRevision == revision,
              analysis.transcript == note.transcript, analysis.summary == note.summary else { return nil }
        return analysis
    }
}

struct StateOfMindEvidence: Identifiable {
    let id: String
    let point: StateOfMindPoint
    let excerpts: [TranscriptSegment]

    func material(in note: VoiceNote) -> String {
        let scope = point.kind == .momentaryEmotion ? "录音 \(point.timeLabel(in: note)) 的当下感受" : "录音所在日的全天心情，仅作背景，不能定位具体话语；记录时间 \(point.timeLabel(in: note))"
        return "\(id)：本人心境记录，\(scope)。愉悦程度：\(point.feelingLabel)（本人记录值 \(String(format: "%.2f", point.valence))，范围-1至1，非AI评分）；感受标签：\(point.labelsText)；本人选择的关联因素：\(point.associationsText)。关联因素不证明会议因果。"
    }

    static func statistics(in timeline: NoteTimeline) -> String {
        let momentary = timeline.statesOfMind.filter { $0.kind == .momentaryEmotion }.count
        return "本人心境记录：\(momentary) 条录音期间的当下感受、\(timeline.statesOfMind.count - momentary) 条同日全天心情背景。空结果可能为未记录、未授权或未同步，不能推断本人没有感受。"
    }

    static func records(in timeline: NoteTimeline, note: VoiceNote) -> [Self] {
        func selected(_ kind: StateOfMindPoint.Kind, limit: Int) -> [StateOfMindPoint] {
            let points = timeline.statesOfMind.filter { $0.kind == kind && $0.isRelevant(to: note) }
            guard points.count > limit else { return points }
            return (0..<limit).map { points[Int((Double(points.count - 1) * Double($0) / Double(limit - 1)).rounded())] }
        }
        let points = (selected(.momentaryEmotion, limit: 6) + selected(.dailyMood, limit: 2)).sorted { $0.date < $1.date }
        return points.enumerated().map { index, point in
            let offset = point.date.timeIntervalSince(note.capturedAt)
            let excerpts = point.kind == .momentaryEmotion ? timeline.alignedSegments(for: note).filter { $0.start <= offset && $0.end >= offset } : []
            return Self(id: "M\(index + 1)", point: point, excerpts: excerpts)
        }
    }
}

struct HRVEvidence: Identifiable, Equatable {
    let id: String
    let point: HRVPoint
    let range: ClosedRange<Double>
    let excerpts: [TranscriptSegment]

    func material(in note: VoiceNote) -> String {
        let boundary = point.crossesBoundary(of: note) ? "跨录音边界，包含会议外采样，不能全部归因于会议。" : "测量窗口在录音范围内。"
        let duration = point.end.timeIntervalSince(point.start)
        return "\(id)：HRV SDNN \(point.valueLabel)，原始测量窗口 \(point.windowLabel(in: note))，窗口时长 \(Int(duration)) 秒。\(boundary)"
            + (duration == 0 ? "未提供实际窗口时长，不能推断瞬时变化。" : "")
    }

    static func statistics(in timeline: NoteTimeline, note: VoiceNote) -> String {
        let values = timeline.hrvPoints.map(\.sdnnMilliseconds)
        guard let minimum = values.min(), let maximum = values.max() else {
            return "暂无可用 HRV SDNN 样本，不能推断本次会议的 HRV 变化；未授权、未测量与未同步无法仅凭空结果区分。"
        }
        let boundaryCount = timeline.hrvPoints.filter { $0.crossesBoundary(of: note) }.count
        let sourceCount = Set(timeline.hrvPoints.map { [$0.sourceBundle, $0.productType, $0.deviceName ?? ""].joined(separator: "\u{1F}") }).count
        return "HRV SDNN 共 \(values.count) 个测量窗口，样本值范围 \(String(format: "%.1f", minimum))–\(String(format: "%.1f", maximum)) ms；其中 \(boundaryCount) 个跨录音边界，\(sourceCount) 个来源。数值属于各自完整窗口，非逐秒曲线；不同来源不可直接比较，没有个人基线，不能评价情绪或健康好坏。"
    }

    static func windows(in timeline: NoteTimeline, note: VoiceNote) -> [Self] {
        let points = timeline.hrvPoints.filter { $0.overlap(in: note) != nil }
        let selected: [HRVPoint]
        if points.count <= 6 { selected = points }
        else { selected = (0..<6).map { points[Int((Double(points.count - 1) * Double($0) / 5).rounded())] } }
        return selected.enumerated().compactMap { index, point in
            guard let range = point.overlap(in: note) else { return nil }
            let excerpts = timeline.alignedSegments(for: note).filter { $0.end >= range.lowerBound && $0.start <= range.upperBound }
            return Self(id: "V\(index + 1)", point: point, range: range, excerpts: excerpts)
        }
    }
}

struct HeartRateEvidence: Identifiable, Equatable {
    let id: String
    let from: HeartRatePoint
    let to: HeartRatePoint
    let excerpts: [TranscriptSegment]
    var delta: Double { to.bpm - from.bpm }

    static func changes(in timeline: NoteTimeline, note: VoiceNote) -> [Self] {
        guard timeline.points.count > 1 else { return [] }
        let pairs = zip(timeline.points, timeline.points.dropFirst()).filter {
            let gap = $1.start.timeIntervalSince($0.start)
            // Never compare two different physical watches or bridge more than ten minutes.
            return gap > 0 && gap <= 600 && abs($1.bpm - $0.bpm) >= 10
                && $0.sourceBundle == $1.sourceBundle && $0.productType == $1.productType
                && $0.deviceName == $1.deviceName
        }.sorted { abs($0.1.bpm - $0.0.bpm) > abs($1.1.bpm - $1.0.bpm) }
        return pairs.prefix(8).sorted { $0.1.start < $1.1.start }.enumerated().map { index, pair in
            let lower = pair.0.offset(in: note)
            let upper = pair.1.offset(in: note)
            let excerpts = timeline.alignedSegments(for: note).filter { $0.end >= lower && $0.start <= upper }
            return Self(id: "E\(index + 1)", from: pair.0, to: pair.1, excerpts: excerpts)
        }
    }
}

final class NoteTimelineStore {
    private let directory: URL

    init(root: URL) throws {
        directory = root.appendingPathComponent("Timelines", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var url = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try url.setResourceValues(values)
    }

    func load(_ id: UUID) throws -> NoteTimeline {
        let path = url(id)
        guard FileManager.default.fileExists(atPath: path.path) else { return NoteTimeline() }
        let timeline = try JSONDecoder().decode(NoteTimeline.self, from: Data(contentsOf: path))
        guard timeline.schemaVersion == 4 else { throw TimelineError.unsupportedVersion }
        return timeline
    }

    func save(_ value: NoteTimeline, id: UUID) throws {
        let data = try JSONEncoder().encode(value)
        #if os(iOS)
        try data.write(to: url(id), options: [.atomic, .completeFileProtection])
        #else
        try data.write(to: url(id), options: .atomic)
        #endif
    }

    func delete(_ id: UUID) throws {
        if FileManager.default.fileExists(atPath: url(id).path) { try FileManager.default.removeItem(at: url(id)) }
    }
    private func url(_ id: UUID) -> URL { directory.appendingPathComponent("\(id.uuidString).json") }
}

enum TimelineError: LocalizedError {
    case unsupportedVersion
    case unavailable
    case tooManySamples
    var errorDescription: String? {
        switch self {
        case .unsupportedVersion: "时间轴版本不受支持，请更新 App"
        case .unavailable: "这台设备暂不能读取健康数据"
        case .tooManySamples: "该录音的健康采样数据过多，暂未更新，已有数据已保留"
        }
    }
}
