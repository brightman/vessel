import SwiftUI

/// The normal runtime stays alive behind this gate (Watch receipt, recording recovery, Face ID).
struct OnboardingRootView: View {
    @ObservedObject var store: OnboardingStore
    @ObservedObject var settings: AppSettings
    var body: some View {
        Group {
            if store.progress.shouldPresent {
                OnboardingView(store: store, settings: settings)
            } else { DaybookView() }
        }
        .preferredColorScheme(settings.appearance.colorScheme)
        .environment(\.locale, settings.interfaceLanguage.locale)
    }
}

struct OnboardingView: View {
    @ObservedObject var store: OnboardingStore
    @ObservedObject var settings: AppSettings
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var transcription: TranscriptionSettingsModel
    @StateObject private var ai: AISettingsModel
    @StateObject private var keyboard = AppKeyboardCoordinator()
    @State private var page: OnboardingProgress.Page
    @State private var appleReason = AISettingsView.appleUnavailableReason()
    @State private var retrievalReady = false
    @State private var retrievalPrepareRequest = 0
    @State private var confirmingSkip = false
    @State private var errorMessage: String?

    init(store: OnboardingStore, settings: AppSettings) {
        self.store = store; self.settings = settings
        let editor = TranscriptionSettingsModel(settings: settings, resources: .live())
        if store.progress.disposition != .completed,
           let draft = store.transcriptionDraft { editor.configuration = draft }
        _transcription = StateObject(wrappedValue: editor)
        let aiEditor = AISettingsModel(settings: settings, requiresFreshTest: true)
        if store.progress.disposition != .completed, let draft = store.aiDraft { aiEditor.configuration = draft }
        _ai = StateObject(wrappedValue: aiEditor)
        _page = State(initialValue: store.progress.page)
    }

    private var understandingReady: Bool {
        ai.configuration.mode == .local ? appleReason == nil : ai.configuration.mode == .custom ? ai.state == .success : false
    }
    private var aiReady: Bool { OnboardingReadiness.aiStep(understanding: understandingReady, retrieval: retrievalReady) }
    private var completeCount: Int { (transcription.canSave ? 1 : 0) + (aiReady ? 1 : 0) + (store.progress.dataReviewed ? 1 : 0) + (store.progress.usageReviewed ? 1 : 0) }
    private var privacy: String {
        ai.configuration.mode == .local ? "你的数据和 AI 能力，都在你的设备上。使用端上模型时，个人记录无需上传到 WiseLife 服务器。" : "转写、检索与记录保存在本机；AI 理解使用你选择的服务，仅发送你允许的文字。数据授权不等于云端发送授权。"
    }
    private let steps: [OnboardingProgress.Page] = [.transcription, .ai, .data, .usage]

    var body: some View {
        VStack(spacing: 0) {
            header
            if page != .welcome && page != .review { stepBar }
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        Color.clear.frame(height: 0).id("top")
                        pageContent
                    }.padding(.horizontal, 25).padding(.bottom, 28)
                }.scrollIndicators(.hidden).scrollDismissesKeyboard(.interactively)
                    .onChange(of: page) { _, _ in proxy.scrollTo("top", anchor: .top) }
            }
            if !keyboard.isVisible { footer }
        }
        .foregroundStyle(DaybookStyle.ink).background(DaybookStyle.paper.ignoresSafeArea())
        .tint(DaybookStyle.accent).buttonStyle(.plain)
        .background(AppKeyboardAttachment(keyboard: keyboard).frame(width: 0, height: 0))
        .task { refreshLocalReadiness(); await transcription.refresh() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                refreshLocalReadiness()
                if !transcription.isDownloading { transcription.scheduleRefresh() }
            } else if phase == .background { ai.invalidateTest(); keyboard.dismiss() }
        }
        .onChange(of: transcription.configuration) { _, value in
            store.transcriptionDraft = value
            if transcription.canSave { saveTranscription() }
        }
        .onChange(of: transcription.state) { _, state in if state == .ready { saveTranscription() } }
        .onChange(of: ai.state) { _, state in if state == .success { saveAI() } }
        .onChange(of: ai.configuration) { _, configuration in store.aiDraft = configuration }
        .onReceive(NotificationCenter.default.publisher(for: .daybookSemanticChanged)) { _ in refreshLocalReadiness() }
        .onDisappear { transcription.cancel(); ai.invalidateTest() }
        .alert(transcription.canSave && aiReady ? "先开始记录" : "AI 还没准备完整", isPresented: $confirmingSkip) {
            Button("继续设置", role: .cancel) {}
            Button("先使用基础记录") { finish(skipped: true) }
        } message: { Text(missingExplanation + "\n已完成的设置会保留。之后可在设置的「语言与 AI」中调整模型，在「数据来源」中管理授权。") }
        .alert("准备提示", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("好") { errorMessage = nil }
        } message: { Text(errorMessage ?? "") }
    }

    private var header: some View {
        HStack {
            Button { go(.welcome) } label: {
                Image(systemName: "chevron.left").frame(width: 44, height: 44)
            }.opacity(page == .welcome ? 0 : 1)
                .disabled(page == .welcome).accessibilityLabel("准备清单")
            Spacer()
            Text("AI 与数据准备").font(.system(size: 14, weight: .medium))
            Spacer()
            Button("稍后") {
                confirmingSkip = true
            }.font(.system(size: 12)).frame(width: 44, height: 44)
        }.padding(.horizontal, 16)
    }

    private var stepBar: some View {
        HStack(spacing: 8) {
            ForEach(Array(steps.enumerated()), id: \.element) { index, step in
                Button { go(step) } label: {
                    VStack(alignment: .leading, spacing: 9) {
                        Rectangle().fill(page == step ? DaybookStyle.accent : DaybookStyle.line).frame(height: 2)
                        Text("\(index + 1) \(title(step))").font(.system(size: 10)).lineLimit(1)
                    }.frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                }.foregroundStyle(page == step ? DaybookStyle.accent : DaybookStyle.secondary)
            }
        }.padding(.horizontal, 25)
    }

    @ViewBuilder private var pageContent: some View {
        switch page {
        case .welcome:
            heading("你好，欢迎来到 WiseLife", "懂你的AI，更懂保护你的隐私", "四步开始：准备 AI、选择数据，再学会留下第一条记录。")
            checklist
            SettingsInfo(title: ai.configuration.mode == .local ? "默认全端上" : "你选择的 AI 服务", text: privacy)
        case .transcription:
            heading("01 / 语音转写", "让声音，成为记录。", "选择一个适合你的端上语音模型。")
            purpose("录音自动转成文字，让 AI 更好地理解。原始录音可以设置保留 7 天／14 天。", privacy: "转写在 iPhone 上进行，下载模型需要联网。")
            TranscriptionSettingsView(settings: settings, editor: transcription, embedded: true)
        case .ai:
            heading("02 / AI 能力", "理解你，也找得到。", "理解与检索一起准备，让回答有据可依。")
            purpose("把记录整理成重点、回顾与建议，再从你的记录中找到回答的依据。", privacy: privacy)
            readinessRow("AI 理解", ready: understandingReady, detail: aiDetail)
            AISettingsView(settings: settings, editor: ai, embedded: true)
            readinessRow("AI 检索", ready: retrievalReady, detail: "Apple 上下文向量 · 本机处理")
            DaybookSemanticSettingsView(onboarding: true, prepareRequest: retrievalPrepareRequest, onReadinessChange: { retrievalReady = $0 })
        case .data:
            heading("03 / 数据授权", "你决定，AI 了解什么。", "每一项都可选，也可以暂时一项都不开启。")
            purpose("结合你允许的生活线索，给出更贴近实际的回顾与建议。", privacy: "授权数据在本机读取、保存；不会因此获得云端发送权限。")
            OnboardingDataView()
        case .usage:
            heading("04 / 使用说明", "记录，从这里开始。", "没有手表，一部 iPhone 就能录音和拍照。")
            OnboardingUsageView()
        case .review:
            Image(systemName: completeCount == 4 ? "checkmark.circle" : "clock").font(.system(size: 38, weight: .light)).foregroundStyle(DaybookStyle.accent)
            heading("准备结果 · \(completeCount) / 4 步完成", completeCount == 4 ? "准备好了。\n从你的第一条记录开始。" : "记录可以先开始。\nAI 还需要一点准备。", "未准备完整的模型会影响智能整理与问答。基础录音和图片记录仍可使用。")
            checklist
            if !transcription.canSave || !aiReady { SettingsInfo(title: "基础记录仍可使用", text: missingExplanation) }
            SettingsFootnote(text: privacy)
        }
    }

    private var checklist: some View {
        VStack(spacing: 0) {
            HStack { Text("首次使用准备"); Spacer(); Text("\(completeCount) / 4").monospacedDigit() }
                .font(.system(size: 12)).foregroundStyle(DaybookStyle.secondary).padding(.bottom, 12)
            stepRow(.transcription, icon: "waveform", detail: "把录音变成文字，留住你的原话。", status: transcription.canSave ? "已就绪" : "待准备")
            stepRow(.ai, icon: "sparkles", detail: "理解与检索一起准备，让回答有据可依。", status: aiReady ? "已就绪" : "待准备")
            stepRow(.data, icon: "lock.shield", detail: "由你决定，让 AI 了解哪些生活线索。", status: store.progress.dataReviewed ? "已确认选择" : "可选授权")
            stepRow(.usage, icon: "camera", detail: "用 iPhone 或 Apple Watch 留下第一条记录。", status: store.progress.usageReviewed ? "已了解" : "待了解")
        }
    }

    private func stepRow(_ step: OnboardingProgress.Page, icon: String, detail: String, status: String) -> some View {
        Button { go(step) } label: {
            HStack(spacing: 13) {
                Image(systemName: icon).font(.system(size: 18)).frame(width: 37, height: 37)
                    .foregroundStyle(DaybookStyle.accent).background(DaybookStyle.blueSoft, in: RoundedRectangle(cornerRadius: 12))
                VStack(alignment: .leading, spacing: 7) {
                    HStack { Text(title(step)).font(.system(size: 14, weight: .medium)); Spacer(); Text(status).font(.system(size: 10)).foregroundStyle(DaybookStyle.secondary) }
                    Text(detail).font(.system(size: 11)).foregroundStyle(DaybookStyle.secondary).lineSpacing(4)
                }
                Image(systemName: "chevron.right").font(.system(size: 11)).foregroundStyle(DaybookStyle.secondary)
            }.padding(.vertical, 17).overlay(alignment: .bottom) { DaybookStyle.line.frame(height: 1) }
        }.accessibilityIdentifier("onboarding.step.\(step.rawValue)")
    }

    private var footer: some View {
        VStack(spacing: 6) {
            Button(action: primaryAction) {
                Text(primaryTitle).font(.system(size: 14, weight: .medium)).frame(maxWidth: .infinity).padding(.vertical, 16)
                    .foregroundStyle(.white).background(DaybookStyle.accent, in: RoundedRectangle(cornerRadius: 15))
            }.disabled(transcription.isDownloading && page == .transcription || ai.state == .testing && page == .ai)
                .accessibilityIdentifier("onboarding.next")
            if page == .welcome || page == .review {
                Button("稍后设置，先记录") { confirmingSkip = true }.font(.system(size: 12)).padding(12)
            } else if page == .transcription || page == .ai {
                Button(page == .ai ? "稍后完成，先选数据范围" : "稍后设置此项") {
                    if page == .transcription { if transcription.isDownloading { transcription.cancel() }; go(.ai) } else { go(.data) }
                }.font(.system(size: 12)).padding(12)
            } else {
                Text(page == .data ? "可以一项也不开启，不影响完成这一步" : "无需拥有 Apple Watch，也能完成这一步")
                    .font(.system(size: 10)).foregroundStyle(DaybookStyle.secondary).padding(.top, 5)
            }
        }.padding(.horizontal, 25).padding(.top, 14).padding(.bottom, 10)
            .background(DaybookStyle.paper).overlay(alignment: .top) { DaybookStyle.line.frame(height: 1) }
    }

    private var primaryTitle: String {
        switch page {
        case .welcome: "开始准备"
        case .transcription: transcription.canSave ? "下一步：AI 能力" : transcription.isDownloading ? "正在准备…" : "检查并准备离线资源"
        case .ai: aiReady ? "下一步：数据授权" : "检查 AI 能力"
        case .data: "按当前选择继续"
        case .usage: "我知道怎么记录了"
        case .review: completeCount == 4 ? "开始使用 WiseLife" : "继续完成设置"
        }
    }
    private var aiDetail: String {
        switch ai.configuration.mode {
        case .local: appleReason ?? "Apple Intelligence · 已就绪"
        case .custom: ai.state == .success ? "当前配置已通过连接测试" : "请测试当前配置，不发送个人记录"
        case .nearbyMac, .chatgpt: "保留已有配置；请在原模型设置中管理连接。服务可用性需在使用时检查。"
        }
    }
    private var missingExplanation: String {
        var lines = ["你仍可录音、拍照和查看已有记录。"]
        if !transcription.canSave { lines.append("语音转写未就绪：暂时无法把录音转成文字。") }
        if !understandingReady { lines.append("AI 理解未就绪：总结、建议及问答可能不可用。") }
        if !retrievalReady { lines.append("语义检索未就绪：仍可按日期和关键词查找。") }
        return lines.joined(separator: "\n")
    }
    private func primaryAction() {
        switch page {
        case .welcome: go(firstPending)
        case .transcription:
            if transcription.canSave { saveTranscription(); if errorMessage == nil { go(.ai) } }
            else if transcription.state == .missing || isFailedTranscription { transcription.startDownload() }
            else { transcription.scheduleRefresh() }
        case .ai:
            refreshLocalReadiness()
            if aiReady { saveAI(); if errorMessage == nil { go(.data) } }
            else {
                if !retrievalReady { retrievalPrepareRequest += 1 }
                if ai.configuration.mode == .custom && ai.state != .success { ai.startTest() }
                else if ai.configuration.mode == .local, let appleReason { errorMessage = appleReason + " 可选择其他模型，或稍后设置，先使用基础记录。" }
                else if ai.configuration.mode == .chatgpt || ai.configuration.mode == .nearbyMac { errorMessage = aiDetail }
            }
        case .data: store.progress.dataReviewed = true; go(.usage)
        case .usage: store.progress.usageReviewed = true; go(.review)
        case .review: if completeCount == 4 { finish(skipped: false) } else { go(firstPending) }
        }
    }
    private var isFailedTranscription: Bool { if case .failed = transcription.state { true } else { false } }
    private var firstPending: OnboardingProgress.Page {
        !transcription.canSave ? .transcription : !aiReady ? .ai : !store.progress.dataReviewed ? .data : !store.progress.usageReviewed ? .usage : .review
    }
    private func go(_ target: OnboardingProgress.Page) {
        keyboard.dismiss(); page = target; store.progress.page = target
        if target == .transcription && !transcription.isDownloading { transcription.scheduleRefresh() }
    }
    private func refreshLocalReadiness() {
        appleReason = AISettingsView.appleUnavailableReason()
        retrievalReady = AppleDaybookEmbedding.make() != nil
    }
    private func saveTranscription() {
        do { try transcription.save(); store.transcriptionDraft = nil }
        catch { errorMessage = error.localizedDescription }
    }
    private func saveAI() {
        do { try ai.save(); store.aiDraft = nil } catch { errorMessage = error.localizedDescription }
    }
    private func finish(skipped: Bool) {
        if transcription.canSave { saveTranscription() }
        if understandingReady { saveAI() }
        guard errorMessage == nil else { return }
        store.finish(skipped: skipped)
    }
    private func title(_ step: OnboardingProgress.Page) -> String {
        switch step { case .transcription: "语音转写"; case .ai: "AI 能力"; case .data: "数据授权"; case .usage: "使用说明"; default: "准备结果" }
    }
    private func heading(_ kicker: String, _ title: String, _ subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(kicker).font(.system(size: 11, weight: .medium)).foregroundStyle(DaybookStyle.accent)
            Text(title).font(.system(size: 27, weight: .medium)).lineSpacing(5).fixedSize(horizontal: false, vertical: true)
            Text(subtitle).font(.system(size: 13)).foregroundStyle(DaybookStyle.secondary).lineSpacing(6)
        }.padding(.top, 5)
    }
    private func purpose(_ text: String, privacy: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("为什么要设置").font(.system(size: 13, weight: .medium))
            Text(text).font(.system(size: 12)).lineSpacing(6)
            Divider()
            Label(privacy, systemImage: "lock.shield").font(.system(size: 11)).lineSpacing(5).foregroundStyle(DaybookStyle.secondary)
        }.padding(16).frame(maxWidth: .infinity, alignment: .leading).background(DaybookStyle.blueSoft, in: RoundedRectangle(cornerRadius: 15))
    }
    private func readinessRow(_ title: String, ready: Bool, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack { Text(title).font(.system(size: 16, weight: .medium)); Spacer(); Text(ready ? "已就绪" : "待准备").font(.system(size: 11)).foregroundStyle(ready ? DaybookStyle.green : DaybookStyle.secondary) }
            Text(detail).font(.system(size: 12)).foregroundStyle(DaybookStyle.secondary)
        }.padding(.top, 8)
    }
}
