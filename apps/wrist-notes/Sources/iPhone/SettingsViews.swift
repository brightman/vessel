import SwiftUI
import FoundationModels

enum SettingsRoute: Hashable { case settings, transcription, myVoice, ai, about }

struct SettingsView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var model: NotesModel
    var showDaybookSettings = false
    let importAudio: () -> Void

    var body: some View {
        SettingsPage(title: "设置", subtitle: "让记录，按你的习惯来。", backTitle: showDaybookSettings ? "我的一天" : "语音笔记") {
            SettingsSection("外观") {
                HStack(spacing: 10) {
                    ForEach(AppAppearance.allCases, id: \.self) { appearance in
                        Button { settings.appearance = appearance } label: {
                            VStack(spacing: 12) {
                                Image(systemName: appearance.symbol).font(.system(size: 24))
                                Text(LocalizedStringKey(appearance.title)).font(.system(size: 13, weight: .semibold))
                            }
                            .frame(maxWidth: .infinity).frame(height: 94)
                            .foregroundStyle(settings.appearance == appearance ? NotesStyle.red : .primary)
                            .background(NotesStyle.card, in: RoundedRectangle(cornerRadius: 15))
                            .overlay(RoundedRectangle(cornerRadius: 15).stroke(settings.appearance == appearance ? NotesStyle.red : NotesStyle.border, lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(settings.appearance == appearance ? .isSelected : [])
                    }
                }
            }
            SettingsSection("界面语言") {
                Picker("界面语言", selection: $settings.interfaceLanguage) {
                    ForEach(AppLanguage.allCases) { language in Text(language.title).tag(language) }
                }.pickerStyle(.segmented)
                SettingsFootnote(text: "界面语言独立于语音转写语言。")
            }
            SettingsSection("模型与语言") {
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
                    SettingsRow(symbol: "info.circle", title: "关于", subtitle: "隐私协议、服务协议与联系信息")
                }
                .settingsCard()
            }
        }
    }
}

struct AboutView: View {
    private let privacyPolicyURL = URL(string: "https://wiselife.cloud/privacy")!
    private let termsOfServiceURL = URL(string: "https://wiselife.cloud/terms")!
    private let contactURL = URL(string: "mailto:hello@wiselife.cloud")!

    var body: some View {
        SettingsPage(title: "关于", subtitle: "WiseLife 的隐私、服务条款与联系渠道。") {
            SettingsSection("法律与支持") {
                VStack(spacing: 0) {
                    Link(destination: privacyPolicyURL) {
                        SettingsRow(symbol: "hand.raised", title: "隐私协议", subtitle: "查看隐私政策与数据使用说明")
                    }
                    Divider().overlay(NotesStyle.border)
                    Link(destination: termsOfServiceURL) {
                        SettingsRow(symbol: "doc.text", title: "服务协议", subtitle: "查看应用服务条款")
                    }
                    Divider().overlay(NotesStyle.border)
                    Link(destination: contactURL) {
                        SettingsRow(symbol: "envelope", title: "联系我", subtitle: "hello@wiselife.cloud")
                    }
                }
                .settingsCard()
            }
        }
        .tint(NotesStyle.red)
    }
}

struct AISettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var settings: AppSettings
    @StateObject private var editor: AISettingsModel
    @ObservedObject private var chatGPT: ChatGPTAccountModel
    @State private var saveError: String?

    init(settings: AppSettings) {
        self.settings = settings
        _editor = StateObject(wrappedValue: AISettingsModel(settings: settings))
        chatGPT = settings.chatGPT
    }

    var body: some View {
        SettingsPage(title: "AI 模型", subtitle: "用于笔记总结、跨记录回顾与 AI 对话。", canSave: editor.canSave, save: {
            do { try editor.save(); dismiss() }
            catch { saveError = error.localizedDescription }
        }) {
            VStack(spacing: 0) {
                ModelChoice(title: "Apple 本地模型", badge: "本机",
                            description: "由 Apple Intelligence 提供，在 iPhone 上处理文本，无需 API Key。",
                            selected: editor.configuration.mode == .local) {
                    editor.configuration.mode = .local
                }
                ModelChoice(title: "ChatGPT 账号", badge: "云端",
                            description: "使用已有 ChatGPT 账号，按套餐额度在云端处理。",
                            selected: editor.configuration.mode == .chatgpt) {
                    editor.configuration.mode = .chatgpt
                }
                ModelChoice(title: "自定义模型", badge: "自有服务",
                            description: "使用自己的服务与 Key，支持 OpenAI 或 Anthropic 兼容接口。",
                            selected: editor.configuration.mode == .custom) {
                    editor.configuration.mode = .custom
                }
            }
            if editor.configuration.mode == .local {
                SettingsInfo(title: localAvailabilityTitle,
                             text: "在系统设置中启用并下载。可用性取决于设备、语言和地区；不可用时不自动切换远程服务。")
                    .padding(.top, 20)
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
            DaybookSemanticSettingsView().padding(.top, 20)
            SettingsFootnote(text: "模型配置保存后用于下一次总结、问答、每日回顾与每日洞察。关闭会放弃未保存的模型修改，发送确认偏好即时保存。")
                .padding(.top, 20)
        }
        .onDisappear { editor.invalidateTest() }
        .alert("配置未保存", isPresented: Binding(get: { saveError != nil }, set: { if !$0 { saveError = nil } })) {
            Button("好") { saveError = nil }
        } message: { Text(saveError ?? "") }
    }

    private var localAvailabilityTitle: String {
        if case .available = SystemLanguageModel.default.availability,
           SystemLanguageModel.default.supportsLocale(Locale(identifier: "zh-CN")) { return "Apple 本地模型可用" }
        return "需要 Apple Intelligence 可用"
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
                Text(LocalizedStringKey(subtitle)).font(.system(size: 12)).foregroundStyle(DaybookStyle.secondary)
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
            Text(LocalizedStringKey(title)).font(.system(size: 12, weight: .medium)).foregroundStyle(DaybookStyle.ink)
            content
        }.padding(.top, 24)
    }
}

private struct SettingsRow: View {
    let symbol: String
    let title: String
    let subtitle: String
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).font(.system(size: 17)).frame(width: 21).foregroundStyle(DaybookStyle.secondary)
            VStack(alignment: .leading, spacing: 6) {
                Text(LocalizedStringKey(title)).font(.system(size: 12, weight: .medium)).foregroundStyle(DaybookStyle.ink)
                Text(LocalizedStringKey(subtitle)).font(.system(size: 10)).foregroundStyle(DaybookStyle.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
            DaybookIcon("ChevronRight", size: 17).foregroundStyle(DaybookStyle.secondary)
        }
        .padding(.vertical, 16).contentShape(Rectangle())
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
                    Text(LocalizedStringKey(title)).font(.system(size: 13, weight: .medium)).foregroundStyle(DaybookStyle.ink)
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
                Text(LocalizedStringKey(title)).font(.system(size: 13, weight: .medium)).lineSpacing(7)
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
