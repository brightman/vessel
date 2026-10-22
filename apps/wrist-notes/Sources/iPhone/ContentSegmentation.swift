import Foundation

enum ContentProcessingState: String, Codable, Sendable { case pending, processed, processedNoSpeech }
struct ContentSegmentDraft: Equatable, Sendable {
    let ranges: [AudioSourceRange]
    let isFinal: Bool
}
struct ContentSegmentationResult: Sendable {
    let segments: [ContentSegmentDraft]
    let state: ContentProcessingState
}
enum ContentSegmentation {
    static func build(source: AudioSourceSnapshot, reliableNoSpeech: [AudioTimeRange], successfulCoverage: [AudioTimeRange]) throws -> ContentSegmentationResult {
        try source.validate()
        for interval in reliableNoSpeech + successfulCoverage { try interval.validate() }
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
                    drafts.append(.init(ranges:try AudioWindowPlanner.slices(group,start:cursor,end:stop),isFinal:covers(coverage,start:cursor,end:stop)))
                }
                cursor = gap.end == end ? end : max(cursor,gap.end-2)
            }
            if cursor < end {
                drafts.append(.init(ranges:try AudioWindowPlanner.slices(group,start:cursor,end:end),isFinal:source.complete && covers(coverage,start:cursor,end:end)))
            }
        }
        let done = source.complete && !source.ranges.isEmpty && allCovered
        return .init(segments:drafts,state:done ? (drafts.isEmpty ? .processedNoSpeech : .processed) : .pending)
    }

    static func applyingTopicCuts(_ cuts: [Double], to drafts: [ContentSegmentDraft]) throws -> [ContentSegmentDraft] {
        var output: [ContentSegmentDraft] = []
        for draft in drafts {
            guard let first=draft.ranges.first, let last=draft.ranges.last else { continue }
            var cursor=first.sessionStartOffset
            for cut in Set(cuts).sorted() where cut > cursor && cut < last.end {
                guard draft.ranges.contains(where:{ cut >= $0.sessionStartOffset && cut <= $0.end }) else { continue }
                let ranges=try AudioWindowPlanner.slices(draft.ranges,start:cursor,end:cut)
                if !ranges.isEmpty { output.append(.init(ranges:ranges,isFinal:draft.isFinal)); cursor=cut }
            }
            let tail=try AudioWindowPlanner.slices(draft.ranges,start:cursor,end:last.end)
            if !tail.isEmpty { output.append(.init(ranges:tail,isFinal:draft.isFinal)) }
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
    var hasText: Bool
    var provenance: ContentSegmentProvenance
}
enum ContentSegmentError: Error { case notFound, staleRevision, invalidEdit, undoConflict }
struct ContentSegmentationTraversal: Sendable {
    var activityRows = 0
    var spanRows = 0
    var maximumPageRows = 0
    var reusedSnapshot = false
}
