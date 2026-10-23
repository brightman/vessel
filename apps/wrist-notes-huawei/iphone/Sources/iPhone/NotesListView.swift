import SwiftUI
import UniformTypeIdentifiers

struct NotesListView: View {
    @EnvironmentObject private var model: NotesModel
    @AppStorage("appearance") private var appearance = "system"
    @State private var path: [UUID] = []
    @State private var search = ""
    @State private var showSettings = false
    @State private var showConnection = false
    @State private var showImporter = false

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
                            description: Text(model.notes.isEmpty ? "可从设置导入录音。GT 6 连接尚未接入。" : "试试其他关键词")
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
            .toolbar(.hidden, for: .navigationBar)
            .fileImporter(isPresented: $showImporter, allowedContentTypes: [.audio]) { result in
                switch result {
                case .success(let url): Task { await model.importAudioFile(url) }
                case .failure(let error): model.errorMessage = error.localizedDescription
                }
            }
            .alert("本地处理失败", isPresented: Binding(
                get: { model.errorMessage != nil },
                set: { if !$0 { model.errorMessage = nil } }
            )) { Button("好") { model.errorMessage = nil } } message: {
                Text(model.errorMessage ?? "")
            }
        }
        .tint(NotesStyle.red)
        .preferredColorScheme(appearance == "system" ? nil : appearance == "light" ? .light : .dark)
        .sheet(isPresented: $showSettings) {
            HuaweiSettingsView(showImporter: $showImporter).environmentObject(model)
        }
        .alert("GT 6 未连接", isPresented: $showConnection) {
            Button("好", role: .cancel) { }
        } message: {
            Text("此版本尚未接入 Wear Engine。手表与华为运动健康配对，不代表语音笔记 App 已建立传输连接。")
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 19) {
            HStack {
                Text("GT 6 · IPHONE")
                    .font(.system(size: 12, weight: .semibold))
                    .tracking(0.5).foregroundStyle(.secondary)
                Spacer()
                Button { showConnection = true } label: { toolbarIcon("applewatch", color: .gray) }
                    .accessibilityLabel("Huawei Watch GT 6 未连接")
                Button { showSettings = true } label: { toolbarIcon("gearshape") }
                    .accessibilityLabel("设置")
            }
            VStack(alignment: .leading, spacing: 9) {
                Text("语音笔记").font(.system(size: 34, weight: .bold))
                Text("录音、转写与想法，都留在这里。")
                    .font(.system(size: 13)).foregroundStyle(.secondary)
            }
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("搜索标题和转写", text: $search)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                if !search.isEmpty {
                    Button { search = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .foregroundStyle(.secondary).accessibilityLabel("清除搜索")
                }
            }
            .font(.system(size: 15))
            .padding(.horizontal, 13).frame(height: 42)
            .background(NotesStyle.field, in: RoundedRectangle(cornerRadius: 12))
            HStack {
                Text("所有录音").font(.system(size: 19, weight: .bold))
                Spacer()
                Text("\(filtered.count) 条").font(.system(size: 13)).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 24).padding(.top, 9).padding(.bottom, 10)
    }

    private func toolbarIcon(_ name: String, color: Color = .primary) -> some View {
        Image(systemName: name).font(.system(size: 18, weight: .medium))
            .foregroundStyle(color).frame(width: 39, height: 39)
            .background(NotesStyle.field, in: Circle())
    }

    private func row(_ note: VoiceNote) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text(note.title).font(.system(size: 17, weight: .semibold)).lineLimit(1)
                Spacer(minLength: 4)
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
            }
            Text("\(RecordingFormat.date(note.capturedAt)) · \(note.kind.label) · \(RecordingFormat.duration(note.duration))")
                .font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
            Text(note.transcript.isEmpty ? status(note) : note.transcript)
                .font(.system(size: 13))
                .foregroundStyle(note.transcript.isEmpty && note.transcriptionState != .ready ? Color.orange : Color(white: 0.7))
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
