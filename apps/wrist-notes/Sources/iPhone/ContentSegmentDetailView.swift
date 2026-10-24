import SwiftUI

struct ContentSegmentDetailView: View {
    let segmentID: UUID
    var playbackAllowed = true
    var citation: DayRecord.ContentProvenance? = nil
    @EnvironmentObject private var content: ContentSegmentModel
    @EnvironmentObject private var processing: AudioProcessingModel
    @Environment(\.dismiss) private var dismiss
    @StateObject private var playback = RecordingRangePlayback()
    @State private var detail: ContentSegmentDetail?
    @State private var ranges: [RecordingSourceRange] = []
    @State private var tab: DaybookAudioContentTab = .summary
    @State private var limit = 1000
    @State private var loadingMore = false
    @State private var confirmDelete = false
    @State private var enrichmentConfirmation: ContentEnrichmentConfirmation?
    @State private var enrichmentError: String?
    @State private var showOriginal = false
    @State private var didSeek = false
    @State private var missing = false

    var body: some View {
        DaybookSheetLayout(title:detail?.segment.displayTitle ?? "录音片段",onClose:{ dismiss() }) {
            if let detail {
                VStack(alignment:.leading,spacing:0) {
                    metadata(detail).padding(.bottom,18)
                    DaybookAudioPlayer(waveform:playback.waveform,position:playback.position,duration:playback.duration,
                        isPlaying:playback.isPlaying,playbackAllowed:playbackAllowed,error:playback.error,
                        gapPositions:playback.gapPositions,onToggle:playback.toggle,onSeek:playback.seek)
                    DaybookAudioTabs(selection:$tab).padding(.vertical,20)
                    transcriptOrSummary(detail)
                    fieldGenerationActions(detail).padding(.top,18)
                    actions(detail).padding(.top,24)
                    processingStatus(detail).padding(.top,18)
                    if let error=content.errorMessage {
                        Text(error).font(.system(size:11)).foregroundStyle(DaybookStyle.red).padding(.top,14)
                        Button("重试") { Task { await reload() } }.font(.system(size:11)).padding(.top,8)
                    }
                }
            } else if missing {
                Text("片段已更新或移除，请返回时间轴查看。")
                    .font(.system(size:13)).foregroundStyle(DaybookStyle.secondary).padding(.vertical,25)
            } else {
                VStack(alignment:.leading,spacing:12) {
                    ProgressView("正在读取片段…")
                    if let error=content.errorMessage {
                        Text(error).foregroundStyle(DaybookStyle.red)
                        Button("重试") { Task { await reload() } }
                    }
                }.font(.system(size:12)).padding(.vertical,25)
            }
        }
        .confirmationDialog("删除片段？",isPresented:$confirmDelete,titleVisibility:.visible) {
            Button("删除片段",role:.destructive) {
                guard let segment=detail?.segment else { return }
                Task { if await content.mutate(sourceID:segment.sourceID,{ try $0.delete(id:segment.id,expectedRevision:segment.revision) }) { playback.stop(); dismiss() } }
            }
        } message: { Text("仅隐藏此片段，保留完整录音。可撤销上次片段编辑。") }
        .sheet(isPresented:$showOriginal) {
            if let source=detail?.segment.sourceID {
                if source.kind == .session { RecordingSessionDetailView(sessionID:source.id,playbackAllowed:playbackAllowed) }
                else { DaybookVoiceDetailView(id:source.id,playbackAllowed:playbackAllowed) }
            }
        }
        .sheet(item:$enrichmentConfirmation) { request in
            ContentEnrichmentConfirmationView(request:request,onCancel:{ enrichmentConfirmation=nil },onConfirm:{ remember in
                enrichmentConfirmation=nil
                Task {
                    do { try await processing.approveEnrichment(request,rememberChoice:remember); enrichmentError=nil }
                    catch { enrichmentError="片段或模型已更新，请重新确认发送内容。" }
                }
            })
        }
        .task(id:content.revision) { await reload() }
        .onChange(of:playbackAllowed) { _, allowed in if !allowed { playback.stop() } }
        .onDisappear { playback.stop() }
    }

    private func metadata(_ detail:ContentSegmentDetail) -> some View {
        let start=detail.source.capturedAt.addingTimeInterval(detail.segment.ranges.first?.sessionStartOffset ?? 0)
        let duration=detail.segment.ranges.reduce(0) { $0+$1.duration }
        let fields=[RecordingFormat.date(start),detail.source.origin?.device,"内容片段",RecordingFormat.duration(duration)].compactMap { $0 }
        return VStack(alignment:.leading,spacing:8) {
            Text(fields.joined(separator:" · "))
            if !detail.segment.isFinal { Text("该片段尚未完成 ASR/VAD 覆盖或话题整理，暂不显示在时间轴。请查看下方处理状态。") }
        }.font(.system(size:10)).lineSpacing(6).foregroundStyle(DaybookStyle.secondary)
    }

    @ViewBuilder private func transcriptOrSummary(_ detail:ContentSegmentDetail) -> some View {
        VStack(alignment:.leading,spacing:14) {
            if tab == .summary {
                Text(detail.segment.summary.isEmpty ?
                    (!detail.segment.hasText && detail.segment.isFinal ? "这段录音未识别到文字，可回听原音频；无文字不表示无人声。" : "摘要尚未生成，可以先查看全文。") : detail.segment.summary)
                    .accessibilityIdentifier("audio.segmentSummary")
            } else {
                // ASR rows can be individual characters. Keep the original order and
                // content, displaying them as readable text instead of one list row per token.
                Text(detail.spans.isEmpty ? "此片段尚无全文；空转写不表示无人声。" : detail.spans.map(\.text).joined())
                    .accessibilityIdentifier("audio.segmentTranscript")
                if detail.hasMore {
                    Button {
                        loadingMore=true; limit += 1000
                        Task { await reload(); loadingMore=false }
                    } label: {
                        HStack(spacing:7) {
                            if loadingMore { ProgressView().controlSize(.mini) }
                            Text(loadingMore ? "正在载入…" : "载入更多全文")
                        }
                    }.disabled(loadingMore).font(.system(size:11)).foregroundStyle(DaybookStyle.accent)
                }
            }
        }.font(.system(size:13)).lineSpacing(10).foregroundStyle(DaybookStyle.bodyText)
            .textSelection(.enabled).frame(maxWidth:.infinity,alignment:.leading)
    }

    private func actions(_ detail:ContentSegmentDetail) -> some View {
        HStack {
            Button("查看完整录音") { playback.stop(); showOriginal=true }
            Spacer(minLength:12)
            Menu {
                if !detail.segment.isFinal {
                    Button("在播放位置拆分") { split(detail) }
                        .disabled(!playbackAllowed || playback.position <= 0 || playback.position >= playback.duration)
                }
                Button("撤销上次片段编辑") {
                    Task { if await content.mutate(sourceID:detail.segment.sourceID,{ try $0.undo(sourceID:detail.segment.sourceID) }) { playback.stop(); dismiss() } }
                }
                Divider()
                Button("删除片段",role:.destructive) { confirmDelete=true }
            } label: {
                HStack(spacing:5) { Text("管理片段"); Image(systemName:"ellipsis") }
            }.disabled(!playbackAllowed)
        }.font(.system(size:11)).foregroundStyle(DaybookStyle.accent).padding(.top,14)
            .overlay(alignment:.top) { Rectangle().fill(DaybookStyle.line).frame(height:1) }
    }

    @ViewBuilder private func fieldGenerationActions(_ detail:ContentSegmentDetail) -> some View {
        if detail.segment.isFinal && detail.segment.hasText {
            HStack(spacing:10) {
                Button(detail.segment.title.isEmpty ? "生成标题" : "重新生成标题") { requestField(.title,for:detail.segment) }
                Button(detail.segment.summary.isEmpty ? "生成摘要" : "重新生成摘要") { requestField(.summary,for:detail.segment) }
            }
            .font(.system(size:11,weight:.medium)).foregroundStyle(DaybookStyle.accent)
            .disabled(processing.fieldGenerationStatuses[detail.segment.id] == .running)
            if let enrichmentError { Text(enrichmentError).font(.system(size:10)).foregroundStyle(DaybookStyle.red) }
        }
    }
    private func requestField(_ field:ContentEnrichmentField,for segment:ContentSegment) {
        Task {
            do {
                enrichmentError=nil
                enrichmentConfirmation=try await processing.prepareFieldGeneration(sourceID:segment.sourceID,segmentID:segment.id,field:field)
            } catch { enrichmentError="片段已更新或模型不可用，请刷新后重试。" }
        }
    }

    private func processingStatus(_ detail:ContentSegmentDetail) -> some View {
        DisclosureGroup("处理状态") {
            VStack(alignment:.leading,spacing:10) {
                if let progress=processing.enrichmentProgress[detail.segment.sourceID],progress.segmentID == nil || progress.segmentID == detail.segment.id {
                    Label(enrichmentProgressLabel(progress.stage),systemImage:"sparkles")
                } else if let status=processing.fieldGenerationStatuses[detail.segment.id],status != .idle {
                    Label(fieldStatusLabel(status),systemImage:status == .complete ? "checkmark.circle" : status == .running ? "sparkles" : "exclamationmark.circle")
                } else if let editorial=detail.segment.editorial,detail.segment.isFinal {
                    Label("此片段已整理并保存",systemImage:"checkmark.circle")
                    if editorial.classification == "lowInformation" {
                        Text("低信息内容保留在录音库中，不在时间轴展示。")
                    } else if editorial.classification == "pendingConfirmation" {
                        Text("此片段的内容尚待确认，暂不在时间轴展示。")
                    }
                    Text(editorial.model)
                } else { AudioSourceProcessingView(sourceID:detail.segment.sourceID) }
            }.font(.system(size:11)).padding(.top,12)
        }.font(.system(size:11)).foregroundStyle(DaybookStyle.secondary)
    }
    private func enrichmentProgressLabel(_ stage:ContentEnrichmentStage) -> String {
        switch stage {
        case .topicUnification: "正在判断相邻内容是否属于同一话题"
        case .classification: "正在判断此片段是否值得出现在时间轴"
        case .title: "正在从此片段全文生成标题"
        case .summary: "正在从此片段全文生成摘要"
        }
    }
    private func fieldStatusLabel(_ status:ContentEnrichmentStatus) -> String {
        switch status {
        case .idle: "等待生成"
        case .running: "正在生成标题或摘要"
        case .complete: "标题或摘要已更新"
        case .awaitingConsent: "等待确认发送到外部 AI"
        case .unavailable: "所选 AI 模型暂不可用"
        case .stale: "片段已更新，请重新发起生成"
        case .failed: "生成失败，可手动重试"
        case .cancelled: "生成已取消"
        }
    }

    private var provenanceRanges: [DayRecord.ContentProvenance.AudioRange] {
        detail?.segment.ranges.map { .init(chunkID:$0.chunkID,startFrame:$0.startFrame,endFrame:$0.endFrame,sampleRate:$0.sampleRate,sourceOffset:$0.sessionStartOffset) } ?? []
    }
    private func seek(_ sourceTime: Double) {
        if let time=ContentSegmentPresentation.playbackTime(at:sourceTime,ranges:provenanceRanges) { playback.seek(time) }
    }
    private func split(_ detail: ContentSegmentDetail) {
        guard let plan=try? RecordingRangePlan(ranges),let position=plan.locate(playback.position) else { return }
        let range=ranges[position.rangeIndex]
        let time=range.sessionStartOffset+Double(position.frame-range.startFrame)/range.sampleRate
        let segment=detail.segment
        Task { if await content.mutate(sourceID:segment.sourceID,{ _ = try $0.split(id:segment.id,at:time,expectedRevision:segment.revision) }) { playback.stop(); dismiss() } }
    }
    private func reload() async {
        do {
            let value=try await content.detail(segmentID,limit:limit)
            guard !Task.isCancelled else { return }
            detail=value; missing=value == nil
            let newRanges=value?.segment.ranges.map(\.recordingRange) ?? []
            if ranges != newRanges { ranges=newRanges; playback.load(newRanges) }
            if value == nil { playback.stop() }
            if !didSeek,let citation,let current=value?.segment,
               citation.segmentRevision == current.revision,citation.contentSignature == current.provenance.contentSignature {
                didSeek=true
                if let start=citation.ranges.first?.sourceOffset { seek(start) }
            }
        } catch { content.errorMessage="无法读取录音片段，请解锁后重试。" }
    }
}

/// Existing settings remains the only resource download entry. Retry never downloads models.
struct AudioSourceProcessingView: View {
    let sourceID: AudioSourceID
    @EnvironmentObject private var processing: AudioProcessingModel
    @EnvironmentObject private var content: ContentSegmentModel
    @EnvironmentObject private var settings: AppSettings
    @State private var showSettings = false
    @State private var enrichmentConfirmation: ContentEnrichmentConfirmation?
    @State private var enrichmentError: String?
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
            if let progress=processing.enrichmentProgress[sourceID] {
                Text(LocalizedStringKey(progressLabel(progress.stage))).font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Button("重试处理") { processing.retry(sourceID) }
                Button("取消转写处理") { processing.cancel(sourceID) }
            }
            Text("整理模型：\(settings.ai.label)").font(.caption).foregroundStyle(.secondary)
            Button("整理主题与总结") {
                Task {
                    do { enrichmentError=nil; enrichmentConfirmation=try await processing.prepareEnrichment(sourceID) }
                    catch { enrichmentError="录音数据已更新，请重试。" }
                }
            }.disabled(processing.enrichmentStatuses[sourceID] == .running)
            if let enrichmentError { Text(enrichmentError).foregroundStyle(.orange) }
            Button("语音转写模型设置") { showSettings = true }
            if content.records.contains(where:{ $0.contentProvenance?.sourceID == sourceID.id }) {
                Text("内容片段已显示在时间轴；完整录音仍可回听。").font(.footnote)
            }
        }
        .sheet(isPresented:$showSettings) { TranscriptionSettingsView(settings:settings) }
        .sheet(item:$enrichmentConfirmation) { request in
            ContentEnrichmentConfirmationView(request:request,onCancel:{ enrichmentConfirmation=nil },onConfirm:{ remember in
                enrichmentConfirmation=nil
                Task {
                    do { try await processing.approveEnrichment(request,rememberChoice:remember); enrichmentError=nil }
                    catch { enrichmentError="录音或模型已更新，请重新确认发送内容。" }
                }
            })
        }
    }
    private func enrichmentLabel(_ status: ContentEnrichmentStatus) -> String {
        switch status {
        case .idle: "等待整理主题与总结"
        case .running: "正在整理主题与总结"
        case .complete: "主题与总结已完成"
        case .unavailable: "所选总结模型暂不可用"
        case .awaitingConsent: "章节已在本机生成，AI 整理等待发送确认"
        case .stale: "内容已更新，等待重新整理"
        case .failed: "主题与总结整理失败，可重试"
        case .cancelled: "主题与总结整理已暂停"
        }
    }
    private func progressLabel(_ stage:ContentEnrichmentStage) -> String {
        switch stage {
        case .topicUnification: "AI 正在判断相邻内容是否同一话题"
        case .classification: "AI 正在按片段全文进行分类"
        case .title: "AI 正在从当前片段全文生成标题"
        case .summary: "AI 正在从当前片段全文生成摘要"
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
                Button(segment.displayTitle) { selectedSegment = segment }
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
