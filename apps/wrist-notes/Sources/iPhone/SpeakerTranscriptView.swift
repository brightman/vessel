import SwiftUI

struct SpeakerTranscriptView: View {
    @EnvironmentObject private var model: NotesModel
    let note: VoiceNote
    @ObservedObject var playback: AudioPlayback
    @State private var filter = ""
    @State private var renaming = false
    @State private var renamingID = ""
    @State private var draftName = ""

    private var timeline: NoteTimeline? { model.timelines[note.id] }
    private var result: SpeakerDiarization? {
        guard let result = timeline?.diarization, result.matches(note) else { return nil }
        return result
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("按发言人与时间回听").font(.subheadline.weight(.semibold))
                Spacer()
                if model.speakerProgress[note.id] != nil {
                    Button("取消") { model.cancelSpeakerDiarization(note.id) }
                } else {
                    Button(result == nil ? "区分发言人" : "重新区分") { model.identifySpeakers(note.id) }
                        .disabled(note.transcriptionState == .running || note.transcript.isEmpty)
                }
            }.font(.caption)
            Text("在 iPhone 本地分析声音，首次需要联网下载模型，原始录音不上传。编号仅适用于本次录音；改名由你确认，不能自动识别真实身份。")
                .font(.caption).foregroundStyle(.secondary)
            if let progress = model.speakerProgress[note.id] { ProgressView(progress).font(.caption) }
            if let error = model.speakerErrors[note.id] { Text(error).font(.caption).foregroundStyle(NotesStyle.warning) }
            if let result {
                speakerControls(result)
                Text("本机分析 · \(result.speakerIDs.count) 位发言人").font(.caption2).foregroundStyle(.secondary)
                Text("多人重叠、边界不清或声音相似时可能标错。待确认片段保留原文，不猜测归属。重新区分会重建编号并清除自定义名称。")
                    .font(.caption).foregroundStyle(.secondary)
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(result.segments.filter { filter.isEmpty || $0.speakerID == filter }) { segment in
                        timedRow(start: segment.start, end: segment.end, text: segment.text,
                            speaker: result.label(for: segment), color: color(segment.speakerID, in: result))
                    }
                }
                if result.segments.map(\.text).joined().trimmingCharacters(in: .whitespacesAndNewlines) != note.transcript.trimmingCharacters(in: .whitespacesAndNewlines) {
                    Text("部分文字没有可用时间戳，未强行定位。展开下方完整原文可查看全部内容。")
                        .font(.caption).foregroundStyle(.secondary)
                    DisclosureGroup("完整原文") {
                        Text(note.transcript).font(.system(size: 15)).lineSpacing(5).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            } else if let segments = timeline?.alignedSegments(for: note), !segments.isEmpty {
                Text("已有真实时间戳；点击“区分发言人”后按声音归属分段。旧录音的时间片段较粗时，重新转写可保留更细的原始时间范围。")
                    .font(.caption).foregroundStyle(.secondary)
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(segments) { segment in
                        timedRow(start: segment.start, end: segment.end, text: segment.text, speaker: nil, color: .secondary)
                    }
                }
            } else {
                Text(note.transcript.isEmpty ? "转写完成后会显示分段原文。" : "此全文尚无可靠时间戳。重新转写后可按时间和发言人回听；已有文字仍可在“编辑全文”查看。")
                    .font(.caption).foregroundStyle(.secondary)
                if !note.transcript.isEmpty { Text(note.transcript).font(.system(size: 15)).lineSpacing(5).textSelection(.enabled) }
            }
        }
        .alert("重命名发言人", isPresented: $renaming) {
            TextField("名称（仅本条录音）", text: $draftName)
            Button("保存") { model.renameSpeaker(note.id, speakerID: renamingID, name: draftName) }
            Button("取消", role: .cancel) { }
        } message: { Text("名称由你确认，不代表模型已识别真实身份。留空恢复默认编号。") }
    }

    private func speakerControls(_ result: SpeakerDiarization) -> some View {
        HStack {
            Picker("筛选发言人", selection: $filter) {
                Text("全部发言人").tag("")
                ForEach(result.speakerIDs, id: \.self) { id in Text(result.name(for: id)).tag(id) }
            }.pickerStyle(.menu)
            Spacer()
            Menu("重命名") {
                ForEach(result.speakerIDs, id: \.self) { id in
                    Button(result.name(for: id)) { renamingID = id; draftName = result.names[id] ?? ""; renaming = true }
                }
            }.font(.caption)
        }
        .onChange(of: result.speakerIDs) { _, ids in if !ids.contains(filter) { filter = "" } }
    }

    private func color(_ id: String?, in result: SpeakerDiarization) -> Color {
        guard let id, let index = result.speakerIDs.firstIndex(of: id) else { return .secondary }
        let colors: [Color] = [.blue, .purple, .teal, .orange, .pink, .indigo]
        return colors[index % colors.count]
    }

    private func timedRow(start: Double, end: Double, text: String, speaker: String?, color: Color) -> some View {
        let current = playback.position >= start && playback.position < end
        return Button { playback.seek(to: start) } label: {
            VStack(alignment: .leading, spacing: 7) {
                HStack {
                    if let speaker { Text(speaker).font(.caption.weight(.semibold)).foregroundStyle(color) }
                    Spacer()
                    Label("\(RecordingFormat.duration(start))–\(RecordingFormat.duration(end))", systemImage: current ? "waveform" : "play.circle")
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
                Text(text).font(.system(size: 15)).lineSpacing(4).foregroundStyle(.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(14)
            .background(current ? color.opacity(0.12) : NotesStyle.card, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(current ? color.opacity(0.5) : NotesStyle.border, lineWidth: 1))
        }.buttonStyle(.plain)
    }
}
