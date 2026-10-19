import SwiftUI
import FoundationModels

enum SettingsRoute: Hashable { case settings, transcription, ai }

struct SettingsView: View {
    @EnvironmentObject private var settings: AppSettings
    let importAudio: () -> Void

    var body: some View {
        SettingsPage(title: "设置", subtitle: "让记录，按你的习惯来。", backTitle: "语音笔记") {
            SettingsSection("外观") {
                HStack(spacing: 10) {
                    ForEach(AppAppearance.allCases, id: \.self) { appearance in
                        Button { settings.appearance = appearance } label: {
                            VStack(spacing: 12) {
                                Image(systemName: appearance.symbol).font(.system(size: 24))
                                Text(appearance.title).font(.system(size: 13, weight: .semibold))
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
            SettingsSection("模型与语言") {
                VStack(spacing: 0) {
                    NavigationLink(value: SettingsRoute.transcription) {
                        SettingsRow(symbol: "waveform", title: "语音转文本", subtitle: settings.transcriptionLabel)
                    }
                    Divider().overlay(NotesStyle.border)
                    NavigationLink(value: SettingsRoute.ai) {
                        SettingsRow(symbol: "sparkles", title: "AI 模型", subtitle: settings.ai.label)
                    }
                }
                .settingsCard()
                SettingsFootnote(text: "默认在 iPhone 上转写和总结。只有选择自定义 AI 后，笔记文本才会发送到你指定的服务。")
            }
            SettingsSection("录音") {
                Button(action: importAudio) {
                    SettingsRow(symbol: "square.and.arrow.down", title: "导入音频文件", subtitle: "从“文件”添加已有录音")
                }
                .settingsCard()
            }
        }
    }
}

struct TranscriptionSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var settings: AppSettings
    @State private var language: String

    init(settings: AppSettings) {
        self.settings = settings
        _language = State(initialValue: settings.localeIdentifier)
    }

    var body: some View {
        SettingsPage(title: "语音转文本", subtitle: "选择负责听懂录音的模型。", save: {
            settings.localeIdentifier = language
            dismiss()
        }) {
            VStack(spacing: 0) {
                ModelChoice(title: "Apple 端上转写", badge: "推荐 · 本机", description: "使用 iPhone 系统语音模型，无需 API Key。首次使用可能需要下载语言资源。", selected: true) {}
                Divider().overlay(NotesStyle.border)
                ModelChoice(title: "Whisper", badge: "尚未接入", description: "Tiny / Base / Small 多语言模型暂不可用，当前使用 Apple 端上转写。", selected: false) {}
                    .disabled(true).opacity(0.55)
            }
            .settingsCard()
            SettingsSection("识别语言") {
                HStack {
                    Text("录音语言").font(.system(size: 15))
                    Spacer()
                    Picker("录音语言", selection: $language) {
                        Text("普通话").tag("zh-CN")
                        Text("English").tag("en-US")
                    }
                    .pickerStyle(.menu).labelsHidden()
                }
                .padding(16).settingsCard()
                SettingsFootnote(text: "保存后用于新的转写任务，已有笔记保持原样。")
            }
            SettingsInfo(title: "音频留在本机", text: "Apple 模型的语言与设备支持情况，以这台 iPhone 的检测结果为准。")
        }
    }
}

struct AISettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var editor: AISettingsModel
    @State private var saveError: String?

    init(settings: AppSettings) { _editor = StateObject(wrappedValue: AISettingsModel(settings: settings)) }

    var body: some View {
        SettingsPage(title: "AI 模型", subtitle: "用来提炼要点，生成笔记总结。", canSave: editor.canSave, save: {
            do { try editor.save(); dismiss() }
            catch { saveError = error.localizedDescription }
        }) {
            VStack(spacing: 0) {
                ModelChoice(title: "Apple 本地模型", badge: "本机", description: "由 Apple Intelligence 提供。笔记文本在 iPhone 上处理，无需 API Key。", selected: editor.configuration.mode == .local) {
                    editor.configuration.mode = .local
                }
                Divider().overlay(NotesStyle.border)
                ModelChoice(title: "自定义模型", badge: "自有服务", description: "使用你的模型与 API Key，支持 OpenAI 兼容的 Chat Completions 接口。", selected: editor.configuration.mode == .custom) {
                    editor.configuration.mode = .custom
                }
            }
            .settingsCard()
            if editor.configuration.mode == .local {
                SettingsInfo(title: localAvailabilityTitle, text: "请在系统设置中启用并下载 Apple Intelligence 模型。可用性还取决于设备、语言及地区；不可用时不会自动切换远程服务。")
            } else {
                SettingsSection("连接配置") {
                    VStack(spacing: 0) {
                        configField("模型名称") {
                            TextField("例如 my-model", text: $editor.configuration.model)
                                .accessibilityLabel("模型名称")
                        }
                        Divider().overlay(NotesStyle.border)
                        configField("服务地址 · Base URL") {
                            TextField("https://api.example.com/v1", text: $editor.configuration.baseURL)
                                .keyboardType(.URL).accessibilityLabel("Base URL")
                        }
                        Divider().overlay(NotesStyle.border)
                        configField("API Key") {
                            SecureField("输入你的 API Key", text: $editor.apiKey)
                                .privacySensitive().accessibilityLabel("API Key")
                        }
                    }
                    .settingsCard()
                    SettingsFootnote(text: "总结时仅将笔记文本发送至此地址，原始录音不发送。API Key 保存在本机钥匙串中。")
                    Button { editor.startTest() } label: {
                        HStack(spacing: 9) {
                            if editor.state == .testing { ProgressView().tint(NotesStyle.red) }
                            Text(editor.state == .testing ? "正在测试连接…" : "测试连接")
                                .font(.system(size: 15, weight: .semibold))
                        }
                        .frame(maxWidth: .infinity).frame(height: 48)
                        .background(NotesStyle.field, in: RoundedRectangle(cornerRadius: 13))
                    }
                    .disabled(editor.state == .testing)
                    testStatus
                }
            }
            SettingsFootnote(text: "保存后用于下一次生成总结。返回会放弃未保存的修改。")
        }
        .onDisappear { editor.invalidateTest() }
        .alert("配置未保存", isPresented: Binding(get: { saveError != nil }, set: { if !$0 { saveError = nil } })) {
            Button("好") { saveError = nil }
        } message: { Text(saveError ?? "") }
    }

    private var localAvailabilityTitle: String {
        if case .available = SystemLanguageModel.default.availability,
           SystemLanguageModel.default.supportsLocale(Locale(identifier: "zh-CN")) { return "Apple 本地模型可用" }
        return "此设备的 Apple 本地模型暂不可用"
    }

    private func configField<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.system(size: 12)).foregroundStyle(Color.secondary)
            content().font(.system(size: 15)).foregroundStyle(Color.primary)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
                .submitLabel(.done)
        }
        .frame(maxWidth: .infinity, alignment: .leading).padding(16)
    }

    private var testStatus: some View {
        Group {
            switch editor.state {
            case .idle: Text("测试只发送固定测试文本。修改配置后需重新测试。").foregroundStyle(Color.secondary)
            case .testing: Text("正在验证地址、API Key 和模型，请稍候…").foregroundStyle(Color.secondary)
            case .success: Label("配置已验证，可以保存。", systemImage: "checkmark.circle.fill").foregroundStyle(NotesStyle.green)
            case .failure(let message): Label(message, systemImage: "exclamationmark.circle").foregroundStyle(NotesStyle.warning)
            }
        }
        .font(.system(size: 12)).lineSpacing(4)
        .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 4)
        .accessibilityElement(children: .combine)
    }
}

private struct SettingsPage<Content: View>: View {
    @Environment(\.dismiss) private var dismiss
    let title: String
    let subtitle: String
    var backTitle = "设置"
    var canSave = true
    var save: (() -> Void)? = nil
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button { dismiss() } label: { Label(backTitle, systemImage: "chevron.left") }
                Spacer()
                if let save { Button("保存", action: save).fontWeight(.semibold).disabled(!canSave) }
            }
            .font(.system(size: 16)).padding(.horizontal, 17).frame(height: 52)
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    VStack(alignment: .leading, spacing: 9) {
                        Text(title).font(.system(size: 32, weight: .bold)).accessibilityAddTraits(.isHeader)
                        Text(subtitle).font(.system(size: 13)).foregroundStyle(Color.secondary)
                    }
                    content
                }
                .padding(.horizontal, 22).padding(.top, 8).padding(.bottom, 44)
            }
            .scrollDismissesKeyboard(.interactively)
        }
        .background(NotesStyle.background)
        .tint(NotesStyle.red)
        .toolbar(.hidden, for: .navigationBar)
    }
}

private struct SettingsSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content
    init(_ title: String, @ViewBuilder content: () -> Content) { self.title = title; self.content = content() }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.system(size: 13, weight: .medium)).foregroundStyle(Color.secondary).padding(.leading, 4)
            content
        }
    }
}

private struct SettingsRow: View {
    let symbol: String
    let title: String
    let subtitle: String
    var body: some View {
        HStack(spacing: 13) {
            Image(systemName: symbol).font(.system(size: 20)).frame(width: 28).foregroundStyle(Color.secondary)
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(.system(size: 15, weight: .semibold)).foregroundStyle(Color.primary)
                Text(subtitle).font(.system(size: 12)).foregroundStyle(Color.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold)).foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 15).padding(.vertical, 18).contentShape(Rectangle())
    }
}

private struct ModelChoice: View {
    let title: String
    let badge: String
    let description: String
    let selected: Bool
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .font(.system(size: 20)).foregroundStyle(selected ? NotesStyle.red : .secondary)
                VStack(alignment: .leading, spacing: 9) {
                    HStack {
                        Text(title).font(.system(size: 15, weight: .semibold)).foregroundStyle(Color.primary)
                        Text(badge).font(.system(size: 10, weight: .medium)).foregroundStyle(Color.secondary)
                            .padding(.horizontal, 6).padding(.vertical, 3).background(NotesStyle.field, in: Capsule())
                    }
                    Text(description).font(.system(size: 12)).foregroundStyle(Color.secondary).lineSpacing(4)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(16).contentShape(Rectangle())
        }
        .buttonStyle(.plain).accessibilityAddTraits(selected ? .isSelected : [])
    }
}

private struct SettingsFootnote: View {
    let text: String
    var body: some View { Text(text).font(.system(size: 12)).foregroundStyle(Color.secondary).lineSpacing(4).padding(.horizontal, 4) }
}

private struct SettingsInfo: View {
    let title: String
    let text: String
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title).font(.system(size: 13, weight: .semibold))
            Text(text).font(.system(size: 12)).foregroundStyle(Color.secondary).lineSpacing(4)
        }
        .frame(maxWidth: .infinity, alignment: .leading).padding(15)
        .background(NotesStyle.field, in: RoundedRectangle(cornerRadius: 14))
    }
}

private extension View {
    func settingsCard() -> some View {
        self.background(NotesStyle.card, in: RoundedRectangle(cornerRadius: 18))
            .overlay(RoundedRectangle(cornerRadius: 18).stroke(NotesStyle.border, lineWidth: 1))
            .buttonStyle(.plain)
    }
}
