import SwiftUI

struct WatchContentView: View {
    @EnvironmentObject private var recorder: WatchRecorder
    @Environment(\.scenePhase) private var scenePhase
    @State private var pressTask: Task<Void, Never>?
    @State private var interaction = RecordingButtonInteraction()
    @State private var notice: String?
    @State private var noticeTask: Task<Void, Never>?
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
            recordingControl

            HStack(alignment: .firstTextBaseline) {
                Text("录音")
                    .font(.system(size: 14, weight: .bold))
                Spacer(minLength: 8)
                Text("\(recordings.count + sessionIDs.count) 条")
                    .font(.system(size: 10, weight: .medium).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 15)
            .padding(.bottom, 3)

            List {
                ForEach(sessionIDs, id: \.self) { id in
                    sessionRow(id)
                        .listRowInsets(EdgeInsets(top: 0, leading: 9, bottom: 0, trailing: 9))
                        .listRowBackground(Color.clear)
                }
                if recordings.isEmpty && sessionIDs.isEmpty {
                    Text("还没有录音")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
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
                    Button {
                        recorder.retryTransfers()
                    } label: {
                        Label("立即重试同步 · \(recorder.pendingCount)", systemImage: "arrow.clockwise")
                            .font(.system(size: 10, weight: .medium))
                    }
                    .tint(.orange)
                    .listRowBackground(Color.clear)
                }
                if let message = recorder.message {
                    Text(message)
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .listRowBackground(Color.clear)
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
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

    private var recordingControl: some View {
        VStack(spacing: 5) {
            ZStack {
                Circle()
                    .fill(red.opacity(0.16))
                    .frame(width: 60, height: 60)
                Circle()
                    .fill(red)
                    .frame(width: 50, height: 50)
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
                .minimumScaleFactor(0.8)

            HStack(spacing: 4) {
                Circle()
                    .fill(syncColor)
                    .frame(width: 5, height: 5)
                Text(syncSummary)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(syncSummary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 2)
        .padding(.bottom, 7)
    }

    private var syncSummary: String {
        if recorder.isFinishingSession { return "正在保存录音…" }
        if recorder.isRecording { return "录音会自动同步到 iPhone" }
        if recorder.pendingCount > 0 { return recorder.connectivityStatus }
        if recorder.connectivityStatus == "已配对" { return "已同步到 iPhone" }
        return recorder.connectivityStatus
    }

    private var syncColor: Color {
        if recorder.isRecording || recorder.pendingCount > 0 { return .orange }
        if recorder.connectivityStatus == "已配对" || recorder.connectivityStatus.hasPrefix("已配对 · 最近同步") { return .green }
        return .gray
    }

    private func sessionRow(_ id: UUID) -> some View {
        let chunks = recorder.sessionChunks.filter { $0.sessionID == id }.sorted { $0.ordinal < $1.ordinal }
        let state = recorder.sessionSyncStates.first { $0.id == id }
        let end = recorder.sessionEnds.first { $0.sessionID == id }
        let progress = RecordingSessionSyncPresentation(sessionID: id, activeSessionID: recorder.activeRecordingSessionID,
            savedChunkCount: state?.savedChunkCount ?? 0, sealedChunkCount: chunks.count,
            hasEnd: end != nil, syncComplete: state?.isComplete == true)
        let status = sessionSyncLabel(progress.phase)
        let duration = chunks.reduce(0) { $0 + $1.duration }
        let start = chunks.first?.sessionStartedAt
        return VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 5) {
                Text("长录音")
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                Spacer(minLength: 0)
                syncBadge(status, color: sessionSyncColor(progress.phase))
            }
            HStack(spacing: 3) {
                Text(start.map(RecordingFormat.date) ?? "录音时间待同步")
                Spacer(minLength: 2)
                Text(RecordingFormat.duration(duration)).monospacedDigit()
            }
            .font(.system(size: 9))
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 8)
        .overlay(alignment: .top) { Rectangle().fill(Color(white: 0.14)).frame(height: 0.5) }
        .accessibilityElement(children: .combine)
    }

    private func sessionSyncLabel(_ phase: RecordingSessionSyncPresentation.Phase) -> String {
        switch phase {
        case .recording: "录音中"
        case .awaitingEnd: "待同步"
        case .syncing: "同步中"
        case .complete: "已同步"
        }
    }

    private func sessionSyncColor(_ phase: RecordingSessionSyncPresentation.Phase) -> Color {
        switch phase {
        case .recording: red
        case .awaitingEnd, .syncing: .orange
        case .complete: .green
        }
    }

    private func recordingRow(_ item: PendingRecording) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 5) {
                Text("\(item.kind == .thought ? "闪念" : "新录音") \(item.capturedAt.formatted(date: .omitted, time: .shortened))")
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                Spacer(minLength: 0)
                syncBadge(item.uploaded ? "已同步" : "待同步", color: item.uploaded ? .green : .orange)
            }
            HStack(spacing: 3) {
                Text(RecordingFormat.date(item.capturedAt))
                Spacer(minLength: 2)
                Text(RecordingFormat.duration(item.duration)).monospacedDigit()
            }
            .font(.system(size: 9))
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 8)
        .overlay(alignment: .top) { Rectangle().fill(Color(white: 0.14)).frame(height: 0.5) }
    }

    private func syncBadge(_ title: String, color: Color) -> some View {
        Text(title)
            .font(.system(size: 8, weight: .semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 5)
            .padding(.vertical, 3)
            .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 5))
            .fixedSize()
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
}
