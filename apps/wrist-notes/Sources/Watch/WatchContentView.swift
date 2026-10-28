import SwiftUI

private enum WatchPalette {
    static let canvas = Color(red: 0.025, green: 0.045, blue: 0.055)
    static let ink = Color(red: 0.91, green: 0.95, blue: 0.94)
    static let gold = Color(red: 0.86, green: 0.75, blue: 0.49)
    static let muted = Color(red: 0.52, green: 0.62, blue: 0.66)
    static let line = Color.white.opacity(0.10)
}

struct WatchContentView: View {
    @EnvironmentObject private var recorder: WatchRecorder
    @Environment(\.scenePhase) private var scenePhase
    @State private var page: Int
    @State private var interaction = RecordingButtonInteraction()
    @State private var pressTask: Task<Void, Never>?
    @State private var noticeTask: Task<Void, Never>?
    @State private var notice: String?
    @State private var deletion: WatchLibraryEntry?
    init(startOnLibrary: Bool = false) { _page = State(initialValue: startOnLibrary ? 1 : 0) }

    var body: some View {
        TabView(selection: $page) {
            home.tag(0)
            Group {
                if scenePhase == .active && page == 1 {
                    TimelineView(.periodic(from: .now, by: 1)) { _ in library }
                } else { library }
            }.tag(1)
        }
        .tabViewStyle(.verticalPage)
        .background(WatchPalette.canvas.ignoresSafeArea())
        .alert("录音提示", isPresented: Binding(get: { recorder.recordingError != nil },
            set: { if !$0 { recorder.recordingError = nil } })) {
            Button("好") { recorder.recordingError = nil }
        } message: { Text(recorder.recordingError ?? "") }
        .confirmationDialog("从手表删除这条录音？", isPresented: Binding(
            get: { deletion != nil }, set: { if !$0 { deletion = nil } }), titleVisibility: .visible) {
            Button("删除录音", role: .destructive) {
                guard let entry = deletion else { return }
                if entry.isSession { recorder.deleteSession(entry.recordingID) }
                else { recorder.delete(entry.recordingID) }
                deletion = nil
            }
            Button("取消", role: .cancel) { deletion = nil }
        } message: {
            Text(deletion.map { recorder.transferPresentation(for: $0).phase == .synced } == true
                 ? "只删除手表上的原件，手机中已保存的记录会保留。"
                 : "尚未确认同步到手机，删除后无法从手表恢复。")
        }
        .onChange(of: page) { _, _ in interruptPress() }
        .onChange(of: scenePhase) { _, value in if value != .active { interruptPress() } }
        .onDisappear { interruptPress(); noticeTask?.cancel() }
    }

    private var home: some View {
        GeometryReader { geometry in
            let size = min(geometry.size.width * 0.80, geometry.size.height * 0.54)
            VStack(spacing: 0) {
                Spacer(minLength: 0)
                WatchRecordingLogo(recording: recorder.isRecording && !recorder.isFinishingSession,
                                   cancelling: interaction.cancelOnRelease, active: scenePhase == .active && page == 0)
                    .frame(width: size, height: size)
                    .contentShape(Circle())
                    .gesture(recordGesture)
                    .accessibilityLabel(recorder.isRecording ? "停止并保存录音" : "开始录音")
                    .accessibilityHint("轻点长录音，按住录闪念，松开保存；快速上滑进入录音列表")
                    .accessibilityAddTraits(.isButton)
                    .accessibilityIdentifier("watch.record")
                    .accessibilityAction { handle(recorder.isRecording ? .stopLong : .startLong) }
                Spacer(minLength: 4)
                Text(recorder.isRecording ? WatchRecordingLibrary.durationText(recorder.elapsed) : "轻点开始录音")
                    .font(.system(size: recorder.isRecording ? 25 : 16, weight: .semibold, design: .rounded).monospacedDigit())
                    .foregroundStyle(WatchPalette.ink).lineLimit(1).minimumScaleFactor(0.8)
                HStack(spacing: 4) {
                    if recorder.isRecording { Circle().fill(.red).frame(width: 4, height: 4) }
                    Text(caption).font(.system(size: 10, weight: .medium))
                }
                .foregroundStyle(interaction.cancelOnRelease ? .red : WatchPalette.muted)
                .lineLimit(1).minimumScaleFactor(0.75).padding(.top, 4)
                Spacer(minLength: 4)
                Button { page = 1 } label: {
                    VStack(spacing: 1) {
                        Image(systemName: "chevron.up").font(.system(size: 9, weight: .semibold))
                        Text("录音列表").font(.system(size: 9))
                    }.frame(maxWidth: .infinity, minHeight: 22)
                }
                .buttonStyle(.plain).foregroundStyle(WatchPalette.muted)
                .accessibilityLabel("查看录音列表").accessibilityIdentifier("watch.library.open")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, 12)
        }
    }

    private var library: some View {
        let entries = recorder.libraryEntries
        let today = WatchRecordingLibrary.today(entries, now: .now)
        return List {
            VStack(alignment: .leading, spacing: 9) {
                Text("今日录音").font(.system(size: 12, weight: .semibold)).foregroundStyle(WatchPalette.muted)
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(WatchRecordingLibrary.durationText(today.duration))
                            .font(.system(size: 24, weight: .semibold, design: .rounded).monospacedDigit())
                            .lineLimit(1).minimumScaleFactor(0.7)
                        Text("总时长").font(.system(size: 10)).foregroundStyle(WatchPalette.muted)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                    Rectangle().fill(WatchPalette.line).frame(width: 1, height: 30)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("\(today.count)").font(.system(size: 24, weight: .semibold, design: .rounded).monospacedDigit())
                        Text("总条数").font(.system(size: 10)).foregroundStyle(WatchPalette.muted)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.foregroundStyle(WatchPalette.ink)
            }
            .padding(.top, 3).padding(.bottom, 12)
            .listRowBackground(Color.clear).listRowInsets(.init(top: 0, leading: 9, bottom: 0, trailing: 9))
            .accessibilityElement(children: .combine).accessibilityIdentifier("watch.library.today")
            if entries.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "waveform").font(.system(size: 25)).foregroundStyle(WatchPalette.gold)
                    Text("还没有录音").font(.system(size: 14, weight: .medium))
                    Text("下滑回到首页，记下第一刻")
                        .font(.system(size: 10)).foregroundStyle(WatchPalette.muted)
                }
                .frame(maxWidth: .infinity).padding(.vertical, 22).listRowBackground(Color.clear)
            }
            ForEach(entries) { entry in
                recordingRow(entry, state: recorder.transferPresentation(for: entry))
                    .listRowInsets(.init(top: 0, leading: 9, bottom: 0, trailing: 9))
                    .listRowBackground(Color.clear)
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button("删除", role: .destructive) { deletion = entry }.disabled(entry.isActive)
                    }
            }
            if recorder.pendingCount > 0 {
                Button { recorder.retryTransfers() } label: {
                    Label("重试待同步 · \(recorder.pendingCount)", systemImage: "arrow.clockwise")
                        .font(.system(size: 11, weight: .medium))
                }.tint(WatchPalette.gold).listRowBackground(Color.clear)
            }
            if let message = recorder.message {
                Text(message).font(.system(size: 10)).foregroundStyle(WatchPalette.muted)
                    .fixedSize(horizontal: false, vertical: true).listRowBackground(Color.clear)
            }
        }
        .listStyle(.plain).scrollContentBackground(.hidden)
        .background(WatchPalette.canvas)
        .accessibilityIdentifier("watch.library")
    }

    private func recordingRow(_ entry: WatchLibraryEntry, state: WatchTransferPresentation) -> some View {
        let tint = state.phase == .synced ? Color.green :
            (state.phase == .failed ? Color.orange : WatchPalette.gold)
        return VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 5) {
                Image(systemName: entry.kind == .thought ? "sparkle" : "waveform")
                    .font(.system(size: 10)).foregroundStyle(WatchPalette.gold)
                Text(entry.title).font(.system(size: 13, weight: .semibold))
                Spacer(minLength: 2)
                Text(WatchRecordingLibrary.durationText(entry.duration))
                    .font(.system(size: 11, weight: .medium).monospacedDigit())
            }.foregroundStyle(WatchPalette.ink)
            Text(entry.startedAt.formatted(Calendar.current.isDateInToday(entry.startedAt)
                ? .dateTime.hour().minute() : .dateTime.month().day().hour().minute()))
                .font(.system(size: 10)).foregroundStyle(WatchPalette.muted)
            HStack(spacing: 5) {
                Image(systemName: state.phase == .failed ? "exclamationmark.circle" :
                    (state.phase == .synced ? "checkmark.circle.fill" : "iphone.and.arrow.forward"))
                    .font(.system(size: 9))
                Text(state.title).font(.system(size: 10, weight: .medium)).lineLimit(1).minimumScaleFactor(0.8)
                Spacer(minLength: 0)
                transferSteps(state, tint: tint)
            }.foregroundStyle(tint)
            if let detail = state.detail {
                Text(detail).font(.system(size: 9)).foregroundStyle(WatchPalette.muted)
            }
            if let fraction = state.fraction, fraction.isFinite {
                ProgressView(value: min(1, max(0, fraction)))
                    .tint(WatchPalette.gold).scaleEffect(y: 0.65)
            }
        }
        .padding(.vertical, 12)
        .overlay(alignment: .top) { Rectangle().fill(WatchPalette.line).frame(height: 0.5) }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("watch.recording.\(entry.id)")
    }

    private func transferSteps(_ state: WatchTransferPresentation, tint: Color) -> some View {
        HStack(spacing: 2) {
            ForEach(0..<3) { step in
                if step > 0 { Capsule().fill(step <= state.step ? tint.opacity(0.6) : WatchPalette.line).frame(width: 6, height: 1) }
                Circle().fill(step <= state.step ? tint : WatchPalette.line).frame(width: 4, height: 4)
            }
        }
        .accessibilityLabel("本机保存、传输、手机确认，第 \(state.step + 1) 步")
    }

    private var caption: String {
        if interaction.isThought { return interaction.cancelOnRelease ? "松开取消闪念" : "闪念 · 松开保存，上滑取消" }
        if recorder.isFinishingSession { return "正在保存录音…" }
        if recorder.isRecording { return "正在录音 · 轻点停止" }
        if interaction.isArming { return "继续按住，记下闪念" }
        return notice ?? "按住记闪念 · 上滑看记录"
    }
    private var recordGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if !interaction.isActive {
                    noticeTask?.cancel(); notice = nil
                    interaction.begin(at: Date.timeIntervalSinceReferenceDate, isRecording: recorder.isRecording)
                    pressTask = Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(450))
                        guard !Task.isCancelled else { return }
                        handle(interaction.recognizeHold(at: Date.timeIntervalSinceReferenceDate))
                    }
                }
                interaction.move(x: value.translation.width, y: value.translation.height)
            }
            .onEnded { value in
                pressTask?.cancel()
                interaction.move(x: value.translation.width, y: value.translation.height)
                let thought = interaction.isThought
                handle(interaction.end(at: Date.timeIntervalSinceReferenceDate))
                if !thought && value.translation.height < -30 { page = 1 }
            }
    }
    private func handle(_ action: RecordingButtonInteraction.Action?) {
        switch action {
        case .startLong: recorder.start(.long)
        case .stopLong: recorder.stop()
        case .startThought: recorder.start(.thought)
        case .saveThought: if recorder.releaseThought() { showNotice("闪念已保存") }
        case .cancelThought: recorder.cancelThought(); showNotice("闪念已取消")
        case .discardShortThought: recorder.cancelThought(); showNotice("闪念太短，未保存")
        case nil: break
        }
    }
    private func interruptPress() { pressTask?.cancel(); handle(interaction.interrupt()) }
    private func showNotice(_ text: String) {
        noticeTask?.cancel(); notice = text
        noticeTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }; notice = nil
        }
    }
}

private struct WatchRecordingLogo: View {
    let recording: Bool
    let cancelling: Bool
    let active: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isLuminanceReduced) private var dimmed
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 15, paused: !recording || !active || reduceMotion || dimmed)) { timeline in
            GeometryReader { geometry in
                let size = min(geometry.size.width, geometry.size.height)
                let time = recording && !reduceMotion && !dimmed ? timeline.date.timeIntervalSinceReferenceDate : 0
                let phase = time.truncatingRemainder(dividingBy: 3.8) / 3.8
                let accent = cancelling ? Color.red : WatchPalette.gold
                ZStack {
                    Circle().fill(Color(red: 0.10, green: 0.18, blue: 0.22).opacity(recording ? 0.7 : 0.45))
                        .scaleEffect(1.06)
                    WiseLifeMark(ink: WatchPalette.ink.opacity(recording ? 0.70 : 1), gold: accent)
                    if recording {
                        WiseLifeSpiral().trim(from: phase, to: min(1, phase + 0.22))
                            .stroke(accent, style: StrokeStyle(lineWidth: size * 0.112, lineCap: .round))
                            .shadow(color: accent.opacity(0.4), radius: 4)
                        if phase + 0.22 > 1 {
                            WiseLifeSpiral().trim(from: 0, to: phase + 0.22 - 1)
                                .stroke(accent, style: StrokeStyle(lineWidth: size * 0.112, lineCap: .round))
                        }
                        Circle().fill(accent).frame(width: size * 0.105, height: size * 0.105)
                            .scaleEffect(1.12 + sin(time * 3) * 0.12)
                            .shadow(color: accent.opacity(0.6), radius: 5)
                            .position(x: size * 0.434, y: size * 0.528)
                    }
                }
                .scaleEffect(recording ? 1 + sin(time * 2.3) * 0.012 : 1)
            }
        }
        .accessibilityHidden(true)
    }
}
