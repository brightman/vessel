import Foundation
import CryptoKit

enum AudioWindowPlanner {
    static let algorithmVersion = "frames-midpoint-v1"
    static func plan(source: AudioSourceSnapshot, configurationKey: String, maximumCoreDuration: Double = 300) throws -> [AudioProcessingWindow] {
        try source.validate()
        guard !configurationKey.isEmpty, maximumCoreDuration.isFinite, maximumCoreDuration > 0, maximumCoreDuration <= 300 else { throw AudioProcessingError.invalidInput }
        var groups: [[AudioSourceRange]] = []
        for range in source.ranges {
            if let last = groups.last?.last, range.discontinuityBefore == nil,
               abs(last.end - range.sessionStartOffset) < 0.0000001 {
                groups[groups.count - 1].append(range)
            } else { groups.append([range]) }
        }
        var windows: [AudioProcessingWindow] = []
        for (index, group) in groups.enumerated() {
            let start = group[0].sessionStartOffset, end = group.last!.end
            // A following hard gap closes the preceding run. The receiving tail needs 2s context.
            let closed = source.complete || index < groups.count - 1
            var cursor = start
            while cursor < end {
                let requestedEnd = min(cursor + maximumCoreDuration, end)
                if !closed && requestedEnd + 2 > end { break }
                // Core boundaries are snapped down to a real source frame.
                guard let owning = group.first(where: { requestedEnd <= $0.end && requestedEnd > $0.sessionStartOffset }) else { throw AudioProcessingError.invalidInput }
                var count = frameOffset(at: requestedEnd, in: owning, rounding: .down)
                var coreEnd = owning.sessionStartOffset + Double(count) / owning.sampleRate
                // A snapped frame may represent its timestamp one ULP above the 300s cap.
                if coreEnd - cursor > maximumCoreDuration {
                    count -= 1
                    coreEnd = owning.sessionStartOffset + Double(count) / owning.sampleRate
                }
                guard coreEnd > cursor else { throw AudioProcessingError.invalidInput }
                let slices = try slices(group, start: max(start, cursor - 2), end: min(end, coreEnd + 2))
                struct Identity: Encodable {
                    let algorithm: String; let source: AudioSourceID; let config: String
                    let coreStart: Double; let coreEnd: Double; let ranges: [AudioSourceRange]
                }
                let id = AudioStableID.make(Identity(algorithm: algorithmVersion, source: source.id, config: configurationKey, coreStart: cursor, coreEnd: coreEnd, ranges: slices))
                windows.append(AudioProcessingWindow(id: id, sourceID: source.id, configurationKey: configurationKey, coreStart: cursor, coreEnd: coreEnd, ranges: slices))
                cursor = coreEnd
            }
        }
        return windows
    }

    /// Only whole frames inside the available request are read; no fabricated gap/silence.
    static func slices(_ ranges: [AudioSourceRange], start: Double, end: Double) throws -> [AudioSourceRange] {
        guard start.isFinite, end.isFinite, start >= 0, end > start else { throw AudioProcessingError.invalidInput }
        var result: [AudioSourceRange] = []
        for range in ranges {
            try range.validate()
            let low = max(start, range.sessionStartOffset), high = min(end, range.end)
            guard high > low else { continue }
            let a = frameOffset(at: low, in: range, rounding: .up)
            let b = frameOffset(at: high, in: range, rounding: .down)
            guard b > a else { continue }
            result.append(try AudioSourceRange(range: RecordingSourceRange(chunkID: range.chunkID, url: range.url, startFrame: range.startFrame + a, endFrame: range.startFrame + b, sampleRate: range.sampleRate, sessionStartOffset: range.sessionStartOffset + Double(a) / range.sampleRate, discontinuityBefore: range.discontinuityBefore), contentHash: range.contentHash))
        }
        return result
    }

    private static func frameOffset(at time: Double, in range: AudioSourceRange,
                                    rounding: FloatingPointRoundingRule) -> Int64 {
        let maximum = range.endFrame - range.startFrame
        // Preserve known integer endpoints, avoiding a lossy seconds -> frames round trip.
        if time == range.sessionStartOffset { return 0 }
        if time == range.end { return maximum }
        let value = (time - range.sessionStartOffset) * range.sampleRate
        let nearest = value.rounded(.toNearestOrEven)
        // Subtracting an absolute source offset can amplify timestamp representation error.
        // Snap only within the ULP error bound of those operations, never a fixed time epsilon.
        let uncertainty = 2 * ((time.ulp + range.sessionStartOffset.ulp) * range.sampleRate + value.ulp)
        let corrected = uncertainty < 0.5 && abs(value - nearest) <= uncertainty ? nearest : value
        let rounded = corrected.rounded(rounding)
        // Compare BEFORE integer conversion: Double(Int64.max) rounds above Int64.max.
        if rounded >= Double(maximum) { return maximum }
        if rounded <= 0 { return 0 }
        return Int64(rounded)
    }

    static func ownedSpans(_ spans: [AudioTranscriptSpan], window: AudioProcessingWindow) throws -> [AudioTranscriptSpan] {
        var result: [AudioTranscriptSpan] = []
        for span in spans {
            try AudioTimeRange(start: span.start, end: span.end).validate()
            let midpoint = span.start + (span.end - span.start) / 2
            guard midpoint >= window.coreStart && midpoint < window.coreEnd else { continue }
            let start = max(window.inputStart, span.start), end = min(window.inputEnd, span.end)
            if end > start { result.append(AudioTranscriptSpan(start: start, end: end, text: span.text, speakerID: span.speakerID)) }
        }
        return result
    }
}

enum AudioStableID {
    static func make<T: Encodable>(_ value: T) -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        // Called only after validation; all encoded values are finite.
        guard let bytes = try? encoder.encode(value) else { preconditionFailure("Invalid audio identity") }
        return SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }
}
