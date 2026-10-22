import Foundation

struct LifeSleepSample: Sendable {
    let start: Date
    let end: Date
    let stage: SleepStage
    let sourceID: String
    let sourceName: String
    var interval: DateInterval { DateInterval(start: start, end: end) }
}

/// Pure aggregation; sources, permissions and storage remain with their existing owners.
enum LifeMomentBuilder {
    /// Every clock update (including a data callback) must follow today across midnight.
    /// A user browsing history keeps the selected historical date.
    static func selectedDate(after now: Date, previousNow: Date, selected: Date, calendar: Calendar) -> Date {
        !calendar.isDate(previousNow, inSameDayAs: now) && calendar.isDate(selected, inSameDayAs: previousNow) ? now : selected
    }
    static func detail(id: UUID, pendingSleepOn day: Date?, records: [DayRecord], calendar: Calendar) -> DayRecord? {
        if let record = records.first(where: { $0.id == id && $0.lifeMoment != nil }) { return record }
        guard let day else { return nil }
        return records.first { $0.lifeMoment?.sleep?.isMain == true && calendar.isDate($0.capturedAt, inSameDayAs: day) }
    }
    static func health(day: Date, steps: Double?, samples: [LifeSleepSample], now: Date, calendar: Calendar) -> [DayRecord] {
        let interval = LifeAggregation.dayInterval(day, calendar: calendar)
        let count = steps.flatMap { $0.isFinite && $0 >= 0 && $0 < Double(Int.max) ? $0 : nil }
        var total = DayRecord(id: LifeAggregation.recordID(source: .health, key: "steps", day: interval.start),
            capturedAt: interval.start, kind: .activity, title: count.map { "步数 · \(Int($0)) 步" } ?? "步数 · 待同步",
            text: count.map { "Apple 健康当天累计步数：\(Int($0)) 步。" } ?? "暂无可读取的步数数据，不代表 0 步。", metricValue: count)
        total.lifeMoment = .init(steps: .init(interval: interval, count: count, updatedAt: now, archived: false))
        // Build episodes within a source first. A broad phone sample must not bridge
        // a Watch night and nap or move its waking time onto another date.
        let valid = samples.filter {
            $0.start.timeIntervalSinceReferenceDate.isFinite && $0.end.timeIntervalSinceReferenceDate.isFinite
                && $0.end > $0.start && $0.start < now && $0.end.timeIntervalSince($0.start) <= 24 * 3600
        }
        struct Episode {
            let interval: DateInterval
            let sourceID: String
            let samples: [LifeSleepSample]
            let score: Double
        }
        var candidates: [Episode] = []
        for (sourceID, source) in Dictionary(grouping: valid, by: \.sourceID) {
            let asleep = source.filter { $0.stage != .awake && $0.stage != .inBed }
            let continuity = source.filter { $0.stage == .awake || $0.stage == .inBed }.map(\.interval)
            var episodes: [DateInterval] = []
            for part in union(asleep.map(\.interval)) {
                let joins = episodes.last.map { last in
                    let gap = DateInterval(start: last.end, end: part.start)
                    let supportedGap = LifeAggregation.sleepDuration(continuity, within: gap) >= gap.duration - 1
                    return part.end.timeIntervalSince(last.start) <= 24 * 3600 && (gap.duration <= 90 * 60 || supportedGap)
                } ?? false
                if let last = episodes.last, joins {
                    episodes[episodes.count - 1] = DateInterval(start: last.start, end: part.end)
                } else { episodes.append(part) }
            }
            for episode in episodes {
                let relevant = source.filter { $0.start < episode.end && $0.end > episode.start }
                candidates.append(Episode(interval: episode, sourceID: sourceID, samples: relevant, score: rank(relevant, within: episode)))
            }
        }
        var selected: [Episode] = []
        for candidate in candidates.sorted(by: {
            if $0.score != $1.score { return $0.score > $1.score }
            if $0.sourceID != $1.sourceID { return $0.sourceID < $1.sourceID }
            return $0.interval.start < $1.interval.start
        }) {
            if !selected.contains(where: { $0.interval.start < candidate.interval.end && candidate.interval.start < $0.interval.end }) {
                selected.append(candidate)
            }
        }
        var nights: [(SleepMoment, [DateInterval])] = []
        for candidate in selected.sorted(by: { $0.interval.start < $1.interval.start }) {
            let episode = candidate.interval, source = candidate.samples
            // Ongoing samples remain evidence of an unfinished episode, rather than
            // disappearing and making an earlier completed stage look like wake-up.
            guard episode.end <= now else { continue }
            let points = Set(source.flatMap { [max($0.start, episode.start), min($0.end, episode.end)] }).sorted()
            var spans: [DateInterval] = [], stages: [SleepStage: TimeInterval] = [:], awake: TimeInterval = 0
            for (start, end) in zip(points, points.dropFirst()) where end > start {
                let kinds = Set(source.filter { $0.start < end && $0.end > start }.map(\.stage)).subtracting([.inBed])
                let seconds = end.timeIntervalSince(start)
                if kinds.contains(.awake) { awake += seconds; continue }
                guard !kinds.isEmpty else { continue }
                spans.append(.init(start: start, end: end))
                let specified = kinds.subtracting([.asleep])
                let stage = specified.count == 1 ? specified.first! : SleepStage.asleep
                stages[stage, default: 0] += seconds
            }
            spans = union(spans)
            guard let start = spans.first?.start, let end = spans.last?.end,
                  end >= interval.start, end < interval.end else { continue }
            let detailed = source.contains { [.deep, .core, .rem, .awake].contains($0.stage) }
            let asleepSeconds = spans.reduce(0) { $0 + $1.duration }
            let completeCoverage = abs(end.timeIntervalSince(start) - asleepSeconds - awake) < 1
            nights.append((SleepMoment(startedAt: start, endedAt: end, asleepSeconds: asleepSeconds,
                awakeSeconds: detailed && completeCoverage ? awake : nil, stages: stages, sourceName: source.first?.sourceName, isMain: false), spans))
        }
        // A morning/overnight episode wins over a later nap. Shift-worker sleep uses the longest episode.
        let main = nights.indices.filter { (nights[$0].0.asleepSeconds ?? 0) >= 2 * 3600 }.max { a, b in
            func score(_ index: Int) -> Double {
                let sleep = nights[index].0
                let morning = calendar.component(.hour, from: sleep.endedAt!) < 12
                return (morning ? 100_000 : 0) + (sleep.asleepSeconds ?? 0)
            }
            return score(a) < score(b)
        }
        let sleepRecords = nights.enumerated().map { index, value -> DayRecord in
            let detail = SleepMoment(startedAt: value.0.startedAt, endedAt: value.0.endedAt, asleepSeconds: value.0.asleepSeconds,
                awakeSeconds: value.0.awakeSeconds, stages: value.0.stages, sourceName: value.0.sourceName, isMain: index == main)
            let key = index == main ? "sleep" : "sleep-nap|\(detail.startedAt!.timeIntervalSince1970)"
            var record = DayRecord(id: LifeAggregation.recordID(source: .health, key: key, day: interval.start),
                capturedAt: detail.endedAt!, kind: .sleep, title: index == main ? "起床 · 估计" : "一段睡眠",
                text: "\(clock(detail.startedAt!)) 入睡 · \(clock(detail.endedAt!)) 醒来 · 实际睡眠 \(duration(detail.asleepSeconds!))。睡眠结束不等于离床时间。",
                duration: detail.asleepSeconds!, metricValue: detail.asleepSeconds, intervals: value.1)
            record.lifeMoment = .init(sleep: detail); return record
        }
        return [total] + sleepRecords
    }

    static func archive(records: [DayRecord], day: Date, updatedAt: Date?, calendar: Calendar) -> DayRecord {
        let end = calendar.startOfDay(for: day), start = calendar.date(byAdding: .day, value: -1, to: end)!
        let original = records.first { $0.kind == .activity && $0.lifeMoment?.steps?.archived != true && $0.capturedAt >= start && $0.capturedAt < end }
        let count = original?.metricValue.flatMap { $0.isFinite && $0 >= 0 && $0 < Double(Int.max) ? $0 : nil }
        let date = start.formatted(.dateTime.month().day())
        var result = DayRecord(id: LifeAggregation.recordID(source: .health, key: "steps-archive", day: start),
            capturedAt: end, kind: .activity, title: count.map { "昨天走了 \(Int($0)) 步" } ?? "昨日步数 · 待同步",
            text: "\(date) 全天累计 · " + (count == nil ? "等待健康数据" : "已更新"))
        result.lifeMoment = .init(steps: .init(interval: .init(start: start, end: end), count: count, updatedAt: updatedAt, archived: true))
        return result
    }

    static func pendingSleep(day: Date, calendar: Calendar) -> DayRecord {
        var record = DayRecord(id: LifeAggregation.recordID(source: .health, key: "sleep-pending", day: calendar.startOfDay(for: day)),
            capturedAt: calendar.startOfDay(for: day), kind: .sleep, title: "昨夜睡眠 · 待同步", text: "等待完整睡眠记录，暂不推测入睡、起床时间或睡眠质量。")
        record.lifeMoment = .init(sleep: .init(startedAt: nil, endedAt: nil, asleepSeconds: nil, awakeSeconds: nil, stages: [:], sourceName: nil, isMain: true))
        return record
    }

    /// Only observed days and the selected day get projections; no fabricated history.
    static func timeline(records: [DayRecord], day: Date, now: Date, healthEnabled: Bool,
                         calendar: Calendar, snapshot: (Date) -> LifeSourceSnapshot?,
                         isSuppressed: (UUID) -> Bool) -> [DayRecord] {
        let today = calendar.startOfDay(for: now), selected = calendar.startOfDay(for: day)
        var days = Set(records.filter { $0.kind == .activity && $0.lifeMoment?.steps?.archived != true }
            .compactMap { calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: $0.capturedAt)) })
        if healthEnabled { days.insert(selected) }
        var result: [DayRecord] = days.filter { $0 <= today }.compactMap { date in
            let previous = calendar.date(byAdding: .day, value: -1, to: date)!
            guard !isSuppressed(LifeAggregation.recordID(source: .health, key: "steps", day: previous)) else { return nil }
            let saved = snapshot(previous)
            var item = archive(records: records, day: date, updatedAt: saved?.refreshedAt, calendar: calendar)
            guard !isSuppressed(item.id) else { return nil }
            if saved?.isStale == true {
                item.title = "【旧快照】" + item.title
                item.text += " · 来源刷新失败，数据可能已过期"
            }
            return item
        }
        if healthEnabled, selected <= today,
           !records.contains(where: { $0.kind == .sleep && calendar.isDate($0.capturedAt, inSameDayAs: selected) && ($0.lifeMoment?.sleep?.isMain ?? true) }),
           !isSuppressed(LifeAggregation.recordID(source: .health, key: "sleep", day: selected)) {
            let pending = pendingSleep(day: selected, calendar: calendar)
            if !isSuppressed(pending.id) { result.append(pending) }
        }
        return result
    }
    private static func rank(_ samples: [LifeSleepSample], within interval: DateInterval) -> Double {
        let hasStages = samples.contains { [.deep, .core, .rem].contains($0.stage) }
        let seconds = LifeAggregation.sleepDuration(samples.filter { $0.stage != .awake && $0.stage != .inBed }.map(\.interval), within: interval)
        return (hasStages ? 1_000_000 : 0) + seconds
    }
    private static func union(_ samples: [DateInterval]) -> [DateInterval] {
        guard let start = samples.map(\.start).min(), let end = samples.map(\.end).max() else { return [] }
        return LifeAggregation.mergedSleepIntervals(samples, within: .init(start: start, end: end))
    }
    static func duration(_ seconds: TimeInterval) -> String { "\(Int(seconds) / 3600)小时\(Int(seconds) / 60 % 60)分" }
    static func clock(_ date: Date) -> String { date.formatted(date: .omitted, time: .shortened) }
}
