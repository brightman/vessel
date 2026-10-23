import Foundation

@main
struct NoteEditingSmoke {
    static func main() {
        var note = VoiceNote(id: UUID(), kind: .thought, capturedAt: .now, duration: 10)
        note.transcript = "原文"
        note.summary = "原总结"
        note.summaryState = .ready
        note.transcriptionState = .running
        note.applyEdit(title: "  新标题  ", transcript: "原文")
        precondition(note.title == "新标题")
        precondition(note.summary == "原总结", "Renaming must preserve the summary")
        precondition(note.transcriptionState == .running, "Viewing or saving without edits must not finish ASR")
        note.applyEdit(title: "  ", transcript: "修改后的全文")
        precondition(note.title == "未命名录音")
        precondition(note.summary.isEmpty && note.summaryState == .pending, "Edited text invalidates its old summary")
        note.transcriptionState = .failed
        note.processingMessage = "转写失败"
        note.applyEdit(title: note.title, transcript: "手工补充")
        precondition(note.transcriptionState == .ready && note.processingMessage == nil)
        print("Note editing: 5 scenarios passed")
    }
}
