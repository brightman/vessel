import SwiftUI
import Translation

struct AIRetrievalSettingsView: View {
    var body: some View {
        SettingsPage(title: "AI 检索", subtitle: "在本机查找相关记录，管理检索语言与资源。") {
            DaybookSemanticSettingsView()
        }
    }
}

struct DaybookSemanticSettingsView: View {
    var onboarding = false
    var prepareRequest = 0
    var onReadinessChange: (Bool) -> Void = { _ in }
    @Environment(\.scenePhase) private var scenePhase
    @State private var language = AppleDaybookEmbedding.selectedLanguage
    @State private var status = ""
    @State private var canDownload = false
    @State private var embeddingBusy = false
    @State private var confirmingClear = false
    @State private var refreshID = UUID()
    @State private var translationState: AppleQueryTranslator.ResourceState?
    @State private var translationMessage: String?
    @State private var translationBusy = false
    @State private var translationRequestID = UUID()
    @State private var translationConfiguration: TranslationSession.Configuration?
    private var busy: Bool { embeddingBusy || translationBusy }
    private var translationTarget: QueryTranslationLanguage? { .init(rawValue: language) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsSection("本地语义检索") {
                DaybookSettingsField("记录主要语言") {
                    Menu {
                        Picker("记录主要语言", selection: $language) {
                            Text("简体中文").tag("zh-Hans")
                            Text("English").tag("en")
                            Text("繁體中文").tag("zh-Hant")
                            Text("日本語").tag("ja")
                        }
                    } label: {
                        DaybookSettingsMenuLabel(text: ["zh-Hans":"简体中文", "en":"English", "zh-Hant":"繁體中文", "ja":"日本語"][language] ?? language)
                    }.disabled(busy).accessibilityLabel("记录主要语言")
                        .accessibilityIdentifier("semantic.settings.language")
                }
                resourceCard("Apple 上下文向量") {
                    Text(status).font(SettingsMenuStyle.note).foregroundStyle(DaybookStyle.secondary)
                        .accessibilityIdentifier("semantic.settings.embedding.status")
                    if canDownload {
                        Button("下载 Apple 上下文向量资源") {
                            prepareEmbedding()
                        }.buttonStyle(DaybookSettingsButtonStyle()).disabled(busy)
                            .accessibilityIdentifier("semantic.settings.embedding.download")
                    }
                }
            }
            SettingsSection("中英跨语言检索") {
                SettingsFootnote(text: "中文、英文及中英混合问题可在本机翻译为记录主要语言，再检索原文。原问题保留用于姓名、日期和关键词匹配；翻译不作为回答依据。首次使用需准备系统语言包，无需 API Key。")
                resourceCard("中英翻译语言包") {
                    Text(translationStatus).font(SettingsMenuStyle.note).foregroundStyle(DaybookStyle.secondary)
                        .accessibilityIdentifier("semantic.settings.translation.status")
                    if translationTarget != nil, translationState == .downloadable {
                        Button(translationBusy ? "正在准备翻译语言包…" : "准备中英翻译语言包") { prepareTranslation() }
                            .buttonStyle(DaybookSettingsButtonStyle()).disabled(busy)
                            .accessibilityIdentifier("semantic.settings.translation.download")
                    }
                }
            }
            if !onboarding {
            SettingsSection("索引管理") {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) { indexActions }
                    VStack(alignment: .leading, spacing: 8) { indexActions }
                }.disabled(busy)
                SettingsFootnote(text: "语义检索只读取查询日期范围内、允许 AI 读取的原文，并按所选语言建立索引。长文本分块处理，每批最多计算 64 块；Apple 模型窗口可能只覆盖块内部分文本。其他语言、缺少资源或检索失败时使用原文关键词。原始转写和图片文字保留完整。")
                SettingsFootnote(text: "语言和资源设置即时生效。清除只删除计算出的索引，保留原记录及 Apple 管理的语言资源。升级向量模型后会自动重建；在记录搜索中可查看进度。翻译仅用于检索，回答仍使用你选择的 AI 模型。")
            }
            }
            if onboarding { SettingsFootnote(text: "中英翻译为可选增强。新用户没有记录、索引为空，不影响完成准备。索引会在有记录后按需建立。") .padding(.top, 16) }
        }
        .onAppear { refresh() }
        .onChange(of: prepareRequest) { _, _ in prepareEmbedding() }
        .onChange(of: scenePhase) { _, phase in if phase == .active && !busy { refresh() } }
        .onChange(of: language) { _, value in
            translationConfiguration = nil
            translationRequestID = UUID()
            translationBusy = false
            UserDefaults.standard.set(value, forKey: AppleDaybookEmbedding.languageKey)
            refresh()
            reset(change: .languageChanged)
        }
        .task(id: refreshID) {
            guard let target = translationTarget else { return }
            let state = await AppleQueryTranslator.resourceState(to: target)
            guard !Task.isCancelled, translationTarget == target else { return }
            translationState = state
        }
        .translationTask(translationConfiguration) { session in
            let request = translationRequestID
            defer { if translationRequestID == request { translationBusy = false } }
            do {
                try await session.prepareTranslation()
                try Task.checkCancellation()
                guard translationRequestID == request, let target = translationTarget else { return }
                let state = await AppleQueryTranslator.resourceState(to: target)
                guard !Task.isCancelled, translationRequestID == request else { return }
                translationState = state
                translationMessage = state == .installed ? nil : "语言包尚未就绪，请稍后重试。"
                DaybookSemanticResourceChange.downloadCompleted.publish()
            } catch {
                guard !Task.isCancelled, translationRequestID == request else { return }
                translationMessage = "未完成语言包准备。可重试；当前继续使用原问题检索。"
            }
        }
        .onDisappear {
            translationRequestID = UUID()
            translationConfiguration = nil
            translationBusy = false
        }
        .confirmationDialog("清除本地语义索引？", isPresented: $confirmingClear, titleVisibility: .visible) {
            Button("清除索引", role: .destructive) { reset(change: .cleared) }
        }
    }
    private func resourceCard<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(LocalizedStringKey(title)).font(SettingsMenuStyle.title)
            content()
        }.frame(maxWidth: .infinity, alignment: .leading).padding(15)
            .background(DaybookStyle.blueSoft, in: RoundedRectangle(cornerRadius: 16))
    }
    @ViewBuilder private var indexActions: some View {
        Button("刷新资源状态") { refresh(); DaybookSemanticResourceChange.refreshed.publish() }
            .buttonStyle(DaybookSettingsButtonStyle())
        Button("重建索引") { reset(change: .rebuilt) }.buttonStyle(DaybookSettingsButtonStyle())
        Button("清除索引", role: .destructive) { confirmingClear = true }.buttonStyle(DaybookSettingsButtonStyle())
    }
    private var translationStatus: String {
        guard translationTarget != nil else { return "跨语言翻译目前支持简体中文与英文；此语言继续使用原问题检索。" }
        if translationBusy { return "正在准备 Apple 中英翻译语言包…" }
        return translationMessage ?? translationState?.message ?? "正在检查本机翻译语言包…"
    }
    private func prepareTranslation() {
        guard let target = translationTarget, !busy, translationState == .downloadable else { return }
        translationBusy = true; translationMessage = nil; translationRequestID = UUID()
        if translationConfiguration != nil { translationConfiguration?.invalidate() }
        else {
            translationConfiguration = .init(source: Locale.Language(identifier: target.counterpart.rawValue),
                                             target: Locale.Language(identifier: target.rawValue))
        }
    }
    private func refresh() {
        let resource = AppleDaybookEmbedding.resourceStatus(language: language)
        status = resource.message; canDownload = resource.canDownload
        reportReadiness()
        translationState = nil; translationMessage = nil; refreshID = UUID()
    }
    private func prepareEmbedding() {
        guard canDownload, !busy else { reportReadiness(); return }
        embeddingBusy = true; status = "正在请求 Apple 上下文向量资源…"
        let requested = language
        Task {
            status = await AppleDaybookEmbedding.download(language: requested)
            embeddingBusy = false
            canDownload = AppleDaybookEmbedding.resourceStatus(language: requested).canDownload
            reportReadiness()
            DaybookSemanticResourceChange.downloadCompleted.publish()
        }
    }
    private func reportReadiness() {
        guard language == AppleDaybookEmbedding.selectedLanguage else { return }
        onReadinessChange(AppleDaybookEmbedding.make(language: language) != nil)
    }
    private func reset(change: DaybookSemanticResourceChange) {
        let rebuild = change != .cleared
        embeddingBusy = true
        DaybookSemanticResourceChange.resetStarted.publish()
        Task {
            do {
                try await DaybookSemanticIndex.shared.clear()
                refresh(); status += rebuild ? "；将在当前或下次检索时重建索引。" : "；索引已清除。"
            } catch { status = "索引操作失败；继续使用关键词。请稍后重试。" }
            embeddingBusy = false
            change.publish()
        }
    }
}
