import Foundation

@main struct VoiceOwnerSmoke {
    static func main() throws {
        var note = VoiceNote(id: UUID(), kind: .long, capturedAt: .now, duration: 40)
        let pieces = [TranscriptSegment(start: 0, end: 10, text: "hello", speakerID: "speaker-1")]
        note.applyTranscription(.init(text: "hello", segments: pieces))
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(note)) as! [String: Any]
        json["ownerSpeakerIDs"] = ["speaker-1"]
        var decoded = try JSONDecoder().decode(VoiceNote.self, from: JSONSerialization.data(withJSONObject: json))
        guard decoded.speakerName("speaker-1") == "我" else {
            fputs("FAIL automatic owner match does not survive note decoding\n", stderr); exit(1)
        }
        decoded.renameSpeaker("speaker-1", name: "Alice")
        precondition(decoded.speakerName("speaker-1") == "Alice", "Manual label must win")
        decoded.renameSpeaker("speaker-1", name: "")
        precondition(decoded.speakerName("speaker-1") == "说话人 1", "Reset must suppress inferred owner label")
        decoded.applyTranscription(.init(text: "new", segments: pieces))
        precondition(decoded.speakerName("speaker-1") == "说话人 1", "New transcription cannot inherit stale owner identity")
        print("Owner persistence, manual override and transcription reset passed")
    }
}
