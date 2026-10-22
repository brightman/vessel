import SwiftUI
import UniformTypeIdentifiers

private enum VoiceLibraryRoute: Hashable { case note(UUID), session(UUID) }
private struct VoiceLibraryItem: Identifiable {
    let id: UUID
    let date: Date
    let note: VoiceNote?
    let session: RecordingSessionSummary?
}

struct NotesListView: View {
    @EnvironmentObject private var recorder: PhoneRecorder
    @EnvironmentObject private var sessions: RecordingSessionModel
    @EnvironmentObject private var model: NotesModel
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.scenePhase) private var scenePhase
    @State private var path = NavigationPath()
    @State private var search = ""
    @State private var showImporter = false
    @State private var showWatchStatus = false
    @State private var deletingSession: UUID?

    private var filtered: [VoiceNote] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return model.notes }
        return model.notes.filter {
            $0.displayTitle.localizedCaseInsensitiveContains(query) ||
            $0.transcript.localizedCaseInsensitiveContains(query)
        }
    }

    private var items: [VoiceLibraryItem] {
        let legacyIDs = Set(model.notes.map(\.id))
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        let sessions = sessions.sessions.filter { session in
            (session.legacyNoteID.map { !legacyIDs.contains($0) } ?? true) &&
                (query.isEmpty || String(localized: "完整录音").localizedCaseInsensitiveContains(query))
        }
        return (filtered.map { VoiceLibraryItem(id: $0.id, date: $0.capturedAt, note: $0, session: nil) } +
            sessions.map { VoiceLibraryItem(id: $0.id, date: $0.startedAt ?? .distantFuture, note: nil, session: $0) })
            .sorted { $0.date > $1.date }
    }

    var body: some View {
        NavigationStack(path: $path) {
            VStack(spacing: 0) {
                header
                List {
                    if items.isEmpty {
                        ContentUnavailableView(
                            model.notes.isEmpty ? "还没有语音笔记" : "没有匹配的笔记",
                            systemImage: "waveform",
                            description: Text(model.notes.isEmpty ? "在 Apple Watch 上开始录音，连接后会传到这里。" : "试试其他关键词")
                        )
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                    }
                    ForEach(items) { item in
                        Button {
                            if item.session != nil { path.append(VoiceLibraryRoute.session(item.id)) }
                            else { path.append(VoiceLibraryRoute.note(item.id)) }
                        } label: {
                            if let note = item.note { row(note) }
                            else if let session = item.session { sessionRow(session) }
                        }
                        .buttonStyle(.plain)
                        .listRowInsets(EdgeInsets(top: 4, leading: 14, bottom: 4, trailing: 14))
                        .listRowBackground(Color.clear).listRowSeparator(.hidden)
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button("删除", systemImage: "trash", role: .destructive) {
                                if item.session != nil { deletingSession = item.id } else { model.delete(item.id) }
                            }
                        }
                    }
                    if sessions.hasMore { Button("载入更早的录音") { sessions.loadMore() }.disabled(sessions.loading) }
                    if !sessions.cleanupIDs.isEmpty {
                        Text("文件清理待重试").foregroundStyle(.orange)
                        Button("重试清理") { sessions.refresh(recover: true) }
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .contentMargins(.top, 0)
                .scrollDismissesKeyboard(.interactively)
            }
            .background(NotesStyle.background)
            .navigationDestination(for: UUID.self) { id in NoteDetailView(id: id) }
            .navigationDestination(for: VoiceLibraryRoute.self) { route in
                switch route {
                case .note(let id): NoteDetailView(id: id)
                case .session(let id): RecordingSessionDetailView(sessionID: id, playbackAllowed: !recorder.isRecording && !recorder.requestingPermission)
                }
            }
            .confirmationDialog("删除完整录音？", isPresented: Binding(get: { deletingSession != nil }, set: { if !$0 { deletingSession = nil } }), titleVisibility: .visible) {
                Button("删除完整录音", role: .destructive) {
                    if let id = deletingSession { Task { await sessions.delete(id) } }
                    deletingSession = nil
                }
            } message: { Text("这会删除本机完整会话及全部原始分片；无法仅删除一个派生片段。") }
            .navigationDestination(for: SettingsRoute.self) { route in
                switch route {
                case .settings:
                    SettingsView { showImporter = true }
                case .transcription: TranscriptionSettingsView(settings: settings)
                case .myVoice: MyVoiceEnrollmentView(profile: model.voiceProfile)
                case .ai: AISettingsView(settings: settings)
                case .about: AboutView()
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
                get: { sessions.errorMessage != nil || model.errorMessage != nil },
                set: { if !$0 { model.errorMessage = nil; sessions.errorMessage = nil } }
            )) { Button("好") { model.errorMessage = nil; sessions.errorMessage = nil } } message: {
                Text(LocalizedStringKey(sessions.errorMessage ?? model.errorMessage ?? ""))
            }
        }
        .tint(NotesStyle.red)
        .preferredColorScheme(settings.appearance.colorScheme)
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { WiseLifeRuntime.shared.foreground() }
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
                        .foregroundStyle(model.watchStatus.hasPairedWatch ? NotesStyle.green : .secondary)
                        .frame(width: 39, height: 39)
                        .background(model.watchStatus.hasPairedWatch ? NotesStyle.greenBackground : NotesStyle.field, in: Circle())
                        .overlay(alignment: .bottomTrailing) {
                            Circle().fill(model.watchStatus.hasPairedWatch ? NotesStyle.green : .secondary)
                                .frame(width: 6, height: 6).padding(7)
                        }
                }
                .accessibilityLabel(model.watchStatus.title)
                .popover(isPresented: $showWatchStatus, arrowEdge: .top) {
                    VStack(alignment: .leading, spacing: 9) {
                        Text(model.watchStatus.title).font(.headline)
                        Text(model.watchStatus.message).font(.subheadline).foregroundStyle(Color.secondary)
                        ForEach(model.watchStatus.issueMessages, id: \.self) { issue in
                            Text(issue).font(.caption).foregroundStyle(.orange)
                        }
                        if model.watchStatus.hasPairedWatch, model.watchStatus.isInstalled {
                            if let error = model.watchRetryError { Text(error).font(.caption).foregroundStyle(.orange) }
                            if model.watchStatus.retryPending {
                                Text("重试请求已提交，等待手表处理。后台传输时间由系统安排。")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Button("重试同步") { model.retryWatchSync() }.disabled(!model.watchStatus.canRetrySync)
                        }
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
                Text("\(items.count) 条").font(.system(size: 13)).foregroundStyle(Color.secondary)
            }
        }
        .padding(.horizontal, 24).padding(.top, 9).padding(.bottom, 10)
    }

    private func sessionRow(_ session: RecordingSessionSummary) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("完整录音").font(.headline)
            if let start = session.startedAt { Text(start, style: .date); Text(start, style: .time) }
            else { Text("录音时间待同步") }
            Text(RecordingFormat.duration(session.recordedDuration)).font(.subheadline).monospacedDigit()
            Text(LocalizedStringKey(RecordingSessionPresentation.status(session))).font(.caption).foregroundStyle(.secondary)
        }.padding(17).frame(maxWidth: .infinity, alignment: .leading)
            .background(NotesStyle.card, in: RoundedRectangle(cornerRadius: 17))
            .accessibilityElement(children: .combine)
    }

    private func toolbarIcon(_ name: String) -> some View {
        Image(systemName: name).font(.system(size: 18, weight: .medium))
            .foregroundStyle(Color.primary).frame(width: 39, height: 39)
            .background(NotesStyle.field, in: Circle())
    }

    private func row(_ note: VoiceNote) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text(note.displayTitle).font(.system(size: 17, weight: .semibold)).lineLimit(1)
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
