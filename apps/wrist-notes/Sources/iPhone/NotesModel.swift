import Combine
import AVFAudio
import Foundation

@MainActor
final class NotesModel: ObservableObject {
    @Published private(set) var notes: [VoiceNote] = []
    @Published var errorMessage: String?
    @Published private(set) var watchStatus = PhoneWatchStatus()
    @Published private(set) var summaryModels: [UUID: String] = [:]
    @Published private(set) var timelines: [UUID: NoteTimeline] = [:]
    @Published private(set) var heartRateLoading: Set<UUID> = []
    @Published private(set) var timelineMessages: [UUID: String] = [:]
    @Published private(set) var hrvMessages: [UUID: String] = [:]
    @Published private(set) var stateOfMindMessages: [UUID: String] = [:]
    @Published private(set) var analysisModels: [UUID: String] = [:]
    @Published private(set) var analysisErrors: [UUID: String] = [:]
    @Published private(set) var speakerProgress: [UUID: String] = [:]
    @Published private(set) var speakerErrors: [UUID: String] = [:]
    let settings: AppSettings

    private var repository: NoteRepository?
    private var connectivity: PhoneConnectivity?
    private var activeTranscriptions: Set<UUID> = []
    private var timelineStore: NoteTimelineStore?
    private let heartRate = HeartRateService()
    private var refreshingHeartRates = false
    private var heartRatesDirty = false
    private var healthGeneration = UUID()
    private var analysisTasks: [UUID: Task<Void, Never>] = [:]
    private var speakerTasks: [UUID: Task<Void, Never>] = [:]
    private var speakerRunIDs: [UUID: UUID] = [:]
    private var pendingSpeakerIDs: Set<UUID> = []
    @Published private(set) var requestingHealthAccess = false

    init(settings initialSettings: AppSettings? = nil) {
        self.settings = initialSettings ?? AppSettings()
        do {
            let root = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("VoiceNotes", isDirectory: true)
            let repository = try NoteRepository(root: root)
            let inbox = root.appendingPathComponent("Inbox", isDirectory: true)
            let connectivity = try PhoneConnectivity(inbox: inbox)
            self.repository = repository
            self.connectivity = connectivity
            self.notes = repository.notes.sorted { $0.capturedAt > $1.capturedAt }
            do { timelineStore = try NoteTimelineStore(root: root) }
            catch { errorMessage = "无法打开时间轴：\(error.localizedDescription)" }
            heartRate.onChange = { [weak self] in await self?.refreshHeartRates() }
            heartRate.startObserving(includeHRV: settings.hrvEnabled, includeStateOfMind: settings.stateOfMindEnabled,
                includeHeartRate: settings.heartRateEnabled)
            connectivity.onReceive = { [weak self] metadata, audio in
                Task { @MainActor [weak self] in self?.receive(metadata, audio: audio) }
            }
            connectivity.onStatusChange = { [weak self] status in
                Task { @MainActor [weak self] in self?.watchStatus = status }
            }
            connectivity.refreshStatus()
            connectivity.drainInbox()
            for note in notes where note.transcriptionState == .pending || note.transcriptionState == .running {
                Task { await self.transcribe(note.id) }
            }
        } catch {
            errorMessage = "无法打开本地笔记：\(error.localizedDescription)"
        }
    }

    func note(_ id: UUID) -> VoiceNote? { notes.first { $0.id == id } }
    func refreshWatchStatus() { connectivity?.refreshStatus() }
    func audioURL(_ id: UUID) -> URL? {
        guard let repository, let note = note(id) else { return nil }
        return repository.audioURL(for: note)
    }

    func save(id: UUID, title: String, transcript: String) {
        if note(id)?.transcript != transcript {
            cancelAnalysis(id)
            cancelSpeakerDiarization(id)
            mutateTimeline(id) { $0.segments = []; $0.words = []; $0.diarization = nil; $0.segmentTranscript = nil; $0.invalidate() }
        }
        edit(id) { $0.applyEdit(title: title, transcript: transcript) }
    }

    func delete(_ id: UUID) {
        cancelAnalysis(id)
        cancelSpeakerDiarization(id)
        do {
            try repository?.delete(id: id)
            refresh()
            try timelineStore?.delete(id)
            timelines[id] = nil
            timelineMessages[id] = nil
            hrvMessages[id] = nil
            stateOfMindMessages[id] = nil
            analysisErrors[id] = nil
            speakerErrors[id] = nil
            refresh()
        } catch { errorMessage = error.localizedDescription }
    }

    func importAudioFile(_ source: URL) async {
        guard let repository else { return }
        let access = source.startAccessingSecurityScopedResource()
        defer { if access { source.stopAccessingSecurityScopedResource() } }
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).m4a")
        do {
            try FileManager.default.copyItem(at: source, to: temporary)
            let file = try AVAudioFile(forReading: temporary)
            let duration = Double(file.length) / file.processingFormat.sampleRate
            let note = try repository.importRecording(
                id: UUID(), from: temporary, kind: .long, capturedAt: .now, duration: duration
            )
            try repository.update(id: note.id) {
                $0.title = source.deletingPathExtension().lastPathComponent
            }
            refresh()
            await transcribe(note.id)
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            errorMessage = "导入录音失败：\(error.localizedDescription)"
        }
    }

    func transcribe(_ id: UUID) async {
        guard !activeTranscriptions.contains(id), let file = audioURL(id) else { return }
        let transcriptBeforeRun = note(id)?.transcript ?? ""
        cancelSpeakerDiarization(id)
        activeTranscriptions.insert(id)
        defer { activeTranscriptions.remove(id) }
        edit(id) { $0.transcriptionState = .running; $0.processingMessage = nil }
        do {
            let result = try await OnDeviceTranscriber().transcribe(fileURL: file, locale: Locale(identifier: settings.localeIdentifier))
            let unchanged = note(id)?.transcript == transcriptBeforeRun
            if unchanged {
                cancelAnalysis(id)
                mutateTimeline(id) {
                    $0.segments = result.segments; $0.words = result.words
                    $0.diarization = nil; $0.segmentTranscript = result.text; $0.invalidate()
                }
            }
            edit(id) {
                if unchanged { $0.applyEdit(title: $0.title, transcript: result.text) }
                $0.transcriptionState = .ready
                $0.processingMessage = nil
            }
            if unchanged, settings.speakerDiarizationEnabled { identifySpeakers(id) }
        } catch {
            edit(id) {
                $0.transcriptionState = error is TranscriptionFailure ? .unavailable : .failed
                $0.processingMessage = error.localizedDescription
            }
        }
    }

    func summarize(_ id: UUID) async {
        guard let note = note(id), summaryModels[id] == nil else { return }
        let text = note.transcript
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let configuration = settings.ai
        summaryModels[id] = configuration.label
        defer { summaryModels[id] = nil }
        edit(id) { $0.summaryState = .running; $0.processingMessage = nil }
        do {
            let summary: String
            if configuration.mode == .local {
                summary = try await OnDeviceSummarizer().summarize(text)
            } else {
                summary = try await CustomAISummarizer().summarize(text, configuration: configuration, apiKey: settings.apiKey())
            }
            edit(id) {
                guard $0.transcript == text else { return }
                $0.summary = summary
                $0.summaryState = .ready
                $0.processingMessage = nil
            }
        } catch {
            edit(id) {
                guard $0.transcript == text else { return }
                $0.summaryState = error is SummaryFailure ? .unavailable : .failed
                $0.processingMessage = error.localizedDescription
            }
        }
    }

    private func receive(_ metadata: IncomingRecording, audio: URL) {
        guard let repository else { return }
        do {
            let isNewRecording = !repository.notes.contains { $0.id == metadata.id }
            _ = try repository.importRecording(
                id: metadata.id, from: audio, kind: metadata.kind,
                capturedAt: metadata.capturedAt, duration: metadata.duration
            )
            if let clock = metadata.recordingClock, clock.canAlign(capturedAt: metadata.capturedAt, duration: metadata.duration) {
                try repository.update(id: metadata.id) { if $0.recordingClock == nil { $0.recordingClock = clock } }
            }
            // A duplicate transfer leaves its inbox copy untouched; the durable copy is already indexed.
            if FileManager.default.fileExists(atPath: audio.path) {
                try? FileManager.default.removeItem(at: audio)
            }
            refresh()
            connectivity?.acknowledge(metadata.id)
            Task { await self.refreshHeartRate(metadata.id) }
            if isNewRecording { Task { await self.transcribe(metadata.id) } }
        } catch { errorMessage = "录音接收失败：\(error.localizedDescription)" }
    }

    func openTimeline(_ id: UUID) async {
        _ = loadTimeline(id)
        await refreshHeartRate(id)
    }

    func setHeartRateEnabled(_ enabled: Bool) async {
        guard !requestingHealthAccess else { return }
        if enabled {
            requestingHealthAccess = true
            defer { requestingHealthAccess = false }
            do {
                try await heartRate.requestAccess(includeHRV: settings.hrvEnabled)
                settings.heartRateEnabled = true
                await refreshHeartRates()
            } catch { errorMessage = "无法开启心率接入：\(error.localizedDescription)" }
        } else {
            settings.heartRateEnabled = false
            settings.hrvEnabled = false
            healthGeneration = UUID()
            for id in Array(analysisTasks.keys) { cancelAnalysis(id) }
            var failedToClear = false
            for note in notes {
                if !mutateTimeline(note.id, {
                    $0.points = []; $0.refreshedAt = nil
                    $0.hrvPoints = []; $0.hrvRefreshedAt = nil; $0.invalidate()
                }) { failedToClear = true }
                hrvMessages[note.id] = nil
            }
            if failedToClear {
                errorMessage = "心率接入已关闭，但部分本地时间轴未能清除。请保持 iPhone 解锁后再次关闭，或删除对应笔记。"
            }
            await heartRate.stopHeartRateObserving()
        }
    }

    func setHRVEnabled(_ enabled: Bool) async {
        guard !requestingHealthAccess else { return }
        if enabled {
            requestingHealthAccess = true
            defer { requestingHealthAccess = false }
            do {
                // Add a new read type without forcing existing users to turn off and erase heart-rate data.
                try await heartRate.requestAccess(includeHRV: true)
                if !settings.hrvEnabled {
                    healthGeneration = UUID()
                    for id in Array(analysisTasks.keys) { cancelAnalysis(id) }
                    for note in notes { mutateTimeline(note.id) { $0.invalidate() } }
                }
                settings.heartRateEnabled = true
                settings.hrvEnabled = true
                await refreshHeartRates()
            } catch { errorMessage = "无法开启 HRV 接入：\(error.localizedDescription)" }
        } else {
            settings.hrvEnabled = false
            healthGeneration = UUID()
            for id in Array(analysisTasks.keys) { cancelAnalysis(id) }
            var failedToClear = false
            for note in notes {
                if !mutateTimeline(note.id, { $0.hrvPoints = []; $0.hrvRefreshedAt = nil; $0.invalidate() }) { failedToClear = true }
                hrvMessages[note.id] = nil
            }
            if failedToClear { errorMessage = "HRV 接入已关闭，但部分本地数据未能清除。请解锁手机后重试。" }
            await heartRate.stopHRVObserving()
        }
    }

    func setStateOfMindEnabled(_ enabled: Bool) async {
        guard !requestingHealthAccess else { return }
        if enabled {
            requestingHealthAccess = true
            defer { requestingHealthAccess = false }
            do {
                try await heartRate.requestStateOfMindAccess()
                if !settings.stateOfMindEnabled {
                    healthGeneration = UUID()
                    for id in Array(analysisTasks.keys) { cancelAnalysis(id) }
                    for note in notes { mutateTimeline(note.id) { $0.invalidate() } }
                }
                settings.stateOfMindEnabled = true
                await refreshHeartRates()
            } catch { errorMessage = "无法开启心境接入：\(error.localizedDescription)" }
        } else {
            settings.stateOfMindEnabled = false
            healthGeneration = UUID()
            for id in Array(analysisTasks.keys) { cancelAnalysis(id) }
            var failedToClear = false
            for note in notes {
                if !mutateTimeline(note.id, { $0.statesOfMind = []; $0.stateOfMindRefreshedAt = nil; $0.invalidate() }) { failedToClear = true }
                stateOfMindMessages[note.id] = nil
            }
            if failedToClear { errorMessage = "心境接入已关闭，但部分本地数据未能清除。请解锁手机后重试。" }
            await heartRate.stopStateOfMindObserving()
        }
    }

    private var healthEnabled: Bool { settings.heartRateEnabled || settings.stateOfMindEnabled }

    func refreshHeartRates() async {
        guard healthEnabled else { return }
        heartRatesDirty = true
        guard !refreshingHeartRates else { return }
        refreshingHeartRates = true
        defer { refreshingHeartRates = false }
        repeat {
            heartRatesDirty = false
            for id in notes.filter({ $0.recordingClock != nil }).map(\.id) {
                guard healthEnabled else { return }
                await refreshHeartRate(id)
            }
        } while heartRatesDirty
    }

    func refreshHeartRate(_ id: UUID) async {
        guard healthEnabled, !heartRateLoading.contains(id), let note = note(id), loadTimeline(id) else { return }
        guard note.recordingClock?.canAlign(capturedAt: note.capturedAt, duration: note.duration) == true else {
            timelineMessages[id] = "此录音缺少可靠的录制时钟，无法自动关联健康数据。请使用更新后的手表 App 录制。"
            return
        }
        let generation = healthGeneration
        heartRateLoading.insert(id)
        defer {
            heartRateLoading.remove(id)
            // A permission toggle during an in-flight query must schedule a refresh for the new selection.
            if generation != healthGeneration, healthEnabled {
                Task { await self.refreshHeartRate(id) }
            }
        }
        if settings.heartRateEnabled {
            do {
                let points = try await heartRate.points(for: note)
                guard settings.heartRateEnabled, generation == healthGeneration, self.note(id) != nil else { return }
                timelineMessages[id] = nil
                mutateTimeline(id) { $0.replacePoints(points, for: note) }
            } catch {
                if generation == healthGeneration { timelineMessages[id] = "心率更新失败，已保留上次数据：\(error.localizedDescription)" }
            }
        }
        guard generation == healthGeneration, self.note(id) != nil else { return }
        if settings.heartRateEnabled && settings.hrvEnabled {
            do {
                let points = try await heartRate.hrvPoints(for: note)
                guard settings.heartRateEnabled, settings.hrvEnabled, generation == healthGeneration, self.note(id) != nil else { return }
                hrvMessages[id] = nil
                mutateTimeline(id) { $0.replaceHRVPoints(points, for: note) }
            } catch {
                if generation == healthGeneration { hrvMessages[id] = "HRV 更新失败，已保留上次数据：\(error.localizedDescription)" }
            }
        }
        guard settings.stateOfMindEnabled, generation == healthGeneration, self.note(id) != nil else { return }
        do {
            let points = try await heartRate.statesOfMind(for: note)
            guard settings.stateOfMindEnabled, generation == healthGeneration, self.note(id) != nil else { return }
            stateOfMindMessages[id] = nil
            mutateTimeline(id) { $0.replaceStatesOfMind(points, for: note) }
        } catch {
            if generation == healthGeneration { stateOfMindMessages[id] = "心境更新失败，已保留上次数据：\(error.localizedDescription)" }
        }
    }

    func analyze(_ id: UUID, authorizedRemote: AIConfiguration? = nil) {
        guard analysisTasks[id] == nil, let snapshot = note(id), loadTimeline(id), let timeline = timelines[id] else { return }
        guard (settings.hrvEnabled || timeline.hrvPoints.isEmpty), (settings.heartRateEnabled || timeline.points.isEmpty),
              (settings.stateOfMindEnabled || timeline.statesOfMind.isEmpty) else {
            analysisErrors[id] = "已关闭的健康数据尚未清理完成，请解锁手机后重试关闭，再生成分析。"
            return
        }
        let configuration = settings.ai
        guard configuration.mode != .custom || authorizedRemote == configuration else {
            analysisErrors[id] = "请先确认将转写、总结及本次心率、活动状态、HRV 和心境记录发送到当前 AI 服务。"
            return
        }
        analysisModels[id] = configuration.label
        analysisErrors[id] = nil
        analysisTasks[id] = Task { [weak self] in
            guard let self else { return }
            defer { self.analysisTasks[id] = nil; self.analysisModels[id] = nil }
            do {
                let key = configuration.mode == .custom ? try self.settings.apiKey() : nil
                let text = try await MeetingAnalyzer().analyze(note: snapshot, timeline: timeline, configuration: configuration, apiKey: key)
                try Task.checkCancellation()
                guard let current = self.note(id), current.transcript == snapshot.transcript,
                      current.summary == snapshot.summary, self.timelines[id]?.revision == timeline.revision,
                      configuration == self.settings.ai else {
                    self.analysisErrors[id] = "分析期间内容或健康数据已更新，请重新生成。"
                    return
                }
                self.mutateTimeline(id) {
                    $0.analysis = MeetingAnalysis(text: text, model: configuration.label, generatedAt: .now,
                        inputRevision: timeline.revision, transcript: snapshot.transcript, summary: snapshot.summary)
                }
            } catch is CancellationError { }
            catch { if !Task.isCancelled { self.analysisErrors[id] = "综合分析未完成：\(error.localizedDescription)" } }
        }
    }

    func cancelAnalysis(_ id: UUID) { analysisTasks[id]?.cancel() }

    func identifySpeakers(_ id: UUID) {
        if let task = speakerTasks[id] {
            if task.isCancelled { pendingSpeakerIDs.insert(id) }
            return
        }
        guard let snapshot = note(id), let file = audioURL(id), loadTimeline(id),
              let timeline = timelines[id] else { return }
        guard speakerTasks.isEmpty else { speakerErrors[id] = "正在处理另一条录音，请完成或取消后再试。"; return }
        guard snapshot.transcriptionState != .running, !timeline.alignedSegments(for: snapshot).isEmpty else {
            speakerErrors[id] = "请先完成带时间戳的转写。已有全文不会为区分发言人而自动改写。"
            return
        }
        settings.speakerDiarizationEnabled = true
        speakerErrors[id] = nil
        let runID = UUID()
        speakerRunIDs[id] = runID
        speakerProgress[id] = "准备本地说话人模型；首次使用需要下载…"
        let words = timeline.words.isEmpty ? timeline.alignedSegments(for: snapshot) : timeline.words
        speakerTasks[id] = Task { [weak self] in
            guard let self else { return }
            defer {
                self.speakerTasks[id] = nil; self.speakerProgress[id] = nil; self.speakerRunIDs[id] = nil
                if self.pendingSpeakerIDs.remove(id) != nil, self.settings.speakerDiarizationEnabled { self.identifySpeakers(id) }
            }
            do {
                let worker = Task.detached(priority: .utility) {
                    try await LocalSpeakerDiarizer().identify(file: file, note: snapshot, words: words) { [weak self] message in
                        Task { @MainActor [weak self] in
                            guard let self, self.speakerRunIDs[id] == runID, self.speakerTasks[id]?.isCancelled == false else { return }
                            self.speakerProgress[id] = message
                        }
                    }
                }
                let result = try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
                try Task.checkCancellation()
                guard self.note(id)?.transcript == snapshot.transcript,
                      self.note(id)?.audioFilename == snapshot.audioFilename,
                      self.note(id)?.duration == snapshot.duration,
                      self.timelines[id]?.segmentTranscript == snapshot.transcript,
                      self.note(id)?.transcriptionState != .running else {
                    self.speakerErrors[id] = "转写或录音内容已更新，请重新区分发言人。"
                    return
                }
                cancelAnalysis(id)
                if !mutateTimeline(id, { $0.diarization = result; $0.invalidate() }) {
                    self.speakerErrors[id] = "发言人结果未能保存，请保持手机解锁后重试。"
                }
            } catch is CancellationError { }
            catch { if !Task.isCancelled { self.speakerErrors[id] = "本地区分未完成：\(error.localizedDescription)" } }
        }
    }

    func cancelSpeakerDiarization(_ id: UUID) {
        pendingSpeakerIDs.remove(id)
        if let task = speakerTasks[id] {
            task.cancel()
            speakerProgress[id] = "正在取消；当前步骤结束后停止…"
        }
    }

    func renameSpeaker(_ id: UUID, speakerID: String, name: String) {
        let name = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(40))
        guard timelines[id]?.diarization?.speakerIDs.contains(speakerID) == true else { return }
        speakerErrors[id] = nil
        if !mutateTimeline(id, {
            if name.isEmpty { $0.diarization?.names[speakerID] = nil }
            else { $0.diarization?.names[speakerID] = name }
            $0.invalidate()
        }) { speakerErrors[id] = "名称未能保存，请保持手机解锁后重试。" }
    }

    @discardableResult
    private func loadTimeline(_ id: UUID) -> Bool {
        guard note(id) != nil, let timelineStore else { return false }
        if timelines[id] != nil { return true }
        do { timelines[id] = try timelineStore.load(id); return true }
        catch { timelineMessages[id] = "无法读取时间轴：\(error.localizedDescription)"; return false }
    }

    @discardableResult
    private func mutateTimeline(_ id: UUID, _ mutate: (inout NoteTimeline) -> Void) -> Bool {
        guard loadTimeline(id), var timeline = timelines[id], let timelineStore else { return false }
        mutate(&timeline)
        do { try timelineStore.save(timeline, id: id); timelines[id] = timeline; return true }
        catch { timelineMessages[id] = "时间轴保存失败：\(error.localizedDescription)"; return false }
    }

    private func edit(_ id: UUID, _ change: (inout VoiceNote) -> Void) {
        do {
            try repository?.update(id: id, change)
            refresh()
        } catch { errorMessage = error.localizedDescription }
    }

    private func refresh() {
        notes = repository?.notes.sorted { $0.capturedAt > $1.capturedAt } ?? []
    }
}
