import Foundation

/// Sweep speaker intervals before selecting samples: simultaneous speakers are excluded.
enum VoiceSpeechSelection {
    static func enrollmentRanges(turns: [SpeakerTurn], sampleCount: Int) throws -> [[Range<Int>]] {
        let overlap = selectedRanges(turns: turns, sampleCount: sampleCount) { $0.count > 1 }
        guard overlap.reduce(0, { $0 + $1.count }) < 2 * 16_000 else { throw VoiceEnrollmentError.multipleVoices }
        let candidates = Set(turns.map(\.speaker)).map { speaker in
            // Count each speaker's full union, including overlap with other speakers.
            // Otherwise a fully overlapped second voice would count as zero.
            let fullRanges = ranges(turns: turns.filter { $0.speaker == speaker }, speaker: speaker, sampleCount: sampleCount)
            return (speaker: speaker, count: fullRanges.reduce(0) { $0 + $1.count })
        }.filter { $0.count >= 2 * 16_000 }.sorted { $0.speaker < $1.speaker }
        var groups: [[Range<Int>]] = []
        for candidate in candidates {
            let clean = ranges(turns: turns, speaker: candidate.speaker, sampleCount: sampleCount)
            // Every substantial cluster must contribute usable evidence. Do not silently
            // omit another speaker whose clean audio is too short after removing overlap.
            guard clean.reduce(0, { $0 + $1.count }) >= 2 * 16_000 else { throw VoiceEnrollmentError.insufficientSpeech }
            groups.append(clean)
        }
        guard groups.flatMap({ $0 }).reduce(0, { $0 + $1.count }) >= 15 * 16_000 else { throw VoiceEnrollmentError.insufficientSpeech }
        // Sequential clusters may be one over-split voice. Keep them separate until the
        // unchanged all-pairs embedding policy verifies consistency across every cluster.
        return groups
    }

    static func ranges(turns: [SpeakerTurn], speaker: Int, sampleCount: Int) -> [Range<Int>] {
        selectedRanges(turns: turns, sampleCount: sampleCount) { $0.count == 1 && $0.contains(speaker) }
    }

    private static func selectedRanges(turns: [SpeakerTurn], sampleCount: Int, include: (Set<Int>) -> Bool) -> [Range<Int>] {
        guard sampleCount > 0 else { return [] }
        struct Edge { let sample: Int; let speaker: Int; let delta: Int }
        var edges: [Edge] = []
        for turn in turns where turn.start.isFinite && turn.end.isFinite && turn.end > turn.start {
            let start = Int(min(Double(sampleCount), max(0, turn.start * 16_000)))
            let end = Int(min(Double(sampleCount), max(0, turn.end * 16_000)))
            guard end > start else { continue }
            edges.append(.init(sample: start, speaker: turn.speaker, delta: 1))
            edges.append(.init(sample: end, speaker: turn.speaker, delta: -1))
        }
        edges.sort { $0.sample < $1.sample }
        var active: [Int: Int] = [:], previous = 0
        var result: [Range<Int>] = []
        for edge in edges {
            if edge.sample > previous, include(Set(active.keys)) {
                if let last = result.last, last.upperBound == previous {
                    result[result.count - 1] = last.lowerBound..<edge.sample
                } else { result.append(previous..<edge.sample) }
            }
            let count = (active[edge.speaker] ?? 0) + edge.delta
            active[edge.speaker] = count > 0 ? count : nil
            previous = edge.sample
        }
        return result
    }

    /// Concatenate only clean speech; do not pad silence, overlap or gaps into enrollment.
    static func windows(samples: [Float], ranges: [Range<Int>], limit: Int) -> [[Float]] {
        guard limit > 0 else { return [] }
        let size = 80_000, minimum = 32_000
        var output: [[Float]] = [], current: [Float] = []
        current.reserveCapacity(size)
        for range in ranges {
            var start = max(0, range.lowerBound)
            let end = min(samples.count, range.upperBound)
            while start < end {
                let take = min(size - current.count, end - start)
                current.append(contentsOf: samples[start..<(start + take)])
                start += take
                if current.count == size {
                    output.append(current); current = []; current.reserveCapacity(size)
                    if output.count == limit { return output }
                }
            }
        }
        if current.count >= minimum { output.append(current) }
        return output
    }
}

struct VoiceDiarizationOutput: Sendable {
    var segments: [TranscriptSegment]
    var ownerSpeakerIDs: Set<String> = []
    var profileID: UUID?
    var identityMessage: String?
}

enum VoiceEnrollmentError: LocalizedError {
    case duration, soloConfirmation, insufficientSpeech, multipleVoices
    var errorDescription: String? {
        switch self {
        case .duration: NSLocalizedString("请录制 30～60 秒后再保存。", comment: "")
        case .soloConfirmation: NSLocalizedString("请先确认录音中只有你一个人在讲话。", comment: "")
        case .insufficientSpeech: NSLocalizedString("清晰讲话的时间不足，请在安静环境中多说几句话后重录。", comment: "")
        case .multipleVoices: NSLocalizedString("检测到多种声音或明显的声音变化，请独自讲话并重新录制。", comment: "")
        }
    }
}
