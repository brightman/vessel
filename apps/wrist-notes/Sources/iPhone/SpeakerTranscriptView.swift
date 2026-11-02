import SwiftUI

struct AudioSpeakerTranscriptSnapshot: Sendable {
    let spans: [AudioTranscriptSpan]
    let labels: [String: String]
    let contacts: [String: SpeakerContactSnapshot]
}

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

/// Grouped recordings keep diarization on the durable, source-level transcript spans.
/// Render those spans directly instead of relying on each legacy VoiceNote's speaker state.
struct GroupedSpeakerTranscriptView: View {
    let spans: [AudioTranscriptSpan]

    private struct Turn: Identifiable {
        let id: Int
        var speakerID: String?
        var start: Double
        var end: Double
        var text: String
    }

    private struct Presentation {
        let turns: [Turn]
        let speakerLabels: [String: String]
    }

    private func makePresentation() -> Presentation {
        let ordered = spans.sorted(by: { $0.start == $1.start ? $0.end < $1.end : $0.start < $1.start })
        var result: [Turn] = []
        var labels: [String: String] = [:]
        for span in ordered {
            if let id = span.speakerID, labels[id] == nil {
                labels[id] = "说话人 \(labels.count + 1)"
            }
            if let last = result.indices.last,
               result[last].speakerID == span.speakerID,
               span.start <= result[last].end + 1.25 {
                result[last].end = max(result[last].end, span.end)
                result[last].text += span.text
            } else {
                result.append(.init(id: result.count, speakerID: span.speakerID,
                                    start: span.start, end: span.end, text: span.text))
            }
        }
        return .init(turns: result, speakerLabels: labels)
    }

    var body: some View {
        let presentation = makePresentation()
        VStack(alignment: .leading, spacing: 12) {
            if presentation.turns.contains(where: { $0.speakerID == nil }) {
                Text("部分内容尚未区分说话人。")
                    .font(.system(size: 10)).foregroundStyle(DaybookStyle.secondary)
            }
            LazyVStack(alignment: .leading, spacing: 16) {
                ForEach(presentation.turns) { turn in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 8) {
                            Label(turn.speakerID.flatMap { presentation.speakerLabels[$0] } ?? "未区分",
                                  systemImage: turn.speakerID == nil ? "person.crop.circle.dashed" : "person.crop.circle")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(turn.speakerID == nil ? DaybookStyle.secondary : DaybookStyle.accent)
                            Spacer(minLength: 4)
                            Text("\(RecordingFormat.timecode(turn.start))–\(RecordingFormat.timecode(turn.end))")
                                .font(.system(size: 10).monospacedDigit()).foregroundStyle(DaybookStyle.secondary)
                        }
                        Text(turn.text.trimmingCharacters(in: .whitespacesAndNewlines))
                            .font(.system(size: 13)).lineSpacing(7)
                            .foregroundStyle(DaybookStyle.bodyText)
                            .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
    }
}

/// Timeline segment transcript with recording-scoped speaker labels and contact links.
struct ContentSegmentSpeakerTranscriptView: View {
    let spans:[AudioTranscriptSpan]
    let speakerLabels:[String:String]
    let speakerContacts:[String:SpeakerContactSnapshot]
    let onManage:(String,String,String)->Void

    private struct Turn:Identifiable {
        let id:Int
        let speakerID:String?
        let start:Double
        let end:Double
        let text:String
    }

    private var turns:[Turn] {
        let ordered=spans.sorted { $0.start == $1.start ? $0.end < $1.end : $0.start < $1.start }
        var values:[Turn]=[]
        for span in ordered {
            if let last=values.indices.last,values[last].speakerID == span.speakerID,span.start <= values[last].end+1.25 {
                let old=values[last]
                values[last]=Turn(id:old.id,speakerID:old.speakerID,start:old.start,end:max(old.end,span.end),text:old.text+span.text)
            } else {
                values.append(.init(id:values.count,speakerID:span.speakerID,start:span.start,end:span.end,text:span.text))
            }
        }
        return values
    }

    var body:some View {
        VStack(alignment:.leading,spacing:15) {
            if turns.contains(where:{$0.speakerID == nil}) {
                Text("部分内容尚未区分说话人。")
                    .font(.system(size:10)).foregroundStyle(DaybookStyle.secondary)
            }
            LazyVStack(alignment:.leading,spacing:16) {
                ForEach(turns) { turn in
                    VStack(alignment:.leading,spacing:6) {
                        HStack(spacing:8) {
                            if let speakerID=turn.speakerID {
                                let label=speakerLabels[speakerID] ?? "说话人"
                                Button { onManage(speakerID,label,String(turn.text.prefix(140))) } label: {
                                    HStack(spacing:5) {
                                        if let data=speakerContacts[speakerID]?.thumbnailData,let image=UIImage(data:data) {
                                            Image(uiImage:image).resizable().scaledToFill().frame(width:17,height:17).clipShape(Circle())
                                        } else { Image(systemName:"person.crop.circle") }
                                        Text(speakerContacts[speakerID]?.displayName ?? label)
                                        Image(systemName:"chevron.down").font(.system(size:8,weight:.semibold))
                                    }
                                    .font(.system(size:11,weight:.semibold)).foregroundStyle(DaybookStyle.accent)
                                }
                                .buttonStyle(.plain)
                                .accessibilityHint("关联或更换这条录音中的联系人")
                            } else {
                                Label("未区分",systemImage:"person.crop.circle.dashed")
                                    .font(.system(size:11)).foregroundStyle(DaybookStyle.secondary)
                            }
                            Spacer(minLength:4)
                            Text("\(RecordingFormat.timecode(turn.start))–\(RecordingFormat.timecode(turn.end))")
                                .font(.system(size:10).monospacedDigit()).foregroundStyle(DaybookStyle.secondary)
                        }
                        Text(turn.text.trimmingCharacters(in:.whitespacesAndNewlines))
                            .font(.system(size:13)).lineSpacing(7).foregroundStyle(DaybookStyle.bodyText)
                            .textSelection(.enabled).frame(maxWidth:.infinity,alignment:.leading)
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
