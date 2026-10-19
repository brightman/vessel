import Foundation

/// Deliberately lexical: a bounded, dated projection of allowed text, never a semantic-memory claim.
struct DaybookRetrieval {
    struct Limits {
        var maxSources = 5
        var maxSnippetCharacters = 200
        var maxContextCharacters = 1_400
    }

    enum Failure: LocalizedError {
        case emptyQuestion, questionTooLong, invalidDate, ambiguousDate
        var errorDescription: String? {
            switch self {
            case .emptyQuestion: "请输入一个问题。"
            case .questionTooLong: "请把问题缩短到 300 字以内。"
            case .invalidDate: "日期无效，请使用 YYYY-MM-DD 或在日记中选择日期。"
            case .ambiguousDate: "目前一次查询一天，请只指定一个日期。"
            }
        }
    }

    struct Statistics: Equatable, Sendable {
        let totalCount: Int
        let voiceCount: Int
        let thoughtCount: Int
        let imageCount: Int
        let audioDuration: TimeInterval

        var description: String {
            let seconds = Int(min(audioDuration, Double(Int.max / 2)).rounded(.down))
            return "共 \(totalCount) 条记录：录音 \(voiceCount) 条、闪念 \(thoughtCount) 条、图片记录 \(imageCount) 条；录音与闪念总时长 \(seconds / 60) 分 \(seconds % 60) 秒。"
        }
    }

    struct Source: Identifiable, Equatable, Sendable {
        let id: UUID
        let number: Int
        let title: String
        let capturedAt: Date
        let kind: DayRecord.Kind
        let snippet: String
        let truncated: Bool
    }

    struct Prepared: Sendable {
        let question: String
        let dayStart: Date
        let dayEnd: Date
        let dateLabel: String
        let statistics: Statistics
        let matchedCount: Int
        let sources: [Source]
        let context: String
        let directResponse: String?
        let scopeDescription: String
        private let snapshots: [DayRecord]
        private let allowedKinds: Set<DayRecord.Kind>

        fileprivate init(question: String, dayStart: Date, dayEnd: Date, dateLabel: String, statistics: Statistics,
                         matchedCount: Int, sources: [Source], context: String, directResponse: String?,
                         scopeDescription: String, snapshots: [DayRecord], allowedKinds: Set<DayRecord.Kind>) {
            self.question = question; self.dayStart = dayStart; self.dayEnd = dayEnd; self.dateLabel = dateLabel
            self.statistics = statistics; self.matchedCount = matchedCount; self.sources = sources
            self.context = context; self.directResponse = directResponse; self.scopeDescription = scopeDescription
            self.snapshots = snapshots; self.allowedKinds = allowedKinds
        }

        /// Includes every allowed record on the day: edits outside top-k can also invalidate aggregate facts.
        func isCurrent(records: [DayRecord], allowedKinds: Set<DayRecord.Kind>) -> Bool {
            guard allowedKinds == self.allowedKinds else { return false }
            return DaybookRetrieval.scoped(records, from: dayStart, to: dayEnd, allowedKinds: allowedKinds) == snapshots
        }
    }

    var calendar: Calendar = .current
    var limits = Limits()

    func prepare(question: String, records: [DayRecord], selectedDate: Date, now: Date = .now,
                 allowedKinds: Set<DayRecord.Kind> = [.voice, .thought, .image]) throws -> Prepared {
        let question = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty else { throw Failure.emptyQuestion }
        guard question.count <= 300 else { throw Failure.questionTooLong }
        let resolved = try resolveDate(question, selectedDate: selectedDate, now: now)
        let start = calendar.startOfDay(for: resolved.date)
        let end = calendar.date(byAdding: .day, value: 1, to: start)!
        let day = Self.scoped(records, from: start, to: end, allowedKinds: allowedKinds)
        let stats = Statistics(totalCount: day.count, voiceCount: day.filter { $0.kind == .voice }.count,
                               thoughtCount: day.filter { $0.kind == .thought }.count,
                               imageCount: day.filter { $0.kind == .image }.count,
                               audioDuration: day.reduce(0) { sum, record in
                                   let duration = record.kind != .image && record.duration.isFinite ? max(0, record.duration) : 0
                                   return min(Double(Int.max / 2), sum + duration)
                               })
        let dateLabel = format(start, pattern: "yyyy-MM-dd")
        let terms = keywords(resolved.remaining)
        let requestedKind: DayRecord.Kind? = {
            if ["照片", "图片", "相片"].contains(where: question.contains) { return .image }
            if question.contains("闪念") { return .thought }
            if question.contains("录音") { return .voice }
            return nil
        }()
        let ranked = day.compactMap { record -> (DayRecord, Int)? in
            if let requestedKind, record.kind != requestedKind { return nil }
            let title = record.title.lowercased()
            let body = record.text.lowercased()
            let score = terms.reduce(0) { sum, term in
                sum + (title.contains(term) ? 4 * term.count : 0) + (body.contains(term) ? term.count : 0)
            }
            return terms.isEmpty || score > 0 ? (record, score) : nil
        }.sorted {
            if $0.1 != $1.1 { return $0.1 > $1.1 }
            if $0.0.capturedAt != $1.0.capturedAt { return $0.0.capturedAt < $1.0.capturedAt }
            return $0.0.id.uuidString < $1.0.id.uuidString
        }
        let maxContext = max(0, limits.maxContextCharacters)
        var context = String("日期：\(dateLabel)（设备时区）。以下统计由程序对当天全部允许读取的记录计算，不能用摘录数量替代：\n\(stats.description)\n关键词匹配 \(ranked.count) 条。以下仅为有限原文摘录，不保证覆盖当天所有细节。\n".prefix(maxContext))
        var sources: [Source] = []
        if !resolved.unsupportedRange {
            for (record, _) in ranked.prefix(max(0, limits.maxSources)) {
                let number = sources.count + 1
                let title = String(record.title.prefix(48))
                let header = "\n[\(number)] ID=\(record.id.uuidString) \(format(record.capturedAt, pattern: "HH:mm")) \(Self.kindLabel(record.kind)) · \(title)\n"
                let available = maxContext - context.count - header.count - 1
                guard available >= 12 else { break }
                let original = record.text.trimmingCharacters(in: .whitespacesAndNewlines)
                let text = original.isEmpty ? "（此记录尚无原文；标题不能证明更多细节）" : original
                let excerpt = snippet(text, terms: terms, limit: min(max(0, limits.maxSnippetCharacters), available))
                guard !excerpt.isEmpty else { break }
                context += header + excerpt + "\n"
                sources.append(Source(id: record.id, number: number, title: title, capturedAt: record.capturedAt,
                                      kind: record.kind, snippet: excerpt, truncated: excerpt != text))
            }
        }
        let scope = "\(dateLabel) · 按日期与关键词检索；当天允许读取 \(day.count) 条，匹配 \(ranked.count) 条，提供 \(sources.count) 条摘录。"
        let direct: String?
        if resolved.unsupportedRange {
            context = ""
            direct = "目前一次查询一天。请在日记中选一天，或在问题中写明 YYYY-MM-DD，再询问当天的记录。"
        } else if day.isEmpty {
            direct = "\(dateLabel) 没有允许读取的记录。可以先保存录音或图片，或在设置中允许读取相应来源。"
        } else if Self.isAggregateQuestion(question) {
            let photoNote = requestedKind == .image || ["多少张", "几张"].contains(where: question.contains)
                ? "\n这里计算的是图片记录条数；一条可含多张照片，不表示照片张数。" : ""
            direct = "\(dateLabel) 的全天统计：\n\(stats.description)" + (terms.isEmpty && requestedKind == nil ? "" : "\n其中符合本次类型与关键词筛选的记录有 \(ranked.count) 条。") + photoNote
        } else if sources.isEmpty {
            direct = "在 \(dateLabel) 允许读取的 \(day.count) 条记录中，没有找到可用于回答的文字摘录。目前按日期和关键词检索，可换一个更具体的关键词。"
        } else if !sources.contains(where: { source in
            day.contains { $0.id == source.id && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        }) {
            direct = "找到的记录尚无可用于问答的转写或图片文字。请先打开原记录完成转写，或添加图片描述，再重新提问。"
        } else {
            direct = nil
        }
        return Prepared(question: question, dayStart: start, dayEnd: end, dateLabel: dateLabel,
                        statistics: stats, matchedCount: ranked.count, sources: sources, context: context,
                        directResponse: direct, scopeDescription: scope, snapshots: day, allowedKinds: allowedKinds)
    }

    static func kindLabel(_ kind: DayRecord.Kind) -> String {
        switch kind { case .voice: "录音"; case .thought: "闪念"; case .image: "图片记录" }
    }

    private static func scoped(_ records: [DayRecord], from start: Date, to end: Date,
                               allowedKinds: Set<DayRecord.Kind>) -> [DayRecord] {
        records.filter { $0.capturedAt >= start && $0.capturedAt < end && allowedKinds.contains($0.kind) }
            .sorted { $0.id.uuidString < $1.id.uuidString }
    }

    private static func isAggregateQuestion(_ question: String) -> Bool {
        let namesRecordKind = ["记录", "录音", "闪念", "照片", "图片", "相片"].contains(where: question.contains)
        let asksCount = ["多少条", "几条", "多少张", "几张", "数量"].contains(where: question.contains)
        return (namesRecordKind && asksCount) || ["总时长", "录音多久", "录音多长时间", "录了多久", "录了几分钟"].contains(where: question.contains)
    }

    private func format(_ date: Date, pattern: String) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar; formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.dateFormat = pattern
        return formatter.string(from: date)
    }

    private func resolveDate(_ question: String, selectedDate: Date, now: Date) throws -> (date: Date, remaining: String, unsupportedRange: Bool) {
        let unsupported = ["最近一周", "过去一周", "最近七天", "最近7天", "本周", "上周", "这周", "本月", "上个月", "所有日期", "全部记录", "最近几天", "这几天", "最近一个月"]
            .contains(where: question.contains)
        var remaining = question
        var dates: [Date] = []
        let expression = try NSRegularExpression(pattern: #"(?:(\d{4})[-/年])?(\d{1,2})[-/月](\d{1,2})日?"#)
        let matches = expression.matches(in: question, range: NSRange(question.startIndex..., in: question))
        for match in matches.reversed() {
            func component(_ index: Int) -> Int? {
                Range(match.range(at: index), in: question).flatMap { Int(question[$0]) }
            }
            let year = component(1) ?? calendar.component(.year, from: now)
            guard let month = component(2), let day = component(3),
                  let date = calendar.date(from: DateComponents(year: year, month: month, day: day)),
                  calendar.component(.year, from: date) == year,
                  calendar.component(.month, from: date) == month,
                  calendar.component(.day, from: date) == day else { throw Failure.invalidDate }
            dates.append(date)
            if let range = Range(match.range, in: remaining) { remaining.replaceSubrange(range, with: " ") }
        }
        for (word, offset) in [("今天", 0), ("今日", 0), ("昨天", -1), ("昨日", -1), ("前天", -2), ("明天", 1)] {
            if remaining.contains(word) {
                dates.append(calendar.date(byAdding: .day, value: offset, to: calendar.startOfDay(for: now))!)
                remaining = remaining.replacingOccurrences(of: word, with: " ")
            }
        }
        let unique = Set(dates.map { calendar.startOfDay(for: $0) })
        guard unique.count <= 1 else { throw Failure.ambiguousDate }
        return (unique.first ?? selectedDate, remaining, unsupported)
    }

    private func keywords(_ question: String) -> [String] {
        var query = question.lowercased()
        // Remove question scaffolding before CJK n-grams, keeping the actual topic.
        let fillers = ["最值得跟进什么", "有哪些要点", "有哪些待办", "有什么待办", "有什么记录", "有哪些记录", "有多少条记录", "有多少记录", "说了什么", "记录了什么", "发生了什么", "回顾这一天", "总结这一天", "多长时间", "总时长", "几分钟", "这一天", "这一天的", "选中的日期", "所选日期", "请帮我", "帮我", "请问", "总结", "回顾", "概括", "要点", "待办", "行动项", "记录", "录音", "闪念", "图片", "照片", "相片", "拍了", "多少", "几条", "几张", "数量", "多久", "有哪些", "有什么", "是什么", "怎么样", "如何", "什么", "有关", "关于", "的", "了", "呢", "吗", "请"]
        for filler in fillers { query = query.replacingOccurrences(of: filler, with: " ") }
        let expression = try! NSRegularExpression(pattern: #"[\p{Han}]+|[a-z0-9]+"#)
        var result = Set<String>()
        for match in expression.matches(in: query, range: NSRange(query.startIndex..., in: query)) {
            guard let range = Range(match.range, in: query) else { continue }
            let word = String(query[range])
            guard !["有", "条", "共", "我", "是", "中", "在", "和", "与", "个"].contains(word) else { continue }
            let characters = Array(word)
            if word.unicodeScalars.first.map({ (0x3400...0x9FFF).contains(Int($0.value)) }) == true {
                if characters.count == 1 { result.insert(word) }
                for width in [2, 3] where characters.count >= width {
                    for index in 0...(characters.count - width) { result.insert(String(characters[index..<(index + width)])) }
                }
                result.insert(word)
            } else if !["the", "a", "of", "what", "today", "summary", "summarize"].contains(word) {
                result.insert(word)
            }
        }
        return result.sorted { $0.count == $1.count ? $0 < $1 : $0.count > $1.count }
    }

    private func snippet(_ text: String, terms: [String], limit: Int) -> String {
        guard limit > 0 else { return "" }
        guard text.count > limit else { return text }
        let match = terms.lazy.compactMap { text.range(of: $0, options: .caseInsensitive) }.first
        let matchOffset = match.map { text.distance(from: text.startIndex, to: $0.lowerBound) } ?? 0
        let startOffset = max(0, matchOffset - limit / 3)
        let start = text.index(text.startIndex, offsetBy: startOffset)
        let budget = max(0, limit - 2)
        let end = text.index(start, offsetBy: budget, limitedBy: text.endIndex) ?? text.endIndex
        return (start == text.startIndex ? "" : "…") + String(text[start..<end]) + (end == text.endIndex ? "" : "…")
    }
}
