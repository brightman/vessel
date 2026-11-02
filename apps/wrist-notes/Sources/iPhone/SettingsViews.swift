import SwiftUI
import FoundationModels

enum SettingsRoute: Hashable { case settings, quickRecording, transcription, myVoice, ai, aiRetrieval, about }

struct SettingsView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var model: NotesModel
    var showDaybookSettings = false
    let importAudio: () -> Void

    var body: some View {
        SettingsPage(title: "设置", subtitle: "让记录，按你的习惯来。", backTitle: showDaybookSettings ? "我的一天" : "语音笔记") {
            SettingsMenuGroup("通用设置") {
                SettingsMenuRow(icon: "Sun", title: "外观") {
                    Menu {
                        Picker("外观", selection: $settings.appearance) {
                            ForEach(AppAppearance.allCases, id: \.self) { appearance in Text(LocalizedStringKey(appearance.title)).tag(appearance) }
                        }
                    } label: { SettingsMenuValue(text: settings.appearance.title) }
                    .accessibilityLabel("外观")
                }
                SettingsMenuRow(icon: "MessageCircle", title: "界面语言") {
                    Menu {
                        Picker("界面语言", selection: $settings.interfaceLanguage) {
                            ForEach(AppLanguage.allCases) { language in Text(language.title).tag(language) }
                        }
                    } label: { SettingsMenuValue(text: settings.interfaceLanguage.title) }
                    .accessibilityLabel("界面语言")
                }
                NavigationLink(value: SettingsRoute.quickRecording) {
                    SettingsMenuRow(icon: "Mic", title: "快捷设置", subtitle: "操作按钮、锁屏小组件与实时活动")
                }
            }
            SettingsSection("语言与AI") {
                VStack(spacing: 0) {
                    NavigationLink(value: SettingsRoute.transcription) {
                        SettingsRow(symbol: "waveform", title: "语音转写模型", subtitle: settings.transcriptionLabel)
                    }
                    Divider().overlay(NotesStyle.border)
                    MyVoiceSettingsEntry(profile: model.voiceProfile)
                    Divider().overlay(NotesStyle.border)
                    NavigationLink(value: SettingsRoute.ai) {
                        SettingsRow(symbol: "sparkles", title: "AI 模型", subtitle: settings.ai.label)
                    }
                    Divider().overlay(NotesStyle.border)
                    NavigationLink(value: SettingsRoute.aiRetrieval) {
                        SettingsRow(symbol: "magnifyingglass", title: "AI 检索", subtitle: "本地语义检索、语言包与索引")
                    }
                }
                .settingsCard()
                SettingsFootnote(text: "默认在 iPhone 上转写、总结和回答问题。使用外部 AI 时默认先确认发送内容，也可选择下次不再提示。")
            }
            if showDaybookSettings {
                SettingsSection("我的 AI") {
                    NavigationLink(value: DaybookRoute.preferences) {
                        SettingsRow(symbol: "bell.badge", title: "AI 偏好与提醒", subtitle: "主动建议、免打扰与允许使用的数据")
                    }.settingsCard()
                }
            }
            SettingsSection("录音") {
                Button(action: importAudio) {
                    SettingsRow(symbol: "square.and.arrow.down", title: "导入音频文件", subtitle: "从“文件”添加已有录音")
                }
                .settingsCard()
            }
            SettingsSection("关于") {
                NavigationLink(value: SettingsRoute.about) {
                    SettingsRow(symbol: "info.circle", title: "关于", subtitle: "常见问题与法律信息")
                }
                .settingsCard()
                AppReleaseInfoView()
            }
        }
    }
}

struct AboutView: View {
    var body: some View {
        SettingsPage(title: "关于", subtitle: "查看常见问题、隐私与服务条款，或联系 WiseLife。") {
            SettingsMenuGroup("法律与支持") { SettingsAboutLinks() }
            AppReleaseInfoView()
        }
    }
}

struct AISettingsView: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var localUnavailableReason = Self.appleUnavailableReason()
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var settings: AppSettings
    @StateObject private var editor: AISettingsModel
    @ObservedObject private var chatGPT: ChatGPTAccountModel
    @State private var saveError: String?

    private let embedded: Bool
    init(settings: AppSettings, editor: AISettingsModel? = nil, embedded: Bool = false) {
        self.embedded = embedded
        self.settings = settings
        _editor = StateObject(wrappedValue: editor ?? AISettingsModel(settings: settings))
        chatGPT = settings.chatGPT
    }

    var body: some View {
        Group {
        if embedded { configurationContent } else {
        SettingsPage(title: "AI 模型", subtitle: "用于笔记总结、跨记录回顾与 AI 对话。", canSave: editor.canSave && (editor.configuration.mode != .local || localUnavailableReason == nil), save: {
            localUnavailableReason = Self.appleUnavailableReason()
            guard editor.configuration.mode != .local || localUnavailableReason == nil else { return }
            do { try editor.save(); dismiss() }
            catch { saveError = error.localizedDescription }
        }) {
            configurationContent
        }
        }
        }
        .onAppear { localUnavailableReason = Self.appleUnavailableReason() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { localUnavailableReason = Self.appleUnavailableReason() }
        }
        .onDisappear { if !embedded { editor.invalidateTest() } }
        .alert("配置未保存", isPresented: Binding(get: { saveError != nil }, set: { if !$0 { saveError = nil } })) {
            Button("好") { saveError = nil }
        } message: { Text(saveError ?? "") }
    }

    private var configurationContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(spacing: 0) {
                ModelChoice(title: "Apple Intelligence", badge: "本机",
                            description: localUnavailableReason ?? "无需 API Key，在 iPhone 上理解文字。可用性以本机系统检查为准。",
                            selected: editor.configuration.mode == .local) {
                    guard localUnavailableReason == nil else { return }
                    editor.selectMode(.local)
                }
                .disabled(localUnavailableReason != nil)
                .opacity(localUnavailableReason == nil ? 1 : 0.45)
                .accessibilityIdentifier("ai.settings.appleIntelligence")
                ModelChoice(title: "连接本地 Mac 模型", badge: "局域网",
                            description: "连接 WiseLife Mac Companion，使用 Mac 上的 LLM 生成总结、标题与问答。",
                            selected: editor.configuration.mode == .nearbyMac) {
                    editor.selectMode(.nearbyMac)
                }
                ModelChoice(title: "ChatGPT 账号", badge: "云端",
                            description: "使用已有 ChatGPT 账号，按套餐额度在云端处理。",
                            selected: editor.configuration.mode == .chatgpt) {
                    editor.selectMode(.chatgpt)
                }
                ModelChoice(title: settings.interfaceLanguage == .english ? "Bring Your Own Model" : "自定义 AI 模型", badge: "自有服务",
                            description: "使用自己的模型地址与 API Key。选择云端服务时，允许的文字会发送给该服务。",
                            selected: editor.configuration.mode == .custom) {
                    editor.selectMode(.custom)
                }
            }
            if embedded {
                SettingsFootnote(text: "Apple Intelligence：无需 API Key，在 iPhone 上理解文字。WiseLife 产品要求为 iOS 27.3 及以上、iPhone 15 Pro／Pro Max 或更新的支持机型；实际能力以本机系统检查为准。")
                    .padding(.top, 14)
                if editor.configuration.mode == .custom { Text("Bring Your Own Model").font(.system(size: 11)).foregroundStyle(DaybookStyle.accent).padding(.top, 10) }
            }
            if editor.configuration.mode == .local {
                SettingsInfo(title: localUnavailableReason ?? "Apple Intelligence可用",
                             text: "在系统设置中启用并下载。可用性取决于设备、语言和地区；不可用时不自动切换远程服务。")
                    .padding(.top, 20)
            } else if editor.configuration.mode == .nearbyMac {
                NearbyMacSettingsSection(settings: settings, configuration: $editor.configuration).padding(.top, 20)
            } else if editor.configuration.mode == .chatgpt {
                ChatGPTSettingsSection(account: chatGPT, configuration: $editor.configuration).padding(.top, 20)
            } else {
                VStack(alignment: .leading, spacing: 18) {
                    DaybookSettingsField("API 接口兼容") {
                        Menu {
                            Picker("API 接口兼容", selection: $editor.configuration.apiProtocol) {
                                Text("OpenAI").tag(AIConfiguration.APIProtocol.openai)
                                Text("Anthropic").tag(AIConfiguration.APIProtocol.anthropic)
                            }
                        } label: { DaybookSettingsMenuLabel(text: editor.configuration.apiProtocol.title) }
                        .accessibilityLabel("API 接口兼容")
                    }
                    DaybookSettingsField("模型名称") {
                        TextField("例如 my-model", text: $editor.configuration.model)
                            .accessibilityLabel("模型名称")
                    }
                    DaybookSettingsField("上下文窗口（tokens，可选）") {
                        TextField("留空：按 4,096 估算", text: Binding(
                            get: { editor.configuration.contextWindowTokens.map(String.init) ?? "" },
                            set: { input in
                                let digits=String(input.filter(\.isNumber))
                                editor.configuration.contextWindowTokens=digits.isEmpty ? nil : Int(digits)
                            }))
                            .keyboardType(.numberPad)
                            .accessibilityLabel("上下文窗口（tokens，可选）")
                    }
                    SettingsFootnote(text: "填写模型服务商公布的上下文窗口；不确定时留空，按 4,096 tokens 估算。")
                        .padding(.top, -8)
                    DaybookSettingsField("服务地址 · Base URL") {
                        TextField(editor.configuration.apiProtocol.baseURLHint, text: $editor.configuration.baseURL)
                            .keyboardType(.URL).accessibilityLabel("Base URL")
                    }
                    SettingsFootnote(text: "兼容 \(editor.configuration.apiProtocol.title)。填写 Base URL，不含末尾 /\(editor.configuration.apiProtocol.endpointPath)。")
                        .padding(.top, -8)
                    DaybookSettingsField("API Key") {
                        SecureField("输入你的 API Key", text: $editor.apiKey)
                            .privacySensitive().accessibilityLabel("API Key")
                    }
                    SettingsFootnote(text: "自定义模型会接收你允许用于本次任务的文本，原始录音与图片保留在本机。API Key 保存在本机钥匙串中。")
                        .padding(.top, -6)
                    Button { editor.startTest() } label: {
                        HStack(spacing: 7) {
                            if editor.state == .testing { ProgressView().controlSize(.small) }
                            Text(editor.state == .testing ? "正在测试连接…" : "测试连接")
                        }
                    }
                    .buttonStyle(DaybookSettingsButtonStyle())
                    .disabled(editor.state == .testing)
                    testStatus.padding(.top, -7)
                }
                .padding(.top, 18)
            }
            VStack(alignment: .leading, spacing: 10) {
                Toggle("发送给外部 AI 前确认", isOn: $settings.requiresRemoteAIConfirmation)
                    .font(.system(size: 14)).tint(DaybookStyle.accent)
                    .accessibilityIdentifier("ai.settings.confirmBeforeSending")
                SettingsFootnote(text: "即时生效。关闭后，外部 AI 问答与总结直接发送允许使用的文字，每日回顾、每日洞察和长录音标题可自动生成；可随时重新开启。")
            }.padding(.top, 24)
            SettingsFootnote(text: embedded ? "模型准备后用于总结、问答与回顾。非敏感选择可恢复，未测试的 API Key 不保存；发送确认偏好即时保存。" : "模型配置保存后用于下一次总结、问答、每日回顾与每日洞察。关闭会放弃未保存的模型修改，发送确认偏好即时保存。")
                .padding(.top, 20)
        }
    }

    static func appleUnavailableReason() -> String? {
        switch SystemLanguageModel.default.availability {
        case .available:
            return SystemLanguageModel.default.supportsLocale(Locale(identifier: "zh-CN"))
                ? nil : "本机 Apple 模型暂不支持中文。"
        case .unavailable(let reason):
            switch reason {
            case .deviceNotEligible: return "此设备不支持 Apple Intelligence。"
            case .appleIntelligenceNotEnabled: return "请先在系统设置中启用 Apple Intelligence。"
            case .modelNotReady: return "Apple Intelligence 模型尚未准备好，请等待系统下载完成。"
            @unknown default: return "Apple Intelligence 当前不可用。"
            }
        }
    }

    private var testStatus: some View {
        Group {
            switch editor.state {
            case .idle: Text("测试只发送固定测试文本。修改配置后需重新测试。").foregroundStyle(DaybookStyle.secondary)
            case .testing: Text("正在验证地址、API Key 和模型，请稍候…").foregroundStyle(DaybookStyle.secondary)
            case .success:
                HStack(spacing: 6) { DaybookIcon("Check", size: 13); Text("配置已验证，可以保存。") }
                    .foregroundStyle(DaybookStyle.green)
            case .failure(let message):
                HStack(alignment: .top, spacing: 6) { DaybookIcon("CircleHelp", size: 13); Text(message) }
                    .foregroundStyle(DaybookStyle.red)
            }
        }
        .font(.system(size: 11)).lineSpacing(6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

struct SettingsPage<Content: View>: View {
    @Environment(\.dismiss) private var dismiss
    let title: String
    let subtitle: String
    var backTitle = "设置"
    var canSave = true
    var save: (() -> Void)? = nil
    @ViewBuilder var content: Content

    var body: some View {
        DaybookSheetLayout(title: title, onClose: { dismiss() }) {
            VStack(alignment: .leading, spacing: 0) {
                Text(LocalizedStringKey(subtitle)).font(SettingsMenuStyle.note).foregroundStyle(DaybookStyle.secondary)
                    .lineSpacing(8).padding(.top, 6).padding(.bottom, 20)
                content
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if let save {
                DaybookSettingsActions(cancel: { dismiss() }, save: save, canSave: canSave)
                    .padding(.horizontal, 25).padding(.top, 15).padding(.bottom, 20)
                    .background(DaybookStyle.paper)
                    .overlay(alignment: .top) { Rectangle().fill(DaybookStyle.line).frame(height: 1).padding(.horizontal, 25) }
            }
        }
    }
}

struct SettingsSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content
    init(_ title: String, @ViewBuilder content: () -> Content) { self.title = title; self.content = content() }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(LocalizedStringKey(title)).font(SettingsMenuStyle.heading).foregroundStyle(DaybookStyle.ink)
            content
        }.padding(.top, 24)
    }
}

private struct SettingsRow: View {
    let symbol: String
    let title: String
    let subtitle: String
    var body: some View {
        SettingsMenuRow(icon: ["waveform":"AudioLines", "sparkles":"MessageCircle", "magnifyingglass":"Search", "bell.badge":"Bell", "square.and.arrow.down":"AudioLines", "info.circle":"CircleHelp"][symbol] ?? "Settings2", title: title, subtitle: subtitle)
    }
}

struct ModelChoice: View {
    let title: String
    let badge: String
    let description: String
    let selected: Bool
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 10) {
                Circle().stroke(selected ? DaybookStyle.accent : DaybookStyle.secondary, lineWidth: 1)
                    .background { if selected { Circle().fill(DaybookStyle.accent).padding(3) } }
                    .frame(width: 13, height: 13).padding(.top, 4)
                VStack(alignment: .leading, spacing: 6) {
                    Text(LocalizedStringKey(title)).font(SettingsMenuStyle.title).foregroundStyle(DaybookStyle.ink)
                        .lineSpacing(7)
                    Text(description).font(.system(size: 11)).foregroundStyle(DaybookStyle.secondary)
                        .lineSpacing(7).fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.vertical, 17).contentShape(Rectangle())
            .overlay(alignment: .bottom) { Rectangle().fill(DaybookStyle.line).frame(height: 1) }
        }
        .buttonStyle(.plain).accessibilityAddTraits(selected ? .isSelected : [])
    }
}

struct SettingsFootnote: View {
    let text: String
    var body: some View {
        Text(LocalizedStringKey(text)).font(.system(size: 11)).foregroundStyle(DaybookStyle.secondary)
            .lineSpacing(7).fixedSize(horizontal: false, vertical: true)
    }
}

struct SettingsInfo: View {
    let title: String
    let text: String
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            DaybookIcon("ShieldCheck", size: 18).foregroundStyle(DaybookStyle.accent)
            VStack(alignment: .leading, spacing: 7) {
                Text(LocalizedStringKey(title)).font(SettingsMenuStyle.title).lineSpacing(7)
                Text(LocalizedStringKey(text)).font(.system(size: 11)).foregroundStyle(DaybookStyle.secondary).lineSpacing(7)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading).padding(17)
        .background(DaybookStyle.blueSoft, in: RoundedRectangle(cornerRadius: 16))
    }
}

struct DaybookSettingsField<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content
    init(_ title: String, @ViewBuilder content: () -> Content) { self.title = title; self.content = content() }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(LocalizedStringKey(title)).font(.system(size: 11)).foregroundStyle(DaybookStyle.secondary)
            content.font(.system(size: 16)).foregroundStyle(DaybookStyle.ink)
                .textInputAutocapitalization(.never).autocorrectionDisabled().submitLabel(.done)
                .frame(maxWidth: .infinity, minHeight: 20, alignment: .leading)
                .padding(12).background(DaybookStyle.white, in: RoundedRectangle(cornerRadius: 12))
                .overlay { RoundedRectangle(cornerRadius: 12).stroke(DaybookStyle.accent.opacity(0.2), lineWidth: 1) }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct DaybookSettingsMenuLabel: View {
    let text: String
    var body: some View {
        HStack(spacing: 8) {
            Text(LocalizedStringKey(text)).frame(maxWidth: .infinity, alignment: .leading)
            DaybookIcon("ChevronDown", size: 15).foregroundStyle(DaybookStyle.secondary)
        }.contentShape(Rectangle())
    }
}

struct DaybookSettingsButtonStyle: ButtonStyle {
    var primary = false
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 12, weight: primary ? .medium : .regular))
            .foregroundStyle(primary ? Color.white : DaybookStyle.accent)
            .padding(.horizontal, 14).padding(.vertical, 12)
            .background(primary ? DaybookStyle.accent : DaybookStyle.blueSoft, in: RoundedRectangle(cornerRadius: 14))
            .opacity(!isEnabled ? 0.42 : configuration.isPressed ? 0.75 : 1)
    }
}

struct DaybookSettingsActions: View {
    let cancel: () -> Void
    let save: () -> Void
    var canSave = true
    var saveTitle = "保存设置"
    var isSaving = false
    var canCancel = true

    var body: some View {
        HStack(spacing: 10) {
            Button(action: cancel) { Text("取消").frame(maxWidth: .infinity) }
                .buttonStyle(DaybookSettingsButtonStyle()).disabled(!canCancel)
            Button(action: save) {
                HStack(spacing: 6) {
                    if isSaving { ProgressView().controlSize(.small).tint(.white) }
                    else { DaybookIcon("Check", size: 13) }
                    Text(saveTitle)
                }.frame(maxWidth: .infinity)
            }
            .buttonStyle(DaybookSettingsButtonStyle(primary: true)).disabled(!canSave)
        }
    }
}

extension View {
    func settingsCard() -> some View {
        self.overlay(alignment: .bottom) { Rectangle().fill(DaybookStyle.line).frame(height: 1) }
            .buttonStyle(.plain)
    }
}

struct AppReleaseInfoView: View {
    @Environment(\.locale) private var locale
    private let release = AppReleaseInfo()
    var body: some View {
        VStack(spacing: 12) {
            HStack { Text("版本号"); Spacer(); Text(verbatim: release.versionLabel) }
            HStack {
                Text("发布时间"); Spacer()
                if let date = release.releaseLabel(locale: locale) { Text(verbatim: date) }
                else { Text("未提供") }
            }
        }
        .font(SettingsMenuStyle.note).foregroundStyle(DaybookStyle.secondary)
        .monospacedDigit().padding(.top, 16)
        .accessibilityIdentifier("settings.releaseInfo")
    }
}

// Shared by the settings overview and its nested menus.
enum SettingsMenuStyle {
    static let heading = Font.system(size: 16, weight: .semibold)
    static let title = Font.system(size: 14, weight: .medium)
    static let note = Font.system(size: 11)
}

struct SettingsMenuGroup<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content
    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title; self.content = content()
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(LocalizedStringKey(title)).font(SettingsMenuStyle.heading)
                .foregroundStyle(DaybookStyle.ink).accessibilityAddTraits(.isHeader)
            VStack(spacing: 0) { content }
                .overlay(alignment: .top) { DaybookStyle.line.frame(height: 1) }
        }.padding(.top, 28).buttonStyle(.plain)
    }
}

struct SettingsMenuRow<Trailing: View>: View {
    let icon: String
    let title: String
    var subtitle: String = ""
    var status: String = ""
    var labelAction: (() -> Void)? = nil
    @ViewBuilder var trailing: Trailing
    var body: some View {
        HStack(spacing: 12) {
            Group {
                if icon == "Ring" { Circle().stroke(lineWidth: 1.6).frame(width: 20, height: 20) }
                else { DaybookIcon(icon, size: 20) }
            }.foregroundStyle(DaybookStyle.accent).frame(width: 20).accessibilityHidden(true)
            Group {
                if let labelAction { Button(action: labelAction) { label }.buttonStyle(.plain) }
                else { label }
            }.frame(maxWidth: .infinity, alignment: .leading)
            trailing
        }.padding(.vertical, 15).frame(minHeight: 72)
            .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            .overlay(alignment: .bottom) { DaybookStyle.line.frame(height: 1) }
    }
    private var label: some View {
        VStack(alignment: .leading, spacing: 4) {
                Text(LocalizedStringKey(title)).font(SettingsMenuStyle.title).foregroundStyle(DaybookStyle.ink)
                if !subtitle.isEmpty {
                    Text(LocalizedStringKey(subtitle)).font(SettingsMenuStyle.note)
                        .foregroundStyle(DaybookStyle.secondary).lineSpacing(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !status.isEmpty {
                    Text(LocalizedStringKey(status)).font(SettingsMenuStyle.note).foregroundStyle(DaybookStyle.secondary)
                }
        }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
    }
}

struct SettingsMenuValue: View {
    let text: String
    var body: some View {
        HStack(spacing: 5) {
            Text(LocalizedStringKey(text)).font(.system(size: 13))
            DaybookIcon("ChevronDown", size: 14)
        }.foregroundStyle(DaybookStyle.secondary).frame(minHeight: 44)
    }
}

struct SettingsMenuChevron: View {
    var body: some View {
        DaybookIcon("ChevronRight", size: 16).foregroundStyle(DaybookStyle.secondary).accessibilityHidden(true)
    }
}

extension SettingsMenuRow where Trailing == SettingsMenuChevron {
    init(icon: String, title: String, subtitle: String = "") {
        self.icon = icon; self.title = title; self.subtitle = subtitle; trailing = SettingsMenuChevron()
    }
}

struct SettingsAboutLinks: View {
    var body: some View {
        VStack(spacing: 0) {
            Link(destination: URL(string: "https://wiselife.cloud/#questions")!) {
                SettingsMenuRow(icon: "CircleHelp", title: "常见问题")
            }
            Link(destination: URL(string: "https://wiselife.cloud/privacy")!) {
                SettingsMenuRow(icon: "ShieldCheck", title: "隐私条款")
            }
            Link(destination: URL(string: "https://wiselife.cloud/terms")!) {
                SettingsMenuRow(icon: "BookOpen", title: "服务条款")
            }
            Link(destination: URL(string: "mailto:hello@wiselife.cloud")!) {
                SettingsMenuRow(icon: "MessageCircle", title: "联系我们")
            }
        }.buttonStyle(.plain)
    }
}

struct DataPrivacySettingsView: View {
    var body: some View {
        SettingsPage(title: "数据与隐私", subtitle: "了解本机存储与 AI 数据使用范围") {
            SettingsSection("记录留在本机") {
                SettingsFootnote(text: "录音、图片、转写与笔记默认保存在你的 iPhone。由你决定 AI 可以读取哪些来源。")
            }
            SettingsSection("本机检索") {
                SettingsFootnote(text: "语义索引与问题翻译在本机处理；清除索引不会删除原始记录。")
            }
            SettingsSection("自选 AI 服务") {
                SettingsFootnote(text: "使用外部 AI 时，按你的发送确认偏好处理允许使用的文字。原始录音、图片和声音档案留在本机。")
            }
        }
    }
}
