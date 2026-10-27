import Foundation

enum ContentProcessingState: String, Codable, Sendable { case pending, processed, processedNoSpeech }
enum ContentSegmentClassification: String, Codable, Sendable { case meaningful, lowInformation, pendingConfirmation }
struct ContentSegmentDraft: Equatable, Sendable {
    let ranges: [AudioSourceRange]
    let boundaryReady: Bool
}
struct ContentSegmentationResult: Sendable {
    let segments: [ContentSegmentDraft]
    let state: ContentProcessingState
}
enum ContentSegmentation {
    static func build(source: AudioSourceSnapshot, reliableNoSpeech: [AudioTimeRange], successfulCoverage: [AudioTimeRange], asrEmpty: [AudioTimeRange] = [], transcriptRanges: [AudioTimeRange] = [], keepAsSingleRecording: Bool = false) throws -> ContentSegmentationResult {
        try source.validate()
        for interval in reliableNoSpeech + successfulCoverage + asrEmpty + transcriptRanges { try interval.validate() }
        let silence = normalized(reliableNoSpeech)
        let coverage = normalized(successfulCoverage)
        var groups: [[AudioSourceRange]] = []
        for range in source.ranges {
            if let last = groups.last?.last, range.discontinuityBefore == nil, range.sessionStartOffset <= last.end + 0.0000001 {
                groups[groups.count-1].append(range)
            } else { groups.append([range]) }
        }
        var drafts: [ContentSegmentDraft] = []
        var allCovered = true
        for group in groups {
            let start = group[0].sessionStartOffset, end = group.last!.end
            let covered = covers(coverage,start:start,end:end)
            allCovered = allCovered && covered
            if covered && covers(silence,start:start,end:end) { continue }
            // Only dual-success coverage may supply a silence boundary.
            let gaps = intersect(silence,coverage).compactMap { value -> AudioTimeRange? in
                let a = max(start,value.start), b = min(end,value.end)
                return b-a >= 600 ? .init(start:a,end:b) : nil
            }
            var cursor = start
            for gap in gaps {
                if gap.start > cursor {
                    let stop = min(end,gap.start+2)
                    drafts.append(.init(ranges:try AudioWindowPlanner.slices(group,start:cursor,end:stop),boundaryReady:covers(coverage,start:cursor,end:stop)))
                }
                cursor = gap.end == end ? end : max(cursor,gap.end-2)
            }
            if cursor < end {
                drafts.append(.init(ranges:try AudioWindowPlanner.slices(group,start:cursor,end:end),boundaryReady:source.complete && covers(coverage,start:cursor,end:end)))
            }
        }
        if keepAsSingleRecording {
            let whole = source.ranges.isEmpty ? [] : [ContentSegmentDraft(
                ranges:source.ranges,
                boundaryReady:source.complete && allCovered
            )]
            let done = source.complete && !source.ranges.isEmpty && allCovered
            return .init(segments:whole,state:done ? .processed : .pending)
        }
        // ASR-empty successful coverage is retained as a low-information chapter. It is
        // not acoustic silence and cannot authorize dropping media or transcript rows.
        let speech = normalized(transcriptRanges)
        var separated: [ContentSegmentDraft] = []
        for draft in drafts {
            guard let start=draft.ranges.first?.sessionStartOffset, let end=draft.ranges.last?.end else { continue }
            let blanks=normalized(asrEmpty).filter { $0.end-$0.start >= 180 }
            let cuts=blanks.flatMap { blank -> [Double] in
                let gap=AudioTimeRange(start:max(start,blank.start),end:min(end,blank.end))
                guard gap.end > gap.start else { return [] }
                return [blank.start-start <= 2 ? nil : safeFrameCut(near:gap.start,in:gap,ranges:draft.ranges),end-blank.end <= 2 ? nil : safeFrameCut(near:gap.end,in:gap,ranges:draft.ranges)].compactMap { $0 }
            }.filter { $0 > start && $0 < end }
            for piece in try applyingTopicCuts(cuts,to:[draft]) {
                guard let a=piece.ranges.first?.sessionStartOffset, let b=piece.ranges.last?.end else { continue }
                var cursor=a
                while b-cursor > 1800 {
                    let target=cursor+1800, cap=min(b,cursor+2400)
                    // Cut inside a real transcript-free gap, outside the closure of
                    // overlapping rows. Exact ASR endpoints may round to adjacent audio
                    // frames; an interior frame prevents assigning a raw row twice.
                    let gaps=subtract([.init(start:cursor,end:cap)],speech)
                    let safe=gaps.compactMap { safeFrameCut(near:target,in:$0,ranges:piece.ranges) }
                    let cut=safe.min { abs($0-target) < abs($1-target) } ?? cap
                    separated.append(.init(ranges:try AudioWindowPlanner.slices(piece.ranges,start:cursor,end:cut),boundaryReady:piece.boundaryReady))
                    cursor=cut
                }
                if cursor < b { separated.append(.init(ranges:try AudioWindowPlanner.slices(piece.ranges,start:cursor,end:b),boundaryReady:piece.boundaryReady)) }
            }
        }
        drafts=separated
        let done = source.complete && !source.ranges.isEmpty && allCovered
        return .init(segments:drafts,state:done ? (drafts.isEmpty ? .processedNoSpeech : .processed) : .pending)
    }

    private static func safeFrameCut(near target: Double, in gap: AudioTimeRange, ranges: [AudioSourceRange]) -> Double? {
        var candidates: [Double] = []
        for range in ranges {
            let low=max(gap.start,range.sessionStartOffset), high=min(gap.end,range.end)
            guard high > low else { continue }
            let inset=min(1/range.sampleRate,(high-low)/3)
            let desired=max(low+inset,min(high-inset,target))
            let frame=((desired-range.sessionStartOffset)*range.sampleRate).rounded(.toNearestOrEven)
            let cut=range.sessionStartOffset+frame/range.sampleRate
            guard cut > gap.start, cut < gap.end, cut >= range.sessionStartOffset, cut <= range.end else { continue }
            candidates.append(cut)
        }
        return candidates.min { abs($0-target) < abs($1-target) }
    }

    static func applyingTopicCuts(_ cuts: [Double], to drafts: [ContentSegmentDraft]) throws -> [ContentSegmentDraft] {
        var output: [ContentSegmentDraft] = []
        for draft in drafts {
            guard let first=draft.ranges.first, let last=draft.ranges.last else { continue }
            var cursor=first.sessionStartOffset
            for cut in Set(cuts).sorted() where cut > cursor && cut < last.end {
                guard draft.ranges.contains(where:{ cut >= $0.sessionStartOffset && cut <= $0.end }) else { continue }
                let ranges=try AudioWindowPlanner.slices(draft.ranges,start:cursor,end:cut)
                if !ranges.isEmpty { output.append(.init(ranges:ranges,boundaryReady:draft.boundaryReady)); cursor=cut }
            }
            let tail=try AudioWindowPlanner.slices(draft.ranges,start:cursor,end:last.end)
            if !tail.isEmpty { output.append(.init(ranges:tail,boundaryReady:draft.boundaryReady)) }
        }
        return output
    }

    static func normalized(_ values: [AudioTimeRange]) -> [AudioTimeRange] {
        var output: [AudioTimeRange] = []
        for value in values.sorted(by: { $0.start < $1.start }) where value.end > value.start {
            if let last = output.last, value.start <= last.end + 0.0000001 {
                output[output.count-1] = .init(start:last.start,end:max(last.end,value.end))
            } else { output.append(value) }
        }
        return output
    }
    static func intersect(_ lhs: [AudioTimeRange], _ rhs: [AudioTimeRange]) -> [AudioTimeRange] {
        var output: [AudioTimeRange] = [], i = 0, j = 0
        while i < lhs.count && j < rhs.count {
            let a = max(lhs[i].start,rhs[j].start), b = min(lhs[i].end,rhs[j].end)
            if b > a { output.append(.init(start:a,end:b)) }
            if lhs[i].end < rhs[j].end { i += 1 } else { j += 1 }
        }
        return normalized(output)
    }
    static func subtract(_ values: [AudioTimeRange], _ removed: [AudioTimeRange]) -> [AudioTimeRange] {
        var output: [AudioTimeRange] = []
        let cuts = normalized(removed)
        var first = 0
        for value in values {
            var cursor = value.start
            while first < cuts.count && cuts[first].end <= cursor { first += 1 }
            var index = first
            while index < cuts.count && cuts[index].start < value.end {
                if cuts[index].start > cursor { output.append(.init(start:cursor,end:min(value.end,cuts[index].start))) }
                cursor = max(cursor,cuts[index].end)
                if cursor >= value.end { break }
                index += 1
            }
            if cursor < value.end { output.append(.init(start:cursor,end:value.end)) }
        }
        return output
    }
    static func covers(_ values: [AudioTimeRange], start: Double, end: Double) -> Bool {
        values.contains { $0.start <= start + 0.0000001 && $0.end >= end - 0.0000001 }
    }
}

struct ContentSegmentProvenance: Codable, Equatable, Sendable {
    let algorithmVersion: String
    let configurationKey: String
    let contentSignature: String
    /// Older cache keys are retained after proving equivalence to this locator-free digest.
    var semanticContentSignature: String? = nil
}
struct ContentSegment: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let sourceID: AudioSourceID
    var sourceRevision: Int
    var ranges: [AudioSourceRange]
    var title: String
    var summary: String
    var revision: Int
    var isManual: Bool
    var isFinal: Bool
    /// Whether this range has complete successful ASR/VAD coverage and a closed
    /// deterministic/manual boundary. Topic inference is a separate finalization gate.
    var boundaryReady: Bool? = nil
    var hasText: Bool
    var provenance: ContentSegmentProvenance
    /// Optional so existing on-device content remains readable. This is persisted
    /// editorial output, not a heuristic derived each time the timeline opens.
    var editorial: ContentSegmentEditorial? = nil
    /// Missing in older stores means model-generated, so adaptive enrichment may refresh it.
    var titleManuallyEdited: Bool? = nil
    var displayTitle: String {
        if !title.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty { return title }
        return hasText ? "录音片段" : (isFinal || boundaryReady == true ? "未识别到文字" : "等待识别")
    }
}
struct ContentSegmentEditorial: Codable, Equatable, Sendable {
    let classification: String
    let engineVersion: String
    let model: String
    let evidenceBlockIDs: [String]
}
enum ContentSegmentError: Error { case notFound, staleRevision, invalidEdit, undoConflict }
struct ContentSegmentationTraversal: Sendable {
    var activityRows = 0
    var spanRows = 0
    var maximumPageRows = 0
    var reusedSnapshot = false
}
