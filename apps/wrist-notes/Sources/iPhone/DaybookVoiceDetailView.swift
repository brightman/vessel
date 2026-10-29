import SwiftUI

/// Shared with derived content so both detail routes use the approved prototype.
enum DaybookAudioContentTab: String, CaseIterable {
    case summary = "总结", transcript = "全文"
}

struct DaybookAudioTabs: View {
    @Binding var selection: DaybookAudioContentTab
    var summaryTitle = "总结"
    var body: some View {
        HStack(spacing:0) {
            ForEach(DaybookAudioContentTab.allCases,id:\.self) { tab in
                Button { selection=tab } label: {
                    Text(LocalizedStringKey(tab == .summary ? summaryTitle : tab.rawValue)).font(.system(size:12,weight:selection == tab ? .medium : .regular))
                        .foregroundStyle(selection == tab ? DaybookStyle.ink : DaybookStyle.secondary)
                        .frame(maxWidth:.infinity).padding(9)
                        .background(selection == tab ? DaybookStyle.white : .clear,in:RoundedRectangle(cornerRadius:9))
                        .shadow(color:selection == tab ? Color(red:37/255,green:61/255,blue:80/255).opacity(0.06) : .clear,radius:2,x:0,y:1)
                }
                .buttonStyle(.plain).accessibilityAddTraits(selection == tab ? .isSelected : [])
                .accessibilityIdentifier(tab == .summary ? "audio.summaryTab" : "audio.transcriptTab")
            }
        }.padding(3).background(DaybookStyle.tabs,in:RoundedRectangle(cornerRadius:12))
    }
}

struct DaybookAudioPlayer: View {
    let waveform: [Float]
    let position: Double
    let duration: Double
    let isPlaying: Bool
    var playbackAllowed = true
    var error: String?
    var gapPositions: [Double] = []
    let onToggle: () -> Void
    var onSeek: ((Double) -> Void)?

    private var bars: [CGFloat] {
        guard !waveform.isEmpty else { return Array(repeating:3,count:46) }
        return (0..<46).map { index in
            let lower=min(waveform.count-1,index*waveform.count/46)
            let upper=min(waveform.count,max(lower+1,(index+1)*waveform.count/46))
            return max(3,4+CGFloat(min(1,max(0,waveform[lower..<upper].max() ?? 0)))*32)
        }
    }

    private var wave: some View {
        HStack(spacing:3) {
            ForEach(bars.indices,id:\.self) { index in
                RoundedRectangle(cornerRadius:2).fill(Color(red:138/255,green:166/255,blue:189/255))
                    .frame(maxWidth:4).frame(height:bars[index])
            }
        }.padding(.horizontal,2).frame(maxWidth:.infinity,alignment:.leading).frame(height:46)
    }

    var body: some View {
        VStack(spacing:0) {
            if let onSeek {
                GeometryReader { geometry in
                    wave.contentShape(Rectangle())
                        .onTapGesture(coordinateSpace:.local) { point in
                            guard playbackAllowed, duration > 0 else { return }
                            onSeek(min(1,max(0,point.x/max(1,geometry.size.width)))*duration)
                        }
                        .gesture(DragGesture(minimumDistance:8).onChanged { value in
                            guard playbackAllowed, duration > 0, abs(value.translation.width) > abs(value.translation.height) else { return }
                            onSeek(min(1,max(0,value.location.x/max(1,geometry.size.width)))*duration)
                        })
                }.frame(height:46)
                    .accessibilityElement(children:.ignore).accessibilityLabel("播放进度")
                    .accessibilityValue("\(RecordingFormat.duration(position)) / \(RecordingFormat.duration(duration))")
                    .accessibilityAdjustableAction { direction in
                        guard playbackAllowed, duration > 0 else { return }
                        switch direction {
                        case .increment: onSeek(min(duration,position+10))
                        case .decrement: onSeek(max(0,position-10))
                        @unknown default: break
                        }
                    }
            } else { wave.accessibilityHidden(true) }
            HStack {
                Text(RecordingFormat.duration(position)).lineLimit(1).minimumScaleFactor(0.7).frame(minWidth:55,alignment:.leading)
                Spacer()
                Button(action:onToggle) {
                    DaybookIcon(isPlaying ? "Pause" : "Play",size:16).foregroundStyle(DaybookStyle.white)
                        .frame(width:37,height:37).background(DaybookStyle.accent,in:Circle())
                }.buttonStyle(.plain).disabled(!playbackAllowed || duration <= 0)
                    .accessibilityLabel(isPlaying ? "暂停播放" : "播放录音")
                    .accessibilityIdentifier("audio.playPause")
                Spacer()
                Text(RecordingFormat.duration(duration)).lineLimit(1).minimumScaleFactor(0.7).frame(minWidth:55,alignment:.trailing)
            }.font(.system(size:10).monospacedDigit()).foregroundStyle(DaybookStyle.secondary).padding(.top,12)
            if !gapPositions.isEmpty { Text("有缺失音频，播放时会跳过。").font(.system(size:10)).foregroundStyle(DaybookStyle.secondary).padding(.top,12) }
            if !playbackAllowed { Text("正在录音，结束并保存后可回听。").font(.system(size:10)).foregroundStyle(DaybookStyle.secondary).padding(.top,12) }
            if let error { Text(error).font(.system(size:10)).foregroundStyle(DaybookStyle.red).padding(.top,12) }
        }.padding(18).background(DaybookStyle.player,in:RoundedRectangle(cornerRadius:18))
    }
}

struct DaybookVoiceDetailView: View {
    let id: UUID
    var playbackAllowed = true
    @EnvironmentObject private var model: NotesModel
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var audioProcessing: AudioProcessingModel
    @EnvironmentObject private var segmentModel: ContentSegmentModel
    @Environment(\.dismiss) private var dismiss
    @StateObject private var playback = AudioPlayback()
    @State private var selectedTab: DaybookAudioContentTab = .summary
    @State private var showEditor = false
    @State private var confirmFullDeletion = false
    @State private var remoteSummary: NotesModel.RemoteSummaryRequest?
    @State private var enrichmentConfirmation: ContentEnrichmentConfirmation?
    @State private var enrichmentError: String?
    @State private var preparingEnrichment = false

    private var sourceID: AudioSourceID { .init(kind:.legacyNote,id:id) }
    private var isLongRecording: Bool { model.note(id).map { $0.kind == .long || $0.duration > 300 } ?? false }
    private var topicStageDisposition:ContentSegmentationV2.LongRecordingTopicPolicy.StageDisposition {
        guard let note=model.note(id),note.duration > 0 else { return .waitingForSourceCompletion }
        return ContentSegmentationV2.LongRecordingTopicPolicy.stageDisposition(duration:note.duration,sourceComplete:true)
    }

    var body: some View {
        DaybookSheetLayout(title: isLongRecording ? "完整录音" : model.note(id)?.displayTitle ?? "语音记录", onClose: { dismiss() }) {
            if let note = model.note(id) {
                if isLongRecording { longRecordingContent(note) }
                else { standardVoiceContent(note) }
            } else {
                Text("这条语音记录已不存在。")
                    .font(.system(size: 13)).foregroundStyle(DaybookStyle.secondary)
                    .padding(.vertical, 25)
            }
        }
        .task(id: id) {
            await playback.load(model.audioURL(id), fallbackDuration: model.note(id)?.duration ?? 0)
            audioProcessing.refresh()
        }
        .onDisappear { if playbackAllowed { playback.stop() } }
        .confirmationDialog("删除完整录音？",isPresented:$confirmFullDeletion,titleVisibility:.visible) {
            Button("删除完整录音",role:.destructive) {
                guard playbackAllowed else { return }
                playback.stop(); model.delete(id)
                if model.note(id) == nil { dismiss() }
            }
        } message: { Text("这会删除本机原始音频及全部派生内容片段，无法撤销。") }
        .sheet(isPresented: $showEditor) {
            NavigationStack { NoteDetailView(id: id) }
                .environmentObject(model).environmentObject(settings)
        }
        .sheet(item: $enrichmentConfirmation) { request in
            ContentEnrichmentConfirmationView(request:request,onCancel:{ enrichmentConfirmation=nil },onConfirm:{ remember in
                enrichmentConfirmation=nil
                Task {
                    do { try await audioProcessing.approveEnrichment(request,rememberChoice:remember); enrichmentError=nil }
                    catch { enrichmentError="录音或模型已更新，请重新确认发送内容。" }
                }
            })
        }
        .sheet(item: $remoteSummary) { request in
            RemoteSummaryConfirmationView(request: request, onCancel: { remoteSummary = nil }, onConfirm: { doNotAskAgain in
                remoteSummary = nil
                Task { await model.summarize(id, confirmation: request, doNotAskAgain: doNotAskAgain) }
            })
        }
    }

    private var player: some View {
        DaybookAudioPlayer(waveform:playback.waveform,position:playback.position,duration:playback.duration,
            isPlaying:playback.isPlaying,playbackAllowed:playbackAllowed,error:playback.error,onToggle:playback.toggle)
    }

    private var tabs: some View { DaybookAudioTabs(selection:$selectedTab) }

    private func standardVoiceContent(_ note: VoiceNote) -> some View {
        VStack(alignment:.leading,spacing:0) {
            standardVoiceMetadata(note).padding(.bottom,12)
            player.padding(.bottom,12)
            tabs.padding(.bottom,16)
            content(note)
            Button("删除完整录音", role:.destructive) { confirmFullDeletion = true }
                .font(.system(size:12)).padding(.top,18).disabled(!playbackAllowed)
        }
    }

    private func standardVoiceMetadata(_ note:VoiceNote) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("\(RecordingFormat.date(note.capturedAt)) · \(note.kind == .thought ? "闪念" : "语音记录") · \(RecordingFormat.duration(note.duration))")
                .font(.system(size: 10)).lineSpacing(6).foregroundStyle(DaybookStyle.secondary)
            LabeledContent("录制设备", value: note.origin?.device ?? "设备未知")
                .font(.system(size: 12))
            if let sources = note.mergedSources, !sources.isEmpty {
                VStack(alignment: .leading, spacing: 7) {
                    Text("原录音来源").font(.system(size: 10, weight: .medium)).foregroundStyle(DaybookStyle.secondary)
                    ForEach(sources) { source in
                        HStack(spacing: 8) {
                            Text(source.deviceName)
                            Spacer(minLength: 8)
                            Text("\(RecordingFormat.date(source.capturedAt)) · \(RecordingFormat.duration(source.duration))")
                                .monospacedDigit()
                        }.font(.system(size: 10)).foregroundStyle(DaybookStyle.secondary)
                    }
                }
            }
            if let point = note.location { CapturePlaceDetails(point: point) }
            if let origin = note.origin, origin.recordingTimeIsEstimated {
                Text("来自 \(origin.device) · 录制时间缺失，按同步时间显示")
                    .font(.system(size: 10)).foregroundStyle(DaybookStyle.secondary)
            }
            if note.usesLocalThoughtAI {
                Text("闪念在 iPhone 本地转写，并由 Apple Intelligence整理。模型暂不可用时可先回听、查看全文，稍后重试。")
                    .font(.system(size: 10)).lineSpacing(6).foregroundStyle(DaybookStyle.secondary)
            }
        }.daybookRecordingCard(padding:13)
    }

    private func longRecordingContent(_ note: VoiceNote) -> some View {
        VStack(alignment:.leading,spacing:0) {
            longRecordingMetadata(note).padding(.bottom,12)
            player.padding(.bottom,12)
            legacyProcessingCard.padding(.bottom,12)
            legacyFileStatusCard(note).padding(.bottom,18)
            DaybookAudioTabs(selection:$selectedTab,summaryTitle:"片段").padding(.bottom,16)
            if selectedTab == .summary {
                ContentSegmentSourceListView(sourceID:sourceID,playbackAllowed:playbackAllowed)
            } else {
                content(note)
            }
            Button("删除完整录音",role:.destructive) { confirmFullDeletion=true }
                .font(.system(size:12)).padding(.top,18).disabled(!playbackAllowed)
        }
    }

    private func longRecordingMetadata(_ note:VoiceNote) -> some View {
        VStack(alignment:.leading,spacing:10) {
            HStack(spacing:5) {
                Text("\(DaybookFormat.day(note.capturedAt)) \(DaybookFormat.time(note.capturedAt))")
                Text("·")
                Text("长录音")
                Text("·")
                Text(RecordingFormat.duration(note.duration))
            }.font(.system(size:10)).foregroundStyle(DaybookStyle.secondary)
            LabeledContent("录制设备",value:note.origin?.device ?? "设备未知")
                .font(.system(size:12))
            if let point=note.location { CapturePlaceDetails(point:point) }
            if let origin=note.origin,origin.recordingTimeIsEstimated {
                Text("来自 \(origin.device) · 录制时间缺失，按同步时间显示")
                    .font(.system(size:10)).foregroundStyle(DaybookStyle.secondary)
            }
            if let sources=note.mergedSources,!sources.isEmpty {
                VStack(alignment:.leading,spacing:6) {
                    Text("原录音来源").font(.system(size:10,weight:.medium)).foregroundStyle(DaybookStyle.secondary)
                    ForEach(sources) { source in
                        HStack(spacing:8) {
                            Text(source.deviceName)
                            Spacer(minLength:8)
                            Text("\(RecordingFormat.date(source.capturedAt)) · \(RecordingFormat.duration(source.duration))")
                                .monospacedDigit()
                        }.font(.system(size:10)).foregroundStyle(DaybookStyle.secondary)
                    }
                }
            }
        }.daybookRecordingCard(padding:13)
    }

    private func retryAction(for step: RecordingProcessingStep) -> (() -> Void)? {
        let current=segmentModel.library.filter { $0.sourceID == sourceID && $0.isFinal }
        guard let task=ContentEnrichmentTask(rawValue:step.id),
              step.state == .failure || (task == .fields && step.state == .waiting &&
                audioProcessing.enrichmentStatus(sourceID,task:.topics) == .complete &&
                audioProcessing.enrichmentStatus(sourceID,task:.fields) == .idle &&
                ContentSegmentPresentation.fieldGenerationCounts(current).eligible > 0) else { return nil }
        return {
            preparingEnrichment=true; enrichmentError=nil
            Task {
                defer { preparingEnrichment=false }
                do { enrichmentConfirmation=try await audioProcessing.prepareEnrichment(sourceID,task:task) }
                catch { enrichmentError="录音数据已更新，请重试。" }
            }
        }
    }

    private var legacyProcessingCard: some View {
        VStack(alignment:.leading,spacing:10) {
            HStack {
                Text("处理进度").font(.system(size:13,weight:.semibold)).foregroundStyle(DaybookStyle.ink)
                Spacer()
                if let status=audioProcessing.statuses[sourceID] {
                    Text("\(status.progress.states[.completed,default:0]) / \(status.progress.states.values.reduce(0,+)) 窗口")
                        .font(.system(size:10,weight:.medium,design:.rounded)).monospacedDigit().foregroundStyle(DaybookStyle.secondary)
                }
            }
            HStack(spacing:5) {
                Image(systemName:"waveform.badge.mic").font(.system(size:10)).foregroundStyle(DaybookStyle.accent)
                Text("ASR 模型").font(.system(size:10,weight:.medium)).foregroundStyle(DaybookStyle.secondary)
                Text(legacyASRModelDescription).font(.system(size:10,weight:.medium)).foregroundStyle(DaybookStyle.bodyText).lineLimit(1)
            }
            VStack(spacing:0) {
                ForEach(legacyProcessingSteps) { step in
                    RecordingProcessingStepRow(step:step,retry:retryAction(for:step),
                        retryDisabled:preparingEnrichment || audioProcessing.isEnrichmentBusy(sourceID) || !playbackAllowed ||
                            (audioProcessing.statuses[sourceID]?.progress.states[.running,default:0] ?? 0) > 0 ||
                            (audioProcessing.statuses[sourceID]?.progress.states[.pending,default:0] ?? 0) > 0,
                        retryTitle:step.state == .failure ? "重新处理" : "继续处理")
                    if step.id != legacyProcessingSteps.last?.id {
                        DaybookStyle.line.frame(height:1).padding(.leading,25)
                    }
                }
            }
            if let enrichmentError { Text(enrichmentError).font(.system(size:10)).foregroundStyle(DaybookStyle.red) }
            if audioProcessing.enrichmentStatuses[sourceID] == .awaitingConsent {
                Button("确认并继续 AI 整理") {
                    preparingEnrichment=true
                    Task {
                        defer { preparingEnrichment=false }
                        do { enrichmentConfirmation=try await audioProcessing.prepareEnrichment(sourceID,task:audioProcessing.enrichmentRetryTasks[sourceID]) }
                        catch { enrichmentError="录音数据已更新，请重试。" }
                    }
                }.buttonStyle(DaybookSecondaryButtonStyle()).disabled(preparingEnrichment)
            }
            Button {
                audioProcessing.reprocess(sourceID)
            } label: {
                Label("重新处理",systemImage:"arrow.clockwise")
                    .font(.system(size:11,weight:.semibold)).frame(maxWidth:.infinity)
            }.buttonStyle(DaybookPrimaryButtonStyle(wide:true))
        }.daybookRecordingCard(padding:15)
    }

    private func legacyFileStatusCard(_ note:VoiceNote) -> some View {
        let audioExists = model.audioURL(id).map { FileManager.default.fileExists(atPath:$0.path) } ?? false
        return VStack(alignment:.leading,spacing:9) {
            HStack {
                Text("录音文件").font(.system(size:13,weight:.semibold)).foregroundStyle(DaybookStyle.ink)
                Spacer()
                Label(audioExists ? "本机可用" : "文件暂不可用",systemImage:audioExists ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                    .font(.system(size:10,weight:.medium))
                    .foregroundStyle(audioExists ? DaybookStyle.green : DaybookStyle.red)
            }
            LazyVGrid(columns:[GridItem(.flexible(),alignment:.leading),GridItem(.flexible(),alignment:.leading)],alignment:.leading,spacing:8) {
                legacyFileMetric("录制设备",value:note.origin?.device ?? "设备未知")
                legacyFileMetric("录音时长",value:RecordingFormat.duration(note.duration))
                legacyFileMetric("存储位置",value:"仅此 iPhone")
                legacyFileMetric("原始音频",value:audioExists ? "已保存在本机" : "未找到文件")
            }
        }.daybookRecordingCard(padding:15)
    }

    private func legacyFileMetric(_ title:String,value:String) -> some View {
        VStack(alignment:.leading,spacing:2) {
            Text(title).font(.system(size:10)).foregroundStyle(DaybookStyle.secondary)
            Text(value).font(.system(size:10,weight:.medium,design:.rounded)).foregroundStyle(DaybookStyle.ink).lineLimit(1)
        }.frame(maxWidth:.infinity,alignment:.leading).padding(.vertical,3)
    }

    private var legacyProcessingSteps:[RecordingProcessingStep] {
        guard let status=audioProcessing.statuses[sourceID] else {
            let asrState:RecordingProcessingStep.State = switch model.note(id)?.transcriptionState {
            case .ready: .success
            case .running: .running
            case .failed,.unavailable: .failure
            default: .waiting
            }
            return [
                .init(id:"asr",title:"语音转写",detail:legacyTranscriptionDetail,state:asrState),
                legacyVADStep(progress:nil,total:0,live:false,pending:false),
                .init(id:"speaker",title:"说话人分析",detail:legacySpeakerDetail,state:legacySpeakerState),
                .init(id:"topics",title:"主题拆分与分类",detail:topicStageDisposition == .skippedWholeRecording ? "短录音保留为整段；跳过主题拆分与 AI 分类" : "等待主题分析",state:topicStageDisposition == .skippedWholeRecording ? .skipped : .waiting),
                .init(id:"fields",title:"标题与摘要",detail:"主题定稿后生成",state:.waiting)
            ]
        }
        let total=status.progress.states.values.reduce(0,+)
        let live=status.progress.states[.running,default:0]>0
        let pending=status.progress.states[.pending,default:0]>0
        let asr=legacyStageStep("asr",title:"语音转写",progress:status.asr,total:total,live:live,pending:pending,
            successDetail:noteTranscriptAvailable ? "\(status.asr.success) 个窗口完成 · 全文可查看" : "\(status.asr.success) 个窗口完成 · 未识别到文字")
        let vad=legacyVADStep(progress:status.vad,total:total,live:live,pending:pending)
        let speaker=legacyStageStep("speaker",title:"说话人分析",progress:status.speaker,total:total,live:live,pending:pending,optional:true)
        let current=segmentModel.library.filter { $0.sourceID == sourceID && $0.sourceRevision == status.progress.revision }
        let finalized=current.filter(\.isFinal)
        let enrichment=audioProcessing.enrichmentStatus(sourceID,task:.topics)
        let topics:RecordingProcessingStep
        if topicStageDisposition == .skippedWholeRecording {
            topics = .init(id:"topics",title:"主题拆分与分类",detail:current.contains(where:{$0.editorial != nil}) ? "保留历史分类结果；新规则跳过主题拆分与 AI 分类" : "短录音保留为整段；跳过主题拆分与 AI 分类",state:.skipped)
        } else if topicStageDisposition == .waitingForSourceCompletion {
            topics = .init(id:"topics",title:"主题拆分与分类",detail:"录音完整后按总时长决定是否拆分主题",state:.waiting)
        } else { switch enrichment {
        case .failed,.unavailable:
            topics = .init(id:"topics",title:"主题拆分与分类",detail:enrichment == .unavailable ? "所选整理模型暂不可用" : "主题整理失败，可重新处理",state:.failure)
        case .running:
            topics = .init(id:"topics",title:"主题拆分与分类",detail:"正在整理主题与分类",state:.running)
        case .awaitingConsent:
            topics = .init(id:"topics",title:"主题拆分与分类",detail:"等待确认后继续",state:.waiting)
        case _ where !current.isEmpty && finalized.count == current.count:
            topics = .init(id:"topics",title:"主题拆分与分类",detail:"\(finalized.count) 个片段边界与分类已确定",state:.success)
        case .complete where current.isEmpty && total > 0 && status.asr.success == total && status.vad.success == total:
            topics = .init(id:"topics",title:"主题拆分与分类",detail:"没有需要展示的内容片段",state:.success)
        case .complete where !current.isEmpty:
            topics = .init(id:"topics",title:"主题拆分与分类",detail:"\(finalized.count) / \(current.count) 个片段已定稿",state:.waiting)
        default:
            topics = .init(id:"topics",title:"主题拆分与分类",detail:live || pending ? "等待语音处理完成" : "等待主题分析",state:live || pending ? .running : .waiting)
        } }
        let fieldCounts=ContentSegmentPresentation.fieldGenerationCounts(finalized)
        let eligibleFields=fieldCounts.eligible, titled=fieldCounts.complete
        let fieldEnrichment=audioProcessing.enrichmentStatus(sourceID,task:.fields)
        let fields:RecordingProcessingStep
        if fieldEnrichment == .failed || fieldEnrichment == .unavailable {
            fields = .init(id:"fields",title:"标题与摘要",detail:"标题或摘要整理失败，可重新处理",state:.failure)
        } else if fieldEnrichment == .running,let progress=audioProcessing.enrichmentProgress[sourceID],progress.stage == .title || progress.stage == .summary {
            fields = .init(id:"fields",title:"标题与摘要",detail:progress.stage == .title ? "正在生成片段标题" : "正在生成片段摘要",state:.running)
        } else if eligibleFields > 0 && titled == eligibleFields {
            fields = .init(id:"fields",title:"标题与摘要",detail:"\(titled) 个可生成片段已有标题和摘要",state:.success)
        } else if (fieldEnrichment == .complete || (fieldEnrichment == .idle && eligibleFields == 0 && enrichment == .complete)) && legacyAudioFinished(status:status,total:total) {
            fields = .init(id:"fields",title:"标题与摘要",detail:eligibleFields == 0 ? "没有需要生成标题与摘要的内容片段" : "部分内容片段没有标题或摘要",state:.skipped)
        } else if fieldEnrichment == .awaitingConsent {
            fields = .init(id:"fields",title:"标题与摘要",detail:"等待确认后继续",state:.waiting)
        } else {
            fields = .init(id:"fields",title:"标题与摘要",detail:eligibleFields == 0 ? "主题定稿后生成" : "\(titled) / \(eligibleFields) 个可生成片段已有标题和摘要",state:.waiting)
        }
        return [asr,vad,speaker,topics,fields]
    }

    private func legacyVADStep(progress:AudioStageProgress?,total:Int,live:Bool,pending:Bool) -> RecordingProcessingStep {
        switch topicStageDisposition {
        case .skippedWholeRecording:
            let hadHistoricalResult=(progress?.success ?? 0)+(progress?.failed ?? 0)+(progress?.missingResource ?? 0)>0
            return .init(id:"vad",title:"语音活动检测",detail:hadHistoricalResult ? "旧批次已运行；重新处理时跳过" : "短录音跳过 VAD",state:.skipped)
        case .waitingForSourceCompletion:
            return .init(id:"vad",title:"语音活动检测",detail:"完整同步后按总时长决定是否运行",state:.waiting)
        case .processTopics:
            if let progress { return legacyStageStep("vad",title:"语音活动检测",progress:progress,total:total,live:live,pending:pending) }
            return .init(id:"vad",title:"语音活动检测",detail:"等待处理状态",state:.waiting)
        }
    }

    private func legacyAudioFinished(status:AudioProcessingStatus,total:Int) -> Bool {
        total > 0 && status.progress.states[.completed,default:0] == total && status.asr.success == total &&
            (topicStageDisposition == .skippedWholeRecording || status.vad.success == total)
    }

    private func legacyStageStep(_ id:String,title:String,progress:AudioStageProgress,total:Int,live:Bool,pending:Bool,optional:Bool=false,successDetail:String?=nil) -> RecordingProcessingStep {
        let failures=progress.failed+progress.missingResource
        let accounted=progress.success+progress.missingResource+progress.failed+progress.cancelled+progress.notRequested
        if failures>0 { return .init(id:id,title:title,detail:"\(progress.success) 成功 · \(failures) 失败",state:.failure) }
        if progress.cancelled>0 { return .init(id:id,title:title,detail:"已暂停，可重新处理",state:.waiting) }
        if total>0 && progress.success>=total { return .init(id:id,title:title,detail:successDetail ?? "\(progress.success) / \(total) 个窗口成功",state:.success) }
        if optional && total>0 && progress.notRequested>=total { return .init(id:id,title:title,detail:"未运行（可选步骤）",state:.skipped) }
        if progress.success>0 { return .init(id:id,title:title,detail:"\(progress.success) / \(max(total,accounted)) 个窗口完成",state:live || pending ? .running : .waiting) }
        if live { return .init(id:id,title:title,detail:"正在处理",state:.running) }
        if pending || total==0 { return .init(id:id,title:title,detail:"等待处理",state:.waiting) }
        if optional && progress.notRequested>0 { return .init(id:id,title:title,detail:"部分窗口未运行（可选步骤）",state:.skipped) }
        return .init(id:id,title:title,detail:"尚未完成",state:.waiting)
    }

    private var noteTranscriptAvailable:Bool { !(model.note(id)?.transcript.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty ?? true) }
    private var legacyTranscriptionDetail:String {
        if noteTranscriptAvailable { return "全文可查看" }
        switch model.note(id)?.transcriptionState {
        case .ready: return "未识别到文字"
        case .running: return "正在处理"
        case .failed,.unavailable: return "转写失败，可重新处理"
        default: return "等待本机处理状态"
        }
    }
    private var legacySpeakerState:RecordingProcessingStep.State {
        switch model.note(id)?.diarizationState {
        case .ready: .success
        case .running: .running
        case .failed,.unavailable: .failure
        default: .waiting
        }
    }
    private var legacySpeakerDetail:String {
        switch model.note(id)?.diarizationState {
        case .ready: "说话人已识别"
        case .running: "正在分析说话人"
        case .failed,.unavailable: model.note(id)?.diarizationMessage ?? "说话人分析失败，可重试"
        default: "等待处理"
        }
    }

    private var legacyASRModelDescription: String {
        if let actual = model.note(id)?.transcriptionEngineName, !actual.isEmpty {
            return "本条实际使用 · \(actual)"
        }
        if let engines = audioProcessing.statuses[sourceID]?.asrEngineNames, !engines.isEmpty {
            return "本条实际使用 · \(engines.joined(separator: " / "))"
        }
        guard let key=audioProcessing.statuses[sourceID]?.progress.configurationKey else {
            return "当前设置 · \(settings.transcriptionLabel)"
        }
        let current=AudioProcessingCoordinator.configurationKey(settings.transcription)
        if key == current || key.hasPrefix(current + "~r:") { return "本条实际使用 · \(settings.transcriptionLabel)" }
        return "历史模型未记录 · 当前 \(settings.transcriptionLabel)"
    }

    private func content(_ note: VoiceNote) -> some View {
        let isSummary = selectedTab == .summary
        let text = isSummary ? note.summary : note.transcript
        let pending = isSummary ? model.summaryModels[id] != nil : note.transcriptionState == .running
        let state = isSummary ? note.summaryState : note.transcriptionState
        return VStack(alignment: .leading, spacing: 12) {
            if pending {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.mini)
                    Text(isSummary ? "正在使用 \(model.summaryModels[id] ?? model.summaryConfiguration(for: note).label) 生成总结…" : "正在转写录音…")
                }.font(.system(size: 11)).foregroundStyle(DaybookStyle.secondary)
            }
            if !isSummary && note.diarizationState == .ready, !(note.transcriptSegments ?? []).isEmpty {
                SpeakerTranscriptView(note: note)
            } else {
                Text(text.isEmpty ? (isSummary ? "还没有总结。可以根据转写全文生成。" : "还没有转写文字。可以开始转写，或在编辑页面补充。") : text)
                    .font(.system(size: 13)).lineSpacing(10)
                    .foregroundStyle(DaybookStyle.bodyText)
                    .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            }
            if !isSummary { SpeakerProcessingView(note: note) }
            if state == .failed || state == .unavailable {
                Text(note.processingMessage ?? (isSummary ? "总结暂不可用。" : "转写暂不可用。"))
                    .font(.system(size: 11)).lineSpacing(6).foregroundStyle(DaybookStyle.red)
            }
            if let error = model.errorMessage {
                Text(error).font(.system(size: 11)).foregroundStyle(DaybookStyle.red)
            }
            HStack(spacing: 18) {
                Button(isSummary ? (text.isEmpty ? "生成总结" : "重新生成") : (text.isEmpty ? "开始转写" : "重新转写")) {
                    if isSummary {
                        if model.summaryConfiguration(for: note).isRemote && settings.requiresRemoteAIConfirmation { remoteSummary = model.prepareRemoteSummary(id) }
                        else { Task { await model.summarize(id) } }
                    } else { Task { await model.transcribe(id) } }
                }
                .disabled(pending || (!isSummary && note.diarizationState == .running) || (isSummary && note.transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))
                Spacer(minLength: 0)
                Button("编辑标题与全文") { playback.stop(); showEditor = true }.disabled(!playbackAllowed)
            }
            .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(DaybookStyle.accent)
            .padding(.top, 14)
            .overlay(alignment: .top) { Rectangle().fill(DaybookStyle.line).frame(height: 1) }
        }
    }
}
