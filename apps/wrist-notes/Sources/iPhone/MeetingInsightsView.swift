import Charts
import SwiftUI

struct HeartRateTimelineView: View {
    @EnvironmentObject private var model: NotesModel
    @EnvironmentObject private var settings: AppSettings
    let note: VoiceNote
    @ObservedObject var playback: AudioPlayback
    @State private var selectedOffset: Double?

    private var timeline: NoteTimeline? { model.timelines[note.id] }
    private var points: [HeartRatePoint] { timeline?.points ?? [] }
    private var selected: HeartRatePoint? {
        guard let selectedOffset else { return nil }
        return points.min { abs($0.offset(in: note) - selectedOffset) < abs($1.offset(in: note) - selectedOffset) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("会议健康", systemImage: "heart.fill").font(.subheadline.weight(.semibold))
                Spacer()
                if model.heartRateLoading.contains(note.id) { ProgressView() }
                else if settings.heartRateEnabled || settings.stateOfMindEnabled {
                    Button("刷新") { Task { await model.refreshHeartRate(note.id) } }.font(.caption)
                }
            }
            if !settings.heartRateEnabled {
                Text("接入录制时段内的 Apple Watch 心率，叠加到录音时间轴。无需启动体能训练。")
                    .font(.caption).foregroundStyle(.secondary)
                Button("开启心率接入") { Task { await model.setHeartRateEnabled(true) } }
                    .disabled(model.requestingHealthAccess)
            } else if !points.isEmpty {
                Text("心率（bpm）").font(.caption.weight(.semibold))
                Chart {
                    ForEach(points) { point in
                        PointMark(x: .value("录音时间", point.offset(in: note)), y: .value("心率", point.bpm))
                            .foregroundStyle(NotesStyle.red).symbolSize(30)
                            .accessibilityLabel("\(RecordingFormat.duration(point.offset(in: note)))，\(Int(point.bpm.rounded())) 次每分钟，\(point.motionLabel)")
                    }
                    RuleMark(x: .value("播放位置", playback.position)).foregroundStyle(.secondary).lineStyle(StrokeStyle(dash: [3]))
                    if let selected {
                        RuleMark(x: .value("选中样本", selected.offset(in: note))).foregroundStyle(NotesStyle.red.opacity(0.4))
                    }
                }
                .chartXScale(domain: 0...max(note.duration, 1))
                .chartYScale(domain: yRange)
                .chartXAxis {
                    AxisMarks(values: .automatic(desiredCount: 4)) { value in
                        AxisGridLine()
                        AxisValueLabel { if let seconds = value.as(Double.self) { Text(RecordingFormat.duration(seconds)) } }
                    }
                }
                .chartXSelection(value: $selectedOffset)
                .frame(height: 150)
                .onChange(of: selectedOffset) { _, value in
                    if value != nil, let selected { playback.seek(to: selected.offset(in: note)) }
                }
                if let selected {
                    Text("\(RecordingFormat.duration(selected.offset(in: note))) · \(Int(selected.bpm.rounded())) bpm · \(selected.motionLabel) · \(selected.sourceName)")
                        .font(.caption.monospacedDigit())
                }
                Text("\(points.count) 个样本 · 样本范围 \(Int((points.map(\.bpm).min() ?? 0).rounded()))–\(Int((points.map(\.bpm).max() ?? 0).rounded())) bpm")
                    .font(.caption).foregroundStyle(.secondary)
                Text("点按图表跳转回听。图中只显示实际样本，空白时段没有测量值；采样范围不代表连续峰谷。")
                    .font(.caption).foregroundStyle(.secondary)
                if let timeline { Text(timeline.motionStatistics).font(.caption).foregroundStyle(.secondary) }
            } else {
                Text("暂无可用心率数据").font(.subheadline)
                Text("系统采样可能稀疏，手表健康数据同步到手机后可再次刷新。空结果也可能与健康数据访问设置有关。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let message = model.timelineMessages[note.id] {
                Text(message).font(.caption).foregroundStyle(NotesStyle.warning)
            }
            if let date = timeline?.refreshedAt, settings.heartRateEnabled {
                Text("上次检查 \(date.formatted(date: .abbreviated, time: .shortened))").font(.caption2).foregroundStyle(.secondary)
            }
            if settings.heartRateEnabled {
                Divider()
                HRVTimelineView(note: note, playback: playback)
            }
            Divider()
            StateOfMindTimelineView(note: note, playback: playback)
        }
        .padding(16)
        .background(NotesStyle.card, in: RoundedRectangle(cornerRadius: 17))
        .overlay(RoundedRectangle(cornerRadius: 17).stroke(NotesStyle.border, lineWidth: 1))
    }

    private var yRange: ClosedRange<Double> {
        let values = points.map(\.bpm)
        return max(0, floor(((values.min() ?? 60) - 5) / 10) * 10)...(ceil(((values.max() ?? 100) + 5) / 10) * 10)
    }
}

private struct StateOfMindTimelineView: View {
    @EnvironmentObject private var model: NotesModel
    @EnvironmentObject private var settings: AppSettings
    let note: VoiceNote
    @ObservedObject var playback: AudioPlayback
    private var timeline: NoteTimeline? { model.timelines[note.id] }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("本人心境记录").font(.caption.weight(.semibold))
            if !settings.stateOfMindEnabled {
                Text("可独立接入健康 App 或手表正念 App 中已有的心境记录。")
                    .font(.caption).foregroundStyle(.secondary)
                Button("开启心境接入") { Task { await model.setStateOfMindEnabled(true) } }
                    .disabled(model.requestingHealthAccess)
            } else if let timeline, !timeline.statesOfMind.isEmpty {
                Text(StateOfMindEvidence.statistics(in: timeline)).font(.caption).foregroundStyle(.secondary)
                DisclosureGroup("查看全部心境记录（\(timeline.statesOfMind.count) 条）") {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(timeline.statesOfMind) { point in
                            VStack(alignment: .leading, spacing: 4) {
                                if point.kind == .momentaryEmotion {
                                    Button { playback.seek(to: point.date.timeIntervalSince(note.capturedAt)) } label: {
                                        Label("\(point.timeLabel(in: note)) · \(point.kindLabel)", systemImage: "play.circle")
                                    }
                                } else {
                                    Text("\(point.kindLabel) · 记录于\(point.timeLabel(in: note))")
                                    Text("\(point.backgroundDayLabel)；仅作当日背景，不能定位到某句话。")
                                        .foregroundStyle(.secondary)
                                }
                                Text("本人记录：\(point.feelingLabel) · \(point.labelsText)")
                                Text("关联因素：\(point.associationsText) · 来源：\(point.sourceName)")
                                    .foregroundStyle(.secondary)
                            }.font(.caption)
                        }
                    }.padding(.top, 8)
                }.font(.caption)
            } else {
                Text("暂无可用心境记录。可能尚未记录、未授权或未同步，不能据此判断本人感受。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text("心境由本人主观记录，不是心率传感器识别。全天心情按查询时手机的日历日期归入背景。")
                .font(.caption).foregroundStyle(.secondary)
            if let message = model.stateOfMindMessages[note.id] { Text(message).font(.caption).foregroundStyle(NotesStyle.warning) }
            if settings.stateOfMindEnabled, let date = timeline?.stateOfMindRefreshedAt {
                Text("心境上次检查 \(date.formatted(date: .abbreviated, time: .shortened))").font(.caption2).foregroundStyle(.secondary)
            }
        }
    }
}

private struct HRVTimelineView: View {
    @EnvironmentObject private var model: NotesModel
    @EnvironmentObject private var settings: AppSettings
    let note: VoiceNote
    @ObservedObject var playback: AudioPlayback
    @State private var selectedOffset: Double?
    private var timeline: NoteTimeline? { model.timelines[note.id] }
    private var points: [HRVPoint] { settings.hrvEnabled ? timeline?.hrvPoints ?? [] : [] }
    private var selected: HRVPoint? {
        guard let selectedOffset else { return nil }
        return points.min {
            distance($0, to: selectedOffset) < distance($1, to: selectedOffset)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("HRV · SDNN（ms）").font(.subheadline.weight(.semibold))
            if !settings.hrvEnabled {
                Text("读取 Apple Watch 已记录的心率变异性，按实际测量窗口回填。")
                    .font(.caption).foregroundStyle(.secondary)
                Button("开启 HRV 接入") { Task { await model.setHRVEnabled(true) } }
                    .disabled(model.requestingHealthAccess)
            } else if points.isEmpty {
                Text("暂无可用 HRV 样本").font(.caption)
                Text("会议期间可能未产生 HRV 测量，或数据尚未同步、未获读取许可。刷新不会主动触发测量，也不会补造数值。")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Chart {
                    ForEach(points) { point in
                        if let range = point.overlap(in: note) {
                            if range.upperBound > range.lowerBound {
                                RuleMark(xStart: .value("开始", range.lowerBound), xEnd: .value("结束", range.upperBound),
                                         y: .value("SDNN", point.sdnnMilliseconds))
                                    .lineStyle(StrokeStyle(lineWidth: 5, lineCap: .round)).foregroundStyle(.mint)
                                    .accessibilityLabel("\(point.windowLabel(in: note))，SDNN \(point.valueLabel)")
                            } else {
                                PointMark(x: .value("采样时间", range.lowerBound), y: .value("SDNN", point.sdnnMilliseconds))
                                    .foregroundStyle(.mint).symbolSize(35)
                            }
                        }
                    }
                    RuleMark(x: .value("播放位置", playback.position)).foregroundStyle(.secondary).lineStyle(StrokeStyle(dash: [3]))
                }
                .chartXScale(domain: 0...max(note.duration, 1))
                .chartYScale(domain: yRange)
                .chartXAxis {
                    AxisMarks(values: .automatic(desiredCount: 4)) { value in
                        AxisGridLine()
                        AxisValueLabel { if let seconds = value.as(Double.self) { Text(RecordingFormat.duration(seconds)) } }
                    }
                }
                .chartXSelection(value: $selectedOffset)
                .frame(height: 120)
                .onChange(of: selectedOffset) { _, value in
                    if let value, let selected, let range = selected.overlap(in: note) {
                        playback.seek(to: min(range.upperBound, max(range.lowerBound, value)))
                    }
                }
                if let selected { Text("\(selected.windowLabel(in: note)) · \(selected.valueLabel)").font(.caption.monospacedDigit()) }
                Text("\(points.count) 个测量窗口。横条表示窗口的 SDNN 统计值，并不表示该时段内 HRV 恒定；空白没有测量值。")
                    .font(.caption).foregroundStyle(.secondary)
                DisclosureGroup("查看测量窗口") {
                    LazyVStack(alignment: .leading, spacing: 9) {
                        ForEach(points) { point in
                            Button { playback.seek(to: point.overlap(in: note)?.lowerBound ?? 0) } label: {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text("\(point.windowLabel(in: note)) · \(point.valueLabel)")
                                    if point.crossesBoundary(of: note) { Text("跨录音边界：该值包含会议外的采样").foregroundStyle(.secondary) }
                                    if point.start == point.end { Text("未提供窗口时长，不能定位逐秒变化").foregroundStyle(.secondary) }
                                }.font(.caption).multilineTextAlignment(.leading)
                            }
                        }
                    }.padding(.top, 8)
                }.font(.caption)
            }
            if let message = model.hrvMessages[note.id] { Text(message).font(.caption).foregroundStyle(NotesStyle.warning) }
            if let date = timeline?.hrvRefreshedAt, settings.hrvEnabled {
                Text("HRV 上次检查 \(date.formatted(date: .abbreviated, time: .shortened))").font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    private func distance(_ point: HRVPoint, to offset: Double) -> Double {
        guard let range = point.overlap(in: note) else { return .infinity }
        if range.contains(offset) { return 0 }
        return min(abs(range.lowerBound - offset), abs(range.upperBound - offset))
    }
    private var yRange: ClosedRange<Double> {
        let values = points.map(\.sdnnMilliseconds)
        return max(0, floor((values.min() ?? 20) - 5))...ceil((values.max() ?? 60) + 5)
    }
}

struct MeetingAnalysisView: View {
    @EnvironmentObject private var model: NotesModel
    @EnvironmentObject private var settings: AppSettings
    let note: VoiceNote
    @ObservedObject var playback: AudioPlayback
    @State private var confirmingRemote = false
    @State private var pendingConfiguration: AIConfiguration?

    private var timeline: NoteTimeline? { model.timelines[note.id] }
    private var analysis: MeetingAnalysis? {
        guard settings.hrvEnabled || timeline?.hrvPoints.isEmpty != false,
              settings.heartRateEnabled || timeline?.points.isEmpty != false,
              settings.stateOfMindEnabled || timeline?.statesOfMind.isEmpty != false else { return nil }
        return timeline?.currentAnalysis(for: note)
    }
    private var events: [HeartRateEvidence] { settings.heartRateEnabled ? timeline.map { HeartRateEvidence.changes(in: $0, note: note) } ?? [] : [] }
    private var hrvEvents: [HRVEvidence] { settings.hrvEnabled ? timeline.map { HRVEvidence.windows(in: $0, note: note) } ?? [] : [] }
    private var mindEvents: [StateOfMindEvidence] { settings.stateOfMindEnabled ? timeline.map { StateOfMindEvidence.records(in: $0, note: note) } ?? [] : [] }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("综合分析").font(.subheadline.weight(.semibold))
                Spacer()
                if model.analysisModels[note.id] != nil {
                    Button("取消") { model.cancelAnalysis(note.id) }
                } else {
                    Button(analysis == nil ? "生成分析" : "重新分析", action: generate)
                        .disabled(note.transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.heartRateLoading.contains(note.id))
                }
            }
            .font(.caption)
            Text("结合转写、总结、心率及采样活动状态、HRV 和本人心境记录复盘。本人感受与 AI 假设分开展示；时间重合不能证明某句话造成了变化。")
                .font(.caption).foregroundStyle(.secondary)
            if let running = model.analysisModels[note.id] { ProgressView("正在使用 \(running) 分析…") }
            if let error = model.analysisErrors[note.id] { Text(error).font(.caption).foregroundStyle(NotesStyle.warning) }
            if let analysis {
                Text(analysis.text).font(.system(size: 14)).lineSpacing(5).textSelection(.enabled)
                Text("\(analysis.model) · \(analysis.generatedAt.formatted(date: .abbreviated, time: .shortened)) · AI 生成，待本人确认")
                    .font(.caption2).foregroundStyle(.secondary)
            } else {
                Text(note.transcript.isEmpty ? "先完成转写再生成综合分析。" : "尚未生成当前数据的综合分析。内容、心率活动状态、HRV 或心境记录更新后需重新生成。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if !events.isEmpty {
                Divider()
                Text("采样与原文证据").font(.subheadline.weight(.semibold))
                Text("筛选同一来源相邻样本相差至少 10 bpm、间隔不超过 10 分钟的区间，最多展示变化最大的 8 个。该规则用于复盘，不代表医学异常。")
                    .font(.caption).foregroundStyle(.secondary)
                ForEach(events) { event in evidenceCard(event) }
            } else if !note.transcript.isEmpty {
                Text("当前没有符合筛选规则的心率区间；这不能说明会议中没有情绪变化。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if !hrvEvents.isEmpty {
                Divider()
                Text("HRV 窗口与原文证据").font(.subheadline.weight(.semibold))
                Text("最多按时间均匀选取 6 个测量窗口供分析，全部样本可在健康时间轴查看。SDNN 没有在本 App 中设定情绪或医学判定阈值。")
                    .font(.caption).foregroundStyle(.secondary)
                ForEach(hrvEvents) { event in
                    VStack(alignment: .leading, spacing: 7) {
                        Button { playback.seek(to: event.range.lowerBound) } label: {
                            Label("\(event.id) · \(event.point.windowLabel(in: note)) · \(event.point.valueLabel)", systemImage: "play.circle")
                        }.font(.caption.weight(.semibold))
                        if event.point.crossesBoundary(of: note) {
                            Text("测量跨录音边界，包含会议外采样，不能全部归因于本场会议。").font(.caption).foregroundStyle(.secondary)
                        }
                        if event.excerpts.isEmpty { Text("没有可匹配的时间戳原文。").font(.caption).foregroundStyle(.secondary) }
                        else {
                            DisclosureGroup("查看同期原文（\(event.excerpts.count) 段）") {
                                LazyVStack(alignment: .leading, spacing: 8) {
                                    ForEach(event.excerpts) { segment in
                                        Button { playback.seek(to: segment.start) } label: {
                                            Text("\(RecordingFormat.duration(segment.start))  \(segment.text)").font(.caption).multilineTextAlignment(.leading)
                                        }
                                    }
                                }.padding(.top, 8)
                            }.font(.caption)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(12)
                        .background(NotesStyle.field, in: RoundedRectangle(cornerRadius: 12))
                }
            }
            if !mindEvents.isEmpty { mindEvidenceCards }
        }
        .padding(16)
        .background(NotesStyle.card, in: RoundedRectangle(cornerRadius: 17))
        .overlay(RoundedRectangle(cornerRadius: 17).stroke(NotesStyle.border, lineWidth: 1))
        .confirmationDialog("发送会议资料及本次健康、心境记录到自定义 AI？", isPresented: $confirmingRemote, titleVisibility: .visible) {
            Button("发送并生成分析") { model.analyze(note.id, authorizedRemote: pendingConfiguration) }
            Button("取消", role: .cancel) { pendingConfiguration = nil }
        } message: {
            Text("服务：\(pendingConfiguration?.baseURL ?? "")\n模型：\(pendingConfiguration?.label ?? "")\n发送本篇转写、总结、心率值及采样时活动状态、HRV SDNN（毫秒）及相对测量窗口，以及已接入的本人心境记录（愉悦程度、感受标签、关联因素和相对记录时间）。包括跨录音边界的相对时间及同日全天心情背景。原始音频、健康样本 UUID、设备标识和来源名称不发送。")
        }
    }

    private func generate() {
        if settings.ai.mode == .custom {
            pendingConfiguration = settings.ai
            confirmingRemote = true
        } else { model.analyze(note.id) }
    }

    private var mindEvidenceCards: some View {
        VStack(alignment: .leading, spacing: 12) {
            Divider()
            Text("本人心境与原文证据").font(.subheadline.weight(.semibold))
            Text("按时间选取最多 6 条当下感受和 2 条全天背景供分析，全部记录可在会议健康中查看。全天心情不关联具体话语。")
                .font(.caption).foregroundStyle(.secondary)
            ForEach(mindEvents) { event in
                VStack(alignment: .leading, spacing: 7) {
                    if event.point.kind == .momentaryEmotion {
                        Button { playback.seek(to: event.point.date.timeIntervalSince(note.capturedAt)) } label: {
                            Label("\(event.id) · \(event.point.timeLabel(in: note)) · 当下感受", systemImage: "play.circle")
                        }.font(.caption.weight(.semibold))
                    } else {
                        Text("\(event.id) · 全天心情背景 · \(event.point.backgroundDayLabel)").font(.caption.weight(.semibold))
                    }
                    Text(event.material(in: note)).font(.caption)
                    if !event.excerpts.isEmpty {
                        DisclosureGroup("查看时间点重合的原文（\(event.excerpts.count) 段）") {
                            ForEach(event.excerpts) { segment in
                                Button { playback.seek(to: segment.start) } label: {
                                    Text("\(RecordingFormat.duration(segment.start))  \(segment.text)").font(.caption).multilineTextAlignment(.leading)
                                }
                            }
                        }.font(.caption)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(12)
                    .background(NotesStyle.field, in: RoundedRectangle(cornerRadius: 12))
            }
        }
    }

    private func evidenceCard(_ event: HeartRateEvidence) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Button { playback.seek(to: event.from.offset(in: note)) } label: {
                Label("\(event.id) · \(RecordingFormat.duration(event.from.offset(in: note)))–\(RecordingFormat.duration(event.to.offset(in: note)))", systemImage: "play.circle")
            }
            .font(.subheadline.weight(.semibold))
            Text("\(Int(event.from.bpm.rounded())) → \(Int(event.to.bpm.rounded())) bpm（\(event.delta >= 0 ? "+" : "")\(Int(event.delta.rounded()))）")
                .font(.subheadline.monospacedDigit())
            Text("仅代表两次采样值，中间的变化时刻和原因未知。")
                .font(.caption).foregroundStyle(.secondary)
            Text("两次采样活动状态：\(event.from.motionLabel) → \(event.to.motionLabel)。仅描述采样点。")
                .font(.caption).foregroundStyle(.secondary)
            if event.excerpts.isEmpty {
                Text("此区间暂无可靠的时间戳原文，可重新转写后再分析。")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                DisclosureGroup("查看同期原文（\(event.excerpts.count) 段）") {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(event.excerpts) { segment in
                            Button { playback.seek(to: segment.start) } label: {
                                Text("\(RecordingFormat.duration(segment.start))  \(segment.text)")
                                    .font(.caption).multilineTextAlignment(.leading)
                            }
                        }
                    }.padding(.top, 8)
                }.font(.caption)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading).padding(12)
        .background(NotesStyle.field, in: RoundedRectangle(cornerRadius: 12))
    }
}
