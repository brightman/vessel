import SwiftUI

struct ContentSegmentDetailView: View {
    let segmentID: UUID
    var playbackAllowed = true
    var citation: DayRecord.ContentProvenance? = nil
    @EnvironmentObject private var content: ContentSegmentModel
    @EnvironmentObject private var notes: NotesModel
    @Environment(\.dismiss) private var dismiss
    @StateObject private var playback = RecordingRangePlayback()
    @State private var detail: ContentSegmentDetail?
    @State private var ranges: [RecordingSourceRange] = []
    @State private var tab = 0
    @State private var limit = 100
    @State private var confirmDelete = false
    @State private var showOriginal = false
    @State private var didSeek = false
    @State private var missing = false

    var body: some View {
        NavigationStack {
            List {
                if let detail {
                    Section {
                        Text(detail.segment.title.isEmpty ? "录音片段" : detail.segment.title).font(.title2.bold())
                        Text(detail.source.capturedAt.addingTimeInterval(detail.segment.ranges.first?.sessionStartOffset ?? 0),style:.date)
                        Text(RecordingFormat.duration(playback.duration)).monospacedDigit()
                        if !detail.segment.isFinal { Text("片段仍在处理中，边界与文字可能更新。").foregroundStyle(.secondary) }
                    }
                    Section("回听片段") { player }
                    Section {
                        Picker("内容",selection:$tab) { Text("总结").tag(0); Text("全文").tag(1) }.pickerStyle(.segmented)
                        if tab == 0 {
                            DesktopSummaryPanel(recordID: detail.segment.sourceID.key)
                            Text(detail.segment.summary.isEmpty ? "尚无本机总结，可查看全文或稍后重试。" : detail.segment.summary).textSelection(.enabled)
                        } else {
                            ForEach(Array(detail.spans.enumerated()),id:\.offset) { _, span in
                                VStack(alignment:.leading) {
                                    Button(RecordingFormat.duration(span.start)) { seek(span.start) }.font(.caption)
                                    if let speaker = span.speakerID { Text(speaker).font(.caption).foregroundStyle(.secondary) }
                                    Text(span.text).textSelection(.enabled)
                                }
                            }
                            if detail.spans.isEmpty { Text("此片段尚无全文；空转写不表示无人声。") }
                            if detail.hasMore { Button("载入更多全文") { limit += 100; Task { await reload() } } }
                        }
                    }
                    Section("处理状态") { AudioSourceProcessingView(sourceID:detail.segment.sourceID) }
                    Section("编辑片段") {
                        Button("在播放位置拆分") { split(detail) }.disabled(!playbackAllowed || playback.position <= 0 || playback.position >= playback.duration)
                        ForEach(detail.neighbors.filter { $0.id != segmentID }) { neighbor in
                            Button("与相邻片段合并：\(neighbor.title.isEmpty ? "录音片段" : neighbor.title)") { merge(detail.segment,neighbor) }
                        }
                        Button("撤销上次片段编辑") { Task { if await content.mutate(sourceID:detail.segment.sourceID,{ try $0.undo(sourceID:detail.segment.sourceID) }) { dismiss() } } }
                        Button("查看完整录音") { playback.stop(); showOriginal = true }
                        Button("删除片段",role:.destructive) { confirmDelete = true }
                        Text("片段删除只隐藏派生内容；完整录音及原始音频仍保留。").font(.footnote).foregroundStyle(.secondary)
                    }
                } else if missing { Text("片段已更新或移除，请返回时间轴查看。") }
                else { ProgressView() }
                if let error = content.errorMessage { Text(LocalizedStringKey(error)).foregroundStyle(.orange); Button("重试") { Task { await reload() } } }
            }
            .navigationTitle("录音片段")
            .toolbar { ToolbarItem(placement:.confirmationAction) { Button("完成") { dismiss() } } }
            .confirmationDialog("删除片段？",isPresented:$confirmDelete,titleVisibility:.visible) {
                Button("删除片段",role:.destructive) {
                    guard let segment = detail?.segment else { return }
                    Task { if await content.mutate(sourceID:segment.sourceID,{ try $0.delete(id:segment.id,expectedRevision:segment.revision) }) { playback.stop(); dismiss() } }
                }
            } message: { Text("仅隐藏此派生片段，保留完整录音。可撤销上次片段编辑。") }
            .sheet(isPresented:$showOriginal) {
                if let source = detail?.segment.sourceID {
                    if source.kind == .session { RecordingSessionDetailView(sessionID:source.id,playbackAllowed:playbackAllowed) }
                    else { DaybookVoiceDetailView(id:source.id,playbackAllowed:playbackAllowed) }
                }
            }
        }
        .task(id:content.revision) { await reload() }
        .onChange(of:playbackAllowed) { _, allowed in if !allowed { playback.stop() } }
        .onDisappear { playback.stop() }
    }
    private var player: some View {
        VStack(spacing:12) {
            Button(action:playback.toggle) { Label(playback.isPlaying ? "暂停播放" : "播放录音",systemImage:playback.isPlaying ? "pause.fill" : "play.fill") }.disabled(!playbackAllowed || playback.duration <= 0)
            Slider(value:Binding(get:{ playback.position },set:{ playback.seek($0) }),in:0...max(1,playback.duration)).disabled(!playbackAllowed || playback.duration <= 0)
            Text("\(RecordingFormat.duration(playback.position)) / \(RecordingFormat.duration(playback.duration))").monospacedDigit()
            if !playback.gapPositions.isEmpty { Text("播放将跳过缺口；缺失音频不会填充为静音。").font(.footnote) }
            if !playbackAllowed { Text("录音期间暂停回听").font(.footnote) }
            if let error = playback.error { Text(LocalizedStringKey(error)).foregroundStyle(.orange) }
        }
    }
    private var provenanceRanges: [DayRecord.ContentProvenance.AudioRange] {
        detail?.segment.ranges.map { .init(chunkID:$0.chunkID,startFrame:$0.startFrame,endFrame:$0.endFrame,sampleRate:$0.sampleRate,sourceOffset:$0.sessionStartOffset) } ?? []
    }
    private func seek(_ sourceTime: Double) {
        if let time = ContentSegmentPresentation.playbackTime(at:sourceTime,ranges:provenanceRanges) { playback.seek(time) }
    }
    private func split(_ detail: ContentSegmentDetail) {
        guard let plan = try? RecordingRangePlan(ranges), let position = plan.locate(playback.position) else { return }
        let range = ranges[position.rangeIndex]
        let time = range.sessionStartOffset + Double(position.frame-range.startFrame)/range.sampleRate
        let segment = detail.segment
        Task { if await content.mutate(sourceID:segment.sourceID,{ _ = try $0.split(id:segment.id,at:time,expectedRevision:segment.revision) }) { playback.stop(); dismiss() } }
    }
    private func merge(_ first: ContentSegment, _ second: ContentSegment) {
        Task { if await content.mutate(sourceID:first.sourceID,{ _ = try $0.merge(ids:[first.id,second.id],expectedRevisions:[first.revision,second.revision]) }) { playback.stop(); dismiss() } }
    }
    private func reload() async {
        do {
            let value = try await content.detail(segmentID,limit:limit)
            guard !Task.isCancelled else { return }
            detail = value; missing = value == nil
            let newRanges = value?.segment.ranges.map(\.recordingRange) ?? []
            if ranges != newRanges { ranges = newRanges; playback.load(newRanges) }
            if value == nil { playback.stop() }
            if !didSeek, let citation, let current = value?.segment,
               citation.segmentRevision == current.revision, citation.contentSignature == current.provenance.contentSignature {
                didSeek = true
                if let start = citation.ranges.first?.sourceOffset { seek(start) }
            }
        } catch { content.errorMessage = "无法读取录音片段，请解锁后重试。" }
    }
}

/// Existing settings remains the only resource download entry. Retry never downloads models.
struct AudioSourceProcessingView: View {
    let sourceID: AudioSourceID
    @EnvironmentObject private var processing: AudioProcessingModel
    @EnvironmentObject private var content: ContentSegmentModel
    @EnvironmentObject private var settings: AppSettings
    @State private var showSettings = false
    @State private var enrichmentConfirmation: AIConfiguration?
    @State private var enrichmentRevision = 0
    var body: some View {
        VStack(alignment:.leading,spacing:10) {
            if let status = processing.statuses[sourceID] {
                let state = AudioProcessingPresentation(states:status.progress.states,asr:status.asr.presentation,vad:status.vad.presentation,speaker:status.speaker.presentation)
                Text("已处理窗口 \(state.completedWindows) / \(state.totalWindows)")
                ProgressView(value:Double(state.completedWindows),total:Double(max(1,state.totalWindows)))
                if status.sourceUnavailable { Text("部分原始音频暂不可用，缺口不计为静音。") }
                ForEach(Array(state.messages.enumerated()),id:\.offset) { _, message in Text(LocalizedStringKey(message)) }
            } else { Text("等待本机处理状态") }
            if let enrichment = processing.enrichmentStatuses[sourceID] {
                Text(LocalizedStringKey(enrichmentLabel(enrichment)))
            }
            HStack {
                Button("重试处理") { processing.retry(sourceID) }
                Button("取消转写处理") { processing.cancel(sourceID) }
            }
            Text("总结模型：\(settings.ai.label)")
            if settings.ai.isRemote && settings.requiresRemoteAIConfirmation {
                Text("点击总结并确认后，将这段录音的转写文字发送给所选模型。")
            }
            Button("生成 / 重试片段总结") {
                if settings.ai.isRemote && settings.requiresRemoteAIConfirmation {
                    enrichmentRevision = settings.aiRevision; enrichmentConfirmation = settings.ai
                } else { processing.retryEnrichment(sourceID) }
            }
            Button("语音转写模型设置") { showSettings = true }
            if content.records.contains(where:{ $0.contentProvenance?.sourceID == sourceID.id }) {
                Text("内容片段已显示在时间轴；完整录音仍可回听。").font(.footnote)
            }
        }
        .sheet(isPresented:$showSettings) { TranscriptionSettingsView(settings:settings) }
        .sheet(isPresented: Binding(get: { enrichmentConfirmation != nil }, set: { if !$0 { enrichmentConfirmation = nil } })) {
            if let configuration = enrichmentConfirmation {
                DaybookSheetLayout(title: "整理这段录音", onClose: { enrichmentConfirmation = nil }) {
                    VStack(alignment: .leading, spacing: 18) {
                        Text(configuration.destinationDescription)
                        Text("将当前录音的转写文字逐段发送给这台模型，整理主题、标题与片段总结。原始音频保留在 iPhone。")
                        RemoteAISendControls(buttonTitle: "确认并总结这段录音") { remember in
                            let current = settings.ai == configuration && settings.aiRevision == enrichmentRevision
                            guard settings.authorizeRemoteAISend(confirmationIsCurrent: current, rememberChoice: remember) else { enrichmentConfirmation = nil; return }
                            processing.retryEnrichment(sourceID, confirmation: configuration, revision: enrichmentRevision)
                            enrichmentConfirmation = nil
                        }
                    }
                }
            }
        }
    }
    private func enrichmentLabel(_ status: ContentEnrichmentStatus) -> String {
        switch status {
        case .idle: "等待本机总结"
        case .running: "正在使用所选模型整理主题与总结"
        case .complete: "片段总结已完成"
        case .unavailable: "所选模型暂不可用或等待发送授权"
        case .stale: "内容已更新，等待重新整理"
        case .failed: "本机总结失败，可重试"
        case .cancelled: "本机总结已暂停"
        }
    }
}

/// Complete-recording access survives all-noSpeech and manually hidden derived content.
struct ContentSegmentSourceListView: View {
    let sourceID: AudioSourceID
    var playbackAllowed = true
    @EnvironmentObject private var content: ContentSegmentModel
    @State private var selectedSegment: ContentSegment?
    @State private var segments: [ContentSegment] = []
    @State private var hasMore = false
    @State private var limit = 50
    var body: some View {
        VStack(alignment:.leading,spacing:10) {
            ForEach(segments) { segment in
                Button(segment.title.isEmpty ? "录音片段" : segment.title) { selectedSegment = segment }
            }
            if segments.isEmpty { Text("暂无可显示片段，完整录音仍可回听。").font(.footnote) }
            if hasMore { Button("载入更多片段") { limit += 50; Task { await reload() } } }
            Button("撤销上次片段编辑") { Task { _ = await content.mutate(sourceID:sourceID) { try $0.undo(sourceID:sourceID) } } }
        }.task(id:content.revision) { await reload() }
        .sheet(item:$selectedSegment) { segment in ContentSegmentDetailView(segmentID:segment.id,playbackAllowed:playbackAllowed) }
    }
    private func reload() async {
        do {
            var values: [ContentSegment] = []
            while values.count < limit+1 {
                let count = min(100,limit+1-values.count)
                let page = try await content.sourcePage(sourceID,limit:count,offset:values.count)
                values += page; if page.count < count { break }
            }
            guard !Task.isCancelled else { return }
            segments = Array(values.prefix(limit)); hasMore = values.count > limit
        } catch { content.errorMessage = "无法读取录音片段，请解锁后重试。" }
    }
}

private extension AudioStageProgress {
    var presentation: AudioProcessingPresentation.Stage {
        .init(success:success,missingResource:missingResource,failed:failed,cancelled:cancelled,notRequested:notRequested)
    }
}
