import SwiftUI
import UniformTypeIdentifiers
import AVFAudio

// Retained for older library/settings routes.
enum DaybookRoute: Hashable { case record(UUID), preferences, reminders }
private enum DaybookPage: String { case day, ai, actions, insights, library, data }
private struct DaybookReminderDraft: Hashable {
    let title: String
    let sourceID: UUID?
    let initialDate: Date?
}
private enum DaybookSheet: Hashable, Identifiable {
    case actionProposal, capture, photo, date, places, hardware, watch, transcription, myVoice, quickRecording, aiSettings, preferences, reminders
#if WISELIFE_EUREKA_RING
    case ring
#endif
    case actionOrigin(ActionSource), record(UUID), lifeMoment(UUID, Date, Bool), recap(Date), reminder(DaybookReminderDraft), source(String)
    var id: Self { self }
}
private enum DaybookFilter: String, CaseIterable {
    case all = "全部", audio = "语音", image = "图片", thought = "闪念", life = "生活", recap = "回顾"
    func includes(_ record: DayRecord) -> Bool {
        switch self { case .all: true; case .audio: record.kind.isAudio; case .image: record.kind == .image; case .thought: record.kind == .thought; case .life: record.kind.isLife; case .recap: false }
    }
}

struct DaybookView: View {
    @EnvironmentObject private var content: ContentSegmentModel
    @EnvironmentObject private var sessions: RecordingSessionModel
    @EnvironmentObject private var model: NotesModel
    @EnvironmentObject private var settings: AppSettings
#if WISELIFE_EUREKA_RING
    @EnvironmentObject private var ring: EurekaRingModel
#endif
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var semanticSearch = DaybookSemanticSearchModel()
    @StateObject private var assistant = DaybookAssistantModel()
    @StateObject private var dailyInsight = DaybookInsightModel()
    @StateObject private var recaps = DaybookRecapModel()
    @EnvironmentObject private var life: LifeSourceModel
    @StateObject private var addresses = CaptureAddressModel()
    @StateObject private var recordingAddresses = RecordingLocationAddressModel()
    @StateObject private var photos = PhotoLibraryModel()
    @EnvironmentObject private var recorder: PhoneRecorder
    @EnvironmentObject private var recording: PhoneRecordingSession
    @StateObject private var preferences = DaybookPreferences()
    @StateObject private var reminders = DaybookReminderStore()
    @StateObject private var actions = ActionStore()
    @State private var actionSources: [ActionSource] = []
    @StateObject private var suggestions = DaybookSuggestionStore()
    @State private var page: DaybookPage = .day
    @State private var selectedDate = Date.now
    @State private var clockNow = Date.now
    @State private var sheet: DaybookSheet?
    @State private var nextSheet: DaybookSheet?
    @State private var showImporter = false
    @State private var search = ""
    @State private var focusSearchOnAppear = false
    @FocusState private var searchFocused: Bool
    @State private var filter: DaybookFilter = .all
    @State private var deleteRecord: DayRecord?
    @State private var revealedRecordID: UUID?
    @State private var selectedMergeIDs = Set<UUID>()
    @State private var showMergeConfirmation = false
    @State private var isMergingRecordings = false
    @State private var mergeSelectionMessage: String?
    @State private var recorderMenu = false
    @State private var initialQuestion = ""
    @State private var citation: DayRecord.ContentProvenance?
    @State private var recapSource: DayRecord?
    @State private var assistantID = UUID()

    private var records: [DayRecord] {
        let audio = content.replacingAudio(model.notes.map(DaybookPlaces.voice),kind:.legacyNote)
        let images = photos.moments.map(DaybookPlaces.photo)
        let sessionRecords = content.replacingAudio(RecordingSessionPresentation.records(sessions.allKnownSessions, legacyIDs: Set(model.notes.map(\.id))),kind:.session)
        let places = DaybookPlaces.records(notes: model.notes, photos: photos.moments)
        let movements = LocationMovementBuilder.records(points: places).filter { !life.isSuppressed($0.id) }
        let moments = LifeMomentBuilder.timeline(records: life.records, day: selectedDate, now: clockNow,
            healthEnabled: life.isEnabled(.health), calendar: .current,
            snapshot: { life.snapshot(.health, day: $0) }, isSuppressed: life.isSuppressed)
        return (audio + sessionRecords + images + life.records + places + movements + moments).sorted { $0.capturedAt > $1.capturedAt }
    }
    private var dayRecords: [DayRecord] { records.compactMap { $0.recordingProjection(on: selectedDate) } }
    private var timelineRecords: [DayRecord] { ContentSegmentPresentation.timelineRecords(dayRecords) }
    private var homeRecapDay: Date { DaybookRecapInput.homeDay(selected: selectedDate, now: clockNow) }
    private var recapDay: Date {
        if case .recap(let date) = sheet ?? nextSheet { return date }
        return homeRecapDay
    }
    private var dayPhotoCount: Int { photos.moments.filter { Calendar.current.isDate($0.capturedAt, inSameDayAs: selectedDate) }.reduce(0) { $0 + $1.photos.count } }
    private var shownRecords: [DayRecord] {
        let start = Calendar.current.startOfDay(for: selectedDate)
        let end = Calendar.current.date(byAdding: .day, value: 1, to: start)!
        return DaybookRetrieval.libraryRecords(query: search, records: records, dayStart: start, dayEnd: end,
            allowedKinds: allowedKinds, semantic: activeSemantic).filter {
                filter.includes($0) && ($0.parentRecordID == nil || filter == .life)
                    && !($0.kind == .activity && $0.lifeMoment?.steps?.archived != true)
                    && !ContentSegmentPresentation.timelineRecords([$0]).isEmpty
            }
    }
    private var mergeListRecords: [DayRecord] {
        guard page == .day || page == .library else { return [] }
        return dayRecords
    }
    private var mergeEligibleIDs: Set<UUID> {
        Set(mergeListRecords.compactMap { record in
            guard record.kind == .voice, record.recordingSessionID == nil, record.parentRecordID == nil,
                  model.canMergeLongRecording(record.id) else { return nil }
            return record.id
        })
    }
    private var canMergeSelection: Bool {
        RecordingMergeSelection.canMerge(selectedMergeIDs, orderedIDs: mergeListRecords.map(\.id), eligibleIDs: mergeEligibleIDs)
    }
    private var activeSemantic: DaybookSemanticMatches? {
        semanticSearch.validated(query: search, records: records, date: selectedDate, allowedKinds: allowedKinds)
    }
    private var allowedKinds: Set<DayRecord.Kind> { preferences.allowedKinds }
    private var sourceStorageAvailability: [Bool] { [model.storageIsAvailable, photos.storageIsAvailable, life.storageIsAvailable] }
    private var suggestionPreferences: [Int] {
        [preferences.proactiveEnabled ? 1 : 0, preferences.allowAudio ? 1 : 0, preferences.allowPhotos ? 1 : 0, preferences.allowHealth ? 1 : 0, preferences.allowCalendar ? 1 : 0, preferences.allowLocation ? 1 : 0,
         preferences.quietEnabled ? 1 : 0, preferences.quietStartMinutes, preferences.quietEndMinutes, preferences.dailySuggestionLimit]
    }

    private var pageContent: some View {
        NavigationStack {
            VStack(spacing: 0) {
                header
                if page == .ai {
                    DaybookAssistantView(model: assistant, records: records, selectedDate: selectedDate, settings: settings,
                        allowedKinds: allowedKinds, initialQuestion: initialQuestion, onOpenRecord: openRecord,
                        onReminder: { title, id in proposeReminder(title, id: id) },
                        onPreferences: { present(.preferences) }, onReminders: { present(.reminders) },
                        reminderCount: reminders.items.filter { $0.status == .scheduled }.count,
                        onNewReminder: { title in proposeReminder(title, id: nil, tomorrow: true) },
                        onOpenCitation: { source in citation = source.provenance; present(.record(source.id)) }, onActions: { sources in
                            actionSources = sources.prefix(3).map { source in
                                ActionSource(id:source.id,title:source.title,quote:String(source.snippet.prefix(1600)),capturedAt:source.capturedAt,timeZoneID:TimeZone.current.identifier,recordingKind:source.provenance != nil ? "segment" : nil,offset:source.provenance?.ranges.first?.sourceOffset)
                            }
                            present(.actionProposal)
                        })
                        .id(assistantID)
                } else {
                    ScrollViewReader { proxy in
                        ScrollView {
                            VStack(alignment: .leading, spacing: 0) {
                                Color.clear.frame(height: 0).id("pageTop")
                                switch page {
                                case .day: dayPage
                                case .actions: ActionListView(store:actions,onOpenSource:{ present(.actionOrigin($0)) })
                                case .library: libraryPage
                                case .insights: insightsPage
                                case .data: dataPage
                                case .ai: EmptyView()
                                }
                            }.padding(.horizontal, 23).padding(.top, 15).padding(.bottom, 30)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }.scrollIndicators(.hidden).scrollDismissesKeyboard(.interactively)
                            .onChange(of: page) { _, _ in proxy.scrollTo("pageTop", anchor: .top) }
                    }
                }
                if !selectedMergeIDs.isEmpty { mergeSelectionBar }
                if recording.phase != .idle || recorder.requestingPermission { recordingBanner }
                bottomBar
            }.background(DaybookStyle.paper).foregroundStyle(DaybookStyle.ink)
                .toolbar(.hidden, for: .navigationBar)
                .sheet(item: $sheet, onDismiss: {
                    if let next = nextSheet { nextSheet = nil; sheet = next }
                }) { value in sheetContent(value).presentationDetents(sheetDetents(value)) }
                .fileImporter(isPresented: $showImporter, allowedContentTypes: [.audio]) { result in
                    switch result {
                    case .success(let url): showToday(); Task { await model.importAudioFile(url) }
                    case .failure(let error): model.errorMessage = error.localizedDescription
                    }
                }
                .confirmationDialog("删除这条记录？", isPresented: Binding(get: { deleteRecord != nil }, set: { if !$0 { deleteRecord = nil } }), titleVisibility: .visible) {
                    Button(LocalizedStringKey(deleteRecord?.contentProvenance != nil ? "删除片段" : deleteRecord?.recordingSessionID != nil ? "删除完整录音" : deleteRecord?.kind.isLife == true && deleteRecord?.parentRecordID == nil ? "删除本机快照" : "删除记录和原文件"), role: .destructive) {
                        if let record = deleteRecord {
                            if let provenance = record.contentProvenance { Task { _ = await content.mutate(sourceID:.init(kind:AudioSourceKind(rawValue:provenance.sourceKind) ?? .legacyNote,id:provenance.sourceID)) { try $0.delete(id:record.id,expectedRevision:provenance.segmentRevision) } } } else if let id = record.recordingSessionID { Task { await sessions.delete(id) } } else if let parent = record.parentRecordID { if model.note(parent) != nil { model.delete(parent) } else { photos.delete(parent) } } else if record.kind.isLife { life.delete(record.id) } else if record.kind == .image { photos.delete(record.id) } else { model.delete(record.id) }
                            deleteRecord = nil
                        }
                    }
                } message: {
                    if deleteRecord?.contentProvenance != nil { Text("仅隐藏此派生片段，保留完整录音。") } else if deleteRecord?.recordingSessionID != nil { Text("这会删除本机完整会话、内容片段及全部原始音频。") }
                }
                .confirmationDialog("合并录音？", isPresented: $showMergeConfirmation, titleVisibility: .visible) {
                    Button("合并所选", role: .destructive) { mergeSelectedRecordings() }
                    Button("取消", role: .cancel) {}
                } message: {
                    Text("音频将按时间顺序拼接，并重新生成全文、总结与标题。保存新录音后会删除选中的原条目。外部 AI 仍按当前确认设置运行。")
                }
                .confirmationDialog("语音记录", isPresented: $recorderMenu, titleVisibility: .visible) {
                    if recorder.isRecording { Button("结束并保存") { recordingAction(.stop) } }
                    else if recording.phase == .failed { Button("重试保存") { recordingAction(.retry) } }
                    Button("放弃录音", role: .destructive) { Task { await recording.discard() } }
                }
                .alert("提示", isPresented: Binding(get: { sheet == nil && (sessions.errorMessage != nil || model.errorMessage != nil || photos.errorMessage != nil || recorder.errorMessage != nil || recording.errorMessage != nil || reminders.errorMessage != nil || life.errorMessage != nil) }, set: { if !$0 { clearErrors() } })) {
                    Button("好") { clearErrors() }
                } message: { Text(LocalizedStringKey(sessions.errorMessage ?? model.errorMessage ?? photos.errorMessage ?? recorder.errorMessage ?? recording.errorMessage ?? reminders.errorMessage ?? life.errorMessage ?? "")) }
        }
    }

    private var observedContent: some View {
        pageContent.buttonStyle(.plain).tint(DaybookStyle.accent).preferredColorScheme(settings.appearance.colorScheme)
            .environment(\.locale, settings.interfaceLanguage.locale)
            .task { await prepareDaybook() }
            .onChange(of: content.loading) { _, _ in synchronizeSemantic() }
            .onChange(of: content.revision) { _, _ in assistant.invalidateLoadedScope(); synchronizeAssistant() }
            .onChange(of: sessions.revision) { _, _ in assistant.invalidateLoadedScope(); synchronizeRecaps(); synchronizeAddresses() }
            .onChange(of: life.revision) { _, _ in assistant.invalidateLoadedScope(); synchronizeRecaps() }
            .onChange(of: sourceStorageAvailability) { _, _ in assistant.invalidateLoadedScope(); synchronizeRecaps() }
            .onChange(of: records) { old, new in
                // A loaded cross-date snapshot must never hide edits/deletions in live sources.
                assistant.invalidateLoadedScope()
                if !selectedMergeIDs.isEmpty && !canMergeSelection {
                    selectedMergeIDs = []
                    mergeSelectionMessage = nil
                }
                synchronizeSuggestions(); synchronizeAssistant(); synchronizeAddresses()
            }
    }
    private var preferenceObservedContent: some View {
        observedContent
            .onChange(of: life.isEnabled(.location)) { _, _ in synchronizeAddresses() }
            .onChange(of: search) { _, _ in selectedMergeIDs = []; synchronizeSemantic() }
            .onReceive(NotificationCenter.default.publisher(for: .daybookSemanticChanged)) { notification in
                guard let change = notification.object as? DaybookSemanticResourceChange else { return }
                semanticSearch.resourcesChanged(change, active: page == .library && scenePhase == .active); assistant.cancel()
            }
            .onChange(of: allowedKinds) { _, _ in synchronizeAssistant() }
            .onChange(of: settings.interfaceLanguage) { _, _ in synchronizeInsights(); synchronizeAddresses() }
            .onChange(of: settings.requiresRemoteAIConfirmation) { _, _ in synchronizeInsights() }
            .onChange(of: recorder.isRecording) { _, _ in synchronizeInsights() }
            .onChange(of: recorder.requestingPermission) { _, _ in synchronizeInsights() }
    }

    var body: some View {
        preferenceObservedContent
            .onChange(of: settings.ai) { _, _ in synchronizeAssistant() }
            .onChange(of: settings.aiRevision) { _, _ in synchronizeAssistant() }
            .onChange(of: suggestionPreferences) { _, _ in synchronizeSuggestions() }
            .onChange(of: selectedDate) { _, _ in selectedMergeIDs = []; filter = .all; search = ""; content.selectDay(selectedDate); sessions.selectDay(selectedDate); life.refreshEnabled(day: selectedDate); synchronizeSuggestions(); synchronizeAssistant(); synchronizeAddresses() }
            .onChange(of: page) { _, value in selectedMergeIDs = []; if value == .day { search = ""; if filter == .recap { filter = .all } }; synchronizeAssistant(); synchronizeSuggestions() }
            .onChange(of: filter) { _, _ in selectedMergeIDs = [] }
            .onChange(of: sheet) { _, _ in synchronizeSuggestions() }
            .onChange(of: recording.phase) { _, _ in synchronizeInsights() }
            .onChange(of: recording.lastSaved?.id) { _, id in
                if id != nil, let saved = recording.lastSaved { showToday(); selectedDate = saved.capturedAt }
            }
            .onReceive(Timer.publish(every: 60, on: .main, in: .common).autoconnect()) { now in
                guard scenePhase == .active else { return }; updateCalendar(now: now); synchronizeSuggestions(now: now)
            }
            .onChange(of: scenePhase) { _, phase in
                if phase != .active { assistant.cancel() }
                synchronizeAssistant(resumeSemantic: phase == .active)
                life.setForeground(phase == .active, day: selectedDate)
                synchronizeAddresses()
                if phase == .active {
                    updateCalendar(now: .now); model.refreshWatchStatus(); synchronizeSuggestions()
                    Task {
                        await reminders.refreshAuthorization()
#if WISELIFE_EUREKA_RING
                        await ring.foreground()
#endif
                    }
                }
            }
    }

    private func prepareDaybook() async {
        actions.attach(reminders)
        recaps.scopeLoader = loadRecapRecords
        content.selectDay(selectedDate)
        assistant.scopeLoader = loadRecapRecords
        sessions.selectDay(selectedDate); synchronizeAssistant(); WiseLifeRuntime.shared.foreground(); synchronizeSuggestions()
        life.setForeground(scenePhase == .active, day: selectedDate); synchronizeAddresses()
        await reminders.refreshAuthorization()
    }

    private var header: some View {
        HStack {
            Button { model.refreshWatchStatus(); present(.hardware) } label: {
                HStack(spacing: 7) {
                    Circle().fill(configuredHardwareCount > 0 ? DaybookStyle.green : DaybookStyle.secondary).frame(width: 5, height: 5)
                    DaybookIcon(hardwareStatusIcon, size: 21)
                    Text(hardwareStatusLabel).font(.system(size: 11, weight: .medium)).lineLimit(1).minimumScaleFactor(0.8)
                }.padding(.leading, 10).padding(.trailing, 12).frame(height: 40)
                    .background(DaybookStyle.white, in: Capsule()).overlay(Capsule().stroke(DaybookStyle.line, lineWidth: 1))
            }.accessibilityLabel("硬件状态：\(hardwareStatusLabel)")
            Spacer()
            Text("WiseLife").font(.system(size: 15, weight: .semibold))
            Spacer()
            HStack(spacing: 4) {
                Button { focusSearchOnAppear = true; page = .library; searchFocused = true } label: { DaybookIcon("Search", size: 21).frame(width: 40, height: 40) }.accessibilityLabel("搜索记录")
                Button { page = .data } label: { DaybookIcon("Settings2", size: 21).frame(width: 40, height: 40) }.accessibilityLabel("数据与设置")
            }.padding(.horizontal, 3).background(DaybookStyle.white, in: Capsule()).overlay(Capsule().stroke(DaybookStyle.line, lineWidth: 1))
        }.padding(.horizontal, 23).padding(.top, 8).padding(.bottom, 10)
    }
    private var configuredHardwareCount: Int {
        var count = model.watchStatus.hasPairedWatch ? 1 : 0
#if WISELIFE_EUREKA_RING
        count += ring.isConnected ? 1 : 0
#endif
        return count
    }
    private var hardwareStatusIcon: String {
#if WISELIFE_EUREKA_RING
        if ring.isConnected { return "Ring" }
#endif
        return "Watch"
    }
    private var hardwareStatusLabel: String {
#if WISELIFE_EUREKA_RING
        if ring.isRecording { return "Ring 录音中" }
#endif
        return model.watchStatus.compactLabel
    }
    private var dayPage: some View {
        VStack(alignment: .leading, spacing: 0) {
            DaybookDateHeading(date: selectedDate, hasRecords: !timelineRecords.isEmpty, onDate: { present(.date) }).padding(.bottom, 20)
            DaybookOverview(records: timelineRecords, photoCount: dayPhotoCount, date: selectedDate, now: clockNow, healthStale: life.snapshot(.health, day: selectedDate)?.isStale ?? false, onOpenRecord: openRecord, onOpenPlaces: { present(.places) }).padding(.bottom, 18)
            DaybookRecapHome(model: recaps, date: homeRecapDay, yesterday: Calendar.current.isDate(selectedDate, inSameDayAs: clockNow), onOpen: { present(.recap(homeRecapDay)) })

            aiHomeLink
            HStack {
                Text(Calendar.current.isDateInToday(selectedDate) ? "今天的片段" : "\(DaybookFormat.day(selectedDate))的片段").font(.system(size: 17, weight: .semibold)).tracking(-0.3)
                Spacer()
                Button { page = .library } label: { HStack(spacing: 3) { Text("查看全部"); DaybookIcon("ArrowUpRight", size: 13) }.font(.system(size: 10)).foregroundStyle(DaybookStyle.secondary) }
            }.padding(.top, 24).padding(.bottom, 16)
            filters
            if content.loading { ProgressView("正在读取内容片段…").font(.caption).padding(.bottom, 12) }
            if let error = content.errorMessage {
                Text(error).font(.caption).foregroundStyle(.orange)
                Button("重试") { content.refresh() }
            }
            recordList(filter == .life ? shownRecords : Array(shownRecords.prefix(4)), home: true)
            HStack(spacing: 6) {
                DaybookIcon("ShieldCheck", size: 13)
                Text("由你选择记录什么，也由你决定何时暂停。").font(.system(size: 9))
            }.foregroundStyle(DaybookStyle.secondary).padding(.top, 30)
        }
    }
    private var libraryPage: some View {
        VStack(alignment: .leading, spacing: 0) {
            pageHeading("留住那些片刻", title: "我的记录", subtitle: filter == .recap ? "按日期查看每日回顾" : "\(DaybookFormat.day(selectedDate)) · \(timelineRecords.count) 条记录")
            HStack(spacing: 9) {
                DaybookIcon("Search", size: 17).foregroundStyle(DaybookStyle.secondary)
                TextField(filter == .recap ? "搜索每日回顾" : "搜索想法、片段或关键词", text: $search).font(.system(size: 12))
                    .textInputAutocapitalization(.never).autocorrectionDisabled().accessibilityLabel(filter == .recap ? "搜索每日回顾" : "搜索想法、片段或关键词")
                    .onSubmit { synchronizeSemantic(resume: true) }
                    .focused($searchFocused).onAppear { searchFocused = focusSearchOnAppear; focusSearchOnAppear = false }
            }.padding(12).background(DaybookStyle.field, in: RoundedRectangle(cornerRadius: 14)).padding(.bottom, 20)
            if !search.isEmpty && filter != .recap {
                Text(activeSemantic?.status ?? (semanticSearch.isSearching ? "正在本机检索；已显示文字匹配" : "按日期与关键词检索"))
                    .font(.caption).foregroundStyle(DaybookStyle.secondary).padding(.bottom, 12)
            }
            filters
            if filter == .recap { recapLibrary }
            else {
                if content.loading { ProgressView("正在读取完整日期资料") }
                recordList(shownRecords, home: false)
                sessionMaintenance
                if !originalRecordings.isEmpty {
                    DisclosureGroup("原始录音（\(originalRecordings.count)）") {
                        recordList(originalRecordings,home:false)
                    }.font(.system(size:12)).padding(.top,24)
                }
            }
        }
    }
    private var originalRecordings: [DayRecord] {
        guard allowedKinds.contains(.voice), filter == .all || filter == .audio else { return [] }
        let legacy = model.notes.map(DaybookPlaces.voice)
        let streamed = RecordingSessionPresentation.records(sessions.allKnownSessions,legacyIDs:Set(model.notes.map(\.id)))
        return (legacy+streamed).filter { $0.kind == .voice }.compactMap { $0.recordingProjection(on:selectedDate) }
            .sorted { $0.capturedAt > $1.capturedAt }
    }
    private var sessionMaintenance: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(sessions.sessions.filter { $0.startedAt == nil }) { session in
                Button { openRecord(session.id) } label: {
                    VStack(alignment: .leading) { Text("录音时间待同步"); Text(LocalizedStringKey(RecordingSessionPresentation.status(session))).font(.caption) }
                }
            }
            ForEach(content.library.filter { segment in !content.records.contains { $0.id == segment.id } }) { segment in
                Button { openRecord(segment.id) } label: { Label(segment.title.isEmpty ? "录音片段" : segment.title,systemImage:"waveform") }
            }
            if let error = content.errorMessage { Text(LocalizedStringKey(error)).foregroundStyle(.orange); Button("重试") { content.refresh() } }
            if content.hasMore { Button("载入更早的片段") { content.loadMore() }.disabled(content.refreshing) }
            if sessions.hasMore { Button("载入更早的录音") { sessions.loadMore() }.disabled(sessions.loading) }
            if !sessions.cleanupIDs.isEmpty {
                Text("文件清理待重试").foregroundStyle(.orange)
                Button("重试清理") { sessions.refresh(recover: true) }
            }
        }.padding(.top, 12)
    }
    private var recapLibraryEntries: [DaybookRecapEntry] {
        let calendar = Calendar.current
        let dates = records.map(\.capturedAt) + content.calendarDates + sessions.calendarDates
        var entries = Dictionary(uniqueKeysWithValues: recaps.entries.map { ($0.dayKey, $0) })
        for date in Set(dates.map { calendar.startOfDay(for: $0) }) where date <= clockNow {
            let key = DaybookRecapInput.key(date)
            if entries[key] == nil {
                entries[key] = DaybookRecapEntry(input: DaybookRecapInput.prepare(records: [], day: date, allowedKinds: []))
            }
        }
        return entries.values.filter { $0.matches(search) }.sorted { $0.dayKey > $1.dayKey }
    }
    private var recapLibrary: some View {
        VStack(alignment: .leading, spacing: 14) {
            if recaps.isLoading { ProgressView("正在读取每日回顾…") }
            if let error = recaps.storageError {
                Text(error).font(.caption).foregroundStyle(DaybookStyle.red)
                Button("重试读取回顾") { recaps.reload() }
            } else {
                Text("按日期查看每日回顾 · \(recapLibraryEntries.count) 天").font(.system(size: 11)).foregroundStyle(DaybookStyle.secondary)
                if recapLibraryEntries.isEmpty && !recaps.isLoading {
                    DaybookEmptyView(title: "没有找到每日回顾", text: "试试其他日期或关键词。", icon: "BookOpen")
                }
                ForEach(recapLibraryEntries) { entry in
                    if entry.text != nil {
                        DaybookRecapCard(entry: entry, stale: recaps.isStale(entry), onOpen: { present(.recap(entry.scope.start)) })
                    } else {
                        Button { present(.recap(entry.scope.start)) } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 6) {
                                    Text("\(DaybookFormat.day(entry.scope.start)) · 回顾").font(.system(size: 14, weight: .medium))
                                    Text("点开整理这一天的记录").font(.system(size: 11)).foregroundStyle(DaybookStyle.secondary)
                                }
                                Spacer(); DaybookIcon("ChevronRight", size: 14)
                            }.padding(18).background(DaybookStyle.field, in: RoundedRectangle(cornerRadius: 18))
                        }.buttonStyle(.plain)
                    }
                }
            }
        }
    }
    private var filters: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 7) {
                ForEach(DaybookFilter.allCases.filter { $0 != .recap || page == .library }, id: \.self) { item in
                    Button { filter = item } label: {
                        Text(LocalizedStringKey(item.rawValue)).font(.system(size: 10)).padding(.horizontal, 12).padding(.vertical, 7)
                            .foregroundStyle(filter == item ? DaybookStyle.paper : DaybookStyle.secondary)
                            .background(filter == item ? DaybookStyle.ink : DaybookStyle.field, in: Capsule())
                    }.accessibilityAddTraits(filter == item ? .isSelected : [])
                }
            }
        }.scrollIndicators(.hidden).padding(.bottom, 19)
    }
    @ViewBuilder private func recordList(_ values: [DayRecord], home: Bool) -> some View {
        if let error = life.errorMessage { Text(error).font(.caption).foregroundStyle(.orange).padding(.bottom, 12) }
        if values.isEmpty {
            DaybookEmptyView(title: home ? "这里留了一点空白" : search.isEmpty ? "还没有这样的片段" : "没有找到这段记录",
                text: home ? "可以换个筛选，或用右下角的“记此刻”留下今天。" : search.isEmpty ? "下一次记录，会出现在这里。" : "试试更短的关键词，或切换记录类型。", icon: home ? "BookOpen" : "Search")
        } else {
            ForEach(values) { record in recordListRow(record, orderedRecords: mergeListRecords) }
        }
    }
    @ViewBuilder private func recordListRow(_ record: DayRecord, orderedRecords: [DayRecord]) -> some View {
        if record.parentRecordID != nil {
            Button { openRecord(record.id) } label: { DaybookRecordRow(record: record) }
        } else {
            let selected = selectedMergeIDs.contains(record.id)
            let mergeEligible = mergeEligibleIDs.contains(record.id)
            DaybookSwipeRow(id: record.id, revealedID: $revealedRecordID, onDelete: { deleteRecord = record },
                onSelect: mergeEligible ? { toggleMergeSelection(record, in: orderedRecords) } : nil,
                isSelected: selected) {
                Button {
                    if revealedRecordID == record.id { revealedRecordID = nil }
                    else if !selectedMergeIDs.isEmpty && mergeEligible { toggleMergeSelection(record, in: orderedRecords) }
                    else { openRecord(record.id) }
                } label: {
                    DaybookRecordRow(record: record, thumbnails: thumbnails(record), photoCount: photoCount(record), status: recordStatus(record),
                        showsMergeSelection: !selectedMergeIDs.isEmpty && mergeEligible, isMergeSelected: selected)
                }
            }.contextMenu {
                Button("打开") { openRecord(record.id) }
                Button("删除", role: .destructive) { deleteRecord = record }
            }.accessibilityAction(named: "删除记录") { deleteRecord = record }
        }
    }
    private var mergeSelectionBar: some View {
        VStack(spacing: 8) {
            if let mergeSelectionMessage {
                Text(LocalizedStringKey(mergeSelectionMessage)).font(.system(size: 10)).foregroundStyle(DaybookStyle.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 5) {
                        Text("已选择").font(.system(size: 12, weight: .semibold))
                        Text("\(selectedMergeIDs.count)").font(.system(size: 12, weight: .semibold)).monospacedDigit()
                    }
                    Text("相邻长录音").font(.system(size: 10)).foregroundStyle(DaybookStyle.secondary)
                }
                Spacer(minLength: 0)
                Button("取消选择") { selectedMergeIDs = []; mergeSelectionMessage = nil }
                    .font(.system(size: 11, weight: .medium)).foregroundStyle(DaybookStyle.secondary)
                    .disabled(isMergingRecordings)
                Button { showMergeConfirmation = true } label: {
                    HStack(spacing: 5) {
                        if isMergingRecordings { ProgressView().controlSize(.mini).tint(DaybookStyle.paper) }
                        else { DaybookIcon("AudioLines", size: 14) }
                        Text(isMergingRecordings ? "正在合并录音…" : "合并所选").font(.system(size: 11, weight: .medium))
                    }.foregroundStyle(DaybookStyle.paper).padding(.horizontal, 13).padding(.vertical, 10)
                        .background(DaybookStyle.ink, in: Capsule())
                }.disabled(!canMergeSelection || isMergingRecordings)
                    .opacity(canMergeSelection && !isMergingRecordings ? 1 : 0.45)
            }
        }.padding(.horizontal, 23).padding(.vertical, 11)
            .background(DaybookStyle.white).overlay(alignment: .top) { DaybookStyle.line.frame(height: 1) }
    }

    private func toggleMergeSelection(_ record: DayRecord, in orderedRecords: [DayRecord]) {
        let orderedIDs = orderedRecords.map(\.id)
        let eligibleIDs = Set<UUID>(orderedRecords.compactMap { candidate -> UUID? in
            guard candidate.kind == .voice, candidate.recordingSessionID == nil, candidate.parentRecordID == nil,
                  model.canMergeLongRecording(candidate.id) else { return nil }
            return candidate.id
        })
        guard RecordingMergeSelection.canAdd(record.id, to: selectedMergeIDs, orderedIDs: orderedIDs, eligibleIDs: eligibleIDs) else {
            mergeSelectionMessage = "只能选择相邻长录音。"
            return
        }
        if selectedMergeIDs.contains(record.id) { selectedMergeIDs.remove(record.id) }
        else { selectedMergeIDs.insert(record.id) }
        mergeSelectionMessage = nil
    }

    private func mergeSelectedRecordings() {
        guard let orderedIDs = RecordingMergeSelection.orderedSelection(selectedMergeIDs,
            orderedIDs: mergeListRecords.map(\.id), eligibleIDs: mergeEligibleIDs) else {
            mergeSelectionMessage = "请选择至少两条相邻长录音。"
            return
        }
        isMergingRecordings = true
        Task {
            let mergedID = await model.mergeLongRecordings(orderedIDs)
            isMergingRecordings = false
            guard let mergedID else { return }
            selectedMergeIDs = []
            mergeSelectionMessage = nil
            if let merged = model.note(mergedID) {
                showToday()
                selectedDate = merged.capturedAt
            }
            openRecord(mergedID)
        }
    }
    private var insightsPage: some View {
        VStack(alignment: .leading, spacing: 0) {
            pageHeading("从记录中发现", title: "更懂自己一点。", subtitle: "\(DaybookFormat.day(selectedDate)) · 把线索变成一个小行动。")
            dailyInsightCard
            HStack {
                Text("明天的打算").font(.system(size: 17, weight: .semibold))
                Spacer(); Text("从今天出发").font(.system(size: 10)).foregroundStyle(DaybookStyle.secondary)
            }.padding(.top, 30).padding(.bottom, 16)
            let nextDay = Calendar.current.date(byAdding: .day, value: 1, to: clockNow) ?? clockNow
            let plans = reminders.items.filter { $0.status == .scheduled && Calendar.current.isDate($0.scheduledAt, inSameDayAs: nextDay) }
            if plans.isEmpty { DaybookQuietInfo(icon: "Sun", text: "不必排满明天。采纳一条建议，就从一件小事开始。") }
            else {
                ForEach(plans) { item in
                    HStack(alignment: .top, spacing: 12) {
                        DaybookIcon("CheckCheck", size: 19).foregroundStyle(DaybookStyle.accent)
                        VStack(alignment: .leading, spacing: 5) {
                            Text(item.title).font(.system(size: 13, weight: .semibold))
                            Text("\(DaybookFormat.day(item.scheduledAt)) · \(DaybookFormat.time(item.scheduledAt))").font(.system(size: 10)).foregroundStyle(DaybookStyle.secondary)
                        }
                        Spacer()
                        Button("撤销") { Task { await reminders.cancel(item.id) } }.font(.system(size: 10)).foregroundStyle(DaybookStyle.secondary).disabled(reminders.isBusy)
                    }.padding(.vertical, 15).overlay(alignment: .bottom) { DaybookStyle.line.frame(height: 1) }
                }
            }
            DaybookQuietInfo(text: "洞察来自你选择的记录。你可以查看依据，也可以告诉我们哪里不符合。")
        }
    }
    private var dailyInsightCard: some View {
        DaybookInsightView(model: dailyInsight, records: records, selectedDate: selectedDate,
            allowedKinds: allowedKinds, language: settings.interfaceLanguage.rawValue,
            onOpenRecord: openRecord, onReminder: { title, id in proposeReminder(title, id: id, tomorrow: true) })
    }
    private func nudge(_ record: DayRecord) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                HStack(spacing: 6) { DaybookIcon("MessageCircle", size: 13); Text("AI 回顾线索 · \(DaybookFormat.time(record.capturedAt))") }
                    .font(.system(size: 10)).foregroundStyle(DaybookStyle.accent)
                Spacer()
                Menu {
                    Button("下一条线索") { suggestions.advance(records: records, preferences: preferences) }
                    Button("1 小时后再看") { suggestions.snooze(until: .now.addingTimeInterval(3600)) }
                    Button("今天收起") { suggestions.dismissToday() }
                } label: { Text("•••").font(.system(size: 10)).foregroundStyle(DaybookStyle.secondary).padding(5) }.accessibilityLabel("管理这条主动建议")
            }.padding(.bottom, 10)
            Text("给记录下来的事，留一点时间。").font(.system(size: 16, weight: .semibold)).lineSpacing(6).padding(.bottom, 8)
            Text(String(record.text.prefix(110))).font(.system(size: 11)).lineSpacing(6).foregroundStyle(DaybookStyle.secondary).lineLimit(3).padding(.bottom, 10)
            HStack(spacing: 9) {
                Button { proposeReminder(record.title, id: record.id) } label: { Text("提醒我").font(.system(size: 10)).padding(.horizontal, 12).padding(.vertical, 9).background(DaybookStyle.white, in: RoundedRectangle(cornerRadius: 12)) }
                Button("和 AI 聊聊") { ask("回顾这一天") }.font(.system(size: 10))
                Button("查看依据") { openRecord(record.id) }.font(.system(size: 10))
            }.foregroundStyle(DaybookStyle.accent)
        }.padding(17).background(DaybookStyle.nudge, in: RoundedRectangle(cornerRadius: 19))
            .overlay(RoundedRectangle(cornerRadius: 19).stroke(DaybookStyle.line, lineWidth: 1)).padding(.bottom, 18)
    }
    private var aiHomeLink: some View {
        Button { ask("") } label: {
            HStack(spacing: 10) {
                DaybookIcon("MessageCircle", size: 18)
                VStack(alignment: .leading, spacing: 5) {
                    Text("问问 AI，理一理今天").font(.system(size: 12))
                    Text("从自己的记录里，找到一点线索。").font(.system(size: 10)).foregroundStyle(DaybookStyle.secondary)
                }.frame(maxWidth: .infinity, alignment: .leading)
                DaybookIcon("ArrowUpRight", size: 18)
            }.foregroundStyle(DaybookStyle.accent).padding(.vertical, 15)
                .overlay(alignment: .top) { DaybookStyle.line.frame(height: 1) }.overlay(alignment: .bottom) { DaybookStyle.line.frame(height: 1) }
        }
    }
    private var dataPage: some View {
        VStack(alignment: .leading, spacing: 0) {
            pageHeading("按自己的方式记录", title: "设置", subtitle: "选择模型、数据来源和 AI 提醒的节奏。")
            HStack {
                HStack(spacing: 9) { DaybookIcon("Sun", size: 17); Text("外观").font(.system(size: 11)) }
                Spacer()
                Picker("外观", selection: $settings.appearance) {
                    ForEach(AppAppearance.allCases, id: \.self) { appearance in Text(LocalizedStringKey(appearance.title)).tag(appearance) }
                }.labelsHidden().font(.system(size: 11))
            }.padding(.vertical, 16).overlay(alignment: .bottom) { DaybookStyle.line.frame(height: 1) }
            HStack {
                HStack(spacing: 9) { DaybookIcon("MessageCircle", size: 17); Text("界面语言").font(.system(size: 11)) }
                Spacer()
                Picker("界面语言", selection: $settings.interfaceLanguage) {
                    ForEach(AppLanguage.allCases) { language in Text(language.title).tag(language) }
                }.labelsHidden().font(.system(size: 11))
            }.padding(.vertical, 16).padding(.bottom, 20).overlay(alignment: .bottom) { DaybookStyle.line.frame(height: 1) }
            HStack { Text("语音与 AI").font(.system(size: 17, weight: .semibold)); Spacer(); Text("优先在本机处理").font(.system(size: 10)).foregroundStyle(DaybookStyle.secondary) }.padding(.bottom, 16)
            VStack(spacing: 0) {
                Button { present(.quickRecording) } label: { DaybookOptionRow(icon: "Mic", title: "快捷录音", subtitle: "操作按钮、实时活动与自动保存") }
                Button { present(.transcription) } label: { DaybookOptionRow(icon: "AudioLines", title: "语音转写模型", subtitle: settings.transcriptionLabel) }
                MyVoiceSettingsEntry(profile: model.voiceProfile, open: { present(.myVoice) })
                Button { present(.aiSettings) } label: { DaybookOptionRow(icon: "MessageCircle", title: "AI 模型", subtitle: settings.ai.label) }
                Button { present(.preferences) } label: { DaybookOptionRow(icon: "Bell", title: "AI 偏好与提醒", subtitle: "主动建议、免打扰和数据范围") }
            }.overlay(alignment: .top) { DaybookStyle.line.frame(height: 1) }
            Text("硬件").font(.system(size: 17, weight: .semibold)).padding(.top, 24).padding(.bottom, 16)
            hardwareRows
            Text("数据来源").font(.system(size: 17, weight: .semibold)).padding(.top, 24).padding(.bottom, 16)
            HStack(alignment: .top, spacing: 13) {
                DaybookIcon("ShieldCheck", size: 23).foregroundStyle(DaybookStyle.accent)
                VStack(alignment: .leading, spacing: 6) {
                    Text("从本机开始").font(.system(size: 13, weight: .semibold))
                    Text("录音、图片与转写保存在此 iPhone。由你决定 AI 可以使用哪些记录。")
                        .font(.system(size: 10)).lineSpacing(6).foregroundStyle(DaybookStyle.secondary)
                }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(18).background(DaybookStyle.blueSoft, in: RoundedRectangle(cornerRadius: 18)).padding(.bottom, 14)
            sourceRow("Apple 健康", subtitle: "活动、步数与睡眠", icon: "Heart", status: life.status(.health, day: selectedDate)) { present(.source("Apple 健康")) }
            sourceRow("日历", subtitle: "为记录补充日程背景", icon: "CalendarDays", status: life.status(.calendar, day: selectedDate)) { present(.source("日历")) }
            sourceRow("地点", subtitle: "为片段留下一点位置线索", icon: "MapPin", status: life.status(.location, day: selectedDate)) { present(.source("地点")) }
            Text("已有记录保存在本机。录音始终由你主动开始；未授权健康数据时，首页显示闪念条数与图片张数。")
                .font(.system(size: 10)).lineSpacing(6).foregroundStyle(DaybookStyle.secondary).padding(.top, 18).padding(.bottom, 27)
            Button { showImporter = true } label: { plainRow("导入音频文件", icon: "AudioLines") }
        }
    }
    private func sourceRow(_ title: String, subtitle: String, icon: String, status: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Group {
                    if icon == "Ring" { Circle().stroke(lineWidth: 1.6).frame(width: 21, height: 21).padding(1) }
                    else { DaybookIcon(icon, size: 23) }
                }.foregroundStyle(DaybookStyle.secondary).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 5) {
                    Text(LocalizedStringKey(title)).font(.system(size: 13, weight: .semibold))
                    Text(LocalizedStringKey(subtitle)).font(.system(size: 10)).foregroundStyle(DaybookStyle.secondary)
                }.frame(maxWidth: .infinity, alignment: .leading)
                Text(LocalizedStringKey(status)).font(.system(size: 10)).foregroundStyle(DaybookStyle.secondary)
                DaybookIcon("ChevronRight", size: 13).foregroundStyle(DaybookStyle.secondary)
            }.padding(.vertical, 22).overlay(alignment: .bottom) { DaybookStyle.line.frame(height: 1) }
        }
    }
    private func plainRow(_ title: String, icon: String) -> some View {
        HStack(spacing: 9) { DaybookIcon(icon, size: 17); Text(LocalizedStringKey(title)).font(.system(size: 11)); Spacer(); DaybookIcon("ChevronRight", size: 17) }
            .padding(.vertical, 16).overlay(alignment: .bottom) { DaybookStyle.line.frame(height: 1) }
    }
    private func pageHeading(_ eyebrow: String, title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(LocalizedStringKey(eyebrow)).font(.system(size: 11, weight: .medium)).tracking(0.4).foregroundStyle(DaybookStyle.secondary)
            Text(LocalizedStringKey(title)).font(.system(size: 29, weight: .semibold)).tracking(-1).padding(.top, 12).padding(.bottom, 10)
            Text(LocalizedStringKey(subtitle)).font(.system(size: 11)).lineSpacing(6).foregroundStyle(DaybookStyle.secondary)
        }.padding(.top, 8).padding(.bottom, 27)
    }
    private var bottomBar: some View {
        HStack(spacing: 4) {
            navItem(.day, title: "一天", icon: "Sun")
            Spacer(minLength: 0)
            navItem(.ai, title: "AI", icon: "MessageCircle")
            Spacer(minLength: 0)
            navItem(.actions, title: "行动", icon: "CheckCheck")
            Spacer(minLength: 0)
            Button {
                if recording.phase != .idle || recorder.requestingPermission { recorderMenu = true }
                else { present(.capture) }
            } label: {
                HStack(spacing: 5) { DaybookIcon("Plus", size: 17); Text("记此刻").font(.system(size: 11, weight: .medium)) }
                    .padding(.vertical, 12).padding(.horizontal, 15).foregroundStyle(DaybookStyle.paper)
                    .background(DaybookStyle.ink, in: Capsule())
            }.padding(.leading, 12).accessibilityLabel("记录此刻")
        }.padding(.horizontal, 23).padding(.top, 12).padding(.bottom, 10)
            .background(DaybookStyle.paper).overlay(alignment: .top) { DaybookStyle.line.frame(height: 1) }
    }
    private func navItem(_ item: DaybookPage, title: String, icon: String) -> some View {
        let selected = page == item || (page == .library && item == .day)
        return Button { page = item; if item == .ai { initialQuestion = "" } } label: {
            VStack(spacing: 4) { DaybookIcon(icon, size: 22); Text(LocalizedStringKey(title)).font(.system(size: 10)) }
                .frame(minWidth: 49).padding(.horizontal, 6).foregroundStyle(selected ? DaybookStyle.accent : DaybookStyle.secondary)
        }.accessibilityAddTraits(selected ? .isSelected : [])
    }
    private var recordingBanner: some View {
        HStack(spacing: 8) {
            Circle().fill(DaybookStyle.red).frame(width: 6, height: 6)
            Text(LocalizedStringKey(recordingStatus)).font(.system(size: 10))
            Text(RecordingFormat.duration(recorder.isRecording ? recorder.duration : recording.pendingDraft?.duration ?? recorder.duration)).font(.system(size: 12, weight: .semibold)).monospacedDigit()
            Spacer(minLength: 0)
            Button(recorder.isRecording ? "结束并保存" : "重试保存") { recordingAction(recorder.isRecording ? .stop : .retry) }
                .font(.system(size: 10)).underline().disabled(recording.phase == .starting || recording.phase == .saving || recorder.requestingPermission)
        }.padding(.horizontal, 23).padding(.vertical, 11).foregroundStyle(DaybookStyle.red)
            .background(DaybookStyle.red.opacity(0.08)).overlay(alignment: .top) { DaybookStyle.red.opacity(0.15).frame(height: 1) }
    }
    @ViewBuilder private func sheetContent(_ value: DaybookSheet) -> some View {
        switch value {
        case .recap(let date):
            DaybookRecapDetailView(model: recaps, date: date, onOpen: { id in
                recapSource = recaps.record(id); citation = recapSource?.contentProvenance; present(.record(id))
            }, onClose: { sheet = nil })
        case .capture: DaybookCaptureMenu(voice: { sheet = nil; recordingAction(.start) }, image: { present(.photo) })
        case .places: DaybookPlacesView(records: dayRecords.filter { $0.kind == .location && $0.location != nil }, date: selectedDate, onOpen: openRecord, onClose: { sheet = nil })
        case .photo: PhotoCaptureView(library: photos, onSaved: { date in showToday(); selectedDate = date })
        case .date: DaybookCalendarView(selectedDate: $selectedDate, recordDates: records.filter { $0.recordingSessionID == nil }.map(\.capturedAt) + sessions.calendarDates + content.calendarDates, onMonthChange: { date in sessions.selectMonth(date); content.selectMonth(date) })
        case .lifeMoment(let id, let day, let pendingSleep):
            if let record = LifeMomentBuilder.detail(id: id, pendingSleepOn: pendingSleep ? day : nil, records: records, calendar: .current) {
                LifeMomentDetailView(record: record, model: life, onOpen: openRecord, onClose: { sheet = nil })
            } else {
                DaybookSheetLayout(title: "生活片段", onClose: { sheet = nil }) {
                    DaybookQuietInfo(text: "这条生活片段已更新或移除，请返回时间轴查看。")
                }
            }
        case .actionOrigin(let source):
            if source.recordingKind == "segment" {
                ContentSegmentDetailView(segmentID:source.id,playbackAllowed:!recorder.isRecording && !recorder.requestingPermission)
            } else if source.recordingKind == "session" {
                RecordingSessionDetailView(sessionID:source.id,playbackAllowed:!recorder.isRecording && !recorder.requestingPermission)
            } else if model.note(source.id) != nil || photos.moments.contains(where:{$0.id == source.id}) || records.contains(where:{$0.id == source.id}) {
                actionRecordDetail(source.id)
            } else {
                VStack(alignment:.leading,spacing:16) { Text("原记录暂不可用或已删除").font(.headline); Text(source.quote); Text("行动与已保存的原话仍保留在本机。").font(.caption) }.padding()
            }
        case .actionProposal:
            ActionProposalView(sources:actionSources,store:actions,settings:settings,isCurrent:{
                let current = assistant.recordsForEvidence(records)
                return actionSources.allSatisfy { source in
                    current.contains { $0.id == source.id && $0.capturedAt == source.capturedAt && allowedKinds.contains($0.kind) && $0.text.contains(source.quote) }
                }
            },onFinished:{ sheet = nil; page = .actions })
        case .record(let id):
            actionRecordDetail(id).safeAreaInset(edge:.bottom) {
                if let record = assistant.recordsForEvidence(records).first(where:{$0.id == id && $0.kind.isAudio}), !record.text.isEmpty {
                    Button("转为行动") {
                        actionSources = [ActionSource(id:record.id,title:record.title,quote:String(record.text.prefix(1800)),capturedAt:record.capturedAt,timeZoneID:TimeZone.current.identifier,recordingKind:record.contentProvenance != nil ? "segment" : record.recordingSessionID != nil ? "session" : "legacy",offset:record.contentProvenance?.ranges.first?.sourceOffset)]
                        present(.actionProposal)
                    }.buttonStyle(.borderedProminent).padding().frame(maxWidth:.infinity).background(DaybookStyle.paper)
                }
            }
        case .watch: watchSheet
        case .hardware:
#if WISELIFE_EUREKA_RING
            DaybookHardwareView(watch: model.watchStatus, openWatch: { present(.watch) }, openRing: { present(.ring) }, onClose: { sheet = nil })
#else
            DaybookHardwareView(watch: model.watchStatus, openWatch: { present(.watch) }, onClose: { sheet = nil })
#endif
#if WISELIFE_EUREKA_RING
        case .ring: EurekaRingDetailView(onBack: { present(.hardware) }, onClose: { sheet = nil }, phoneIsRecording: recorder.isRecording || recorder.requestingPermission)
#endif
        case .transcription: TranscriptionSettingsView(settings: settings)
        case .myVoice: MyVoiceEnrollmentView(profile: model.voiceProfile, recordingBlocked: recording.phase != .idle || recorder.requestingPermission)
        case .quickRecording: QuickRecordingSettingsView()
        case .aiSettings: AISettingsView(settings: settings)
        case .preferences: DaybookPreferencesView(preferences: preferences, reminders: reminders, onOpenRecord: openRecord, sourceTitle: sourceTitle)
        case .reminders: DaybookReminderListView(store: reminders, onOpenRecord: openRecord, sourceTitle: sourceTitle)
        case .reminder(let draft): DaybookReminderEditor(store: reminders, proposedTitle: draft.title, sourceID: draft.sourceID,
            initialDate: draft.initialDate, sourceTitle: draft.sourceID.flatMap(sourceTitle))
        case .source(let name):
            LifeSourceSheet(model: life, source: LifeSource.allCases.first { $0.title == name } ?? .health, day: selectedDate, onClose: { sheet = nil })
        }
    }
    private func sheetDetents(_ value: DaybookSheet) -> Set<PresentationDetent> {
        switch value { case .capture: [.height(350)]; case .date: [.height(460)]; case .source: [.fraction(0.87)]; default: [.fraction(0.87)] }
    }
    private var watchHardwareStatus: String {
        model.watchStatus.title
    }
    private var hardwareRows: some View {
        VStack(spacing: 0) {
            sourceRow("Apple Watch", subtitle: "语音与闪念", icon: "Watch", status: watchHardwareStatus) {
                model.refreshWatchStatus(); present(.watch)
            }
#if WISELIFE_EUREKA_RING
            sourceRow("EurekaRing", subtitle: "录音与蓝牙同步", icon: "Ring", status: ring.connectionLabel) { present(.ring) }
#endif
        }
    }
    private var allHardwareButton: some View {
        Button { model.refreshWatchStatus(); present(.hardware) } label: {
            HStack(spacing: 4) { DaybookIcon("ChevronLeft", size: 14); Text("全部硬件") }
                .font(.system(size: 11)).foregroundStyle(DaybookStyle.secondary).padding(.vertical, 8)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private func watchFact(_ title: String, value: String) -> some View {
        HStack { Text(LocalizedStringKey(title)); Spacer(); Text(LocalizedStringKey(value)) }.padding(.vertical, 14)
    }
    private var watchSheet: some View {
        DaybookSheetLayout(title: "Apple Watch", onClose: { sheet = nil }) {
            VStack(spacing: 0) {
                allHardwareButton
                DaybookIcon("Watch", size: 36).foregroundStyle(DaybookStyle.accent).frame(width: 70, height: 70).background(DaybookStyle.blueSoft, in: RoundedRectangle(cornerRadius: 22)).padding(.top, 8).padding(.bottom, 18)
                Text(LocalizedStringKey(model.watchStatus.title)).font(.system(size: 20, weight: .semibold)).padding(.bottom, 10)
                Text(LocalizedStringKey(model.watchStatus.message)).font(.system(size: 12)).lineSpacing(6).multilineTextAlignment(.center).foregroundStyle(DaybookStyle.secondary)
                VStack(spacing: 0) {
                    watchFact("配对状态", value: !model.watchStatus.isSupported ? "不可用" : !model.watchStatus.isActivated ? "检查中" : model.watchStatus.isPaired ? "已配对" : "未配对")
                    DaybookStyle.line.frame(height: 1)
                    watchFact("手表 App", value: !model.watchStatus.isSupported ? "不可用" : !model.watchStatus.isActivated ? "检查中" : model.watchStatus.isInstalled ? "已安装" : "未安装")
                    DaybookStyle.line.frame(height: 1)
                    watchFact("待同步录音", value: model.watchStatus.pendingLabel)
                    DaybookStyle.line.frame(height: 1)
                    watchFact("最近同步", value: model.watchStatus.lastSyncLabel)
                    DaybookStyle.line.frame(height: 1)
                    HStack { Text("采集方式"); Spacer(); Text("轻点录音 · 按住闪念") }.padding(.vertical, 14)
                }.font(.system(size: 11)).padding(.horizontal, 16).padding(.vertical, 4).background(DaybookStyle.white, in: RoundedRectangle(cornerRadius: 17)).overlay(RoundedRectangle(cornerRadius: 17).stroke(DaybookStyle.line)).padding(.vertical, 22)
                watchSyncActions
                Text("Apple Watch 的配对与取消配对请在 iPhone 的 Watch App 中管理。")
                    .font(.system(size: 11)).lineSpacing(6).foregroundStyle(DaybookStyle.secondary).padding(.top, 16)
            }
        }.task { model.refreshWatchStatus() }
    }
    private var watchSyncActions: some View {
        VStack(alignment: .leading, spacing: 12) {
            if model.watchStatus.hasPairedWatch, model.watchStatus.isInstalled {
                ForEach(model.watchStatus.issueMessages, id: \.self) { issue in
                    Label(issue, systemImage: "exclamationmark.triangle")
                        .font(.system(size: 12)).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                }
                if let error = model.watchRetryError {
                    Text(error).font(.system(size: 12)).foregroundStyle(.orange)
                }
                if model.watchStatus.retryPending {
                    Text("重试请求已提交，等待手表处理。后台传输时间由系统安排。")
                        .font(.system(size: 12)).foregroundStyle(DaybookStyle.secondary)
                }
                Button("重试同步") { model.retryWatchSync() }
                    .buttonStyle(DaybookPrimaryButtonStyle(wide: true))
                    .disabled(!model.watchStatus.canRetrySync)
                if !model.watchStatus.isActivated {
                    Text("同步服务正在准备，请稍后刷新状态。")
                        .font(.system(size: 11)).foregroundStyle(DaybookStyle.secondary)
                }
            }
            Button("刷新同步状态") { model.refreshWatchStatus() }
                .font(.system(size: 12, weight: .medium)).frame(maxWidth: .infinity).padding(.vertical, 10)
        }
    }
    private func present(_ destination: DaybookSheet) {
        if sheet != nil { nextSheet = destination; sheet = nil } else { sheet = destination }
    }
    private func openRecord(_ id: UUID) {
        citation = nil
        recapSource = nil
        if let record = records.first(where: { $0.id == id && $0.lifeMoment != nil }) {
            present(.lifeMoment(id, record.capturedAt, record.lifeMoment?.sleep != nil && record.lifeMoment?.sleep?.endedAt == nil))
        } else { present(.record(id)) }
    }
    private func proposeReminder(_ title: String, id: UUID?, tomorrow: Bool = false) {
        let initialDate = tomorrow ? Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: Calendar.current.date(byAdding: .day, value: 1, to: .now) ?? .now) : nil
        present(.reminder(DaybookReminderDraft(title: title, sourceID: id, initialDate: initialDate)))
    }
    private func sourceTitle(_ id: UUID) -> String? { records.first { $0.id == id }?.title }
    private func thumbnails(_ record: DayRecord) -> [URL] { photos.moments.first { $0.id == record.id }?.photos.compactMap { photos.imageURL(for: $0) } ?? [] }
    private func photoCount(_ record: DayRecord) -> Int { photos.moments.first { $0.id == record.id }?.photos.count ?? 0 }
    private func recordStatus(_ record: DayRecord) -> String {
        if record.contentProvenance != nil { return record.recordingContinuation == true ? "续段 · 录音片段" : "录音片段" }
        if let id = record.recordingSessionID, let session = sessions.session(id) { return RecordingSessionPresentation.status(session) }
        if record.kind.isLife { return life.isStale(record) ? "本机快照 · 可能已过期" : "本机快照 · 点开查看来源" }
        guard let note = model.note(record.id) else { return "点开查看图片" }
        switch note.transcriptionState { case .pending: return "等待转写 · 原始录音已保存"; case .running: return "正在端上转写"; case .ready: return "点开回听录音"; case .unavailable, .failed: return "转写未完成 · 点开可重试" }
    }
    private func synchronizeAddresses() {
        recordingAddresses.synchronize(sessionIDs: sessions.daySessions.map(\.id), day: selectedDate,
            localeIdentifier: settings.interfaceLanguage.locale.identifier,
            enabled: life.isEnabled(.location), foreground: scenePhase == .active)
        let audio = model.notes.compactMap { note -> CaptureAddressRequest? in
            note.location.map { .init(owner: .voice(note.id), date: note.capturedAt, point: $0) }
        }
        let images = photos.moments.flatMap { moment in
            moment.photos.compactMap { photo -> CaptureAddressRequest? in
                photo.capture?.location.map { .init(owner: .photo(photo.id), date: photo.capture?.capturedAt ?? moment.capturedAt, point: $0) }
            }
        }
        let requests = audio + images
        let evidence = LocationMovementBuilder.records(points: DaybookPlaces.records(notes: model.notes, photos: photos.moments))
            .filter { Calendar.current.isDate($0.capturedAt, inSameDayAs: selectedDate) && !life.isSuppressed($0.id) }
            .compactMap(\.lifeMoment?.movement).flatMap { [$0.from, $0.to] }
        let owners = Set(requests.filter { request in
            evidence.contains { $0.point.matchesCapture(request.point) && $0.capturedAt == request.date }
        }.map(\.owner))
        addresses.synchronize(requests: requests, day: selectedDate,
            localeIdentifier: settings.interfaceLanguage.locale.identifier,
            enabled: life.isEnabled(.location), foreground: scenePhase == .active, additionalOwners: owners) { request, address in
                switch request.owner {
                case .voice(let id): model.setAddress(address, noteID: id, matching: request.point)
                case .photo(let id): photos.setAddress(address, photoID: id, matching: request.point)
                }
            }
    }
    private func synchronizeSuggestions(now: Date = .now) {
        updateCalendar(now: now)
        synchronizeInsights(now: now)
        // Proactive Insight suggestions are deferred; explicit reminders remain available.
    }
    private func showToday() { selectedDate = .now; page = .day; search = ""; filter = .all }
    private func updateCalendar(now: Date) {
        let calendar = Calendar.current
        selectedDate = LifeMomentBuilder.selectedDate(after: now, previousNow: clockNow, selected: selectedDate, calendar: calendar)
        clockNow = now
        life.refreshForCalendarChange(now: now, day: selectedDate)
    }
    private func synchronizeInsights(now: Date = .now) {
        synchronizeRecaps()
        dailyInsight.cancel() // Insight generation is deferred; daily recaps stay enabled.
    }
    private func synchronizeRecaps() {
        recaps.synchronize(day: recapDay, records: records, revisions: [content.revision, sessions.revision] + sourceStorageAvailability.map { $0 ? 1 : 0 },
            settings: settings, allowedKinds: allowedKinds, foreground: scenePhase == .active,
            capturing: recording.phase != .idle || recorder.requestingPermission)
    }
    private func loadRecapRecords(_ scope: DateInterval) async throws -> [DayRecord] {
        let kinds = allowedKinds
        let needsAudio = kinds.contains(.voice) || kinds.contains(.thought)
        let needsLocation = kinds.contains(.location)
        guard (!(needsAudio || needsLocation) || model.storageIsAvailable),
              (!(kinds.contains(.image) || needsLocation) || photos.storageIsAvailable),
              (!kinds.contains(where: \.isLife) || life.storageIsAvailable) else { throw DaybookRecapFailure.storage }
        let revision = [content.revision, sessions.revision]
        let derived: [DayRecord]
        do { derived = needsAudio ? try await content.load(scope: scope) : [] }
        catch ContentSegmentError.staleRevision { throw DaybookRecapFailure.changed }
        let parents = needsAudio ? try await sessions.records(in: scope, legacyIDs: Set(model.notes.map(\.id))) : []
        guard revision == [content.revision, sessions.revision], kinds == allowedKinds else { throw DaybookRecapFailure.changed }
        guard (!(needsAudio || needsLocation) || model.storageIsAvailable),
              (!(kinds.contains(.image) || needsLocation) || photos.storageIsAvailable),
              (!kinds.contains(where: \.isLife) || life.storageIsAvailable) else { throw DaybookRecapFailure.storage }
        let audio = ContentSegmentPresentation.evidenceRecords(legacyParents: model.notes.map(DaybookPlaces.voice), sessionParents: parents, derived: derived, scope: scope)
        let places = DaybookPlaces.records(notes: model.notes, photos: photos.moments)
        let movements = LocationMovementBuilder.records(points: places).filter { !life.isSuppressed($0.id) }
        // Use the day's actual health snapshot. Timeline placeholders and yesterday's step archive
        // are UI entries, not additional factual evidence for this day.
        let other = photos.moments.map(DaybookPlaces.photo) + life.records + places + movements
        return (audio + other.compactMap { $0.recordingProjection(from: scope.start, to: scope.end) })
            .filter { kinds.contains($0.kind) }
    }
    private func synchronizeSemantic(resume: Bool = false) {
        semanticSearch.synchronize(query: search, records: records, date: selectedDate, allowedKinds: allowedKinds, active: page == .library && filter != .recap && scenePhase == .active && !content.loading, resume: resume)
    }
    @ViewBuilder private func actionRecordDetail(_ id: UUID) -> some View {
            if content.contains(id) {
                ContentSegmentDetailView(segmentID:id,playbackAllowed:!recorder.isRecording && !recorder.requestingPermission,citation:citation)
            } else if sessions.session(id) != nil || (recapSource?.id == id && recapSource?.recordingSessionID != nil) {
                RecordingSessionDetailView(sessionID: id, playbackAllowed: !recorder.isRecording && !recorder.requestingPermission)
            } else if model.note(id) != nil {
                DaybookVoiceDetailView(id: id, playbackAllowed: !recorder.isRecording && !recorder.requestingPermission)
            } else if let record = records.first(where: { $0.id == id && $0.lifeMoment != nil }) {
                LifeMomentDetailView(record: record, model: life, onOpen: openRecord, onClose: { sheet = nil })
            } else if let record = records.first(where: { $0.id == id && $0.kind == .location && $0.parentRecordID != nil }) {
                DaybookPlaceDetailView(record: record, onOpenParent: openRecord, onClose: { sheet = nil })
            } else if let record = life.records.first(where: { $0.id == id }) {
                LifeRecordDetailView(record: record, model: life, onClose: { sheet = nil })
            } else if let record = recapSource, record.id == id, record.lifeMoment != nil {
                LifeMomentDetailView(record: record, model: life, onOpen: openRecord, onClose: { sheet = nil })
            } else if let record = recapSource, record.id == id, record.kind == .location {
                DaybookPlaceDetailView(record: record, onOpenParent: openRecord, onClose: { sheet = nil })
            } else {
                PhotoDetailView(momentID: id, library: photos, onAskAI: {
                    if let moment = photos.moments.first(where: { $0.id == id }) { selectedDate = moment.capturedAt }
                    sheet = nil; ask("这一天的图片记录了什么？")
                })
            }
    }
    private func synchronizeAssistant(resumeSemantic: Bool = false) {
        synchronizeSemantic(resume: resumeSemantic)
        synchronizeInsights()
        assistant.synchronize(records: records, selectedDate: selectedDate, allowedKinds: allowedKinds, configuration: settings.ai, configurationRevision: settings.aiRevision)
    }
    private func ask(_ question: String) { initialQuestion = question; assistantID = UUID(); page = .ai }
    private var recordingStatus: String {
        if recorder.requestingPermission { return "等待麦克风授权" }
        switch recording.phase {
        case .starting: return "正在开始录音"
        case .recording: return "录音中"
        case .saving: return "正在保存录音"
        case .failed: return "录音待保存"
        case .idle: return "录音已保存"
        }
    }
    private func recordingAction(_ command: WiseLifeRuntime.Command) {
        Task {
            do {
                await WiseLifeRuntime.shared.prepare()
                if command == .start, recording.phase == .idle {
                    guard await AVAudioApplication.requestRecordPermission() else {
                        recorder.errorMessage = "请在系统设置中允许 WiseLife 使用麦克风，然后重试。"
                        return
                    }
                }
                try await WiseLifeRuntime.shared.perform(command, requireLiveActivity: false)
            }
            catch { recorder.errorMessage = error.localizedDescription }
        }
    }
    private func clearErrors() { sessions.errorMessage = nil; model.errorMessage = nil; photos.errorMessage = nil; recorder.errorMessage = nil; recording.clearError(); reminders.errorMessage = nil; life.errorMessage = nil }
}
