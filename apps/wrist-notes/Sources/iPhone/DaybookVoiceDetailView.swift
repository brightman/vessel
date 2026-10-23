import SwiftUI

/// Shared with derived content so both detail routes use the approved prototype.
enum DaybookAudioContentTab: String, CaseIterable {
    case summary = "总结", transcript = "全文"
}

struct DaybookAudioTabs: View {
    @Binding var selection: DaybookAudioContentTab
    var body: some View {
        HStack(spacing:0) {
            ForEach(DaybookAudioContentTab.allCases,id:\.self) { tab in
                Button { selection=tab } label: {
                    Text(tab.rawValue).font(.system(size:12,weight:selection == tab ? .medium : .regular))
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
    @Environment(\.dismiss) private var dismiss
    @StateObject private var playback = AudioPlayback()
    @State private var selectedTab: DaybookAudioContentTab = .summary
    @State private var showEditor = false
    @State private var confirmFullDeletion = false
    @State private var remoteSummary: NotesModel.RemoteSummaryRequest?

    var body: some View {
        DaybookSheetLayout(title: model.note(id)?.displayTitle ?? "语音记录", onClose: { dismiss() }) {
            if let note = model.note(id) {
                VStack(alignment: .leading, spacing: 0) {
                    Text("\(RecordingFormat.date(note.capturedAt)) · \(note.kind == .thought ? "闪念" : "语音记录") · \(RecordingFormat.duration(note.duration))")
                        .font(.system(size: 10)).lineSpacing(6).foregroundStyle(DaybookStyle.secondary)
                        .padding(.bottom, 18)
                    if note.kind == .long { RecordingTitleAction(note: note).padding(.bottom, 14) }
                    LabeledContent("录制设备", value: note.origin?.device ?? "设备未知")
                        .font(.system(size: 12)).padding(.bottom, 14)
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
                        }.padding(.bottom, 14)
                    }
                    if let point = note.location { CapturePlaceDetails(point: point).padding(.bottom, 14) }
                    if let origin = note.origin, origin.recordingTimeIsEstimated {
                        Text("来自 \(origin.device)\(origin.recordingTimeIsEstimated ? " · 录制时间缺失，按同步时间显示" : "")")
                            .font(.system(size: 10)).foregroundStyle(DaybookStyle.secondary).padding(.bottom, 14)
                    }
                    if note.usesLocalThoughtAI {
                        Text("闪念在 iPhone 本地转写，并由 Apple 本地模型整理。模型暂不可用时可先回听、查看全文，稍后重试。")
                            .font(.system(size: 10)).lineSpacing(6).foregroundStyle(DaybookStyle.secondary).padding(.bottom, 14)
                    }
                    player
                    if note.kind == .long || note.duration > 300 {
                        AudioSourceProcessingView(sourceID:.init(kind:.legacyNote,id:id)).padding(.top,16)
                        ContentSegmentSourceListView(sourceID:.init(kind:.legacyNote,id:id),playbackAllowed:playbackAllowed).padding(.top,16)
                    }
                    tabs.padding(.top, 20).padding(.bottom, 20)
                    content(note)
                    Button("删除完整录音", role:.destructive) { confirmFullDeletion = true }
                        .font(.system(size:12)).padding(.top,24).disabled(!playbackAllowed)
                }
            } else {
                Text("这条语音记录已不存在。")
                    .font(.system(size: 13)).foregroundStyle(DaybookStyle.secondary)
                    .padding(.vertical, 25)
            }
        }
        .task(id: id) {
            await playback.load(model.audioURL(id), fallbackDuration: model.note(id)?.duration ?? 0)
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
