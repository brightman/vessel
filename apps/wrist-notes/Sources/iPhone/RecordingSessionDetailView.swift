import SwiftUI

struct RecordingSessionDetailView: View {
    let sessionID: UUID
    var playbackAllowed = true
    @EnvironmentObject private var content: ContentSegmentModel
    @EnvironmentObject private var sessions: RecordingSessionModel
    @EnvironmentObject private var audioProcessing: AudioProcessingModel
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.dismiss) private var dismiss
    @StateObject private var playback = RecordingRangePlayback()
    @State private var detail: RecordingSessionDetail?
    @State private var ranges: [RecordingSourceRange] = []
    @State private var loadError = false
    @State private var segmentLoadError = false
    @State private var confirmDelete = false
    @State private var deleting = false
    @State private var transcriptSpans: [AudioTranscriptSpan] = []
    @State private var transcriptLoading = false
    @State private var transcriptError: String?
    @State private var sourceSegments: [ContentSegment] = []
    @State private var enrichmentConfirmation: ContentEnrichmentConfirmation?
    @State private var enrichmentError: String?
    @State private var selectedTab: DaybookAudioContentTab = .summary

    private var sourceID: AudioSourceID { .init(kind: .session, id: sessionID) }
    private var processingStatus: AudioProcessingStatus? { audioProcessing.statuses[sourceID] }
    private var enrichmentStatus: ContentEnrichmentStatus? { audioProcessing.enrichmentStatuses[sourceID] }

    var body: some View {
        DaybookSheetLayout(title: "完整录音", onClose: { dismiss() }) {
            if let session = detail?.session ?? sessions.session(sessionID) {
                VStack(alignment: .leading, spacing: 0) {
                    recordingMetadata(session)
                    DaybookAudioPlayer(waveform: playback.waveform, position: playback.position, duration: playback.duration,
                        isPlaying: playback.isPlaying, playbackAllowed: playbackAllowed, error: playback.error,
                        gapPositions: playback.gapPositions, onToggle: playback.toggle, onSeek: playback.seek)
                        .padding(.bottom, 16)
                    processingCard.padding(.bottom, 12)
                    synchronizationCard.padding(.bottom, 18)
                    DaybookAudioTabs(selection: $selectedTab, summaryTitle: "片段")
                        .padding(.bottom, 16)
                    if selectedTab == .summary {
                        contentSegmentsCard
                        chunkDetailsCard.padding(.top, 14)
                    } else {
                        transcriptCard
                    }
                    deleteButton.padding(.top, 18)
                    if detail?.cleanupPending == true || sessions.cleanupIDs.contains(sessionID) {
                        inlineNotice("文件清理待重试", symbol: "exclamationmark.triangle.fill", color: DaybookStyle.red)
                        Button("重试清理") { sessions.refresh(recover: true) }
                            .font(.system(size: 11, weight: .medium)).foregroundStyle(DaybookStyle.accent)
                    }
                    if let error = sessions.errorMessage {
                        inlineNotice(error, symbol: "exclamationmark.circle.fill", color: DaybookStyle.red)
                    }
                }
            } else if loadError {
                VStack(alignment: .leading, spacing: 10) {
                    inlineNotice("无法读取完整录音，请解锁后重试。", symbol: "exclamationmark.circle.fill", color: DaybookStyle.red)
                    Button("重试") { Task { await reload() } }
                        .buttonStyle(DaybookSecondaryButtonStyle())
                }.padding(.vertical, 18)
            } else if detail != nil {
                Text("录音已删除或暂不可用")
                    .font(.system(size: 12)).foregroundStyle(DaybookStyle.secondary).padding(.vertical, 18)
            } else {
                ProgressView().tint(DaybookStyle.accent).frame(maxWidth: .infinity).padding(.vertical, 32)
            }
        }
        .confirmationDialog("删除完整录音？", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("删除完整录音", role: .destructive) {
                playback.stop(); deleting = true
                Task {
                    if await sessions.delete(sessionID) { playback.stop(); dismiss() }
                    deleting = false
                }
            }
        } message: { Text("这会删除本机完整会话、内容片段及全部原始音频。") }
        .sheet(item: $enrichmentConfirmation) { request in
            ContentEnrichmentConfirmationView(request: request, onCancel: { enrichmentConfirmation = nil }, onConfirm: { remember in
                enrichmentConfirmation = nil
                Task {
                    do {
                        try await audioProcessing.approveEnrichment(request, rememberChoice: remember)
                        enrichmentError = nil
                    } catch { enrichmentError = "录音或模型已更新，请重新确认发送内容。" }
                }
            })
        }
        .task(id: sessions.revision) { await reload() }
        .task(id: content.revision) { await loadContentSegments() }
        .task(id: sessionID) {
            audioProcessing.refresh()
            await loadTranscript()
        }
        .onReceive(NotificationCenter.default.publisher(for: AudioProcessingModel.didCommit)) { note in
            guard (note.userInfo?["sourceID"] as? AudioSourceID) == sourceID else { return }
            Task { await loadTranscript() }
        }
        .onChange(of: playbackAllowed) { _, allowed in if !allowed { playback.stop() } }
        .onDisappear { playback.stop() }
    }

    private func recordingMetadata(_ session: RecordingSessionSummary) -> some View {
        let recordedAt = session.startedAt.map { "\(DaybookFormat.day($0)) \(DaybookFormat.time($0))" } ?? "录音时间待同步"
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 5) {
                Text(recordedAt)
                Text("·")
                Text("长录音")
                Text("·")
                Text(RecordingFormat.duration(session.recordedDuration))
            }
                .font(.system(size: 10)).lineSpacing(6).foregroundStyle(DaybookStyle.secondary)
            LabeledContent("录制设备", value: session.origin?.device ?? "设备未知")
                .font(.system(size: 12)).padding(.bottom, 2)
            if let location = session.location { CapturePlaceDetails(point: location) }
            if let origin = session.origin, origin.recordingTimeIsEstimated {
                Text("来自 \(origin.device) · 录制时间缺失，按同步时间显示")
                    .font(.system(size: 10)).foregroundStyle(DaybookStyle.secondary)
            }
        }.daybookRecordingCard(padding: 13).padding(.bottom, 12)
    }

    private var processingCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("处理进度").font(.system(size: 13, weight: .semibold)).foregroundStyle(DaybookStyle.ink)
                Spacer()
                if let status = processingStatus {
                    Text("\(status.progress.states[.completed, default: 0]) / \(status.progress.states.values.reduce(0, +)) 窗口")
                        .font(.system(size: 10, weight: .medium, design: .rounded)).monospacedDigit().foregroundStyle(DaybookStyle.secondary)
                }
            }
            HStack(spacing: 5) {
                Image(systemName: "waveform.badge.mic").font(.system(size: 10)).foregroundStyle(DaybookStyle.accent)
                Text("ASR 模型").font(.system(size: 10, weight: .medium)).foregroundStyle(DaybookStyle.secondary)
                Text(asrModelDescription).font(.system(size: 10, weight: .medium)).foregroundStyle(DaybookStyle.bodyText).lineLimit(1)
            }
            VStack(spacing: 0) {
                ForEach(processingSteps) { step in
                    RecordingProcessingStepRow(step: step)
                    if step.id != processingSteps.last?.id { DaybookStyle.line.frame(height: 1).padding(.leading, 25) }
                }
            }
            if let enrichmentError {
                Text(enrichmentError).font(.system(size: 10)).foregroundStyle(DaybookStyle.red)
            }
            if enrichmentStatus == .awaitingConsent {
                Button {
                    Task {
                        do { enrichmentConfirmation = try await audioProcessing.prepareEnrichment(sourceID) }
                        catch { enrichmentError = "录音数据已更新，请重试。" }
                    }
                } label: {
                    Label("确认并继续 AI 整理", systemImage: "lock.open")
                }.buttonStyle(DaybookSecondaryButtonStyle())
            }
            Button {
                enrichmentError = nil
                audioProcessing.reprocess(sourceID)
            } label: {
                Label("重新处理", systemImage: "arrow.clockwise")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(DaybookPrimaryButtonStyle(wide: true))
            .disabled((detail?.ranges.isEmpty ?? true) || audioProcessing.statuses[sourceID]?.progress.states[.running, default: 0] ?? 0 > 0)
        }
        .padding(15)
        .background(DaybookStyle.white, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(DaybookStyle.line, lineWidth: 1))
    }

    private var synchronizationCard: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text("同步状态").font(.system(size: 13, weight: .semibold)).foregroundStyle(DaybookStyle.ink)
                Spacer()
                Label(syncSummaryLabel, systemImage: syncComplete ? "checkmark.circle.fill" : "arrow.triangle.2.circlepath")
                    .font(.system(size: 10, weight: .medium)).foregroundStyle(syncComplete ? DaybookStyle.green : DaybookStyle.accent)
            }
            LazyVGrid(columns: [GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .leading)], alignment: .leading, spacing: 8) {
                syncMetric("分片", value: chunkCountLabel, state: syncComplete ? .success : .waiting)
                syncMetric("录音结束", value: endMarkerLabel, state: endMarkerState)
                syncMetric("尾片", value: tailChunkLabel, state: tailChunkState)
                syncMetric(syncComplete ? "总时长" : "已收到时长", value: RecordingFormat.duration(detail?.session?.recordedDuration ?? 0), state: .neutral)
            }
            if let session = detail?.session, session.interrupted {
                inlineNotice("录音中断，当前时长仅统计已收到的分片。", symbol: "exclamationmark.triangle.fill", color: DaybookStyle.red)
            }
            if !(detail?.gaps.isEmpty ?? true) {
                Text("检测到 \(detail?.gaps.count ?? 0) 处音频缺口，详见下方分片详情。")
                    .font(.system(size: 10)).foregroundStyle(DaybookStyle.secondary)
            }
        }
        .padding(15)
        .background(DaybookStyle.white, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(DaybookStyle.line, lineWidth: 1))
    }

    private var transcriptCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("完整转写").font(.system(size: 14, weight: .semibold)).foregroundStyle(DaybookStyle.ink)
                Spacer()
                Button { Task { await loadTranscript() } } label: {
                    Image(systemName: "arrow.clockwise").font(.system(size: 12, weight: .medium))
                        .frame(width: 32, height: 32).background(DaybookStyle.field, in: Circle())
                }.disabled(transcriptLoading).accessibilityLabel("刷新转写全文")
            }
            if transcriptLoading {
                HStack(spacing: 8) { ProgressView().controlSize(.small); Text("正在读取本机转写…").font(.system(size: 11)).foregroundStyle(DaybookStyle.secondary) }
            } else if let transcriptError {
                inlineNotice(transcriptError, symbol: "exclamationmark.circle.fill", color: DaybookStyle.red)
                Button("重试读取") { Task { await loadTranscript() } }.font(.system(size: 11)).foregroundStyle(DaybookStyle.accent)
            } else if transcriptSpans.isEmpty {
                Text("暂无已识别文字。录音转写完成后，可刷新查看。")
                    .font(.system(size: 12)).lineSpacing(6).foregroundStyle(DaybookStyle.secondary)
            } else {
                Text(AudioTranscriptPresentation.fullText(transcriptSpans))
                    .font(.system(size: 13)).foregroundStyle(DaybookStyle.bodyText).lineSpacing(9).textSelection(.enabled)
                Text("共 \(transcriptSpans.count) 段识别文字 · 保存在本机")
                    .font(.system(size: 10)).foregroundStyle(DaybookStyle.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var contentSegmentsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("主题片段").font(.system(size: 14, weight: .semibold)).foregroundStyle(DaybookStyle.ink)
                Spacer()
                let finalized = currentSegments.filter(\.isFinal).count
                Text("\(finalized) 个已定稿").font(.system(size: 10)).foregroundStyle(DaybookStyle.secondary)
            }
            if segmentLoadError {
                Text("暂时无法读取内容片段。")
                    .font(.system(size: 11)).foregroundStyle(DaybookStyle.secondary)
            }
            ContentSegmentSourceListView(sourceID: sourceID, playbackAllowed: playbackAllowed)
        }
    }

    private var chunkDetailsCard: some View {
        let chunks = detail?.chunks ?? []
        let gaps = detail?.gaps ?? []
        return Group {
            if !chunks.isEmpty || !gaps.isEmpty {
                DisclosureGroup {
                    VStack(alignment: .leading, spacing: 7) {
                        ForEach(chunks, id: \.id) { chunk in
                            HStack(spacing: 6) {
                                Image(systemName: "checkmark.circle.fill").font(.system(size: 10)).foregroundStyle(DaybookStyle.green)
                                Text("分片 \(chunk.ordinal + 1)").font(.system(size: 10))
                                Spacer()
                                Text(RecordingFormat.duration(chunk.duration)).font(.system(size: 10, design: .rounded)).monospacedDigit().foregroundStyle(DaybookStyle.secondary)
                            }
                        }
                        ForEach(Array(gaps.enumerated()), id: \.offset) { _, gap in
                            HStack(alignment: .top, spacing: 6) {
                                Image(systemName: "xmark.circle.fill").font(.system(size: 10)).foregroundStyle(DaybookStyle.red)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text("录音缺口").font(.system(size: 10, weight: .medium)).foregroundStyle(DaybookStyle.red)
                                    if let first = gap.firstOrdinal, let last = gap.lastOrdinal {
                                        Text("分片 \(first + 1) 至 \(last + 1) 尚未同步").font(.system(size: 9)).foregroundStyle(DaybookStyle.secondary)
                                    }
                                    if let start = gap.startOffset, let end = gap.endOffset {
                                        Text("\(RecordingFormat.duration(start)) – \(RecordingFormat.duration(end))")
                                            .font(.system(size: 9, design: .rounded)).monospacedDigit().foregroundStyle(DaybookStyle.secondary)
                                    }
                                }
                                Spacer(minLength: 0)
                            }
                        }
                    }.padding(.top, 8)
                } label: {
                    HStack(spacing: 7) {
                        Image(systemName: "square.stack.3d.up").font(.system(size: 11)).foregroundStyle(DaybookStyle.accent)
                        Text("分片详情与音频缺口").font(.system(size: 10, weight: .medium)).foregroundStyle(DaybookStyle.ink)
                        Spacer()
                        Text("\(chunks.count) 片").font(.system(size: 9)).foregroundStyle(DaybookStyle.secondary)
                    }
                }
                .tint(DaybookStyle.accent)
                .padding(13)
                .background(DaybookStyle.white, in: RoundedRectangle(cornerRadius: 15))
                .overlay(RoundedRectangle(cornerRadius: 15).stroke(DaybookStyle.line, lineWidth: 1))
            }
        }
    }

    private var deleteButton: some View {
        Button("删除完整录音", role: .destructive) { confirmDelete = true }
            .font(.system(size: 12, weight: .medium))
            .frame(maxWidth: .infinity).padding(.vertical, 12)
            .disabled(deleting)
    }

    private var asrModelDescription: String {
        guard let key = processingStatus?.progress.configurationKey else {
            return "当前设置 · \(settings.transcriptionLabel)"
        }
        let current = AudioProcessingCoordinator.configurationKey(settings.transcription)
        if key == current || key.hasPrefix(current + "~r:") {
            return "本条实际使用 · \(settings.transcriptionLabel)"
        }
        return "历史模型未记录 · 当前 \(settings.transcriptionLabel)"
    }

    private var topicStageDisposition:ContentSegmentationV2.LongRecordingTopicPolicy.StageDisposition {
        guard let session=detail?.session ?? sessions.session(sessionID),session.recordedDuration > 0 else { return .waitingForSourceCompletion }
        return ContentSegmentationV2.LongRecordingTopicPolicy.stageDisposition(
            duration:session.recordedDuration,sourceComplete:session.syncComplete)
    }

    private func vadStep(progress:AudioStageProgress?,total:Int,live:Bool,pending:Bool) -> RecordingProcessingStep {
        switch topicStageDisposition {
        case .skippedWholeRecording:
            let hadHistoricalResult=(progress?.success ?? 0)+(progress?.failed ?? 0)+(progress?.missingResource ?? 0)>0
            return .init(id:"vad",title:"语音活动检测",detail:hadHistoricalResult ? "旧批次已运行；重新处理时跳过" : "短录音跳过 VAD",state:.skipped)
        case .waitingForSourceCompletion:
            return .init(id:"vad",title:"语音活动检测",detail:"完整同步后按总时长决定是否运行",state:.waiting)
        case .processTopics:
            if let progress { return stageStep("vad",title:"语音活动检测",progress:progress,total:total,live:live,pending:pending) }
            return .init(id:"vad",title:"语音活动检测",detail:"等待处理",state:.waiting)
        }
    }

    private var processingSteps: [RecordingProcessingStep] {
        guard let status = processingStatus else {
            return [
                .init(id: "asr", title: "语音转写", detail: "等待本机处理状态", state: .waiting),
                vadStep(progress:nil,total:0,live:false,pending:false),
                .init(id: "speaker", title: "说话人分析", detail: "等待处理", state: .waiting),
                .init(id: "topics", title: "主题拆分与分类", detail: topicStageDisposition == .skippedWholeRecording ? "短录音保留为整段；跳过主题拆分与 AI 分类" : "等待处理", state: topicStageDisposition == .skippedWholeRecording ? .skipped : .waiting),
                .init(id: "fields", title: "标题与摘要", detail: "等待处理", state: .waiting)
            ]
        }
        let windowCount = status.progress.states.values.reduce(0, +)
        let live = status.progress.states[.running, default: 0] > 0
        let pending = status.progress.states[.pending, default: 0] > 0
        let asr = stageStep("asr", title: "语音转写", progress: status.asr, total: windowCount, live: live, pending: pending,
            successDetail: transcriptSpans.isEmpty ? "\(status.asr.success) 个窗口完成 · 未识别到文字" : "\(status.asr.success) 个窗口完成 · 全文可查看")
        let vad = vadStep(progress:status.vad,total:windowCount,live:live,pending:pending)
        let speaker = stageStep("speaker", title: "说话人分析", progress: status.speaker, total: windowCount, live: live, pending: pending, optional: true)
        let current = currentSegments
        let finalized = current.filter(\.isFinal)
        let enrichment = enrichmentStatus
        let totalWindows = status.progress.states.values.reduce(0, +)
        let stagesCovered = status.asr.success == totalWindows &&
            (topicStageDisposition == .skippedWholeRecording || status.vad.success == totalWindows)
        let audioFinished = totalWindows > 0 && status.progress.states[.completed, default: 0] == totalWindows && stagesCovered
        let topicState: RecordingProcessingStep.State
        let topicDetail: String
        if topicStageDisposition == .skippedWholeRecording {
            topicState = .skipped
            topicDetail = current.contains(where: { $0.editorial != nil }) ? "保留历史分类结果；新规则跳过主题拆分与 AI 分类" : "短录音保留为整段；跳过主题拆分与 AI 分类"
        } else if topicStageDisposition == .waitingForSourceCompletion {
            topicState = .waiting; topicDetail = "完整同步后按总时长决定是否拆分主题"
        } else if enrichment == .failed || enrichment == .unavailable {
            topicState = .failure; topicDetail = enrichment == .unavailable ? "所选整理模型暂不可用" : "主题整理失败，可重新处理"
        } else if enrichment == .running {
            topicState = .running; topicDetail = "正在整理主题与分类"
        } else if enrichment == .awaitingConsent {
            topicState = .waiting; topicDetail = "等待确认后继续"
        } else if !current.isEmpty && finalized.count == current.count {
            topicState = .success; topicDetail = "\(finalized.count) 个片段边界与分类已确定"
        } else if enrichment == .complete && current.isEmpty && audioFinished {
            topicState = .success; topicDetail = "没有需要展示的内容片段"
        } else if !current.isEmpty {
            topicState = .waiting; topicDetail = "\(finalized.count) / \(current.count) 个片段已定稿"
        } else {
            topicState = live || pending ? .running : .waiting
            topicDetail = live || pending ? "等待语音处理完成" : "等待主题分析"
        }
        let topics = RecordingProcessingStep(id: "topics", title: "主题拆分与分类", detail: topicDetail, state: topicState)

        let fieldCounts = ContentSegmentPresentation.fieldGenerationCounts(finalized)
        let eligibleFields = fieldCounts.eligible
        let withFields = fieldCounts.complete
        let fieldState: RecordingProcessingStep.State
        let fieldDetail: String
        if enrichment == .failed || enrichment == .unavailable {
            fieldState = .failure; fieldDetail = "标题或摘要整理失败，可重新处理"
        } else if enrichment == .running, let progress = audioProcessing.enrichmentProgress[sourceID], progress.stage == .title || progress.stage == .summary {
            fieldState = .running; fieldDetail = progress.stage == .title ? "正在生成片段标题" : "正在生成片段摘要"
        } else if eligibleFields > 0 && withFields == eligibleFields {
            fieldState = .success; fieldDetail = "\(withFields) 个可生成片段已有标题和摘要"
        } else if enrichment == .complete && audioFinished {
            fieldState = .skipped
            fieldDetail = eligibleFields == 0 ? "没有需要生成标题与摘要的内容片段" : "部分内容片段没有标题或摘要"
        } else if enrichment == .awaitingConsent {
            fieldState = .waiting; fieldDetail = "等待确认后继续"
        } else {
            fieldState = .waiting; fieldDetail = eligibleFields == 0 ? "主题定稿后生成" : "\(withFields) / \(eligibleFields) 个可生成片段已有标题和摘要"
        }
        let fields = RecordingProcessingStep(id: "fields", title: "标题与摘要", detail: fieldDetail, state: fieldState)
        return [asr, vad, speaker, topics, fields]
    }

    private var currentSegments: [ContentSegment] {
        guard let revision = processingStatus?.progress.revision else { return sourceSegments }
        return sourceSegments.filter { $0.sourceRevision == revision }
    }

    private func stageStep(_ id: String, title: String, progress: AudioStageProgress, total: Int,
                           live: Bool, pending: Bool, optional: Bool = false, successDetail: String? = nil) -> RecordingProcessingStep {
        let failures = progress.failed + progress.missingResource
        let accounted = progress.success + progress.missingResource + progress.failed + progress.cancelled + progress.notRequested
        let detail: String
        let state: RecordingProcessingStep.State
        if failures > 0 {
            state = .failure
            detail = "\(progress.success) 成功 · \(failures) 失败"
        } else if progress.cancelled > 0 {
            state = .waiting; detail = "已暂停，可重新处理"
        } else if total > 0 && progress.success >= total {
            state = .success; detail = successDetail ?? "\(progress.success) / \(total) 个窗口成功"
        } else if optional && total > 0 && progress.notRequested >= total {
            state = .skipped; detail = "未运行（可选步骤）"
        } else if progress.success > 0 {
            state = live || pending ? .running : .waiting
            detail = "\(progress.success) / \(max(total, accounted)) 个窗口完成"
        } else if live {
            state = .running; detail = "正在处理"
        } else if pending || total == 0 {
            state = .waiting; detail = "等待处理"
        } else if optional && progress.notRequested > 0 {
            state = .skipped; detail = "部分窗口未运行（可选步骤）"
        } else {
            state = .waiting; detail = "尚未完成"
        }
        return RecordingProcessingStep(id: id, title: title, detail: detail, state: state)
    }

    private var syncComplete: Bool { detail?.session?.syncComplete ?? false }
    private var syncSummaryLabel: String { syncComplete ? "同步完成" : "等待分片" }
    private var chunkCountLabel: String {
        let session = detail?.session
        let saved = detail?.chunks.count ?? session?.savedCount ?? 0
        if let expected = session?.expectedCount { return "\(saved) / \(expected)" }
        return "\(saved) / —"
    }
    private var endMarkerLabel: String { detail?.session?.endRevision == nil ? "未收到" : "已收到" }
    private var endMarkerState: RecordingProcessingStep.State { detail?.session?.endRevision == nil ? .waiting : .success }
    private var tailChunkLabel: String {
        guard let session = detail?.session, session.endRevision != nil else { return "等待结束标记" }
        guard let finalOrdinal = session.finalOrdinal else { return session.savedCount == 0 ? "无音频尾片" : "无法确认" }
        return (detail?.chunks.contains(where: { $0.ordinal == finalOrdinal }) ?? false) ? "已收到" : "未收到"
    }
    private var tailChunkState: RecordingProcessingStep.State {
        guard let session = detail?.session, session.endRevision != nil else { return .waiting }
        guard let finalOrdinal = session.finalOrdinal else { return session.savedCount == 0 ? .neutral : .warning }
        return detail?.chunks.contains(where: { $0.ordinal == finalOrdinal }) == true ? .success : .failure
    }

    private func syncMetric(_ title: String, value: String, state: RecordingProcessingStep.State) -> some View {
        HStack(alignment: .top, spacing: 6) {
            RecordingProcessingStateIcon(state: state, size: 10)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 10)).foregroundStyle(DaybookStyle.secondary)
                Text(value).font(.system(size: 10, weight: .medium, design: .rounded)).monospacedDigit().foregroundStyle(DaybookStyle.ink).lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 3)
    }

    private func inlineNotice(_ text: String, symbol: String, color: Color) -> some View {
        Label {
            Text(text).font(.system(size: 10)).foregroundStyle(DaybookStyle.secondary)
        } icon: {
            Image(systemName: symbol).font(.system(size: 10)).foregroundStyle(color)
        }
    }

    private func reload() async {
        do {
            let value = try await sessions.detail(sessionID)
            guard !Task.isCancelled else { return }
            detail = value; loadError = false
            if value.ranges != ranges { ranges = value.ranges; playback.load(value.ranges) }
            if value.session == nil { playback.stop() }
        } catch { if !Task.isCancelled { loadError = true } }
    }

    private func loadContentSegments() async {
        do {
            var values: [ContentSegment] = [], offset = 0
            while true {
                let page = try await content.sourcePage(sourceID, limit: 100, offset: offset)
                values.append(contentsOf: page)
                offset += page.count
                if page.count < 100 { break }
            }
            guard !Task.isCancelled else { return }
            sourceSegments = values; segmentLoadError = false
        } catch { if !Task.isCancelled { segmentLoadError = true } }
    }

    private func loadTranscript() async {
        guard !transcriptLoading else { return }
        transcriptLoading = true
        transcriptError = nil
        defer { transcriptLoading = false }
        do {
            let sourceID = self.sourceID
            let values = try await audioProcessing.withRepository { repository in
                var all: [AudioTranscriptSpan] = []
                var offset = 0
                while true {
                    let page = try repository.spans(sourceID: sourceID, limit: 1000, offset: offset)
                    all.append(contentsOf: page)
                    offset += page.count
                    if page.count < 1000 { break }
                }
                return all
            }
            guard !Task.isCancelled else { return }
            transcriptSpans = values
        } catch {
            if !Task.isCancelled { transcriptError = "无法读取本机转写，请解锁设备后重试。" }
        }
    }
}

struct RecordingProcessingStep: Identifiable {
    enum State { case success, failure, running, waiting, skipped, warning, neutral }
    let id: String
    let title: String
    let detail: String
    let state: State
}

struct RecordingProcessingStepRow: View {
    let step: RecordingProcessingStep
    var body: some View {
        HStack(spacing: 7) {
            RecordingProcessingStateIcon(state: step.state, size: 12)
            Text(step.title).font(.system(size: 10, weight: .medium)).foregroundStyle(DaybookStyle.ink)
            Spacer(minLength: 4)
            Text(step.detail).font(.system(size: 10)).foregroundStyle(DaybookStyle.secondary).lineLimit(2).multilineTextAlignment(.trailing)
        }.padding(.vertical, 6)
        .accessibilityElement(children: .combine)
    }
}

private struct RecordingProcessingStateIcon: View {
    let state: RecordingProcessingStep.State
    var size: CGFloat = 12
    var body: some View {
        Group {
            switch state {
            case .success: Image(systemName: "checkmark.circle.fill").foregroundStyle(DaybookStyle.green)
            case .failure: Image(systemName: "xmark.circle.fill").foregroundStyle(DaybookStyle.red)
            case .running: ProgressView().controlSize(.mini).tint(DaybookStyle.accent)
            case .waiting: Image(systemName: "circle.dashed").foregroundStyle(DaybookStyle.secondary)
            case .skipped: Image(systemName: "minus.circle").foregroundStyle(DaybookStyle.secondary)
            case .warning: Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange)
            case .neutral: Image(systemName: "circle.fill").foregroundStyle(DaybookStyle.secondary.opacity(0.55))
            }
        }
        .font(.system(size: size, weight: .medium))
        .frame(width: size + 2, height: size + 2)
        .accessibilityLabel(accessibilityStatus)
    }
    private var accessibilityStatus: String {
        switch state {
        case .success: "成功"
        case .failure: "失败"
        case .running: "处理中"
        case .waiting: "待处理"
        case .skipped: "已跳过"
        case .warning: "需要检查"
        case .neutral: "状态信息"
        }
    }
}
