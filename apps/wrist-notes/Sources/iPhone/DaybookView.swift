import SwiftUI
import UniformTypeIdentifiers

// Retained for older library/settings routes.
enum DaybookRoute: Hashable { case record(UUID), preferences, reminders }
private enum DaybookPage: String { case day, ai, insights, library, data }
private struct DaybookReminderDraft: Hashable {
    let title: String
    let sourceID: UUID?
    let initialDate: Date?
}
private enum DaybookSheet: Hashable, Identifiable {
    case capture, photo, date, watch, hardware, ring, transcription, aiSettings, preferences, reminders
    case record(UUID), evidence(UUID), reminder(DaybookReminderDraft), source(String)
    var id: Self { self }
}
private enum DaybookFilter: String, CaseIterable {
    case all = "全部", audio = "语音", image = "图片", thought = "闪念"
    func includes(_ record: DayRecord) -> Bool {
        switch self { case .all: true; case .audio: record.kind != .image; case .image: record.kind == .image; case .thought: record.kind == .thought }
    }
}

struct DaybookView: View {
    @EnvironmentObject private var model: NotesModel
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var ring: EurekaRingModel
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var photos = PhotoLibraryModel()
    @StateObject private var recorder = PhoneRecorder()
    @StateObject private var preferences = DaybookPreferences()
    @StateObject private var reminders = DaybookReminderStore()
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
    @State private var recorderMenu = false
    @State private var initialQuestion = ""
    @State private var assistantID = UUID()
    @State private var dismissedInsights: Set<UUID> = []

    private var records: [DayRecord] {
        let audio = model.notes.map { DayRecord(id: $0.id, capturedAt: $0.capturedAt,
            kind: $0.kind == .thought ? .thought : .voice, title: $0.title,
            text: $0.transcript, summary: $0.summary, duration: $0.duration) }
        let images = photos.moments.map { DayRecord(id: $0.id, capturedAt: $0.capturedAt, kind: .image, title: $0.title, text: $0.searchableText) }
        return (audio + images).sorted { $0.capturedAt > $1.capturedAt }
    }
    private var dayRecords: [DayRecord] { records.filter { Calendar.current.isDate($0.capturedAt, inSameDayAs: selectedDate) } }
    private var dayPhotoCount: Int { photos.moments.filter { Calendar.current.isDate($0.capturedAt, inSameDayAs: selectedDate) }.reduce(0) { $0 + $1.photos.count } }
    private var shownRecords: [DayRecord] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return dayRecords.filter { record in filter.includes(record) && (query.isEmpty ||
            [record.title, record.text, record.summary].contains { $0.localizedCaseInsensitiveContains(query) }) }
    }
    private var allowedKinds: Set<DayRecord.Kind> {
        var result: Set<DayRecord.Kind> = []
        if preferences.allowAudio { result.formUnion([.voice, .thought]) }; if preferences.allowPhotos { result.insert(.image) }; return result
    }
    private var insights: [DayRecord] {
        dayRecords.filter { allowedKinds.contains($0.kind) && !$0.summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !dismissedInsights.contains($0.id) }
    }
    private var suggestionPreferences: [Int] {
        [preferences.proactiveEnabled ? 1 : 0, preferences.allowAudio ? 1 : 0, preferences.allowPhotos ? 1 : 0,
         preferences.quietEnabled ? 1 : 0, preferences.quietStartMinutes, preferences.quietEndMinutes, preferences.dailySuggestionLimit]
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                header
                if page == .ai {
                    DaybookAssistantView(records: records, selectedDate: selectedDate, settings: settings,
                        allowedKinds: allowedKinds, initialQuestion: initialQuestion, onOpenRecord: openRecord,
                        onReminder: { title, id in proposeReminder(title, id: id) },
                        onPreferences: { present(.preferences) }, onReminders: { present(.reminders) },
                        onDate: { present(.date) }, reminderCount: reminders.items.filter { $0.status == .scheduled }.count,
                        onNewReminder: { title in proposeReminder(title, id: nil, tomorrow: true) })
                        .id(assistantID)
                } else {
                    ScrollViewReader { proxy in
                        ScrollView {
                            VStack(alignment: .leading, spacing: 0) {
                                Color.clear.frame(height: 0).id("pageTop")
                                switch page {
                                case .day: dayPage
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
                if recorder.isRecording || recorder.requestingPermission || recorder.draft != nil { recordingBanner }
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
                    Button("删除记录和原文件", role: .destructive) {
                        if let record = deleteRecord {
                            if record.kind == .image { photos.delete(record.id) } else { model.delete(record.id) }
                            deleteRecord = nil
                        }
                    }
                }
                .confirmationDialog("语音记录", isPresented: $recorderMenu, titleVisibility: .visible) {
                    if recorder.isRecording { Button("结束并保存") { recorder.stop() } }
                    else if recorder.draft != nil { Button("重试保存") { saveDraft() } }
                    Button("放弃录音", role: .destructive) { recorder.discard() }
                }
                .alert("提示", isPresented: Binding(get: { sheet == nil && (model.errorMessage != nil || photos.errorMessage != nil || recorder.errorMessage != nil || reminders.errorMessage != nil) }, set: { if !$0 { clearErrors() } })) {
                    Button("好") { clearErrors() }
                } message: { Text(model.errorMessage ?? photos.errorMessage ?? recorder.errorMessage ?? reminders.errorMessage ?? "") }
        }.buttonStyle(.plain).tint(DaybookStyle.accent).preferredColorScheme(settings.appearance.colorScheme)
            .environment(\.locale, settings.interfaceLanguage.locale)
            .task { model.refreshWatchStatus(); synchronizeSuggestions(); await reminders.refreshAuthorization() }
            .onChange(of: records) { _, _ in synchronizeSuggestions() }
            .onChange(of: suggestionPreferences) { _, _ in synchronizeSuggestions() }
            .onChange(of: selectedDate) { _, _ in filter = .all; search = ""; synchronizeSuggestions() }
            .onChange(of: page) { _, value in if value == .day { search = "" }; synchronizeSuggestions() }
            .onChange(of: sheet) { _, _ in synchronizeSuggestions() }
            .onChange(of: recorder.draft?.id) { _, id in if id != nil { saveDraft() } }
            .onReceive(Timer.publish(every: 60, on: .main, in: .common).autoconnect()) { now in
                guard scenePhase == .active else { return }; clockNow = now; synchronizeSuggestions(now: now)
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { model.refreshWatchStatus(); synchronizeSuggestions(); Task { await reminders.refreshAuthorization(); await ring.foreground() } }
            }
    }

    private var header: some View {
        HStack {
            Button { model.refreshWatchStatus(); present(.hardware) } label: {
                HStack(spacing: 7) {
                    Circle().fill(model.watchStatus.isConnected || ring.isConnected ? DaybookStyle.green : DaybookStyle.secondary).frame(width: 5, height: 5)
                    DaybookIcon(ring.isConnected ? "Ring" : "Watch", size: 21)
                    Text(ring.isRecording ? "Ring 录音中" : connectedHardwareCount == 0 ? "连接硬件" : "\(connectedHardwareCount) 台已连接").font(.system(size: 11, weight: .medium))
                }.padding(.leading, 10).padding(.trailing, 12).frame(height: 40)
                    .background(DaybookStyle.white, in: Capsule()).overlay(Capsule().stroke(DaybookStyle.line, lineWidth: 1))
            }.accessibilityLabel("查看录音硬件连接状态")
            Spacer()
            HStack(spacing: 4) {
                Button { focusSearchOnAppear = true; page = .library; searchFocused = true } label: { DaybookIcon("Search", size: 21).frame(width: 40, height: 40) }.accessibilityLabel("搜索记录")
                Button { page = .data } label: { DaybookIcon("Settings2", size: 21).frame(width: 40, height: 40) }.accessibilityLabel("数据与设置")
            }.padding(.horizontal, 3).background(DaybookStyle.white, in: Capsule()).overlay(Capsule().stroke(DaybookStyle.line, lineWidth: 1))
        }.padding(.horizontal, 23).padding(.top, 8).padding(.bottom, 10)
    }
    private var connectedHardwareCount: Int { (model.watchStatus.isConnected ? 1 : 0) + (ring.isConnected ? 1 : 0) }
    private var dayPage: some View {
        VStack(alignment: .leading, spacing: 0) {
            DaybookDateHeading(date: selectedDate, hasRecords: !dayRecords.isEmpty, onDate: { present(.date) }).padding(.bottom, 20)
            DaybookOverview(records: dayRecords, photoCount: dayPhotoCount, date: selectedDate, now: clockNow, onOpenRecord: openRecord).padding(.bottom, 18)
            if let insight = insights.first { insightCard(insight, home: true) }
            else { DaybookQuietInfo(icon: "Lightbulb", text: dayRecords.isEmpty ? "这一天还没有记录。说句话，或拍张照片。" : "多留下一些片段，线索会慢慢清晰。") }
            if Calendar.current.isDate(selectedDate, inSameDayAs: clockNow),
               let candidate = suggestions.visibleCandidate(records: records, preferences: preferences, now: clockNow) { nudge(candidate) }
            else { aiHomeLink }
            HStack {
                Text(Calendar.current.isDateInToday(selectedDate) ? "今天的片段" : "\(DaybookFormat.day(selectedDate))的片段").font(.system(size: 17, weight: .semibold)).tracking(-0.3)
                Spacer()
                Button { page = .library } label: { HStack(spacing: 3) { Text("查看全部"); DaybookIcon("ArrowUpRight", size: 13) }.font(.system(size: 10)).foregroundStyle(DaybookStyle.secondary) }
            }.padding(.top, 24).padding(.bottom, 16)
            filters
            recordList(Array(shownRecords.prefix(4)), home: true)
            HStack(spacing: 6) {
                DaybookIcon("ShieldCheck", size: 13)
                Text("由你选择记录什么，也由你决定何时暂停。").font(.system(size: 9))
            }.foregroundStyle(DaybookStyle.secondary).padding(.top, 30)
        }
    }
    private var libraryPage: some View {
        VStack(alignment: .leading, spacing: 0) {
            pageHeading("留住那些片刻", title: "我的记录", subtitle: "\(DaybookFormat.day(selectedDate)) · \(dayRecords.count) 条记录")
            HStack(spacing: 9) {
                DaybookIcon("Search", size: 17).foregroundStyle(DaybookStyle.secondary)
                TextField("搜索想法、片段或关键词", text: $search).font(.system(size: 12))
                    .textInputAutocapitalization(.never).autocorrectionDisabled().accessibilityLabel("搜索想法、片段或关键词")
                    .focused($searchFocused).onAppear { searchFocused = focusSearchOnAppear; focusSearchOnAppear = false }
            }.padding(12).background(DaybookStyle.field, in: RoundedRectangle(cornerRadius: 14)).padding(.bottom, 20)
            filters
            recordList(shownRecords, home: false)
        }
    }
    private var filters: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 7) {
                ForEach(DaybookFilter.allCases, id: \.self) { item in
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
        if values.isEmpty {
            DaybookEmptyView(title: home ? "这里留了一点空白" : search.isEmpty ? "还没有这样的片段" : "没有找到这段记录",
                text: home ? "可以换个筛选，或用右下角的“记此刻”留下今天。" : search.isEmpty ? "下一次记录，会出现在这里。" : "试试更短的关键词，或切换记录类型。", icon: home ? "BookOpen" : "Search")
        } else {
            ForEach(values) { record in
                DaybookSwipeRow(id: record.id, revealedID: $revealedRecordID, onDelete: { deleteRecord = record }) {
                    Button {
                        if revealedRecordID == record.id { revealedRecordID = nil }
                        else { openRecord(record.id) }
                    } label: {
                        DaybookRecordRow(record: record, thumbnails: thumbnails(record), photoCount: photoCount(record), status: recordStatus(record))
                    }
                }.contextMenu {
                    Button("打开") { openRecord(record.id) }
                    Button("删除", role: .destructive) { deleteRecord = record }
                }.accessibilityAction(named: "删除记录") { deleteRecord = record }
            }
        }
    }
    private var insightsPage: some View {
        VStack(alignment: .leading, spacing: 0) {
            pageHeading("从记录中发现", title: "更懂自己一点。", subtitle: "\(DaybookFormat.day(selectedDate)) · 把线索变成一个小行动。")
            if insights.isEmpty { DaybookEmptyView(title: "先记录，再发现", text: "当一天的记录足够丰富，这里会展示有出处的线索和建议。", icon: "Lightbulb") }
            else { ForEach(insights.prefix(5)) { insightCard($0, home: false) } }
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
    private func insightCard(_ record: DayRecord, home: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 7) { DaybookIcon("Lightbulb", size: 14); Text("今日洞察 · 从你的记录出发") }
                .font(.system(size: 10, weight: .medium)).foregroundStyle(DaybookStyle.accent).padding(.bottom, 11)
            Text(record.title).font(.system(size: 22, weight: .semibold)).tracking(-0.5).lineSpacing(6).padding(.bottom, 10)
            Text(String(record.summary.prefix(180))).font(.system(size: 12)).lineSpacing(6).foregroundStyle(DaybookStyle.secondary).lineLimit(4).padding(.bottom, 14)
            HStack(spacing: 10) {
                Button { present(.evidence(record.id)) } label: {
                    HStack(spacing: 6) { DaybookIcon("Link2", size: 13); Text("1 条记录支持"); DaybookIcon("ChevronRight", size: 13) }
                        .font(.system(size: 10)).foregroundStyle(DaybookStyle.accent).padding(.vertical, 7)
                }
                Spacer(minLength: 0)
                Button { proposeReminder("回顾：\(record.title)", id: record.id, tomorrow: true) } label: {
                    HStack(spacing: 6) { DaybookIcon("ArrowUpRight", size: 13); Text(home ? "给明天一步" : "看看建议") }
                }.buttonStyle(DaybookPrimaryButtonStyle())
            }
        }.padding(.horizontal, 20).padding(.top, 20).padding(.bottom, 17)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(LinearGradient(colors: [DaybookStyle.blueSoft, DaybookStyle.paleBlue], startPoint: .leading, endPoint: .trailing), in: RoundedRectangle(cornerRadius: 23))
            .overlay(RoundedRectangle(cornerRadius: 23).stroke(DaybookStyle.line, lineWidth: 1)).padding(.bottom, 20)
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
                Button { present(.transcription) } label: { DaybookOptionRow(icon: "AudioLines", title: "语音转写模型", subtitle: settings.transcriptionLabel) }
                Button { present(.aiSettings) } label: { DaybookOptionRow(icon: "MessageCircle", title: "AI 模型", subtitle: settings.ai.label) }
                Button { present(.preferences) } label: { DaybookOptionRow(icon: "Bell", title: "AI 偏好与提醒", subtitle: "主动建议、免打扰和数据范围") }
            }.overlay(alignment: .top) { DaybookStyle.line.frame(height: 1) }
            Text("数据来源").font(.system(size: 17, weight: .semibold)).padding(.top, 24).padding(.bottom, 16)
            HStack(alignment: .top, spacing: 13) {
                DaybookIcon("ShieldCheck", size: 23).foregroundStyle(DaybookStyle.accent)
                VStack(alignment: .leading, spacing: 6) {
                    Text("从本机开始").font(.system(size: 13, weight: .semibold))
                    Text("录音、图片与转写保存在此 iPhone。由你决定 AI 可以使用哪些记录。")
                        .font(.system(size: 10)).lineSpacing(6).foregroundStyle(DaybookStyle.secondary)
                }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(18).background(DaybookStyle.blueSoft, in: RoundedRectangle(cornerRadius: 18)).padding(.bottom, 14)
            sourceRow("Apple Watch", subtitle: "语音与闪念", icon: "Watch", status: model.watchStatus.isConnected ? "已连接" : "未连接") { present(.watch) }
            sourceRow("EurekaRing", subtitle: "录音与蓝牙同步", icon: "Ring", status: ring.connectionLabel) { present(.ring) }
            sourceRow("Apple 健康", subtitle: "活动、步数与睡眠", icon: "Heart", status: "未接入") { present(.source("Apple 健康")) }
            sourceRow("日历", subtitle: "为记录补充日程背景", icon: "CalendarDays", status: "未接入") { present(.source("日历")) }
            sourceRow("地点", subtitle: "为片段留下一点位置线索", icon: "MapPin", status: "未接入") { present(.source("地点")) }
            Text("已有记录保存在本机。录音始终由你主动开始；未授权健康数据时，首页显示闪念条数与图片张数。")
                .font(.system(size: 10)).lineSpacing(6).foregroundStyle(DaybookStyle.secondary).padding(.top, 18).padding(.bottom, 27)
            Button { showImporter = true } label: { plainRow("导入音频文件", icon: "AudioLines") }
        }
    }
    private func sourceRow(_ title: String, subtitle: String, icon: String, status: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                DaybookIcon(icon, size: 23).foregroundStyle(DaybookStyle.secondary)
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
            navItem(.insights, title: "洞察", icon: "Lightbulb")
            Spacer(minLength: 0)
            Button {
                if recorder.isRecording || recorder.requestingPermission || recorder.draft != nil { recorderMenu = true }
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
            Text(recorder.requestingPermission ? "等待麦克风授权" : recorder.isRecording ? "录音中" : "录音待保存").font(.system(size: 10))
            Text(RecordingFormat.duration(recorder.duration)).font(.system(size: 12, weight: .semibold)).monospacedDigit()
            Spacer(minLength: 0)
            Button(recorder.isRecording ? "结束并保存" : "重试保存") { if recorder.isRecording { recorder.stop() } else { saveDraft() } }
                .font(.system(size: 10)).underline().disabled(recorder.requestingPermission)
        }.padding(.horizontal, 23).padding(.vertical, 11).foregroundStyle(DaybookStyle.red)
            .background(DaybookStyle.red.opacity(0.08)).overlay(alignment: .top) { DaybookStyle.red.opacity(0.15).frame(height: 1) }
    }
    @ViewBuilder private func sheetContent(_ value: DaybookSheet) -> some View {
        switch value {
        case .capture: DaybookCaptureMenu(voice: { sheet = nil; Task { await recorder.start() } }, image: { present(.photo) })
        case .photo: PhotoCaptureView(library: photos, onSaved: showToday)
        case .date: DaybookCalendarView(selectedDate: $selectedDate, recordDates: records.map(\.capturedAt))
        case .record(let id):
            if model.note(id) != nil {
                DaybookVoiceDetailView(id: id, playbackAllowed: !recorder.isRecording && !recorder.requestingPermission)
            } else {
                PhotoDetailView(momentID: id, library: photos, onAskAI: {
                    if let moment = photos.moments.first(where: { $0.id == id }) { selectedDate = moment.capturedAt }
                    sheet = nil; ask("这一天的图片记录了什么？")
                })
            }
        case .evidence(let id): evidenceSheet(id)
        case .watch: watchSheet
        case .hardware: DaybookHardwareView(watch: model.watchStatus, openWatch: { present(.watch) }, openRing: { present(.ring) }, onClose: { sheet = nil })
        case .ring: EurekaRingDetailView(onBack: { present(.hardware) }, onClose: { sheet = nil }, phoneIsRecording: recorder.isRecording || recorder.requestingPermission)
        case .transcription: TranscriptionSettingsView(settings: settings)
        case .aiSettings: AISettingsView(settings: settings)
        case .preferences: DaybookPreferencesView(preferences: preferences, reminders: reminders, onOpenRecord: openRecord, sourceTitle: sourceTitle)
        case .reminders: DaybookReminderListView(store: reminders, onOpenRecord: openRecord, sourceTitle: sourceTitle)
        case .reminder(let draft): DaybookReminderEditor(store: reminders, proposedTitle: draft.title, sourceID: draft.sourceID,
            initialDate: draft.initialDate, sourceTitle: draft.sourceID.flatMap(sourceTitle))
        case .source(let name):
            DaybookSheetLayout(title: name, onClose: { sheet = nil }) {
                DaybookQuietInfo(icon: name == "Apple 健康" ? "Heart" : "CircleHelp",
                    text: "\(name)尚未接入。当前不会读取这类数据；已有语音和图片记录可以继续使用。")
            }
        }
    }
    private func sheetDetents(_ value: DaybookSheet) -> Set<PresentationDetent> {
        switch value { case .capture: [.height(350)]; case .date: [.height(460)]; case .source: [.height(280)]; default: [.fraction(0.87)] }
    }
    private func evidenceSheet(_ id: UUID) -> some View {
        DaybookSheetLayout(title: "这条洞察从哪里来", onClose: { sheet = nil }) {
            if let record = records.first(where: { $0.id == id }), allowedKinds.contains(record.kind) {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 7) { DaybookIcon("Lightbulb", size: 14); Text("\(DaybookFormat.day(record.capturedAt)) · 今日线索") }.font(.system(size: 10)).foregroundStyle(DaybookStyle.accent)
                    Text(record.title).font(.system(size: 24, weight: .semibold)).lineSpacing(8).padding(.top, 10).padding(.bottom, 14)
                    Text(record.summary).font(.system(size: 12)).lineSpacing(7).foregroundStyle(DaybookStyle.secondary)
                    Text("回到原始记录").font(.system(size: 12, weight: .semibold)).padding(.top, 24).padding(.bottom, 12)
                    Button { openRecord(record.id) } label: {
                        VStack(alignment: .leading, spacing: 9) {
                            HStack(spacing: 5) { DaybookIcon(record.kind.prototypeIcon, size: 12); Text("\(DaybookFormat.time(record.capturedAt)) · \(record.kind.title)"); DaybookIcon("ArrowUpRight", size: 12) }.font(.system(size: 10)).foregroundStyle(DaybookStyle.accent)
                            Text(record.text).font(.system(size: 13)).lineSpacing(7).lineLimit(8)
                        }.padding(.leading, 14).overlay(alignment: .leading) { DaybookStyle.accent.opacity(0.5).frame(width: 2) }
                    }.padding(.vertical, 20)
                    DaybookQuietInfo(text: "总结来自这条记录，请结合原文判断。建议需由你确认后才会安排提醒。")
                    HStack(spacing: 10) {
                        Button("不太符合") { dismissedInsights.insert(record.id); sheet = nil }.buttonStyle(DaybookSecondaryButtonStyle())
                        Button("看看行动建议") { proposeReminder("回顾：\(record.title)", id: record.id, tomorrow: true) }.buttonStyle(DaybookPrimaryButtonStyle(wide: true))
                    }
                }
            } else { DaybookQuietInfo(text: "原记录不存在，或已不允许 AI 使用。") }
        }
    }
    private var watchSheet: some View {
        DaybookSheetLayout(title: "Apple Watch", onClose: { sheet = nil }) {
            VStack(spacing: 0) {
                DaybookIcon("Watch", size: 36).foregroundStyle(DaybookStyle.accent).frame(width: 70, height: 70).background(DaybookStyle.blueSoft, in: RoundedRectangle(cornerRadius: 22)).padding(.top, 8).padding(.bottom, 18)
                Text(model.watchStatus.title).font(.system(size: 20, weight: .semibold)).padding(.bottom, 10)
                Text(model.watchStatus.message).font(.system(size: 12)).lineSpacing(6).multilineTextAlignment(.center).foregroundStyle(DaybookStyle.secondary)
                VStack(spacing: 0) {
                    HStack { Text("连接状态"); Spacer(); Text(model.watchStatus.isConnected ? "已连接" : "未连接") }.padding(.vertical, 14)
                    DaybookStyle.line.frame(height: 1)
                    HStack { Text("采集方式"); Spacer(); Text("轻点录音 · 按住闪念") }.padding(.vertical, 14)
                }.font(.system(size: 11)).padding(.horizontal, 16).padding(.vertical, 4).background(DaybookStyle.white, in: RoundedRectangle(cornerRadius: 17)).overlay(RoundedRectangle(cornerRadius: 17).stroke(DaybookStyle.line)).padding(.vertical, 22)
                Button("刷新连接状态") { model.refreshWatchStatus() }.buttonStyle(DaybookPrimaryButtonStyle(wide: true))
            }
        }
    }
    private func present(_ destination: DaybookSheet) {
        if sheet != nil { nextSheet = destination; sheet = nil } else { sheet = destination }
    }
    private func openRecord(_ id: UUID) { present(.record(id)) }
    private func proposeReminder(_ title: String, id: UUID?, tomorrow: Bool = false) {
        let initialDate = tomorrow ? Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: Calendar.current.date(byAdding: .day, value: 1, to: .now) ?? .now) : nil
        present(.reminder(DaybookReminderDraft(title: title, sourceID: id, initialDate: initialDate)))
    }
    private func sourceTitle(_ id: UUID) -> String? { records.first { $0.id == id }?.title }
    private func thumbnails(_ record: DayRecord) -> [URL] { photos.moments.first { $0.id == record.id }?.photos.compactMap { photos.imageURL(for: $0) } ?? [] }
    private func photoCount(_ record: DayRecord) -> Int { photos.moments.first { $0.id == record.id }?.photos.count ?? 0 }
    private func recordStatus(_ record: DayRecord) -> String {
        guard let note = model.note(record.id) else { return "点开查看图片" }
        switch note.transcriptionState { case .pending: return "等待转写 · 原始录音已保存"; case .running: return "正在端上转写"; case .ready: return "点开回听录音"; case .unavailable, .failed: return "转写未完成 · 点开可重试" }
    }
    private func synchronizeSuggestions(now: Date = .now) {
        clockNow = now
        guard page == .day, sheet == nil, scenePhase == .active, Calendar.current.isDate(selectedDate, inSameDayAs: now) else { return }
        suggestions.synchronize(records: records, preferences: preferences, now: now)
    }
    private func showToday() { selectedDate = .now; page = .day; search = ""; filter = .all }
    private func ask(_ question: String) { initialQuestion = question; assistantID = UUID(); page = .ai }
    private func saveDraft() {
        guard let draft = recorder.draft else { return }
        if model.savePhoneRecording(id: draft.id, fileURL: draft.fileURL, capturedAt: draft.capturedAt, duration: draft.duration) {
            let warning = recorder.errorMessage
            recorder.didSave()
            if warning != nil { recorder.errorMessage = "录音已保存。录制曾被中断，请回听检查内容是否完整。" }
            showToday(); selectedDate = draft.capturedAt
        }
    }
    private func clearErrors() { model.errorMessage = nil; photos.errorMessage = nil; recorder.errorMessage = nil; reminders.errorMessage = nil }
}
