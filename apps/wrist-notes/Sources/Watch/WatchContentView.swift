import SwiftUI

struct WatchContentView: View {
    @EnvironmentObject private var recorder: WatchRecorder
    @Environment(\.scenePhase) private var scenePhase
    @State private var pressTask: Task<Void, Never>?
    @State private var interaction = RecordingButtonInteraction()
    @State private var notice: String?
    @State private var noticeTask: Task<Void, Never>?
    @State private var expandedSessionIDs = Set<UUID>()
    private let red = Color(red: 0.96, green: 0.17, blue: 0.21)

    private var recordings: [PendingRecording] {
        recorder.pending.sorted { $0.capturedAt > $1.capturedAt }
    }

    private var sessionIDs: [UUID] {
        let ids = Set(recorder.sessionChunks.map(\.sessionID) + recorder.sessionEnds.map(\.sessionID) + recorder.sessionSyncStates.map(\.id) + [recorder.activeRecordingSessionID].compactMap { $0 })
        return ids.sorted { left, right in
            let a = recorder.sessionChunks.first { $0.sessionID == left }?.sessionStartedAt ?? .distantPast
            let b = recorder.sessionChunks.first { $0.sessionID == right }?.sessionStartedAt ?? .distantPast
            return a == b ? left.uuidString < right.uuidString : a > b
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 7) {
                ZStack {
                    Circle().fill(red.opacity(0.16)).frame(width: 60, height: 60)
                    Circle().fill(red).frame(width: 50, height: 50)
                    RoundedRectangle(cornerRadius: recorder.isRecording ? 4 : 20)
                        .fill(.white)
                        .frame(width: 18, height: 18)
                }
                .contentShape(Circle())
                .gesture(recordGesture)
                .accessibilityLabel(recorder.isRecording ? "结束录音" : "开始录音")
                .accessibilityHint("轻点长录音，按住说闪念，松开保存，上滑取消")
                .accessibilityAddTraits(.isButton)
                .accessibilityAction {
                    handle(recorder.isRecording ? .stopLong : .startLong)
                }
                Text(caption)
                    .font(.system(size: 10, weight: .medium).monospacedDigit())
                    .foregroundStyle(recorder.isRecording ? red : .secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 3)
            .padding(.bottom, 8)

            HStack {
                Text("录音").font(.system(size: 14, weight: .bold))
                Spacer()
                Text("\(recordings.count + sessionIDs.count)").font(.caption2).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 15)
            .padding(.bottom, 4)

            List {
                ForEach(sessionIDs, id: \.self) { id in sessionRow(id) }
                if recordings.isEmpty && sessionIDs.isEmpty {
                    Text("还没有录音")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .listRowBackground(Color.clear)
                }
                ForEach(recordings) { item in
                    recordingRow(item)
                        .listRowInsets(EdgeInsets(top: 0, leading: 9, bottom: 0, trailing: 9))
                        .listRowBackground(Color.clear)
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button("删除", role: .destructive) { recorder.delete(item.id) }
                        }
                }
                if recorder.pendingCount > 0 {
                    Button("重试上传 · \(recorder.pendingCount) 条") { recorder.retryTransfers() }
                        .font(.caption2).foregroundStyle(.orange)
                    Text(recorder.connectivityStatus)
                        .font(.caption2).foregroundStyle(.secondary)
                        .listRowBackground(Color.clear)
                }
                if let message = recorder.message {
                    Text(message).font(.caption2).foregroundStyle(.secondary)
                        .listRowBackground(Color.clear)
                }
            }
            .listStyle(.plain)
        }
        .background(Color(red: 0.03, green: 0.03, blue: 0.035))
        .alert("录音提示", isPresented: Binding(
            get: { recorder.recordingError != nil },
            set: { if !$0 { recorder.recordingError = nil } }
        )) { Button("好") { recorder.recordingError = nil } } message: {
            Text(recorder.recordingError ?? "")
        }
        .onDisappear { interruptPress() }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { interruptPress() }
        }
    }

    private func sessionRow(_ id: UUID) -> some View {
        let chunks = recorder.sessionChunks.filter { $0.sessionID == id }.sorted { $0.ordinal < $1.ordinal }
        let state = recorder.sessionSyncStates.first { $0.id == id }
        let end = recorder.sessionEnds.first { $0.sessionID == id }
        let progress = RecordingSessionSyncPresentation(sessionID: id, activeSessionID: recorder.activeRecordingSessionID,
            savedChunkCount: state?.savedChunkCount ?? 0, sealedChunkCount: chunks.count,
            hasEnd: end != nil, syncComplete: state?.isComplete == true)
        let expanded = expandedSessionIDs.contains(id)
        return VStack(alignment: .leading, spacing: 6) {
            Button {
                if expanded { expandedSessionIDs.remove(id) } else { expandedSessionIDs.insert(id) }
            } label: {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("完整录音").font(.caption)
                        if let start = chunks.first?.sessionStartedAt { Text(start, style: .time).font(.caption2) }
                        else { Text("录音时间待同步").font(.caption2) }
                        Text(RecordingFormat.duration(chunks.reduce(0) { $0 + $1.duration })).font(.caption2).monospacedDigit()
                        Text(LocalizedStringKey(progress.phase == .recording ? "录音进行中" :
                            (progress.isComplete ? "已同步到当前 iPhone" : "会话尚未同步完成")))
                            .font(.caption2).foregroundStyle(.secondary)
                        Text("已保存 \(progress.savedChunkCount)/\(progress.sealedChunkCount) 个已封口分片到 iPhone")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: expanded ? "chevron.up" : "chevron.down").font(.caption2).accessibilityHidden(true)
                }
            }.buttonStyle(.plain)
                .accessibilityElement(children: .combine)
                .accessibilityValue(Text(LocalizedStringKey(expanded ? "已展开" : "已折叠")))
                .accessibilityHint("展开查看分片进度")
            if expanded {
                ForEach(chunks) { chunk in
                    Text("分片 \(chunk.ordinal + 1) · \(RecordingFormat.duration(chunk.duration))").font(.caption2)
                }
                if progress.phase == .awaitingEnd { Text("录音结束状态待同步").font(.caption2) }
                else if progress.phase == .syncing { Text("会话尚未同步完成").font(.caption2) }
                if end?.interrupted == true { Text("录音已中断").font(.caption2).foregroundStyle(.orange) }
            }
        }
    }

    private var caption: String {
        if interaction.isThought {
            if interaction.cancelOnRelease { return "松开取消闪念" }
            return "闪念 · \(RecordingFormat.duration(recorder.elapsed)) · 松开保存"
        }
        if recorder.isFinishingSession { return "正在保存录音…" }
        if recorder.isRecording { return "长录音 · \(RecordingFormat.duration(recorder.elapsed))" }
        if interaction.isArming { return "继续按住录闪念" }
        return notice ?? "轻点长录音 · 按住闪念"
    }

    private var recordGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if !interaction.isActive {
                    noticeTask?.cancel()
                    notice = nil
                    interaction.begin(at: Date.timeIntervalSinceReferenceDate, isRecording: recorder.isRecording)
                    pressTask = Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(450))
                        guard !Task.isCancelled else { return }
                        handle(interaction.recognizeHold(at: Date.timeIntervalSinceReferenceDate))
                    }
                }
                interaction.move(x: value.translation.width, y: value.translation.height)
            }
            .onEnded { _ in
                pressTask?.cancel()
                handle(interaction.end(at: Date.timeIntervalSinceReferenceDate))
            }
    }

    private func handle(_ action: RecordingButtonInteraction.Action?) {
        switch action {
        case .startLong: recorder.start(.long)
        case .stopLong: recorder.stop()
        case .startThought: recorder.start(.thought)
        case .saveThought:
            if recorder.releaseThought() { showNotice("闪念已保存") }
        case .cancelThought: recorder.cancelThought(); showNotice("闪念已取消")
        case .discardShortThought: recorder.cancelThought(); showNotice("闪念太短，未保存")
        case nil: break
        }
    }

    private func interruptPress() {
        pressTask?.cancel()
        handle(interaction.interrupt())
    }

    private func showNotice(_ value: String) {
        noticeTask?.cancel()
        notice = value
        noticeTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.7))
            guard !Task.isCancelled else { return }
            notice = nil
        }
    }

    private func recordingRow(_ item: PendingRecording) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 3) {
                Text("\(item.kind == .thought ? "闪念" : "新录音") \(item.capturedAt.formatted(date: .omitted, time: .shortened))")
                    .font(.system(size: 12, weight: .semibold)).lineLimit(1)
                Spacer(minLength: 0)
                Text(item.uploaded ? "已上传" : "未上传")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(item.uploaded ? .green : .orange)
            }
            HStack {
                Text(RecordingFormat.date(item.capturedAt))
                Spacer(minLength: 2)
                Text(RecordingFormat.duration(item.duration)).monospacedDigit()
            }
            .font(.system(size: 9)).foregroundStyle(.secondary)
        }
        .padding(.vertical, 8)
        .overlay(alignment: .top) { Rectangle().fill(Color(white: 0.14)).frame(height: 0.5) }
    }
}
