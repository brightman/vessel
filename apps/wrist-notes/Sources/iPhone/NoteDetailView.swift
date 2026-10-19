import SwiftUI

struct NoteDetailView: View {
    @EnvironmentObject private var model: NotesModel
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.dismiss) private var dismiss
    let id: UUID
    @State private var title = ""
    @State private var transcript = ""
    @State private var initialized = false
    @State private var selectedTab: DetailTab = .summary
    @State private var savedNotice = false
    @StateObject private var playback = AudioPlayback()

    private enum DetailTab: String, CaseIterable {
        case summary = "总结"
        case transcript = "全文"
    }

    var body: some View {
        Group {
            if let note = model.note(id) {
                VStack(spacing: 0) {
                    header
                    ScrollView {
                        VStack(alignment: .leading, spacing: 0) {
                            VStack(alignment: .leading, spacing: 7) {
                                Text(note.kind.label).font(.system(size: 13, weight: .semibold)).foregroundStyle(Color.secondary)
                                TextField("笔记标题", text: $title, axis: .vertical)
                                    .font(.system(size: 30, weight: .bold))
                                    .accessibilityLabel("笔记标题")
                                Text(RecordingFormat.date(note.capturedAt))
                                    .font(.system(size: 13)).foregroundStyle(Color.secondary)
                            }
                            playerCard.padding(.top, 29)
                            tabs.padding(.top, 25)
                            Group {
                                if selectedTab == .summary { summaryPanel(note) }
                                else { transcriptPanel(note) }
                            }
                            .padding(.top, 20)
                        }
                        .padding(.horizontal, 22).padding(.top, 8).padding(.bottom, 45)
                    }
                    .scrollDismissesKeyboard(.interactively)
                }
                .background(NotesStyle.background)
                .toolbar(.hidden, for: .navigationBar)
                .task(id: id) {
                    if !initialized {
                        title = note.title
                        transcript = note.transcript
                        initialized = true
                    }
                    await playback.load(model.audioURL(id), fallbackDuration: note.duration)
                }
                .onChange(of: note.transcript) { oldValue, newValue in
                    if transcript == oldValue { transcript = newValue }
                }
                .onDisappear { playback.stop(); save() }
            } else {
                ContentUnavailableView("笔记不存在", systemImage: "doc.questionmark")
            }
        }
        .tint(NotesStyle.red)
    }

    private var header: some View {
        HStack {
            Button { save(); dismiss() } label: { Label("语音笔记", systemImage: "chevron.left") }
            Spacer()
            Button(savedNotice ? "已保存" : "保存") {
                save()
                savedNotice = true
            }
            .fontWeight(.semibold)
        }
        .font(.system(size: 16)).foregroundStyle(NotesStyle.red)
        .padding(.horizontal, 17).frame(height: 52)
        .onChange(of: title) { _, _ in savedNotice = false }
        .onChange(of: transcript) { _, _ in savedNotice = false }
    }

    private var playerCard: some View {
        VStack(spacing: 7) {
            Text("原始录音")
                .font(.system(size: 12, weight: .semibold)).foregroundStyle(Color.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 2) {
                ForEach(playback.waveform.indices, id: \.self) { index in
                    Capsule()
                        .fill(Double(index) / Double(playback.waveform.count) < playback.position / max(playback.duration, 0.01)
                              ? NotesStyle.red : Color(white: 0.41))
                        .frame(maxWidth: 3)
                        .frame(height: CGFloat(playback.waveform[index]) * 49 + 4)
                }
            }
            .frame(maxWidth: .infinity).frame(height: 53)
            .padding(.top, 12).accessibilityHidden(true)
            HStack {
                Text(RecordingFormat.duration(playback.position))
                Spacer()
                Text(RecordingFormat.duration(playback.duration))
            }
            .font(.system(size: 11).monospacedDigit()).foregroundStyle(Color.secondary)
            Button { playback.toggle() } label: {
                Image(systemName: playback.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 25)).foregroundStyle(.white)
                    .frame(width: 62, height: 62).background(NotesStyle.red, in: Circle())
            }
            .padding(.top, 4)
            .accessibilityLabel(playback.isPlaying ? "暂停播放" : "播放录音")
            if let error = playback.error { Text(error).font(.caption).foregroundStyle(.orange) }
        }
        .padding(.horizontal, 20).padding(.top, 19).padding(.bottom, 17)
        .background(NotesStyle.card, in: RoundedRectangle(cornerRadius: 21))
        .overlay(RoundedRectangle(cornerRadius: 21).stroke(NotesStyle.border, lineWidth: 1))
    }

    private var tabs: some View {
        HStack(spacing: 4) {
            ForEach(DetailTab.allCases, id: \.self) { tab in
                Button {
                    if selectedTab == .transcript { save() }
                    selectedTab = tab
                } label: {
                    Text(tab.rawValue)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(selectedTab == tab ? Color.primary : Color.secondary)
                        .frame(maxWidth: .infinity).frame(minHeight: 39)
                        .background(selectedTab == tab ? NotesStyle.selected : .clear, in: RoundedRectangle(cornerRadius: 9))
                }
                .accessibilityAddTraits(selectedTab == tab ? .isSelected : [])
            }
        }
        .padding(4)
        .background(NotesStyle.card, in: RoundedRectangle(cornerRadius: 13))
        .overlay(RoundedRectangle(cornerRadius: 13).stroke(NotesStyle.border, lineWidth: 1))
    }

    private func summaryPanel(_ note: VoiceNote) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("内容概览").foregroundStyle(Color.secondary)
                Spacer()
                Button(model.summaryModels[id] != nil ? "生成中…" : (note.summary.isEmpty ? "生成总结" : "重新生成")) {
                    save()
                    Task { await model.summarize(id) }
                }
                .disabled(transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.summaryModels[id] != nil)
            }
            .font(.system(size: 13, weight: .medium))
            VStack(alignment: .leading, spacing: 12) {
                if let modelName = model.summaryModels[id] { ProgressView("正在使用 \(modelName) 生成总结") }
                Text(note.summary.isEmpty ? summaryHint : note.summary)
                    .font(.system(size: 14)).lineSpacing(5)
                    .foregroundStyle(note.summary.isEmpty ? Color.secondary : Color.primary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, minHeight: 64, alignment: .topLeading)
                if note.summaryState == .failed || note.summaryState == .unavailable {
                    Text(note.processingMessage ?? "总结暂不可用").font(.caption).foregroundStyle(NotesStyle.warning)
                }
            }
            .padding(16).background(NotesStyle.card, in: RoundedRectangle(cornerRadius: 17))
            .overlay(RoundedRectangle(cornerRadius: 17).stroke(NotesStyle.border, lineWidth: 1))
        }
    }

    private var summaryHint: String {
        settings.ai.mode == .local
            ? "根据转写文本，在 iPhone 上生成总结。"
            : "生成总结时，将全文文本发送至你配置的服务，使用 \(settings.ai.label)。原始录音不发送。"
    }

    private func transcriptPanel(_ note: VoiceNote) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("可编辑的转写文本").foregroundStyle(Color.secondary)
                Spacer()
                Button(note.transcriptionState == .running ? "转写中…" : "重新转写") {
                    save()
                    Task { await model.transcribe(id) }
                }
                .disabled(note.transcriptionState == .running)
            }
            .font(.system(size: 13, weight: .medium))
            ZStack(alignment: .topLeading) {
                if transcript.isEmpty {
                    Text("转写完成后会出现在这里，也可以直接编辑。")
                        .font(.system(size: 15)).foregroundStyle(.tertiary)
                        .padding(.horizontal, 5).padding(.top, 8)
                        .allowsHitTesting(false)
                }
                TextEditor(text: $transcript)
                    .font(.system(size: 15)).lineSpacing(5)
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 172)
                    .accessibilityLabel("转写文本")
            }
            .padding(10).background(NotesStyle.card, in: RoundedRectangle(cornerRadius: 17))
            .overlay(RoundedRectangle(cornerRadius: 17).stroke(NotesStyle.border, lineWidth: 1))
            if note.transcriptionState == .failed || note.transcriptionState == .unavailable {
                Text(note.processingMessage ?? "转写暂不可用").font(.caption).foregroundStyle(.orange)
            }
        }
    }

    private func save() {
        guard initialized else { return }
        model.save(id: id, title: title, transcript: transcript)
    }
}
