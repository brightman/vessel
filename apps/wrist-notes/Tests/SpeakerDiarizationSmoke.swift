import Foundation

@main
struct SpeakerDiarizationSmoke {
    static func main() throws {
        var original = VoiceNote(id: UUID(), kind: .long, capturedAt: Date(timeIntervalSince1970: 100), duration: 12)
        original.transcript = "你好。 再见。"
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as! [String: Any]
        let segmentID = UUID().uuidString
        json["transcriptSegments"] = [["id": segmentID, "start": 0.2, "end": 2.0, "text": "你好。", "speakerID": "speaker-1"]]
        json["speakerNames"] = ["speaker-1": "小明"]
        json["diarizationState"] = "ready"
        let note = try JSONDecoder().decode(VoiceNote.self, from: JSONSerialization.data(withJSONObject: json))
        let reencoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(note)) as! [String: Any]
        guard (reencoded["speakerNames"] as? [String: String])?["speaker-1"] == "小明",
              (reencoded["transcriptSegments"] as? [[String: Any]])?.first?["id"] as? String == segmentID else {
            fputs("FAIL: persisted transcript speaker labels were discarded on decode/encode\n", stderr)
            exit(1)
        }
        // Old indexes still load; names survive an actual repository restart.
        let legacy = try JSONDecoder().decode(VoiceNote.self, from: JSONEncoder().encode(original))
        precondition(legacy.transcriptSegments == nil)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = try NoteRepository(root: root)
        let audio = root.appendingPathComponent("fixture.m4a")
        try Data([1, 2]).write(to: audio)
        _ = try repository.importRecording(id: note.id, from: audio, kind: .long, capturedAt: .now, duration: 12)
        try repository.update(id: note.id) { $0 = note; $0.renameSpeaker("speaker-1", name: "  Alice  ") }
        let reopened = try NoteRepository(root: root)
        precondition(reopened.notes[0].speakerName("speaker-1") == "Alice")

        let timed = TimedTranscriptBuilder.segments([
            .init(text: "（", start: nil, end: nil),
            .init(text: "你好", start: 1, end: 2),
            .init(text: "，", start: nil, end: nil),
            .init(text: "世界", start: 3, end: 4),
            .init(text: "。）", start: nil, end: nil)
        ], fallbackStart: 0, fallbackEnd: 5)
        precondition(timed.map(\.text).joined() == "（你好，世界。）")
        precondition(timed.count == 2 && timed[1].text == "世界。）")
        let pieces = [TranscriptSegment(start: 0, end: 1, text: "你好。"),
                      TranscriptSegment(start: 1.1, end: 2, text: " Hi."),
                      TranscriptSegment(start: 3, end: 4, text: " Bye."),
                      TranscriptSegment(start: 9, end: 10, text: " 未匹配")]
        let turns = [SpeakerTurn(start: 0, end: 2.2, speaker: 8),
                     SpeakerTurn(start: 3, end: 4.1, speaker: 3)]
        let aligned = SpeakerAlignment.align(pieces, turns: turns)
        precondition(aligned.count == 3)
        precondition(aligned[0].text == "你好。 Hi." && aligned[0].speakerID == "speaker-1")
        precondition(aligned[1].speakerID == "speaker-2")
        precondition(aligned[2].speakerID == nil, "Unmatched text must not acquire a guessed speaker")
        precondition(aligned.map(\.text).joined() == "你好。 Hi. Bye. 未匹配")
        // Ambiguous overlap and invalid ranges remain unassigned.
        let overlap = SpeakerAlignment.align([pieces[0]], turns: [
            SpeakerTurn(start: 0, end: 1, speaker: 1), SpeakerTurn(start: 0, end: 1, speaker: 2),
            SpeakerTurn(start: .nan, end: 1, speaker: 3)])
        precondition(overlap[0].speakerID == nil)
        // A word near a turn boundary goes to the speaker with greatest overlap.
        let boundary = SpeakerAlignment.align([TranscriptSegment(start: 0.8, end: 1.5, text: "word")], turns: [
            SpeakerTurn(start: 0, end: 1, speaker: 0), SpeakerTurn(start: 1, end: 2, speaker: 1)])
        precondition(boundary.first?.speakerID == "speaker-2")

        var edited = note
        let revision = edited.transcriptRevision
        edited.applyEdit(title: edited.title, transcript: "manual edit")
        precondition(edited.transcriptSegments == nil && edited.speakerNames == nil)
        precondition(!edited.applyDiarization(aligned, expectedRevision: revision))
        edited.applyTranscription(.init(text: "你好。 Hi. Bye. 未匹配", segments: aligned))
        edited.renameSpeaker("speaker-1", name: "Alice")
        let segment = edited.transcriptSegments![0]
        edited.summary = "stale"
        edited.editSegment(segment.id, text: "修改。 ")
        precondition(edited.transcript == "修改。  Bye. 未匹配")
        precondition(edited.transcriptSegments![0].start == 0 && edited.transcriptSegments![0].end == 2)
        precondition(edited.speakerName("speaker-1") == "Alice" && edited.summary.isEmpty)
        edited.applyTranscription(.init(text: "new run", segments: pieces))
        precondition(edited.speakerNames == nil, "Names cannot be applied to IDs from a new clustering")
        print("Speaker persistence, legacy decoding, alignment, rename, editing and revision protection: passed")
    }
}
