import SwiftUI

struct RecordingSessionDetailView: View {
    let sessionID: UUID
    var playbackAllowed = true
    @EnvironmentObject private var content: ContentSegmentModel
    @EnvironmentObject private var sessions: RecordingSessionModel
    @Environment(\.dismiss) private var dismiss
    @StateObject private var playback = RecordingRangePlayback()
    @State private var detail: RecordingSessionDetail?
    @State private var ranges: [RecordingSourceRange] = []
    @State private var loadError = false
    @State private var confirmDelete = false
    @State private var deleting = false

    var body: some View {
        NavigationStack {
            List {
                if let session = detail?.session ?? sessions.session(sessionID) {
                    Section {
                        Text("完整录音").font(.title2.bold())
                        if let start = session.startedAt { Text(start, style: .date); Text(start, style: .time) }
                        else { Text("录音时间待同步") }
                        Text(RecordingFormat.duration(session.recordedDuration)).monospacedDigit()
                        Text(LocalizedStringKey(RecordingSessionPresentation.status(session)))
                        AudioSourceProcessingView(sourceID:.init(kind:.session,id:sessionID))
                    }
                    Section("回听完整录音") {
                        audioControls
                        if !playback.gapPositions.isEmpty { Text("播放将跳过缺口；缺失音频不会填充为静音。").font(.footnote) }
                    }
                    Section("同步状态") {
                        Text("已保存 \(session.savedCount) 个分片")
                        if let expected = session.expectedCount { Text("预期 \(expected) 个分片") }
                        if session.endRevision == nil { Text("录音结束状态待同步") }
                        if session.interrupted { Text("录音已中断").foregroundStyle(.orange) }
                    }
                    if let location = session.location {
                        Section("采集位置") {
                            Text("地点待解析")
                            Text(location.title).font(.footnote)
                            Text("仅为一次采集点，不能推断全程位置。").font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                    Section("内容片段") {
                        DesktopSummaryPanel(recordID: "session:" + sessionID.uuidString)
                        ContentSegmentSourceListView(sourceID:.init(kind:.session,id:sessionID),playbackAllowed:playbackAllowed)
                    }
                    Section("分片与缺口") {
                        ForEach(detail?.chunks ?? [], id: \.id) { chunk in
                            HStack { Text("分片 \(chunk.ordinal + 1)"); Spacer(); Text(RecordingFormat.duration(chunk.duration)).monospacedDigit() }
                                .accessibilityElement(children: .combine)
                        }
                        ForEach(Array((detail?.gaps ?? []).enumerated()), id: \.offset) { _, gap in
                            VStack(alignment: .leading) {
                                Text("录音缺口").foregroundStyle(.orange)
                                if let first = gap.firstOrdinal, let last = gap.lastOrdinal { Text("分片 \(first + 1) 至 \(last + 1) 尚未同步") }
                                if let start = gap.startOffset, let end = gap.endOffset { Text("缺口 \(RecordingFormat.duration(start)) – \(RecordingFormat.duration(end))") }
                            }.accessibilityElement(children: .combine)
                        }
                    }
                    Section {
                        Button("删除完整录音", role: .destructive) { confirmDelete = true }.disabled(deleting)
                    }
                } else if detail != nil {
                    Text("录音已删除或暂不可用")
                } else { ProgressView() }
                if loadError { Text("无法读取完整录音，请解锁后重试。").foregroundStyle(.orange) }
                if detail?.cleanupPending == true || sessions.cleanupIDs.contains(sessionID) {
                    Text("文件清理待重试").foregroundStyle(.orange)
                    Button("重试清理") { sessions.refresh(recover: true) }
                }
                if let error = sessions.errorMessage { Text(LocalizedStringKey(error)).foregroundStyle(.orange) }
                if loadError { Button("重试") { Task { await reload() } } }
            }
            .navigationTitle("完整录音")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
            .confirmationDialog("删除完整录音？", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("删除完整录音", role: .destructive) {
                    playback.stop(); deleting = true
                    Task {
                        if await sessions.delete(sessionID) { playback.stop(); dismiss() }
                        deleting = false
                    }
                }
            } message: { Text("这会删除本机完整会话、内容片段及全部原始音频。") }
        }
        .task(id: sessions.revision) { await reload() }
        .onChange(of: playbackAllowed) { _, allowed in if !allowed { playback.stop() } }
        .onDisappear { playback.stop() }
    }

    private var audioControls: some View {
        VStack(spacing: 12) {
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    HStack(alignment: .center, spacing: 2) {
                        ForEach(playback.waveform.indices, id: \.self) { index in
                            Capsule().fill(DaybookStyle.accent.opacity(0.6))
                                .frame(height: max(3, CGFloat(playback.waveform[index]) * 40))
                        }
                    }
                    ForEach(Array(playback.gapPositions.enumerated()), id: \.offset) { _, time in
                        Rectangle().fill(.orange).frame(width: 2)
                            .offset(x: geometry.size.width * time / max(1, playback.duration))
                    }
                }
            }.frame(height: 44).accessibilityHidden(true)
            Button(action: playback.toggle) {
                Label(LocalizedStringKey(playback.isPlaying ? "暂停播放" : "播放录音"), systemImage: playback.isPlaying ? "pause.fill" : "play.fill")
            }.disabled(!playbackAllowed || playback.duration <= 0)
            Slider(value: Binding(get: { playback.position }, set: { playback.seek($0) }), in: 0...max(1, playback.duration))
                .disabled(!playbackAllowed || playback.duration <= 0)
                .accessibilityLabel("播放进度")
                .accessibilityValue("\(RecordingFormat.duration(playback.position)) / \(RecordingFormat.duration(playback.duration))")
            HStack { Text(RecordingFormat.duration(playback.position)); Spacer(); Text(RecordingFormat.duration(playback.duration)) }.monospacedDigit()
            if !playbackAllowed { Text("录音期间暂停回听").font(.footnote) }
            if let error = playback.error { Text(LocalizedStringKey(error)).foregroundStyle(.orange) }
        }
    }

    private func reload() async {
        do {
            let value = try await sessions.detail(sessionID)
            guard !Task.isCancelled else { return }
            detail = value; loadError = false
            if value.ranges != ranges { ranges = value.ranges; playback.load(ranges) }
            if value.session == nil { playback.stop() }
        } catch { if !Task.isCancelled { loadError = true } }
    }
}
