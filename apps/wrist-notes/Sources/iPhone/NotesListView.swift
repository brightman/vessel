import SwiftUI
import UniformTypeIdentifiers

struct NotesListView: View {
    @EnvironmentObject private var model: NotesModel
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.scenePhase) private var scenePhase
    @State private var path = NavigationPath()
    @State private var search = ""
    @State private var showImporter = false
    @State private var showWatchStatus = false

    private var filtered: [VoiceNote] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return model.notes }
        return model.notes.filter {
            $0.title.localizedCaseInsensitiveContains(query) ||
            $0.transcript.localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        NavigationStack(path: $path) {
            VStack(spacing: 0) {
                header
                List {
                    if filtered.isEmpty {
                        ContentUnavailableView(
                            model.notes.isEmpty ? "还没有语音笔记" : "没有匹配的笔记",
                            systemImage: "waveform",
                            description: Text(model.notes.isEmpty ? "在 Apple Watch 上开始录音，连接后会传到这里。" : "试试其他关键词")
                        )
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                    }
                    ForEach(filtered) { note in
                        Button { path.append(note.id) } label: { row(note) }
                            .buttonStyle(.plain)
                            .listRowInsets(EdgeInsets(top: 4, leading: 14, bottom: 4, trailing: 14))
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                Button("删除", systemImage: "trash", role: .destructive) { model.delete(note.id) }
                            }
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .contentMargins(.top, 0)
                .scrollDismissesKeyboard(.interactively)
            }
            .background(NotesStyle.background)
            .navigationDestination(for: UUID.self) { id in NoteDetailView(id: id) }
            .navigationDestination(for: SettingsRoute.self) { route in
                switch route {
                case .settings:
                    SettingsView { showImporter = true }
                case .transcription: TranscriptionSettingsView(settings: settings)
                case .ai: AISettingsView(settings: settings)
                }
            }
            .toolbar(.hidden, for: .navigationBar)
            .fileImporter(isPresented: $showImporter, allowedContentTypes: [.audio]) { result in
                switch result {
                case .success(let url):
                    path = NavigationPath()
                    Task { await model.importAudioFile(url) }
                case .failure(let error): model.errorMessage = error.localizedDescription
                }
            }
            .alert("操作未完成", isPresented: Binding(
                get: { model.errorMessage != nil },
                set: { if !$0 { model.errorMessage = nil } }
            )) { Button("好") { model.errorMessage = nil } } message: {
                Text(model.errorMessage ?? "")
            }
        }
        .tint(NotesStyle.red)
        .preferredColorScheme(settings.appearance.colorScheme)
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { model.refreshWatchStatus() }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 19) {
            HStack {
                Text("WATCH · IPHONE")
                    .font(.system(size: 12, weight: .semibold))
                    .tracking(0.5).foregroundStyle(Color.secondary)
                Spacer()
                Button { model.refreshWatchStatus(); showWatchStatus.toggle() } label: {
                    Image(systemName: "applewatch")
                        .font(.system(size: 21, weight: .medium))
                        .foregroundStyle(model.watchStatus.isConnected ? NotesStyle.green : .secondary)
                        .frame(width: 39, height: 39)
                        .background(model.watchStatus.isConnected ? NotesStyle.greenBackground : NotesStyle.field, in: Circle())
                        .overlay(alignment: .bottomTrailing) {
                            Circle().fill(model.watchStatus.isConnected ? NotesStyle.green : .secondary)
                                .frame(width: 6, height: 6).padding(7)
                        }
                }
                .accessibilityLabel(model.watchStatus.title)
                .popover(isPresented: $showWatchStatus, arrowEdge: .top) {
                    VStack(alignment: .leading, spacing: 9) {
                        Text(model.watchStatus.title).font(.headline)
                        Text(model.watchStatus.message).font(.subheadline).foregroundStyle(Color.secondary)
                    }
                    .frame(maxWidth: 290, alignment: .leading).padding(20)
                    .presentationCompactAdaptation(.popover)
                }
                NavigationLink(value: SettingsRoute.settings) { toolbarIcon("gearshape") }
                    .accessibilityLabel("设置")
            }
            VStack(alignment: .leading, spacing: 9) {
                Text("语音笔记").font(.system(size: 34, weight: .bold))
                Text("录音、转写与想法，都留在这里。")
                    .font(.system(size: 13)).foregroundStyle(Color.secondary)
            }
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").foregroundStyle(Color.secondary)
                TextField("搜索标题和转写", text: $search)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                if !search.isEmpty {
                    Button { search = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .foregroundStyle(Color.secondary).accessibilityLabel("清除搜索")
                }
            }
            .font(.system(size: 15))
            .padding(.horizontal, 13).frame(height: 42)
            .background(NotesStyle.field, in: RoundedRectangle(cornerRadius: 12))
            HStack {
                Text("所有录音").font(.system(size: 19, weight: .bold))
                Spacer()
                Text("\(filtered.count) 条").font(.system(size: 13)).foregroundStyle(Color.secondary)
            }
        }
        .padding(.horizontal, 24).padding(.top, 9).padding(.bottom, 10)
    }

    private func toolbarIcon(_ name: String) -> some View {
        Image(systemName: name).font(.system(size: 18, weight: .medium))
            .foregroundStyle(Color.primary).frame(width: 39, height: 39)
            .background(NotesStyle.field, in: Circle())
    }

    private func row(_ note: VoiceNote) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text(note.title).font(.system(size: 17, weight: .semibold)).lineLimit(1)
                Spacer(minLength: 4)
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(Color.secondary)
            }
            Text("\(RecordingFormat.date(note.capturedAt)) · \(note.kind.label) · \(RecordingFormat.duration(note.duration))")
                .font(.system(size: 12)).foregroundStyle(Color.secondary).lineLimit(1)
            Text(note.transcript.isEmpty ? status(note) : note.transcript)
                .font(.system(size: 13))
                .foregroundStyle(note.transcript.isEmpty && note.transcriptionState != .ready ? NotesStyle.warning : .secondary)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(17).frame(maxWidth: .infinity, minHeight: 124, alignment: .leading)
        .background(NotesStyle.card, in: RoundedRectangle(cornerRadius: 17))
        .overlay(RoundedRectangle(cornerRadius: 17).stroke(NotesStyle.border, lineWidth: 1))
        .contentShape(RoundedRectangle(cornerRadius: 17))
    }

    private func status(_ note: VoiceNote) -> String {
        switch note.transcriptionState {
        case .pending: "等待端上转写"
        case .running: "正在端上转写"
        case .ready: "暂无转写文本"
        case .unavailable: "端上转写暂不可用，原始录音已保存"
        case .failed: "转写未完成，点开后可重试"
        }
    }
}
