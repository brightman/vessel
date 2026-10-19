// Included only in the disposable preview; all text, turns and audio are synthetic.
import Foundation

@MainActor
enum SpeakerIntegrationPreview {
    private static var didRun = false
    static func run(model: NotesModel, noteID: UUID) async {
        guard !didRun else { return }
        didRun = true
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let output = documents.appendingPathComponent("speaker-integration-result.json")
        var checks: [String] = []
        do {
            func require(_ value: Bool, _ name: String) throws {
                guard value else { throw AIServiceError.invalidConfiguration(name) }
                checks.append(name)
            }
            await model.openTimeline(noteID)
            let note = model.note(noteID)!
            let timeline = model.timelines[noteID]!
            let result = timeline.diarization!
            try require(result.matches(note) && result.speakerIDs.count == 2, "speaker result binds to this audio and transcript")
            try require(result.segments.count == 3 && result.segments.map(\.text).joined() == note.transcript,
                "speaker paragraphs preserve the entire timed transcript")
            try require(result.segments.map(\.speakerID) == ["S1", "S2", "S1"], "returning speaker keeps identity within this recording")
            try require(!timeline.words.isEmpty, "raw ASR ranges remain available for alignment")
            model.identifySpeakers(noteID)
            model.cancelSpeakerDiarization(noteID)
            for _ in 0..<100 {
                if model.speakerProgress[noteID] == nil { break }
                try await Task.sleep(for: .milliseconds(50))
            }
            try require(model.speakerProgress[noteID] == nil && model.timelines[noteID]?.diarization == result,
                "cancelled local inference cannot replace an existing speaker result")
            model.renameSpeaker(noteID, speakerID: "S1", name: "  参会人甲  ")
            let renamed = model.timelines[noteID]!
            try require(renamed.diarization?.name(for: "S1") == "参会人甲", "user-confirmed name appears for all turns of one speaker")
            try require(renamed.analysis == nil && renamed.revision != timeline.revision, "speaker changes invalidate the previous meeting report")
            let store = try NoteTimelineStore(root: documents.appendingPathComponent("VoiceNotes"))
            let saved = try store.load(noteID)
            try require(saved.diarization == renamed.diarization && saved.words == timeline.words,
                "speaker ranges and names survive sidecar reload")
            model.save(id: noteID, title: "新标题", transcript: note.transcript)
            try require(model.timelines[noteID]?.diarization == renamed.diarization, "title-only editing preserves speaker alignment")
            await model.setHeartRateEnabled(false)
            await model.setStateOfMindEnabled(false)
            try require(model.timelines[noteID]?.diarization == renamed.diarization,
                "health opt-outs preserve speaker segmentation")
            model.identifySpeakers(noteID)
            model.save(id: noteID, title: note.title, transcript: note.transcript + " 手动修改。")
            for _ in 0..<100 {
                if model.speakerProgress[noteID] == nil { break }
                try await Task.sleep(for: .milliseconds(50))
            }
            try require(model.timelines[noteID]?.diarization == nil && model.timelines[noteID]?.words.isEmpty == true,
                "full-text edits discard stale speaker and ASR alignment")
            try require(model.note(noteID)?.transcript.hasSuffix("手动修改。") == true && model.audioURL(noteID) != nil,
                "editing retains user text and the original audio")
            model.settings.speakerDiarizationEnabled = false
            try JSONSerialization.data(withJSONObject: ["ok": true, "checks": checks]).write(to: output, options: .atomic)
        } catch {
            try? JSONSerialization.data(withJSONObject: ["ok": false, "checks": checks, "error": error.localizedDescription]).write(to: output, options: .atomic)
        }
    }
}
