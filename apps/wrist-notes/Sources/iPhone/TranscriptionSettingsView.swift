import SwiftUI

struct TranscriptionSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var editor: TranscriptionSettingsModel
    @State private var saveError: String?

    init(settings: AppSettings) {
        _editor = StateObject(wrappedValue: TranscriptionSettingsModel(settings: settings, resources: .live()))
    }

    var body: some View {
        SettingsPage(title: "语音转写模型", subtitle: "先选择模型，再选择转写语言和离线资源。", canSave: editor.canSave, save: {
            do { try editor.save(); dismiss() } catch { saveError = error.localizedDescription }
        }) {
            VStack(spacing: 0) {
                ModelChoice(title: "iPhone端上转写", badge: "推荐 · 本机",
                    description: "iPhone系统语音模型，无需API Key，支持单语言转写，按需下载系统语言包",
                    selected: editor.configuration.engine == .apple) { editor.configuration.engine = .apple }
                ModelChoice(title: "Whisper", badge: "本机",
                    description: "下载多语言模型后离线转写，可指定语言或自动检测，无需逐语言下载。",
                    selected: editor.configuration.engine == .whisper) { editor.configuration.engine = .whisper }
            }
            VStack(alignment: .leading, spacing: 18) {
                if editor.configuration.engine == .apple {
                    DaybookSettingsField("转写语言") {
                        Menu {
                            Picker("转写语言", selection: $editor.configuration.appleLocale) {
                                if !editor.languages.contains(where: { $0.id == editor.configuration.appleLocale }) {
                                    Text("请选择语言").tag(editor.configuration.appleLocale)
                                }
                                ForEach(editor.languages) { Text($0.title).tag($0.id) }
                            }
                        } label: {
                            DaybookSettingsMenuLabel(text: editor.languages.first(where: { $0.id == editor.configuration.appleLocale })?.title ?? "请选择语言")
                        }.disabled(editor.languages.isEmpty).accessibilityLabel("转写语言")
                    }
                    SettingsFootnote(text: "一次选择一种语言。系统已有语言资源可以复用，缺少时按需下载。")
                        .padding(.top, -5)
                } else {
                    DaybookSettingsField("模型大小") {
                        Menu {
                            Picker("模型大小", selection: $editor.configuration.whisperSize) {
                                ForEach(TranscriptionConfiguration.WhisperSize.allCases, id: \.self) { Text($0.detail).tag($0) }
                            }
                        } label: { DaybookSettingsMenuLabel(text: editor.configuration.whisperSize.detail) }
                        .accessibilityLabel("模型大小")
                    }
                    DaybookSettingsField("转写语言") {
                        Menu {
                            Picker("转写语言", selection: $editor.configuration.whisperLanguage) {
                                Text("自动检测").tag("auto")
                                ForEach(TranscriptionConfiguration.whisperLanguageCodes, id: \.self) {
                                    Text(TranscriptionConfiguration.whisperLanguageName($0)).tag($0)
                                }
                            }
                        } label: {
                            DaybookSettingsMenuLabel(text: editor.configuration.whisperLanguage == "auto" ? "自动检测" : TranscriptionConfiguration.whisperLanguageName(editor.configuration.whisperLanguage))
                        }.accessibilityLabel("转写语言")
                    }
                    SettingsFootnote(text: "多语言模型下载一次，其支持的语言共用；切换语言不需要重新下载。更大模型通常占用更多存储与内存。")
                        .padding(.top, -5)
                    SettingsFootnote(text: "Tiny / Base / Small 下载约 80 MB / 150 MB / 490 MB。首次加载可能需要一些时间。")
                        .padding(.top, -9)
                }
            }.padding(.top, 18)
            resourceStatus.padding(.vertical, 20)
            SettingsFootnote(text: "资源就绪后可保存。请保持此页面打开直至下载完成；关闭或切换资源会取消当前下载，已完成的资源会保留。")
            SettingsFootnote(text: editor.configuration.engine == .apple
                ? "语言包由系统管理，音频留在本机。"
                : "模型来自 Hugging Face 上的 Argmax / OpenAI 公共仓库。下载后在本机转写，录音不会上传。")
                .padding(.top, 10)
        }
        .task { await editor.refresh() }
        .onChange(of: scenePhase) { _, phase in if phase == .active && !editor.isDownloading { editor.scheduleRefresh() } }
        .onDisappear { editor.cancel() }
        .alert("配置未保存", isPresented: Binding(get: { saveError != nil }, set: { if !$0 { saveError = nil } })) {
            Button("好") {}
        } message: { Text(saveError ?? "") }
    }

    private var resourceStatus: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(editor.configuration.resourceName + " · " + resourceStateTitle)
                .font(.system(size: 13, weight: .medium)).foregroundStyle(DaybookStyle.ink)
            switch editor.state {
            case .checking:
                HStack(spacing: 8) { ProgressView().controlSize(.small); Text("正在检查资源…") }
            case .ready:
                Text("可保存设置，应用于后续转写任务。").foregroundStyle(DaybookStyle.secondary)
            case .unavailable(let message):
                Text(message).foregroundStyle(DaybookStyle.secondary)
                Button("重新检查") { editor.scheduleRefresh() }.buttonStyle(DaybookSettingsButtonStyle())
            case .missing:
                Text("下载完成后才可保存。已有系统资源会直接复用。").foregroundStyle(DaybookStyle.secondary)
                downloadButton
            case .failed(let message):
                Text(message).foregroundStyle(DaybookStyle.red)
                Button("重新下载") { editor.startDownload() }.buttonStyle(DaybookSettingsButtonStyle())
            case .downloading(let progress):
                Text("正在下载，关闭页面或切换资源会取消。").foregroundStyle(DaybookStyle.secondary)
                if let fraction = progress.fraction {
                    ProgressView(value: max(0, min(1, fraction))).tint(DaybookStyle.accent).padding(.vertical, 6)
                    Text(fraction >= 1 ? "正在校验与安装…" : "正在下载 · \(Int(fraction * 100))%")
                } else { ProgressView("正在准备下载…").tint(DaybookStyle.accent) }
                if let completed = progress.completedBytes, let total = progress.totalBytes {
                    Text("\(ByteCountFormatter.string(fromByteCount: completed, countStyle: .file)) / \(ByteCountFormatter.string(fromByteCount: total, countStyle: .file))")
                        .foregroundStyle(DaybookStyle.secondary)
                }
                Button("取消下载") { editor.scheduleRefresh() }.buttonStyle(DaybookSettingsButtonStyle())
            }
        }
        .font(.system(size: 11)).lineSpacing(7)
        .frame(maxWidth: .infinity, alignment: .leading).padding(17)
        .background(DaybookStyle.blueSoft, in: RoundedRectangle(cornerRadius: 16))
        .accessibilityElement(children: .contain)
    }

    private var resourceStateTitle: String {
        switch editor.state {
        case .checking: "检查中"
        case .ready: "已就绪"
        case .unavailable: "暂不可用"
        case .missing: "尚未下载"
        case .failed: "下载失败"
        case .downloading: "正在下载"
        }
    }

    private var downloadButton: some View {
        Button(editor.configuration.engine == .apple ? "下载语言包" : "下载多语言模型") { editor.startDownload() }
            .buttonStyle(DaybookSettingsButtonStyle())
    }
}
