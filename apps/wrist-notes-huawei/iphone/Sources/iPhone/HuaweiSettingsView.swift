import SwiftUI

struct HuaweiSettingsView: View {
    @EnvironmentObject private var model: NotesModel
    @Environment(\.dismiss) private var dismiss
    @AppStorage("appearance") private var appearance = "system"
    @Binding var showImporter: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section("外观") {
                    Picker("外观", selection: $appearance) {
                        Text("深色").tag("dark")
                        Text("浅色").tag("light")
                        Text("跟随系统").tag("system")
                    }.pickerStyle(.segmented)
                }
                Section {
                    LabeledContent("手表", value: "Huawei Watch GT 6")
                    Label("未连接", systemImage: "circle.fill").foregroundStyle(.secondary)
                } header: { Text("设备连接") } footer: {
                    Text("Wear Engine 尚未接入，此版本不能接收 GT 6 录音。")
                }
                Section {
                    LabeledContent("模型", value: "Apple 端上转写")
                    Picker("录音语言", selection: $model.localeIdentifier) {
                        Text("普通话").tag("zh-CN")
                        Text("English").tag("en-US")
                    }
                } header: { Text("语音转文本") } footer: {
                    Text("在 iPhone 上识别。首次使用可能需要下载 Apple 语言资源；设备或语言不支持时会保留原始录音。")
                }
                Section {
                    LabeledContent("摘要模型", value: "Apple 本地模型")
                } header: { Text("AI 模型") } footer: {
                    Text("需要 Apple Intelligence 已启用且模型可用。此基础版本尚未接入 Whisper 和自定义 AI 服务。")
                }
                Section {
                    Button("导入音频文件", systemImage: "square.and.arrow.down") {
                        dismiss()
                        // Wait for the sheet to dismiss before presenting Files.
                        Task { @MainActor in
                            try? await Task.sleep(for: .milliseconds(350))
                            showImporter = true
                        }
                    }
                }
            }
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
        }
        .preferredColorScheme(appearance == "system" ? nil : appearance == "light" ? .light : .dark)
    }
}
