import Foundation

@main
struct SpeakerTimelineSmoke {
    static func main() throws {
        var note = VoiceNote(id: UUID(), kind: .long, capturedAt: .now, duration: 60)
        note.transcript = "ABCDEFG"
        let words = [(0.0, 1.0, "A"), (1.1, 2.0, "B"), (3.0, 4.0, "C"), (4.1, 5.0, "D"),
            (6.0, 7.0, "E"), (8.0, 9.0, "F"), (10.0, 11.0, "G")].map { TranscriptSegment(start: $0.0, end: $0.1, text: $0.2) }
        let turns = [SpeakerTurn(start: 3, end: 5.5, speakerID: "raw-b"),
            SpeakerTurn(start: 0, end: 2.5, speakerID: "raw-a"),
            SpeakerTurn(start: 6, end: 6.5, speakerID: "raw-a"),
            SpeakerTurn(start: 6.5, end: 7, speakerID: "raw-b"),
            SpeakerTurn(start: 8, end: 9, speakerID: "raw-a"),
            SpeakerTurn(start: 8.1, end: 9, speakerID: "raw-b"),
            SpeakerTurn(start: -2, end: 0, speakerID: "invalid"),
            SpeakerTurn(start: 61, end: 63, speakerID: "outside"),
            SpeakerTurn(start: .nan, end: 10, speakerID: "invalid")]
        var result = SpeakerDiarization.aligned(turns: turns, words: words, note: note, model: "synthetic")
        precondition(result.speakerIDs == ["S1", "S2"], "speaker IDs follow first appearance within this recording")
        precondition(result.segments.count == 5, "merge adjacent words only within the same speaker and uncertainty class")
        precondition(result.segments[0].text == "AB" && result.segments[0].speakerID == "S1")
        precondition(result.segments[1].text == "CD" && result.segments[1].speakerID == "S2")
        precondition(result.segments[2].text == "E" && result.segments[2].speakerID == nil && !result.segments[2].overlapping,
            "a word spanning a speaker change remains unconfirmed, rather than fabricating a text boundary")
        precondition(result.segments[3].text == "F" && result.segments[3].speakerID == nil && result.segments[3].overlapping)
        precondition(result.segments[4].text == "G" && result.segments[4].speakerID == nil, "uncovered words keep text without attribution")
        precondition(result.segments.map(\.text).joined() == note.transcript, "never duplicate or drop timed words to force speaker labels")
        precondition(result.matches(note))
        var edited = note
        edited.transcript += "修改"
        precondition(!result.matches(edited))
        edited = VoiceNote(id: note.id, kind: note.kind, capturedAt: note.capturedAt, duration: note.duration + 1)
        edited.transcript = note.transcript
        precondition(!result.matches(edited), "stale audio bindings cannot display a speaker result")
        precondition(result.name(for: "S1") == "发言人 1")
        result.names["S1"] = "参会人甲"
        precondition(result.label(for: result.segments[0]) == "参会人甲")
        precondition(result.label(for: result.segments[3]).contains("多人重叠"))
        let reloaded = try JSONDecoder().decode(SpeakerDiarization.self, from: JSONEncoder().encode(result))
        precondition(reloaded == result, "turns, timestamps and user names survive a reload")
        let duplicate = SpeakerDiarization.aligned(turns: [SpeakerTurn(start: 0, end: 0.4, speakerID: "a"),
            SpeakerTurn(start: 0, end: 0.4, speakerID: "a")], words: [words[0]], note: note, model: "synthetic")
        precondition(duplicate.segments[0].speakerID == nil, "duplicate turns cannot inflate covered duration")
        let coarse = SpeakerDiarization.aligned(turns: [SpeakerTurn(start: 0, end: 6, speakerID: "a"),
            SpeakerTurn(start: 6, end: 12, speakerID: "b")],
            words: [TranscriptSegment(start: 0, end: 12, text: "一段较粗的旧时间戳")], note: note, model: "synthetic")
        precondition(coarse.segments.count == 1 && coarse.segments[0].speakerID == nil,
            "legacy grouped timestamps are not split by character count")
        print("SpeakerTimelineSmoke passed (alignment, boundaries, overlap, unknown, grouping, no text fabrication, binding, names, persistence)")
    }
}
