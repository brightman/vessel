import SwiftUI

/// Shared by the daybook sheet and the full note editor.
struct SpeakerTranscriptView: View {
    let note: VoiceNote
    var editable = false
    @EnvironmentObject private var model: NotesModel
    @State private var managedSpeaker: SpeakerManagementContext?
    @State private var editingSegment: TranscriptSegment?
    @State private var textDraft = ""

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 18) {
            ForEach(note.transcriptSegments ?? []) { segment in
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 9) {
                        if let speaker = segment.speakerID {
                            Button {
                                managedSpeaker = SpeakerManagementContext(note: note, speakerID: speaker)
                            } label: {
                                Label { SpeakerNameText(note: note, speakerID: speaker) } icon: {
                                    if let data = note.speakerContacts?[speaker]?.thumbnailData, let avatar = UIImage(data: data) {
                                        Image(uiImage: avatar).resizable().scaledToFill().frame(width: 18, height: 18).clipShape(Circle())
                                    } else { Image(systemName: "person.crop.circle") }
                                }
                                    .font(.system(size: 12, weight: .semibold))
                            }
                            .buttonStyle(.plain)
                            .disabled(note.transcriptionState == .running || note.diarizationState == .running)
                            .accessibilityHint("修改这条录音中此说话人的名称")
                        } else {
                            Label("未区分", systemImage: "person.crop.circle.dashed")
                                .font(.system(size: 12)).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 4)
                        Text("\(RecordingFormat.timecode(segment.start))–\(RecordingFormat.timecode(segment.end))")
                            .font(.system(size: 10).monospacedDigit()).foregroundStyle(.secondary)
                        if editable {
                            Button {
                                textDraft = segment.text
                                editingSegment = segment
                            } label: { Image(systemName: "pencil") }
                            .buttonStyle(.plain).accessibilityLabel("编辑这段文字")
                            .disabled(note.transcriptionState == .running || note.diarizationState == .running)
                        }
                    }
                    Text(segment.text.trimmingCharacters(in: .whitespacesAndNewlines))
                        .font(.system(size: 14)).lineSpacing(6)
                        .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                }
                .accessibilityElement(children: .contain)
            }
        }
        .sheet(item: $managedSpeaker) { speaker in
            SpeakerManagementView(note: speaker.note, speakerID: speaker.speakerID)
        }
        .sheet(item: $editingSegment) { segment in
            NavigationStack {
                VStack {
                    TextEditor(text: $textDraft)
                    if let error = model.errorMessage { Text(error).font(.caption).foregroundStyle(.orange) }
                }.padding().navigationTitle("编辑这段文字")
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) { Button("取消") { editingSegment = nil } }
                        ToolbarItem(placement: .confirmationAction) {
                            Button("保存") {
                                if model.editSegment(noteID: note.id, segmentID: segment.id, text: textDraft) {
                                    editingSegment = nil
                                }
                            }
                        }
                    }
            }
        }
    }
}

struct SpeakerProcessingView: View {
    let note: VoiceNote
    @EnvironmentObject private var model: NotesModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if note.diarizationState == .running {
                ProgressView("正在本机区分说话人…").controlSize(.small)
            } else if note.diarizationState == .ready {
                Text("已在本机区分说话人 · 点击名称可修改")
                    .foregroundStyle(.secondary)
            } else if let message = note.diarizationMessage {
                Text(message).foregroundStyle(.secondary)
            }
            if let message = note.voiceIdentityMessage {
                Text(message).foregroundStyle(.secondary)
                if note.diarizationState != .running {
                    Button("重试识别我的声音") { Task { await model.identifySpeakers(note.id) } }.buttonStyle(.plain)
                }
            }
            if note.diarizationState != .ready && note.diarizationState != .running,
               note.transcriptionState == .ready, !(note.transcriptSegments ?? []).isEmpty {
                Button("区分说话人") { Task { await model.identifySpeakers(note.id) } }
                    .buttonStyle(.plain)
            }
        }
        .font(.system(size: 11)).lineSpacing(5)
    }
}
