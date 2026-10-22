import SwiftUI

struct DaybookSemanticSettingsView: View {
    @State private var language = AppleDaybookEmbedding.selectedLanguage
    @State private var status = ""
    @State private var canDownload = false
    @State private var busy = false
    @State private var confirmingClear = false
    var body: some View {
        SettingsSection("本地语义检索") {
            VStack(alignment: .leading, spacing: 14) {
                Picker("检索语言", selection: $language) {
                    Text("简体中文").tag("zh-Hans")
                    Text("English").tag("en")
                    Text("繁體中文").tag("zh-Hant")
                    Text("日本語").tag("ja")
                }.disabled(busy)
                Text(status).font(.footnote).foregroundStyle(.secondary)
                if canDownload {
                    Button("下载 Apple 语言资源") {
                        busy = true; status = "正在请求 Apple 语言资源…"
                        let requested = language
                        Task { status = await AppleDaybookEmbedding.download(language: requested); busy = false; canDownload = AppleDaybookEmbedding.resourceStatus(language: requested).canDownload; DaybookSemanticResourceChange.downloadCompleted.publish() }
                    }.disabled(busy)
                }
                HStack {
                    Button("刷新资源状态") { refresh(); DaybookSemanticResourceChange.refreshed.publish() }
                    Button("重建索引") { reset(change: .rebuilt) }
                    Button("清除索引", role: .destructive) { confirmingClear = true }
                }.font(.footnote).disabled(busy)
                Text("只在本机检索所选日期、所选语言和允许 AI 读取的原文。每条最多索引前 1,800 字，每次最多处理 128 条；不会跨语言检索。缺少资源或检索失败时使用关键词。原始转写和图片文字保留完整。")
                    .font(.footnote).foregroundStyle(.secondary)
                Text("清除只删除计算出的索引，保留原记录及 Apple 管理的语言资源。重建会更新当前检索，或在下次搜索或问答时逐步完成。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }.onAppear { refresh() }
            .onChange(of: language) { _, value in
                UserDefaults.standard.set(value, forKey: AppleDaybookEmbedding.languageKey)
                reset(change: .languageChanged)
            }
            .confirmationDialog("清除本地语义索引？", isPresented: $confirmingClear, titleVisibility: .visible) {
                Button("清除索引", role: .destructive) { reset(change: .cleared) }
            }
    }
    private func refresh() {
        let resource = AppleDaybookEmbedding.resourceStatus(language: language)
        status = resource.message; canDownload = resource.canDownload
    }
    private func reset(change: DaybookSemanticResourceChange) {
        let rebuild = change != .cleared
        busy = true
        DaybookSemanticResourceChange.resetStarted.publish()
        Task {
            do {
                try await DaybookSemanticIndex.shared.clear()
                refresh(); status += rebuild ? "；将在当前或下次检索时重建索引。" : "；索引已清除。"
            } catch { status = "索引操作失败；继续使用关键词。请稍后重试。" }
            busy = false
            change.publish()
        }
    }
}
