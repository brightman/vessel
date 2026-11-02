import SwiftUI

struct ContentSegmentDetailView: View {
    let segmentID: UUID
    var playbackAllowed = true
    var citation: DayRecord.ContentProvenance? = nil
    @EnvironmentObject private var content: ContentSegmentModel
    @EnvironmentObject private var processing: AudioProcessingModel
    @EnvironmentObject private var actionStore: ActionStore
    @Environment(\.dismiss) private var dismiss
    @StateObject private var playback = RecordingRangePlayback()
    @State private var detail: ContentSegmentDetail?
    @State private var ranges: [RecordingSourceRange] = []
    @State private var tab: DaybookAudioContentTab = .summary
    @State private var limit = 1000
    @State private var loadingMore = false
    @State private var confirmDelete = false
    @State private var showProcessingStatus = false
    @State private var enrichmentConfirmation: ContentEnrichmentConfirmation?
    @State private var enrichmentError: String?
    @State private var showOriginal = false
    @State private var showFieldsEditor = false
    @State private var managingSpeaker: ContentSpeakerManagementRequest?
    @State private var editingAction: ActionItem?
    @State private var didSeek = false
    @State private var missing = false

    var body: some View {
        DaybookSheetLayout(title:detail?.segment.displayTitle ?? "录音片段",onClose:{ dismiss() },trailing:detail.map(recordActions)) {
            if let detail {
                VStack(alignment:.leading,spacing:0) {
                    metadata(detail).padding(.bottom,12)
                    DaybookAudioPlayer(waveform:playback.waveform,position:playback.position,duration:playback.duration,
                        isPlaying:playback.isPlaying,playbackAllowed:playbackAllowed,error:playback.error,
                        gapPositions:playback.gapPositions,onToggle:playback.toggle,onSeek:playback.seek).padding(.bottom,12)
                    DaybookAudioTabs(selection:$tab).padding(.bottom,16)
                    transcriptOrSummary(detail)
                    if tab == .summary && detail.segment.isFinal && detail.segment.hasText {
                        actionSuggestions(detail).padding(.top,14)
                    }
                    actions(detail).padding(.top,24)
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
        .sheet(isPresented:$showFieldsEditor) {
            if let segment = detail?.segment { ContentSegmentFieldsEditor(segment:segment) }
        }
        .sheet(item:$managingSpeaker) { request in
            ContentSpeakerAssociationView(request:request)
        }
        .sheet(item:$editingAction) { item in ActionEditor(store:actionStore,item:item) }
        .sheet(isPresented:$showProcessingStatus) {
            if let detail {
                DaybookSheetLayout(title:"处理状态",onClose:{ showProcessingStatus=false }) {
                    processingStatus(detail).padding(.top,8)
                }
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
            .daybookRecordingCard(padding:13)
    }

    @ViewBuilder private func transcriptOrSummary(_ detail:ContentSegmentDetail) -> some View {
        VStack(alignment:.leading,spacing:14) {
            if tab == .summary {
                VStack(alignment:.leading,spacing:12) {
                    Text(detail.segment.summary.isEmpty ?
                        (!detail.segment.hasText && detail.segment.isFinal ? "这段录音未识别到文字，可回听原音频；无文字不表示无人声。" : "摘要尚未生成，可以先查看全文。") : detail.segment.summary)
                        .accessibilityIdentifier("audio.segmentSummary")
                    if detail.segment.isFinal {
                        HStack {
                            Spacer()
                            Button("编辑标题与总结") { showFieldsEditor = true }
                                .font(.system(size:11,weight:.medium)).foregroundStyle(DaybookStyle.accent)
                        }
                    }
                    if let enrichmentError {
                        Text(enrichmentError).font(.system(size:10)).foregroundStyle(DaybookStyle.red)
                    }
                }
            } else {
                if detail.spans.isEmpty {
                    Text("此片段尚无全文；空转写不表示无人声。")
                        .accessibilityIdentifier("audio.segmentTranscript")
                } else {
                    ContentSegmentSpeakerTranscriptView(spans:detail.spans,speakerLabels:detail.speakerLabels,
                        speakerContacts:detail.speakerContacts,onManage:{ speakerID,label,excerpt in
                            managingSpeaker = .init(sourceID:detail.segment.sourceID,speakerID:speakerID,label:label,
                                excerpt:excerpt,contact:detail.speakerContacts[speakerID])
                        })
                        .accessibilityIdentifier("audio.segmentTranscript")
                }
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
            .daybookRecordingCard(padding:15)
    }

    private func actions(_ detail:ContentSegmentDetail) -> some View {
        HStack {
            Button("查看完整录音") { playback.stop(); showOriginal=true }
            Spacer(minLength:0)
        }.font(.system(size:11)).foregroundStyle(DaybookStyle.accent).padding(.top,14)
            .overlay(alignment:.top) { Rectangle().fill(DaybookStyle.line).frame(height:1) }
    }

    private func actionSuggestions(_ detail:ContentSegmentDetail) -> some View {
        let related=actionStore.items.filter {
            $0.source?.id == detail.segment.id && $0.source?.recordingKind == "segment" &&
                $0.status != .cancelled && !$0.deleted
        }
        return VStack(alignment:.leading,spacing:12) {
            HStack {
                Text("建议").font(.system(size:13,weight:.semibold)).foregroundStyle(DaybookStyle.ink)
                Spacer()
                Button(detail.segment.summary.isEmpty ? "生成标题总结建议" : "重新生成标题总结建议") {
                    requestTitleSummaryAndSuggestions(for:detail.segment)
                }
                .font(.system(size:10,weight:.medium)).foregroundStyle(DaybookStyle.accent)
                .disabled(processing.fieldGenerationStatuses[detail.segment.id] == .running)
            }
            Text("AI 会结合片段全文与已绑定的说话人姓名、公司生成标题和总结，并识别可选的待办、提醒或日程。建议由你逐条编辑后再加入行动。")
                .font(.system(size:10)).foregroundStyle(DaybookStyle.secondary).fixedSize(horizontal:false,vertical:true)
            if related.isEmpty && !detail.segment.summary.isEmpty {
                Text("尚无行动建议。没有明确下一步时，AI 会留空。")
                    .font(.system(size:10)).foregroundStyle(DaybookStyle.secondary)
            }
            ForEach(related) { item in
                HStack(alignment:.top,spacing:10) {
                    Image(systemName:item.kind.icon == "CheckCheck" ? "checkmark.circle" : item.kind.icon == "Bell" ? "bell" : "calendar")
                        .font(.system(size:12,weight:.medium)).foregroundStyle(DaybookStyle.accent).frame(width:16)
                    VStack(alignment:.leading,spacing:5) {
                        Text(item.title).font(.system(size:11,weight:.medium)).foregroundStyle(DaybookStyle.ink)
                            .fixedSize(horizontal:false,vertical:true)
                        if let quote=item.source?.quote,!quote.isEmpty {
                            Text("“\(quote)”").font(.system(size:10)).lineSpacing(4).lineLimit(2)
                                .foregroundStyle(DaybookStyle.secondary)
                        }
                        Text(item.kind.title).font(.system(size:9)).foregroundStyle(DaybookStyle.secondary)
                    }
                    Spacer(minLength:4)
                    if item.status == .suggested {
                        Button("添加") { editingAction=item }
                            .font(.system(size:10,weight:.semibold)).foregroundStyle(DaybookStyle.accent)
                    } else {
                        Label(item.status == .completed ? "已完成" : "已加入",systemImage:"checkmark.circle.fill")
                            .font(.system(size:9,weight:.medium)).foregroundStyle(DaybookStyle.green)
                            .fixedSize()
                    }
                }
                .padding(.vertical,8)
                if item.id != related.last?.id { Rectangle().fill(DaybookStyle.line).frame(height:1) }
            }
        }
        .daybookRecordingCard(padding:13)
    }

    private func recordActions(_ detail:ContentSegmentDetail) -> AnyView {
        AnyView(Menu {
            Button { showFieldsEditor=true } label: { Label("编辑记录",systemImage:"square.and.pencil") }
            if detail.segment.isFinal && detail.segment.hasText {
                let generating=processing.fieldGenerationStatuses[detail.segment.id] == .running
                Button { requestTitleSummaryAndSuggestions(for:detail.segment) } label: {
                    Label(generating ? "正在生成标题、总结与建议…" : detail.segment.summary.isEmpty ? "生成标题、总结与建议" : "重新生成标题总结建议",systemImage:"lightbulb")
                }.disabled(generating)
            }
            Button { showProcessingStatus=true } label: { Label("查看处理状态",systemImage:"waveform.path") }
            Divider()
            Button(role:.destructive) { confirmDelete=true } label: { Label("删除此片段",systemImage:"xmark") }
        } label: {
            Image(systemName:"ellipsis")
                .font(.system(size:16,weight:.semibold))
                .frame(width:32,height:32)
                .background(DaybookStyle.field,in:Circle())
        }.accessibilityLabel("管理记录"))
    }
    private func requestTitleSummaryAndSuggestions(for segment:ContentSegment) {
        Task {
            do {
                enrichmentError=nil
                enrichmentConfirmation=try await processing.prepareFieldGeneration(sourceID:segment.sourceID,segmentID:segment.id,field:nil)
            } catch { enrichmentError="片段已更新或模型不可用，请刷新后重试。" }
        }
    }

    private func processingStatus(_ detail:ContentSegmentDetail) -> some View {
        VStack(alignment:.leading,spacing:9) {
            HStack {
                Text("处理状态").font(.system(size:13,weight:.semibold)).foregroundStyle(DaybookStyle.ink)
                Spacer()
                Label(detail.segment.isFinal ? "已定稿" : "仍在整理",systemImage:detail.segment.isFinal ? "checkmark.circle.fill" : "arrow.triangle.2.circlepath")
                    .font(.system(size:10,weight:.medium))
                    .foregroundStyle(detail.segment.isFinal ? DaybookStyle.green : DaybookStyle.accent)
            }
            if detail.segment.isFinal, let editorial=detail.segment.editorial {
                Text("边界已定稿 · \(editorial.model)")
                    .font(.system(size:10)).foregroundStyle(DaybookStyle.secondary)
            }
            classificationInfo(detail.segment)
            DisclosureGroup("查看处理详情") {
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
                        Text("此片段的内容尚待确认，仍显示在时间轴。")
                    }
                    Text(editorial.model)
                } else {
                    let timelineEligible=detail.segment.isFinal && detail.segment.hasText &&
                        detail.segment.editorial?.classification != ContentSegmentClassification.lowInformation.rawValue
                    AudioSourceProcessingView(sourceID:detail.segment.sourceID,timelineEligible:timelineEligible)
                }
            }.font(.system(size:11)).padding(.top,10)
            }.font(.system(size:10)).foregroundStyle(DaybookStyle.secondary)
        }
        .daybookRecordingCard(padding:13)
    }
    private func classificationInfo(_ segment:ContentSegment) -> some View {
        let classification=segment.editorial?.classification
        let title=classificationTitle(classification,isFinal:segment.isFinal)
        let explanation=classificationExplanation(classification,isFinal:segment.isFinal)
        return VStack(alignment:.leading,spacing:5) {
            HStack(spacing:7) {
                Image(systemName:"tag").font(.system(size:10,weight:.medium))
                Text("内容分类").font(.system(size:10,weight:.medium))
                Spacer(minLength:8)
                Text(title).font(.system(size:10,weight:.semibold))
                    .foregroundStyle(classificationColor(classification,isFinal:segment.isFinal))
            }
            Text(explanation).font(.system(size:10)).foregroundStyle(DaybookStyle.secondary)
                .fixedSize(horizontal:false,vertical:true)
        }
        .padding(.top,3)
    }
    private func classificationTitle(_ classification:String?,isFinal:Bool) -> String {
        guard isFinal else { return "等待边界定稿" }
        return switch classification {
        case "meaningful": "有意义 · 显示在时间轴"
        case "lowInformation": "低信息 · 不显示在时间轴"
        case "pendingConfirmation": "待确认 · 显示在时间轴"
        case "directCapture": "按规则直接显示"
        case .none: "未分类 · 显示在时间轴"
        default: "其他分类 · 显示在时间轴"
        }
    }
    private func classificationExplanation(_ classification:String?,isFinal:Bool) -> String {
        guard isFinal else { return "边界确定后再进行内容分类。" }
        return switch classification {
        case "meaningful": "分类模型认为片段包含连贯、具体的主题或想法。"
        case "lowInformation": "片段仍保留在完整录音中，时间轴暂不展示。"
        case "pendingConfirmation": "模型认为证据不足或内容有歧义；片段仍显示在时间轴，可后续复核。"
        case "directCapture": "闪念或短录音按直入规则展示，不依赖 AI 分类。"
        case .none: "分类尚未保存；片段仍显示在时间轴，全文和音频也会保留。"
        default: "分类标记：\(classification ?? "未知")；片段仍显示在时间轴。"
        }
    }
    private func classificationColor(_ classification:String?,isFinal:Bool) -> Color {
        guard isFinal else { return DaybookStyle.secondary }
        return switch classification {
        case "meaningful", "directCapture": DaybookStyle.green
        case "lowInformation": DaybookStyle.secondary
        case "pendingConfirmation": DaybookStyle.accent
        default: DaybookStyle.secondary
        }
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
        case .running: "正在生成标题与摘要"
        case .complete: "标题与摘要已更新"
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
    var timelineEligible: Bool? = nil
    var compact = false
    @EnvironmentObject private var processing: AudioProcessingModel
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
            if !compact {
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
            }
            if let enrichmentError { Text(enrichmentError).foregroundStyle(.orange) }
            if !compact { Button("语音转写模型设置") { showSettings = true } }
            if let timelineEligible {
                Text(timelineEligible ? "此片段符合时间轴展示条件；完整录音仍可回听。" : "此片段暂不符合时间轴展示条件；完整录音仍可回听。")
                    .font(.footnote)
            }
        }
        .font(compact ? .system(size:10) : .body)
        .foregroundStyle(compact ? DaybookStyle.secondary : .primary)
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

private struct ContentSegmentFieldsEditor: View {
    let segment:ContentSegment
    @EnvironmentObject private var content:ContentSegmentModel
    @Environment(\.dismiss) private var dismiss
    @State private var title:String
    @State private var summary:String
    @State private var saving=false
    @State private var error:String?

    init(segment:ContentSegment) {
        self.segment=segment
        _title=State(initialValue:segment.title)
        _summary=State(initialValue:segment.summary)
    }

    var body:some View {
        NavigationStack {
            VStack(alignment:.leading,spacing:16) {
                VStack(alignment:.leading,spacing:7) {
                    HStack {
                        Text("标题").font(.system(size:12,weight:.semibold)).foregroundStyle(DaybookStyle.ink)
                        Spacer()
                        Text("\(title.count)/40").font(.system(size:10)).foregroundStyle(DaybookStyle.secondary)
                    }
                    TextField("输入片段标题",text:$title)
                        .font(.system(size:14)).padding(12).background(DaybookStyle.field,in:RoundedRectangle(cornerRadius:12))
                        .onChange(of:title) { _,value in if value.count>40 { title=String(value.prefix(40)) } }
                }
                VStack(alignment:.leading,spacing:7) {
                    HStack {
                        Text("总结").font(.system(size:12,weight:.semibold)).foregroundStyle(DaybookStyle.ink)
                        Spacer()
                        Text("\(summary.count)/220").font(.system(size:10)).foregroundStyle(DaybookStyle.secondary)
                    }
                    TextEditor(text:$summary)
                        .font(.system(size:13)).scrollContentBackground(.hidden).padding(7)
                        .frame(minHeight:150).background(DaybookStyle.field,in:RoundedRectangle(cornerRadius:12))
                        .onChange(of:summary) { _,value in if value.count>220 { summary=String(value.prefix(220)) } }
                }
                if let error { Text(error).font(.system(size:11)).foregroundStyle(DaybookStyle.red) }
                Spacer(minLength:0)
            }
            .padding(20).frame(maxWidth:.infinity,maxHeight:.infinity,alignment:.topLeading)
            .background(DaybookStyle.paper.ignoresSafeArea())
            .navigationTitle("编辑标题与总结").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement:.cancellationAction) { Button("取消") { dismiss() }.disabled(saving) }
                ToolbarItem(placement:.confirmationAction) {
                    Button(saving ? "保存中…" : "保存") { save() }
                        .disabled(saving || title.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty)
                }
            }
            .tint(DaybookStyle.accent)
        }
        .presentationDetents([.medium,.large])
    }

    private func save() {
        saving=true; error=nil
        Task {
            let saved=await content.editFields(sourceID:segment.sourceID,segmentID:segment.id,
                expectedRevision:segment.revision,title:title,summary:summary)
            saving=false
            if saved { dismiss() } else { error=content.errorMessage ?? "保存失败，请重试。" }
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
                Button { selectedSegment = segment } label: {
                    VStack(alignment:.leading,spacing:7) {
                        HStack {
                            let start = segment.ranges.first?.sessionStartOffset ?? 0
                            let end = segment.ranges.map(\.end).max() ?? start
                            Text("\(RecordingFormat.duration(start)) – \(RecordingFormat.duration(end))")
                                .font(.system(size:10,weight:.medium,design:.rounded)).monospacedDigit().foregroundStyle(DaybookStyle.secondary)
                            Spacer(minLength:4)
                            Image(systemName:"chevron.right").font(.system(size:10,weight:.medium)).foregroundStyle(DaybookStyle.secondary)
                        }
                        Text(segment.displayTitle).font(.system(size:13,weight:.semibold)).foregroundStyle(DaybookStyle.ink)
                            .frame(maxWidth:.infinity,alignment:.leading)
                        if !segment.summary.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty {
                            Text(segment.summary).font(.system(size:11)).lineSpacing(5).foregroundStyle(DaybookStyle.bodyText)
                                .lineLimit(3).frame(maxWidth:.infinity,alignment:.leading)
                        }
                    }
                    .padding(14).frame(maxWidth:.infinity,alignment:.leading)
                    .background(DaybookStyle.white,in:RoundedRectangle(cornerRadius:15))
                    .overlay(RoundedRectangle(cornerRadius:15).stroke(DaybookStyle.line,lineWidth:1))
                    .contentShape(RoundedRectangle(cornerRadius:15))
                }.buttonStyle(.plain)
            }
            if segments.isEmpty { Text("暂无可显示片段，完整录音仍可回听。").font(.system(size:12)).foregroundStyle(DaybookStyle.secondary) }
            if hasMore { Button("载入更多片段") { limit += 50; Task { await reload() } }.font(.system(size:11)).foregroundStyle(DaybookStyle.accent) }
            Button("撤销上次片段编辑") { Task { _ = await content.mutate(sourceID:sourceID) { try $0.undo(sourceID:sourceID) } } }
                .font(.system(size:11)).foregroundStyle(DaybookStyle.secondary)
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
