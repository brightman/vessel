import Foundation

struct TranscriptSegment: Codable, Equatable, Identifiable {
    var id: String { "\(start)-\(end)" }
    let start: TimeInterval
    let end: TimeInterval
    let text: String
}

struct SpeakerTurn: Codable, Equatable {
    let start: TimeInterval
    let end: TimeInterval
    let speakerID: String
}

struct SpeakerTranscriptSegment: Codable, Equatable, Identifiable {
    let id: UUID
    let start: TimeInterval
    let end: TimeInterval
    let text: String
    let speakerID: String?
    let overlapping: Bool
}

struct SpeakerDiarization: Codable, Equatable {
    let turns: [SpeakerTurn]
    let segments: [SpeakerTranscriptSegment]
    let transcript: String
    let audioFilename: String
    let duration: TimeInterval
    let model: String
    let generatedAt: Date
    var names: [String: String] = [:]

    var speakerIDs: [String] {
        var seen = Set<String>()
        return turns.compactMap { seen.insert($0.speakerID).inserted ? $0.speakerID : nil }
    }

    func name(for id: String) -> String { names[id] ?? "发言人 \((speakerIDs.firstIndex(of: id) ?? 0) + 1)" }

    func label(for segment: SpeakerTranscriptSegment) -> String {
        if let id = segment.speakerID { return name(for: id) }
        return segment.overlapping ? "多人重叠／待确认" : "发言人待确认"
    }

    func matches(_ note: VoiceNote) -> Bool {
        audioFilename == note.audioFilename && transcript == note.transcript && duration.isFinite
            && abs(duration - note.duration) < 0.1
    }

    /// Align only measured ASR ranges with acoustic turns. Never split text proportionally to time.
    static func aligned(turns incoming: [SpeakerTurn], words: [TranscriptSegment], note: VoiceNote, model: String) -> Self {
        var bounded: [SpeakerTurn] = []
        for turn in incoming {
            guard turn.start.isFinite, turn.end.isFinite, turn.start >= 0,
                  turn.end > turn.start, turn.start < note.duration, !turn.speakerID.isEmpty else { continue }
            bounded.append(SpeakerTurn(start: turn.start, end: min(turn.end, note.duration), speakerID: turn.speakerID))
        }
        bounded.sort { lhs, rhs in
            if lhs.start == rhs.start { return lhs.speakerID < rhs.speakerID }
            return lhs.start < rhs.start
        }
        // Labels are scoped to this recording, in order of first appearance. No persistent voiceprints.
        var ids: [String: String] = [:]
        let turns = bounded.map { turn -> SpeakerTurn in
            if ids[turn.speakerID] == nil { ids[turn.speakerID] = "S\(ids.count + 1)" }
            return SpeakerTurn(start: turn.start, end: turn.end, speakerID: ids[turn.speakerID]!)
        }
        var segments: [SpeakerTranscriptSegment] = []
        var cursor = 0
        var active: [SpeakerTurn] = []
        for word in words.sorted(by: { $0.start < $1.start }) where word.start.isFinite && word.end.isFinite
            && word.start >= 0 && word.end > word.start && word.end <= note.duration + 1 {
            active.removeAll { $0.end <= word.start }
            while cursor < turns.count, turns[cursor].start < word.end {
                if turns[cursor].end > word.start { active.append(turns[cursor]) }
                cursor += 1
            }
            var intervals: [String: [ClosedRange<Double>]] = [:]
            for turn in active {
                let lower = max(word.start, turn.start), upper = min(word.end, turn.end)
                if upper > lower { intervals[turn.speakerID, default: []].append(lower...upper) }
            }
            // Union repeated/overlapping intervals for each speaker so duplicates cannot inflate confidence.
            var coverage: [(String, Double)] = []
            for (id, ranges) in intervals {
                var total = 0.0, lower = 0.0, upper = 0.0
                for range in ranges.sorted(by: { $0.lowerBound < $1.lowerBound }) {
                    if range.lowerBound > upper { total += upper - lower; lower = range.lowerBound; upper = range.upperBound }
                    else { upper = max(upper, range.upperBound) }
                }
                total += upper - lower
                coverage.append((id, total / (word.end - word.start)))
            }
            coverage.sort { $0.1 == $1.1 ? $0.0 < $1.0 : $0.1 > $1.1 }
            var overlap = false
            let speakers = intervals.keys.sorted()
            for (index, id) in speakers.enumerated() {
                for other in speakers.dropFirst(index + 1) {
                    for a in intervals[id]! {
                        for b in intervals[other]! {
                            if min(a.upperBound, b.upperBound) - max(a.lowerBound, b.lowerBound) > (word.end - word.start) * 0.15 {
                                overlap = true
                            }
                        }
                    }
                }
            }
            let speaker = !overlap && (coverage.first?.1 ?? 0) >= 0.75 && (coverage.dropFirst().first?.1 ?? 0) <= 0.2 ? coverage.first?.0 : nil
            if let last = segments.last, last.speakerID == speaker, last.overlapping == overlap,
               word.start >= last.start, word.start - last.end < 1.2,
               word.end - last.start <= 25, last.text.count + word.text.count <= 180 {
                segments[segments.count - 1] = SpeakerTranscriptSegment(id: last.id, start: last.start,
                    end: max(last.end, word.end), text: last.text + word.text, speakerID: speaker, overlapping: overlap)
            } else {
                segments.append(SpeakerTranscriptSegment(id: UUID(), start: word.start, end: word.end,
                    text: word.text, speakerID: speaker, overlapping: overlap))
            }
        }
        return Self(turns: turns, segments: segments, transcript: note.transcript, audioFilename: note.audioFilename,
            duration: note.duration, model: model, generatedAt: .now)
    }
}
