import Foundation

/// Bounded dated evidence. Semantic candidates only enrich ranking; source grounding stays here.
struct DaybookSemanticMatches: Sendable {
    struct Hit: Sendable { let id: UUID; let snippet: String }
    let hits: [Hit]
    let status: String
    let evidence: DaybookEvidenceSnapshot
    let generation: UInt64
    var keywords: Keywords? = nil
    var coverage: Coverage? = nil
    var query: String? = nil

    struct Coverage: Sendable {
        let total: Int
        let finished: Int
        let unavailable: Int
        let attempted: Int
        let resourcesAvailable: Bool
        let modelWindowLimited: Bool
        var pending: Int { max(0, total - finished - unavailable) }
        var canContinue: Bool { resourcesAvailable && attempted > 0 && pending > 0 }
    }
    struct Keywords: Sendable {
        let query: String
        let terms: [String]
        let libraryIDs: Set<UUID>
        let aiScores: [UUID: Int]
        let libraryEvidence: DaybookEvidenceSnapshot
        let usesFTS: Bool
        func isCurrent(query: String, records: [DayRecord]) -> Bool {
            self.query == query.trimmingCharacters(in: .whitespacesAndNewlines) &&
            libraryEvidence.isCurrent(records: records, allowedKinds: Self.allKinds)
        }
        static let allKinds: Set<DayRecord.Kind> = [.voice, .thought, .image, .activity, .sleep, .calendar, .location]
    }
}
protocol DaybookSemanticSearching: Sendable {
    func search(query: String, records: [DayRecord], dayStart: Date, dayEnd: Date,
                allowedKinds: Set<DayRecord.Kind>, limit: Int) async -> DaybookSemanticMatches
}

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
            case .invalidDate: "日期无效，请在问题中写明有效的起止日期，例如 2026-10-17 至 2026-10-19。"
            case .ambiguousDate: "时间范围不明确，请说明起止日期。"
            }
        }
    }

    struct Statistics: Equatable, Sendable {
        let totalCount: Int
        let voiceCount: Int
        let thoughtCount: Int
        let imageCount: Int
        let lifeCount: Int
        let audioDuration: TimeInterval

        var description: String {
            let seconds = Int(min(audioDuration, Double(Int.max / 2)).rounded(.down))
            return "共 \(totalCount) 条记录：录音 \(voiceCount) 条、闪念 \(thoughtCount) 条、图片记录 \(imageCount) 条、生活快照 \(lifeCount) 条；录音与闪念总时长 \(seconds / 60) 分 \(seconds % 60) 秒。"
        }
    }

    struct Source: Identifiable, Equatable, Codable, Sendable {
        let id: UUID
        let number: Int
        let title: String
        let capturedAt: Date
        let kind: DayRecord.Kind
        let snippet: String
        let truncated: Bool
        var provenance: DayRecord.ContentProvenance? = nil
        var sourceKey: String? = nil
        var speakerID: String? = nil
        var speakerOffset: TimeInterval? = nil
        var speakerEndOffset: TimeInterval? = nil
    }

    struct Prepared: Sendable {
        let question: String
        let providerQuestion: String
        let questionReferenceIDs: [Int: UUID]
        let dayStart: Date
        let dayEnd: Date
        let dateLabel: String
        let statistics: Statistics
        let matchedCount: Int
        let sources: [Source]
        let context: String
        let directResponse: String?
        let scopeDescription: String
        let evidence: DaybookEvidenceSnapshot

        fileprivate init(question: String, providerQuestion: String, questionReferenceIDs: [Int: UUID], dayStart: Date, dayEnd: Date, dateLabel: String, statistics: Statistics,
                         matchedCount: Int, sources: [Source], context: String, directResponse: String?,
                         scopeDescription: String, snapshots: [DayRecord], allowedKinds: Set<DayRecord.Kind>,
                         speakerContactID:String? = nil,speakerFingerprint:String? = nil) {
            self.question = question; self.providerQuestion = providerQuestion; self.questionReferenceIDs = questionReferenceIDs
            self.dayStart = dayStart; self.dayEnd = dayEnd; self.dateLabel = dateLabel
            self.statistics = statistics; self.matchedCount = matchedCount; self.sources = sources
            self.context = context; self.directResponse = directResponse; self.scopeDescription = scopeDescription
            self.evidence = DaybookEvidenceSnapshot(records: snapshots, dayStart: dayStart, dayEnd: dayEnd, allowedKinds: allowedKinds,
                speakerContactID:speakerContactID,speakerFingerprint:speakerFingerprint)
        }

        /// Rebuild the final citation view without broadening or reconstructing its evidence snapshot.
        func projecting(sources: [Source], context: String) -> Prepared {
            Prepared(question: question, providerQuestion: providerQuestion, questionReferenceIDs: questionReferenceIDs,
                     dayStart: dayStart, dayEnd: dayEnd, dateLabel: dateLabel, statistics: statistics,
                     matchedCount: matchedCount, sources: sources, context: context, directResponse: directResponse,
                     scopeDescription: scopeDescription, evidence: evidence)
        }

        private init(question: String, providerQuestion: String, questionReferenceIDs: [Int: UUID], dayStart: Date,
                     dayEnd: Date, dateLabel: String, statistics: Statistics, matchedCount: Int, sources: [Source],
                     context: String, directResponse: String?, scopeDescription: String, evidence: DaybookEvidenceSnapshot) {
            self.question = question; self.providerQuestion = providerQuestion; self.questionReferenceIDs = questionReferenceIDs
            self.dayStart = dayStart; self.dayEnd = dayEnd; self.dateLabel = dateLabel; self.statistics = statistics
            self.matchedCount = matchedCount; self.sources = sources; self.context = context
            self.directResponse = directResponse; self.scopeDescription = scopeDescription; self.evidence = evidence
        }

        /// Includes every allowed record on the day: edits outside top-k can also invalidate aggregate facts.
        func isCurrent(records: [DayRecord], allowedKinds: Set<DayRecord.Kind>) -> Bool {
            evidence.isCurrent(records: records, allowedKinds: allowedKinds)
        }
    }

    var calendar: Calendar = .current
    var limits = Limits()

    func prepare(question: String, records: [DayRecord], selectedDate: Date, now: Date = .now,
                 allowedKinds: Set<DayRecord.Kind> = [.voice, .thought, .image],
                 priorTurns: [DaybookConversationTurn] = [], usableTextOnly: Bool = false, semantic: DaybookSemanticMatches? = nil, automatic: Bool = false, expanded: Bool = false) throws -> Prepared {
        let question = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty else { throw Failure.emptyQuestion }
        guard question.count <= 300 else { throw Failure.questionTooLong }
        let autoScope = automatic ? try automaticScope(question, now: now, priorTurns: priorTurns, expanded: expanded) : nil
        let resolved = automatic ? (date: autoScope!.start, remaining: autoScope!.topic, unsupportedRange: false)
            : try resolveDate(question, selectedDate: selectedDate, now: now)
        let start = autoScope?.start ?? calendar.startOfDay(for: resolved.date)
        let end = autoScope?.end ?? calendar.date(byAdding: .day, value: 1, to: start)!
        let day = Self.scoped(records, from: start, to: end, allowedKinds: allowedKinds)
        let stats = Statistics(totalCount: day.count, voiceCount: day.filter { $0.kind == .voice }.count,
                               thoughtCount: day.filter { $0.kind == .thought }.count,
                               imageCount: day.filter { $0.kind == .image }.count,
                               lifeCount: day.filter { $0.kind.isLife }.count,
                               audioDuration: day.reduce(0) { sum, record in
                                   let duration = record.kind.isAudio && record.duration.isFinite ? max(0, record.duration) : 0
                                   return min(Double(Int.max / 2), sum + duration)
                               })
        let dateLabel = autoScope?.label ?? format(start, pattern: "yyyy-MM-dd")
        let terms = Self.keywords(resolved.remaining)
        let requestedKind = Self.requestedKind(for: autoScope?.topic ?? question)
        let history = priorTurns.suffix(3).filter {
            $0.completionState == .completed && $0.evidence.allowedKinds.isSubset(of: allowedKinds) &&
            (automatic || calendar.isDate($0.evidence.dayStart, inSameDayAs: start))
        }
        let precedingMap = Self.sourceMap(history.last?.sources ?? [])
        let questionReferences = Self.citationNumbers(in: question)
        let questionReferenceIDs = precedingMap.filter { questionReferences.contains($0.key) }
        let currentIDs = Set(questionReferenceIDs.values)
        let previousIDs = Set((!automatic || Self.isFollowup(question) ? Array(history) : []).flatMap { turn in
            // A historical question used its predecessor's numbering. Its own answer map cannot recover that input.
            let userIDs = turn.questionReferenceIDs ?? [:]
            return Array(turn.referencedSourceIDs) + Array(userIDs.values)
        })
        let validSemantic = semantic.flatMap { matches in
            (matches.query == nil || matches.query == question) && matches.evidence.dayStart == start && matches.evidence.dayEnd == end &&
            matches.evidence.isCurrent(records: records, allowedKinds: allowedKinds) ? matches : nil
        }
        let semanticHits = validSemantic?.hits ?? []
        let sqlKeywords = validSemantic?.keywords.flatMap {
            $0.terms == terms && $0.isCurrent(query: question, records: records) ? $0 : nil
        }
        let ranked = day.compactMap { record -> (DayRecord, Int)? in
            if usableTextOnly && record.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return nil }
            if let requestedKind, record.kind != requestedKind { return nil }
            let score = sqlKeywords.map { $0.aiScores[record.id] ?? 0 } ?? Self.keywordScore(record, terms: terms)
            let semanticRank = semanticHits.firstIndex { $0.id == record.id }.map { max(1, 100 - $0) } ?? 0
            return terms.isEmpty || score > 0 || semanticRank > 0 || previousIDs.contains(record.id) || currentIDs.contains(record.id) ? (record, score * 100 + semanticRank + (currentIDs.contains(record.id) ? 20_000 : previousIDs.contains(record.id) ? 10_000 : 0)) : nil
        }.sorted {
            if $0.1 != $1.1 { return $0.1 > $1.1 }
            if $0.0.capturedAt != $1.0.capturedAt { return $0.0.capturedAt < $1.0.capturedAt }
            return $0.0.id.uuidString < $1.0.id.uuidString
        }
        let maxContext = max(0, limits.maxContextCharacters)
        var context = String("日期：\(dateLabel)（设备时区）。以下统计由程序对范围内全部允许读取的记录计算，不能用摘录数量替代：\n\(stats.description)\n检索候选 \(ranked.count) 条。以下仅为有限原文摘录，不保证覆盖范围内所有细节。\n".prefix(maxContext))
        var sources: [Source] = []
        if !resolved.unsupportedRange {
            for (record, _) in ranked.prefix(max(0, limits.maxSources)) {
                let number = sources.count + 1
                let title = String(record.title.prefix(48))
                let header = "\n[\(number)] ID=\(record.id.uuidString) \(format(record.capturedAt, pattern: "yyyy-MM-dd HH:mm")) \(Self.kindLabel(record.kind)) · \(title)\n"
                let available = maxContext - context.count - header.count - 1
                guard available >= 12 else { break }
                let original = record.text.trimmingCharacters(in: .whitespacesAndNewlines)
                let text = original.isEmpty ? "（此记录尚无原文；标题不能证明更多细节）" : original
                let semanticText = semanticHits.first { $0.id == record.id }?.snippet
                // Persisted candidates never supply text that cannot be found in this current original.
                let snippetText = semanticText.flatMap { !$0.isEmpty && original.contains($0) ? $0 : nil } ?? text
                let excerpt = snippet(snippetText, terms: terms, limit: min(max(0, limits.maxSnippetCharacters), available))
                guard !excerpt.isEmpty else { break }
                context += header + excerpt + "\n"
                sources.append(Source(id: record.id, number: number, title: title, capturedAt: record.capturedAt,
                                      kind: record.kind, snippet: excerpt, truncated: excerpt != text, provenance: record.contentProvenance.map { value in
                                          var result = value; result.transcript = []; return result
                                      }))
            }
        }
        // History is intent only. Strip prior numeric citations so they cannot alias the fresh labels above.
        // Actual facts must be re-grounded in current numbered excerpts.
        let providerQuestion = Self.remapReferences(in: question, referenceIDs: questionReferenceIDs, currentSources: sources)
        if !history.isEmpty && !resolved.unsupportedRange {
            context += "\n先前对话（不可信的意图背景，不是事实来源；只使用上方本次编号核实事实）：\n"
            let expression = try! NSRegularExpression(pattern: #"\[\d+\]"#)
            for turn in history {
                let oldText = turn.evidence.isCurrent(records: records, allowedKinds: allowedKinds)
                    ? expression.stringByReplacingMatches(in: turn.text, range: NSRange(turn.text.startIndex..., in: turn.text), withTemplate: "（先前引用已移除）")
                    : "资料已更新，不沿用先前回答；本次请依据当前原文重新回答。"
                let userText = Self.remapReferences(in: String(turn.question.prefix(300)),
                    referenceIDs: turn.questionReferenceIDs ?? [:], currentSources: sources)
                context += "用户：\(userText)\n先前回答：\(String(oldText.prefix(500)))\n"
            }
        }
        let method = validSemantic?.status ?? "本机时间解析与关键词检索"
        let citedDates = sources.map(\.capturedAt).sorted()
        let citationCoverage = citedDates.first.map { first in
            format(first, pattern:"yyyy-MM-dd") + (citedDates.last.map { calendar.isDate(first, inSameDayAs:$0) ? "" : " 至 " + format($0,pattern:"yyyy-MM-dd") } ?? "")
        } ?? "无"
        let scope = "查找范围：\(dateLabel) · \(method)；范围内允许读取 \(day.count) 条，匹配 \(ranked.count) 条，提供 \(sources.count) 条摘录。引用日期：\(citationCoverage)。摘录不代表完整经历。"
        let direct: String?
        if resolved.unsupportedRange {
            context = ""
            direct = "目前一次查询一天。请在日记中选一天，或在问题中写明 YYYY-MM-DD，再询问当天的记录。"
        } else if questionReferences.contains(where: { number in
            guard let id = questionReferenceIDs[number] else { return true }
            return !sources.contains { $0.id == id }
        }) {
            direct = "你引用的先前来源目前不可用，或未包含在本次允许读取的摘录中。请重新打开原记录或选择当前可用来源后提问；不会把旧编号对应到其他记录。"
        } else if day.isEmpty {
            direct = "\(dateLabel) 没有允许读取的记录。可以先保存录音或图片，或在设置中允许读取相应来源。"
        } else if Self.isAggregateQuestion(question) {
            let photoNote = requestedKind == .image || ["多少张", "几张"].contains(where: question.contains)
                ? "\n这里计算的是图片记录条数；一条可含多张照片，不表示照片张数。" : ""
            direct = "\(dateLabel) 的记录统计：\n\(stats.description)" + (terms.isEmpty && requestedKind == nil ? "" : "\n其中符合本次类型与关键词筛选的记录有 \(ranked.count) 条。") + photoNote
        } else if sources.isEmpty {
            direct = "在 \(dateLabel) 允许读取的 \(day.count) 条记录中，没有找到可用于回答的文字摘录。目前按日期和关键词检索，可换一个更具体的关键词。"
        } else if !sources.contains(where: { source in
            day.contains { $0.id == source.id && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        }) {
            direct = "找到的记录尚无可用于问答的转写或图片文字。请先打开原记录完成转写，或添加图片描述，再重新提问。"
        } else {
            direct = nil
        }
        return Prepared(question: question, providerQuestion: providerQuestion, questionReferenceIDs: questionReferenceIDs, dayStart: start, dayEnd: end, dateLabel: dateLabel,
                        statistics: stats, matchedCount: ranked.count, sources: sources, context: context,
                        directResponse: direct, scopeDescription: scope, snapshots: day, allowedKinds: allowedKinds)
    }

    func prepareSpeaker(question:String,items:[SpeakerAskEvidence],records:[DayRecord],contactID:String,contactName:String? = nil,fingerprint:String,selectedDate:Date,now:Date = .now,directResponse:String? = nil) throws -> Prepared {
        let question=question.trimmingCharacters(in:.whitespacesAndNewlines)
        guard !question.isEmpty else { throw Failure.emptyQuestion }
        guard question.count<=300 else { throw Failure.questionTooLong }
        var scopedItems=items
        var requestedScope: DateInterval?
        if Self.hasExplicitDate(question) {
            let resolved=try resolveDate(question,selectedDate:selectedDate,now:now)
            let day=calendar.startOfDay(for:resolved.date),tomorrow=calendar.date(byAdding:.day,value:1,to:day)!
            requestedScope=DateInterval(start:day,end:tomorrow)
            scopedItems=items.filter{$0.capturedAt>=day && $0.capturedAt<tomorrow}
        } else if ["过去一周","最近一周","最近七天","最近7天"].contains(where:question.contains) {
            let today=calendar.startOfDay(for:now),end=calendar.date(byAdding:.day,value:1,to:today)!,start=calendar.date(byAdding:.day,value:-6,to:today)!
            requestedScope=DateInterval(start:start,end:end)
            scopedItems=items.filter{$0.capturedAt>=start && $0.capturedAt<end}
        }
        let ordered=scopedItems.sorted { $0.capturedAt == $1.capturedAt ? ($0.start == $1.start ? $0.id.uuidString < $1.id.uuidString : $0.start < $1.start) : $0.capturedAt < $1.capturedAt }
        let days=ordered.map { calendar.startOfDay(for:$0.capturedAt) }
        let start=requestedScope?.start ?? days.min() ?? calendar.startOfDay(for:selectedDate)
        let last=days.max() ?? start
        let end=requestedScope?.end ?? calendar.date(byAdding:.day,value:1,to:last) ?? last.addingTimeInterval(86_400)
        let terms=Self.keywords(question)
        let buckets = Dictionary(grouping: ordered) { item in item.id }
        var grouped: [(UUID, [SpeakerAskEvidence], Int)] = []
        grouped.reserveCapacity(buckets.count)
        for (id, spans) in buckets {
            let sorted = spans.sorted { left, right in left.start < right.start }
            let score=sorted.reduce(0) { sum,item in
                let record=DayRecord(id:id,capturedAt:item.capturedAt,kind:item.kind,title:item.title,text:item.text)
                return sum+Self.keywordScore(record,terms:terms)
            }
            grouped.append((id, sorted, score))
        }
        grouped.sort { left, right in
            if left.2 == right.2 { return left.1[0].capturedAt > right.1[0].capturedAt }
            return left.2 > right.2
        }
        let byID=Dictionary(records.map { ($0.id,$0) },uniquingKeysWith:{ first,_ in first })
        var sources:[Source]=[]
        let displayName=contactName?.trimmingCharacters(in:.whitespacesAndNewlines) ?? ""
        let identity=displayName.isEmpty ? "" : "当前检索对象是联系人「\(displayName)」。以下逐字稿来自本机已关联到该联系人的说话人，可据此回答其在录音中说了什么；关联本身不构成现实身份或会议出席的独立证明。\n"
        let transcriptSpeakerLabel=displayName.isEmpty ? nil : displayName
        var context=String((identity+"以下内容只来自已关联说话人的逐字稿片段，保留录音日期和发言时间。只根据逐字稿复述或概括发言，不推断未记录的事实。引用来源使用 [序号]。\n").prefix(limits.maxContextCharacters))
        for (index,group) in grouped.prefix(max(0,limits.maxSources)).enumerated() {
            let first=group.1[0]
            let runs=Self.speakerTranscriptRuns(group.1)
            let transcript=runs.map { run in
                "[\(Int(run.first.start/60))分\(Int(run.first.start)%60)秒] \(transcriptSpeakerLabel ?? run.first.speakerLabel)：\(run.text)"
            }.joined(separator:"\n")
            let snippet=String(transcript.prefix(max(0,limits.maxSnippetCharacters)))
            sources.append(Source(id:group.0,number:index+1,title:first.title,capturedAt:first.capturedAt,kind:first.kind,
                snippet:snippet,truncated:transcript.count>snippet.count,provenance:byID[group.0]?.contentProvenance,
                sourceKey:first.sourceKey,speakerID:first.speakerID,speakerOffset:first.start,speakerEndOffset:group.1.map { span in span.end }.max()))
            // A segment title may summarize other speakers too. Keep it on the
            // navigable citation, but only the associated speech enters AI context.
            let block="\n[\(index+1)] \(first.capturedAt.formatted(date:.abbreviated,time:.shortened)) · 已关联说话人的发言\n\(transcript)\n"
            if context.count<limits.maxContextCharacters { context+=String(block.prefix(limits.maxContextCharacters-context.count)) }
        }
        let stats=Statistics(totalCount:grouped.count,voiceCount:grouped.filter{$0.1.first?.kind == .voice}.count,
            thoughtCount:grouped.filter{$0.1.first?.kind == .thought}.count,imageCount:0,lifeCount:0,audioDuration:0)
        let direct=directResponse ?? (ordered.isEmpty ? "没有找到当前范围内的关联发言。请检查录音中的说话人关联，或等待转写处理完成。" : nil)
        let allowed: Set<DayRecord.Kind> = contactID == "self" ? [.thought] : [.voice]
        let dateLabel=requestedScope.map { _ in
            let lastDay=calendar.date(byAdding:.day,value:-1,to:end)!
            return format(start,pattern:"yyyy-MM-dd") + (calendar.isDate(start,inSameDayAs:lastDay) ? "" : " 至 " + format(lastDay,pattern:"yyyy-MM-dd"))
        } ?? "已关联说话人记录"
        return Prepared(question:question,providerQuestion:question,questionReferenceIDs:[:],dayStart:start,dayEnd:end,dateLabel:dateLabel,
            statistics:stats,matchedCount:grouped.count,sources:sources,context:context,directResponse:direct,
            scopeDescription:"仅检索已关联说话人的录音片段 · \(dateLabel) · \(grouped.count) 条记录",snapshots:records,
            allowedKinds:allowed,speakerContactID:contactID,speakerFingerprint:fingerprint)
    }

    /// Compact word-timed ASR for context only. Durable rows, speaker assignments,
    /// and citation offsets stay unchanged; gaps and source changes start new runs.
    private static func speakerTranscriptRuns(_ items:[SpeakerAskEvidence]) -> [(first:SpeakerAskEvidence,end:Double,text:String)] {
        var runs:[(first:SpeakerAskEvidence,end:Double,text:String)]=[]
        for item in items {
            if let last=runs.last,last.first.sourceKey == item.sourceKey,last.first.speakerID == item.speakerID,
               item.start-last.end <= 1,item.end-last.first.start <= 30,last.text.count+item.text.count <= 400 {
                // Most engines preserve separators. For word-only Latin spans,
                // retain a word boundary without adding spaces inside Chinese.
                let latinEdge=#"[\p{Latin}]"#
                let needsSpace=last.text.last.map { String($0).range(of:latinEdge,options:.regularExpression) != nil } == true
                    && item.text.first.map { String($0).range(of:latinEdge,options:.regularExpression) != nil } == true
                runs[runs.count-1].text += (needsSpace ? " " : "")+item.text
                runs[runs.count-1].end=max(last.end,item.end)
            } else { runs.append((item,item.end,item.text)) }
        }
        return runs
    }

    struct AutomaticScope {
        let start: Date
        let end: Date // exclusive, in the device timezone
        let label: String
        let topic: String
        let canExpand: Bool
    }

    static func isFollowup(_ question: String) -> Bool {
        ["只看", "再往前", "更早", "那接下来", "继续", "那天", "这一天", "这些", "这条", "它"].contains(where: question.contains)
            || question.range(of: #"\[\d+\]"#, options: .regularExpression) != nil
    }

    /// Planning is local and never grants data access. Hard user dates are never broadened.
    func automaticScope(_ question: String, now: Date = .now, priorTurns: [DaybookConversationTurn] = [], expanded: Bool = false) throws -> AutomaticScope {
        let today = calendar.startOfDay(for: now)
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: today)!
        var topic = question
        var start = Date(timeIntervalSince1970: 0), end = tomorrow
        var label = "全部获准记录", soft = false
        let pattern = #"(?:(\d{4})[-/年])?(\d{1,2})[-/月](\d{1,2})日?"#
        let regex = try NSRegularExpression(pattern: pattern)
        let matches = regex.matches(in: question, range: NSRange(question.startIndex..., in: question))
        var dates: [Date] = []
        for match in matches {
            let token = String(question[Range(match.range, in: question)!])
            dates.append(try resolveDate(token, selectedDate: now, now: now).date)
            topic = topic.replacingOccurrences(of: token, with: " ")
        }
        let relativeDays = Self.extractRelativeDays(topic)
        dates += relativeDays.offsets.map { calendar.date(byAdding:.day,value:$0,to:today)! }
        topic = relativeDays.remaining
        let unique = Array(Set(dates)).sorted()
        if !unique.isEmpty {
            guard unique.count <= 2 else { throw Failure.ambiguousDate }
            start = unique.first!; end = calendar.date(byAdding: .day, value: 1, to: unique.last!)!
            // A two-date range is inclusive; reversed written ranges need clarification.
            if matches.count == 2 && dates.count == 2 && dates[0] > dates[1] { throw Failure.invalidDate }
        } else if ["上个月","上月","本月","这个月"].contains(where: topic.contains) {
            let month = calendar.dateInterval(of: .month, for: now)!
            let previous = topic.contains("上个月") || topic.contains("上月")
            start = previous ? calendar.date(byAdding: .month, value: -1, to: month.start)! : month.start
            end = previous ? month.start : tomorrow
        } else if ["上周","本周","这周"].contains(where: topic.contains) {
            // A week starts on Monday regardless of the user's calendar display preference.
            let offset = (calendar.component(.weekday, from: today) + 5) % 7
            let monday = calendar.date(byAdding: .day, value: -offset, to: today)!
            start = topic.contains("上周") ? calendar.date(byAdding: .day, value: -7, to: monday)! : monday
            end = topic.contains("上周") ? monday : tomorrow
        } else if ["再往前","更早","全部","所有","之前","以前"].contains(where: topic.contains) {
            label = "跨时间查找全部获准记录"
        } else if ["最近","近期","这段时间","过去","近一周","近7天"].contains(where: topic.contains) {
            var days = topic.contains("月") || topic.contains("30天") ? 30 : 7
            if let numberRange = topic.range(of: #"\d+(?=天)"#, options: .regularExpression), let value = Int(topic[numberRange]) { days = min(3650, max(1,value)) }
            start = calendar.date(byAdding: .day, value: 1-days, to: today)!
            soft = !["过去", "天", "周", "月"].contains(where: topic.contains)
            if expanded { start = Date(timeIntervalSince1970:0); label = "近期匹配不足，已扩大到全部获准记录" }
        } else if Self.isFollowup(question), let previous = priorTurns.last {
            start = previous.evidence.dayStart; end = previous.evidence.dayEnd
        }
        if start != Date(timeIntervalSince1970:0) {
            let last = calendar.date(byAdding: .day, value: -1, to: end)!
            label = format(start, pattern:"yyyy-MM-dd") + (calendar.isDate(start, inSameDayAs:last) ? "" : " 至 " + format(last, pattern:"yyyy-MM-dd"))
        }
        for word in ["只看","再往前找找","再往前","更早","继续","上个月","上月","本月","这个月","上周","本周","这周","最近一个月","最近一周","过去一周","近一周","最近七天","最近7天","近7天","最近几天","最近","近期","这段时间","过去","全部","所有日期","所有","之前","以前","到","至"] {
            topic = topic.replacingOccurrences(of:word,with:" ")
        }
        topic = topic.replacingOccurrences(of:#"\d+天"#,with:" ",options:.regularExpression)
        if Self.isFollowup(question), Self.keywords(topic).isEmpty, let previous = priorTurns.last {
            // Reuse intent, never historical answer text. Bounded recursion over completed turns.
            topic = try automaticScope(previous.question, now:now, priorTurns:Array(priorTurns.dropLast())).topic
        }
        return AutomaticScope(start:start,end:end,label:label,topic:topic,canExpand:soft && !expanded)
    }

    /// Manual substring matches include all local sources. Semantic additions obey AI scope and freshness.
    static func originalRecordingRecords(query: String, records: [DayRecord], dayStart: Date, dayEnd: Date) -> [DayRecord] {
        let query = normalize(query)
        return records.filter { record in
            guard record.kind == .voice, record.contentProvenance == nil, record.parentRecordID == nil,
                  record.capturedAt >= dayStart, record.capturedAt < dayEnd else { return false }
            return query.isEmpty || [record.title, record.text, record.summary].contains { normalize($0).contains(query) }
        }.sorted { $0.capturedAt > $1.capturedAt }
    }

    /// Manual substring matches include all local sources. Semantic additions obey AI scope and freshness.
    static func libraryRecords(query: String, records: [DayRecord], dayStart: Date, dayEnd: Date,
                               allowedKinds: Set<DayRecord.Kind>, semantic: DaybookSemanticMatches?) -> [DayRecord] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let valid = semantic.flatMap { result in
            (result.query == nil || result.query == query) && result.evidence.dayStart == dayStart && result.evidence.dayEnd == dayEnd &&
            result.evidence.isCurrent(records: records, allowedKinds: allowedKinds) ? result : nil
        }
        let day = DayRecord.evidenceRecords(records, scope: DateInterval(start:dayStart,end:dayEnd))
        let sqlKeywords = valid?.keywords.flatMap { $0.isCurrent(query: query, records: records) ? $0 : nil }
        let literal = day.filter { record in
            if let sqlKeywords { return sqlKeywords.libraryIDs.contains(record.id) }
            return query.isEmpty || [record.title, record.text, record.summary].contains { normalize($0).contains(normalize(query)) }
        }
        let literalIDs = Set(literal.map(\.id))
        let available = Dictionary(day.filter { allowedKinds.contains($0.kind) }.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let additions = (valid?.hits ?? []).compactMap { hit in literalIDs.contains(hit.id) ? nil : available[hit.id] }
        return literal + additions
    }

    private static func sourceMap(_ sources: [Source]) -> [Int: UUID] {
        sources.reduce(into: [:]) { result, source in result[source.number] = source.id }
    }

    private static func citationNumbers(in text: String) -> Set<Int> {
        let expression = try! NSRegularExpression(pattern: #"\[(\d+)\]"#)
        return Set(expression.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { match in
            Range(match.range(at: 1), in: text).flatMap { Int(text[$0]) }
        })
    }

    /// Resolve the old numeric label to a stable record identity before assigning a fresh label.
    /// Unknown, revoked, out-of-day or budget-excluded references never retain an aliasable [n].
    private static func remapReferences(in text: String, referenceIDs: [Int: UUID], currentSources: [Source]) -> String {
        let expression = try! NSRegularExpression(pattern: #"\[(\d+)\]"#)
        var result = text
        for match in expression.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed() {
            guard let numberRange = Range(match.range(at: 1), in: text),
                  let number = Int(text[numberRange]), let range = Range(match.range, in: result) else { continue }
            let replacement: String
            if let id = referenceIDs[number], let current = currentSources.first(where: { $0.id == id }) {
                replacement = "（本次[\(current.number)]）"
            } else { replacement = "（先前引用\(number)不可用）" }
            result.replaceSubrange(range, with: replacement)
        }
        return result
    }

    static func requestedKind(for question: String) -> DayRecord.Kind? {
        if ["照片", "图片", "相片"].contains(where: question.contains) { return .image }
        if ["闪念", "想法", "灵感"].contains(where: question.contains) { return .thought }
        if ["睡眠", "睡了", "睡得"].contains(where: question.contains) { return .sleep }
        if ["步数", "步行", "运动", "训练", "跑步", "骑行", "游泳", "健身"].contains(where: question.contains) { return .activity }
        if question.contains("录音") { return .voice }
        return nil
    }

    static func kindLabel(_ kind: DayRecord.Kind) -> String {
        switch kind { case .voice: "录音"; case .thought: "闪念"; case .image: "图片记录"; case .activity: "活动与体能训练"; case .sleep: "睡眠"; case .calendar: "日历"; case .location: "地点" }
    }

    private static func scoped(_ records: [DayRecord], from start: Date, to end: Date,
                               allowedKinds: Set<DayRecord.Kind>) -> [DayRecord] {
        DayRecord.evidenceRecords(records, scope: DateInterval(start:start,end:end)).filter { allowedKinds.contains($0.kind) }
            .sorted { $0.id.uuidString < $1.id.uuidString }
    }

    static func isAggregateQuestion(_ question: String) -> Bool {
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

    static func hasExplicitDate(_ question: String) -> Bool {
        if !extractRelativeDays(question).offsets.isEmpty { return true }
        return question.range(of: #"(?:\d{4}[-/年])?\d{1,2}[-/月]\d{1,2}"#, options: .regularExpression) != nil
    }

    // Shared by general and speaker retrieval so a hard date cannot disappear
    // when the question takes a different route. Consume the longer phrase first.
    private static let relativeDayTokens: [(expression:NSRegularExpression,offset:Int)] = [
        (#"前天|\b(?:the\s+)?day\s+before\s+yesterday\b(?:['’]s\b)?"#, -2),
        (#"今天|今日|\btoday\b(?:['’]s\b)?"#, 0),
        (#"昨天|昨日|\byesterday\b(?:['’]s\b)?"#, -1),
        (#"明天|\btomorrow\b(?:['’]s\b)?"#, 1)
    ].map { (try! NSRegularExpression(pattern:$0.0,options:.caseInsensitive),$0.1) }

    private static func extractRelativeDays(_ question:String) -> (offsets:[Int],remaining:String) {
        var remaining=question,offsets:[Int]=[]
        for (expression,offset) in relativeDayTokens {
            let range=NSRange(remaining.startIndex...,in:remaining)
            guard expression.firstMatch(in:remaining,range:range) != nil else { continue }
            offsets.append(offset)
            remaining=expression.stringByReplacingMatches(in:remaining,range:range,withTemplate:" ")
        }
        return (offsets,remaining)
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
        let relativeDays=Self.extractRelativeDays(remaining)
        dates += relativeDays.offsets.map { calendar.date(byAdding:.day,value:$0,to:calendar.startOfDay(for:now))! }
        remaining=relativeDays.remaining
        let unique = Set(dates.map { calendar.startOfDay(for: $0) })
        guard unique.count <= 1 else { throw Failure.ambiguousDate }
        return (unique.first ?? selectedDate, remaining, unsupported)
    }

    /// Versioned fixed-locale normalization shared by SQL and live fallback.
    static let normalizationVersion = "nfc-casefold-posix-v1"
    static func normalize(_ text: String) -> String {
        text.precomposedStringWithCanonicalMapping.folding(options: [.caseInsensitive], locale: Locale(identifier: "en_US_POSIX")).precomposedStringWithCanonicalMapping
    }
    static func keywordScore(_ record: DayRecord, terms: [String]) -> Int {
        let title = normalize(record.title), body = normalize(record.text)
        return terms.reduce(0) { $0 + (title.contains($1) ? 4 * $1.count : 0) + (body.contains($1) ? $1.count : 0) }
    }
    func keywordTerms(question: String, selectedDate: Date, now: Date = .now) throws -> [String] {
        Self.keywords(try resolveDate(question, selectedDate: selectedDate, now: now).remaining)
    }
    static func keywords(_ question: String) -> [String] {
        var query = normalize(question)
        // Remove question scaffolding before CJK n-grams, keeping the actual topic.
        let fillers = ["有哪些值得跟进的事", "那接下来", "记下过", "找找", "想法", "灵感", "只看", "睡眠", "最近", "之前", "情况", "变化", "最值得跟进什么", "有哪些要点", "有哪些待办", "有什么待办", "有什么记录", "有哪些记录", "有多少条记录", "有多少记录", "说了什么", "记录了什么", "发生了什么", "回顾这一天", "总结这一天", "多长时间", "总时长", "几分钟", "这一天", "这一天的", "选中的日期", "所选日期", "请帮我", "帮我", "请问", "总结", "回顾", "概括", "要点", "待办", "行动项", "记录", "录音", "闪念", "图片", "照片", "相片", "拍了", "多少", "几条", "几张", "数量", "多久", "有哪些", "有什么", "是什么", "怎么样", "如何", "什么", "有关", "关于", "的", "了", "呢", "吗", "请"]
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

struct SpeakerAskEvidence: Sendable {
    let id:UUID
    let sourceKey:String
    let speakerID:String?
    let speakerLabel:String
    let title:String
    let capturedAt:Date
    let kind:DayRecord.Kind
    let start:TimeInterval
    let end:TimeInterval
    let text:String
}

/// Resolves contacts before reading transcript evidence. No contact fields except the display
/// name enter AI context; phone numbers, email addresses and photos stay local.
struct DaybookSpeakerAskRepository: @unchecked Sendable {
    enum Resolution:Sendable {
        case unrelated
        case contact(id:String,name:String)
        case selfThoughts
        case ambiguous([String])
        case unlinked(String)
        var contactID:String? {
            switch self {
            case .contact(let id,_): id
            case .selfThoughts: "self"
            case .ambiguous(let names): "ambiguous:"+names.joined(separator:"|")
            case .unlinked(let name): "unlinked:"+name
            case .unrelated: nil
            }
        }
        var contactName:String? {
            switch self {
            case .contact(_,let name): name
            case .selfThoughts: nil
            case .ambiguous,.unlinked,.unrelated: nil
            }
        }
        var directResponse:String? {
            switch self {
            case .ambiguous(let names): "找到多个同名联系人：\(names.joined(separator:"、"))。请在录音中查看并关联对应的说话人后再提问。"
            case .unlinked(let name): "\(name) 还没有关联到录音中的说话人。请先打开录音全文，选择说话人并关联联系人。"
            default: nil
            }
        }
        var requiredKind:DayRecord.Kind? {
            switch self { case .contact,.ambiguous,.unlinked: .voice; case .selfThoughts: .thought; case .unrelated: nil }
        }
    }
    struct Snapshot:Sendable { let items:[SpeakerAskEvidence]; let fingerprint:String }
    private let db:DaybookDatabase
    init(database:DaybookDatabase? = nil) throws { db=try database ?? DaybookDatabase() }

    func resolve(question:String,priorTurns:[DaybookConversationTurn]) throws -> Resolution {
        let question=DaybookRetrieval.normalize(question)
        let cues=["说了什么","说过什么","提到","谈到","参与过哪些会议","参加过哪些会议","参与的会议","哪些会议","说过","原话","发言","聊过","观点","看法","意见","建议"]
        let explicit=cues.contains(where:question.contains) || question.range(
            of:#"\b(?:say|said|says|saying|speak|spoke|speaking|spoken|mention(?:ed|s)?|discuss(?:ed|es|ion)?|opinion(?:s)?|view(?:s)?|think|thinks|thoughts?|recommend(?:ed|s|ation|ations)?|suggest(?:ed|s|ion|ions)?|recording(?:s)?|meeting(?:s)?|transcript(?:s)?)\b"#,
            options:.regularExpression) != nil
        let names=try db.query("SELECT id,display_name FROM contacts ORDER BY length(display_name) DESC,display_name COLLATE NOCASE")
            .compactMap { row -> (String,String)? in guard let id=row["id"]?.string,let name=row["display_name"]?.string,!name.isEmpty else{return nil};return(id,name) }
        let matches=names.filter { _,name in
            // English possessives are valid name boundaries; Kate Bella is not Kate Bell.
            let escaped=NSRegularExpression.escapedPattern(for:DaybookRetrieval.normalize(name))
            return question.range(of:"(?<![\\p{Latin}\\p{N}_])"+escaped+"(?![\\p{Latin}\\p{N}_])",options:.regularExpression) != nil
        }
        let nameOnly=matches.contains { question.trimmingCharacters(in:.whitespacesAndNewlines.union(.punctuationCharacters)) == DaybookRetrieval.normalize($0.1) }
        if explicit || nameOnly, !matches.isEmpty {
            let unique=Dictionary(matches.map { ($0.0,$0.1) },uniquingKeysWith:{ first,_ in first }).sorted { $0.value < $1.value }
            if unique.count>1 { return .ambiguous(unique.map(\.value)) }
            let (id,name)=unique[0]
            let linked=try !db.query("SELECT 1 FROM recording_speaker_contacts WHERE contact_id=? LIMIT 1",[.text(id)]).isEmpty
            return linked ? .contact(id:id,name:name) : .unlinked(name)
        }
        if ["我说过","我提到过","我讲过","我记录过","我之前说","我的闪念","我在闪念","我说了什么"].contains(where:question.contains) { return .selfThoughts }
        let refersToPrior=["他","她","他们","她们","这个人"].contains(where:question.contains)
            || question.range(of:#"\b(?:he|she|they|him|her|them|his|their)\b"#,options:.regularExpression) != nil
        if explicit,refersToPrior,let id=priorTurns.reversed().first(where:{$0.completionState == .completed})?.evidence.speakerContactID {
            if id == "self" { return .selfThoughts }
            if let row=try db.query("SELECT id,display_name FROM contacts WHERE id=?",[.text(id)]).first,
               let name=row["display_name"]?.string { return .contact(id:id,name:name) }
        }
        return .unrelated
    }

    func snapshot(contactID:String) throws -> Snapshot {
        if contactID == "self" { return try thoughtSnapshot() }
        var items:[SpeakerAskEvidence]=[]
        var fingerprintParts:[String]=[contactID]
        let links=try db.query("SELECT l.source_key,l.speaker_id,l.speaker_revision,s.kind,s.source_id,s.descriptor,c.display_name FROM recording_speaker_contacts l JOIN audio_processing_sources s ON s.source_key=l.source_key JOIN contacts c ON c.id=l.contact_id WHERE l.contact_id=? ORDER BY l.source_key,l.speaker_id",[.text(contactID)])
        for link in links {
            guard let key=link["source_key"]?.string,let speaker=link["speaker_id"]?.string else { continue }
            let current=try currentSpeakerRevision(sourceKey:key,speakerID:speaker)
            guard link["speaker_revision"]?.string == current else { continue }
            let descriptor=try DaybookDatabase.decode(AudioSourceSnapshot.self,link["descriptor"])
            let kind=descriptor.id.kind == .legacyNote ? DayRecord.Kind.voice : .voice
            let rows=try db.query("SELECT t.start,t.end,t.text FROM audio_transcript_spans t JOIN audio_processing_jobs j ON j.id=t.job_id JOIN audio_processing_sources s ON s.source_key=j.source_key WHERE j.source_key=? AND j.active=1 AND j.configuration_key=s.configuration_key AND j.result IS NOT NULL AND t.speaker_id=? AND j.core_start<t.end AND j.core_end>t.start ORDER BY t.start,t.end,j.id,t.position",[.text(key),.text(speaker)])
            let sourceUUID=descriptor.id.id
            var seen=Set<String>()
            let label=String(descriptor.title.isEmpty ? "录音" : descriptor.title.prefix(100))
            for row in rows {
                let start=try row.requiredDouble("start"),end=try row.requiredDouble("end"),text=try row.requiredString("text")
                guard !text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty else { continue }
                let signature="\(Int((start*1000).rounded()))|\(Int((end*1000).rounded()))|\(DaybookRetrieval.normalize(text))"
                guard seen.insert(signature).inserted else { continue }
                let destination=try segmentDestination(sourceKey:key,sourceID:sourceUUID,at:start,fallbackTitle:label)
                items.append(.init(id:destination.id,sourceKey:key,speakerID:speaker,speakerLabel:labelForSpeaker(speaker),title:destination.title,
                    capturedAt:descriptor.capturedAt,kind:kind,start:start,end:end,text:text))
                // Keep cached citations fresh when the source date/title or the destination
                // segment title changes, even if the underlying transcript spans do not.
                fingerprintParts.append(contentsOf:[key,speaker,current,String(start),String(end),text,
                    String(descriptor.capturedAt.timeIntervalSinceReferenceDate),label,destination.id.uuidString,destination.title])
            }
        }
        if let name=try db.query("SELECT display_name FROM contacts WHERE id=?",[.text(contactID)]).first?["display_name"]?.string { fingerprintParts.append(name) }
        return Snapshot(items:items,fingerprint:AudioStableID.make(fingerprintParts))
    }

    func currentFingerprint(contactID:String) throws -> String { try snapshot(contactID:contactID).fingerprint }

    private func thoughtSnapshot() throws -> Snapshot {
        let rows=try db.query("SELECT id,captured_at,title,transcript,summary,duration FROM voice_notes WHERE kind='thought' ORDER BY captured_at,id")
        var items:[SpeakerAskEvidence]=[],parts:[String]=["self"]
        for row in rows {
            guard let idText=row["id"]?.string,let id=UUID(uuidString:idText) else { continue }
            let captured=Date(timeIntervalSinceReferenceDate:try row.requiredDouble("captured_at"))
            let title=row["title"]?.string ?? "闪念",text=(row["transcript"]?.string ?? row["summary"]?.string ?? "").trimmingCharacters(in:.whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            let duration=max(0,row["duration"]?.double ?? 0)
            items.append(.init(id:id,sourceKey:"thought:\(idText)",speakerID:nil,speakerLabel:"我",title:title,capturedAt:captured,kind:.thought,start:0,end:duration,text:text))
            parts += [idText,String(captured.timeIntervalSinceReferenceDate),title,text]
        }
        return Snapshot(items:items,fingerprint:AudioStableID.make(parts))
    }

    private func currentSpeakerRevision(sourceKey:String,speakerID:String) throws -> String {
        let rows=try db.query("SELECT j.id,j.result_hash,t.position,t.start,t.end,t.text FROM audio_transcript_spans t JOIN audio_processing_jobs j ON j.id=t.job_id JOIN audio_processing_sources s ON s.source_key=j.source_key WHERE j.source_key=? AND j.active=1 AND j.configuration_key=s.configuration_key AND j.result IS NOT NULL AND t.speaker_id=? ORDER BY t.start,t.end,j.id,t.position",[.text(sourceKey),.text(speakerID)])
        var parts: [String] = []
        parts.reserveCapacity(rows.count * 6)
        for row in rows {
            parts.append(row["id"]?.string ?? "")
            parts.append(row["result_hash"]?.string ?? "")
            parts.append(String(row["position"]?.double ?? 0))
            parts.append(String(row["start"]?.double ?? 0))
            parts.append(String(row["end"]?.double ?? 0))
            parts.append(row["text"]?.string ?? "")
        }
        return AudioStableID.make(parts)
    }

    private func segmentDestination(sourceKey:String,sourceID:UUID,at offset:Double,fallbackTitle:String) throws -> (id:UUID,title:String) {
        let rows=try db.query("SELECT c.payload FROM content_segments c JOIN content_segment_ranges r ON r.segment_id=c.id WHERE c.source_key=? AND c.deleted=0 AND r.start<=? AND r.end>? ORDER BY c.start DESC LIMIT 1",[.text(sourceKey),.real(offset),.real(offset)])
        if let data=rows.first?["payload"],let segment=try? DaybookDatabase.decode(ContentSegment.self,data) { return (segment.id,segment.title) }
        if let uuid=UUID(uuidString:String(sourceKey.split(separator:":").last ?? "")),sourceKey.hasPrefix("legacyNote:") {
            let title=try db.query("SELECT title FROM voice_notes WHERE id=?",[.text(uuid.uuidString)]).first?["title"]?.string ?? fallbackTitle
            return (uuid,title)
        }
        return (sourceID,fallbackTitle)
    }

    private func labelForSpeaker(_ id:String) -> String { "说话人 \(id.replacingOccurrences(of:"speaker-",with:""))" }
}

/// Siri uses the same bounded, source-grounded retrieval as Ask AI, but only local voice and
/// thought records are eligible. The caller chooses the local model explicitly.
enum WiseLifeSiriQuery {
    static func prepare(question: String, records: [DayRecord], now: Date = .now,
                        calendar: Calendar = .current,
                        allowedKinds: Set<DayRecord.Kind> = [.voice, .thought]) throws -> DaybookRetrieval.Prepared {
        var retrieval = DaybookRetrieval(calendar: calendar)
        retrieval.limits.maxSources = 4
        retrieval.limits.maxSnippetCharacters = 220
        retrieval.limits.maxContextCharacters = 1_200
        return try retrieval.prepare(question: question, records: records, selectedDate: now, now: now,
                                     allowedKinds: allowedKinds.intersection([.voice, .thought]), automatic: true)
    }
}
