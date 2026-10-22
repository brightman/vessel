import Foundation
@main struct SpeakerContactsSmoke {
 static func main() throws {
  var note = VoiceNote(id: UUID(), kind: .long, capturedAt: .now, duration: 2)
  let segment = TranscriptSegment(start: 0, end: 2, text: "Hello", speakerID: "speaker-1")
  note.applyTranscription(.init(text: "Hello", segments: [segment]))
  let legacy = try JSONDecoder().decode(VoiceNote.self, from: JSONEncoder().encode(note))
  precondition(legacy.speakerContacts == nil)
  let contact = SpeakerContactSnapshot(identifier: "one", displayName: "Alice", thumbnailData: nil)
  let opening = SpeakerManagementContext(note: note, speakerID: "speaker-1")
  var replacementTranscript = note
  replacementTranscript.applyTranscription(.init(text: "New person", segments: [segment]))
  precondition(!replacementTranscript.canEditSpeaker(opening.speakerID, expectedRevision: opening.note.transcriptRevision, expectedSegments: opening.note.transcriptSegments ?? []))
  let revision = note.transcriptRevision
  precondition(note.setSpeakerContact("speaker-1", contact: contact, expectedRevision: revision, expectedSegments: [segment]))
  precondition(note.speakerName("speaker-1") == "Alice")
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: root) }
  let repository = try NoteRepository(root: root)
  let audio = root.appendingPathComponent("fixture.m4a")
  try Data([1, 2]).write(to: audio)
  _ = try repository.importRecording(id: note.id, from: audio, kind: .long, capturedAt: .now, duration: 2)
  try repository.update(id: note.id) { $0 = note }
  let reopened = try NoteRepository(root: root)
  precondition(reopened.notes.first?.speakerContacts?["speaker-1"] == contact)
  var busy = note; busy.diarizationState = .running
  precondition(!busy.setSpeakerContact("speaker-1", contact: nil, expectedRevision: revision, expectedSegments: [segment]))
  busy = note; busy.transcriptionState = .running
  precondition(!busy.setSpeakerContact("speaker-1", contact: nil, expectedRevision: revision, expectedSegments: [segment]))
  precondition(!note.setSpeakerContact("speaker-2", contact: contact, expectedRevision: revision, expectedSegments: [segment]))
  let other = legacy
  precondition(other.speakerContacts == nil)
  let replacement = SpeakerContactSnapshot(identifier: "two", displayName: "名称", thumbnailData: nil)
  precondition(note.setSpeakerContact("speaker-1", contact: replacement, expectedRevision: revision, expectedSegments: [segment]))
  note = try JSONDecoder().decode(VoiceNote.self, from: JSONEncoder().encode(note))
  precondition(note.speakerContacts?["speaker-1"] == replacement)
  note.editSegment(segment.id, text: "Changed")
  precondition(note.speakerContacts?["speaker-1"] == replacement)
  precondition(!note.setSpeakerContact("speaker-1", contact: contact, expectedRevision: revision, expectedSegments: [segment]))
  precondition(note.applyDiarization(note.transcriptSegments!, expectedRevision: note.transcriptRevision))
  precondition(note.speakerContacts?["speaker-1"] == replacement)
  let current = note.transcriptSegments!
  precondition(note.setSpeakerContact("speaker-1", contact: nil, expectedRevision: note.transcriptRevision, expectedSegments: current))
  precondition(note.speakerName("speaker-1") == "说话人 1")
  precondition(note.setSpeakerContact("speaker-1", contact: contact, expectedRevision: note.transcriptRevision, expectedSegments: current))
  note.renameSpeaker("speaker-1", name: "Manual")
  precondition(note.speakerContacts?["speaker-1"] == nil && note.speakerName("speaker-1") == "Manual")
  _ = note.setSpeakerContact("speaker-1", contact: contact, expectedRevision: note.transcriptRevision, expectedSegments: current)
  var changed = current; changed[0].speakerID = "speaker-2"
  precondition(note.applyDiarization(changed, expectedRevision: note.transcriptRevision))
  precondition(note.speakerContacts == nil)
  note.applyTranscription(.init(text: "Hello", segments: [segment]))
  _ = note.setSpeakerContact("speaker-1", contact: contact, expectedRevision: note.transcriptRevision, expectedSegments: [segment])
  note.applyTranscription(.init(text: "Hello", segments: [segment]))
  precondition(note.speakerContacts == nil)
  print("Speaker contacts smoke passed")
 }
}
