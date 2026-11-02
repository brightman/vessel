import SwiftUI
import Translation

// Foreground-only diagnostic app. Apple's sheet owns consent and asset downloads.
// It translates no personal records and is not part of the WiseLife app target.
@main
struct AppleTranslationResourceHelper: App {
    var body: some Scene {
        WindowGroup("WiseLife 翻译实验") { ResourceView() }
            .defaultSize(width: 520, height: 300)
    }
}

private struct ResourceView: View {
    @State private var configuration: TranslationSession.Configuration?
    @State private var message = "准备 Apple 中英离线翻译资源"
    @State private var running = false
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Apple 端上翻译实验").font(.title2.bold())
            Text("下载系统语言包后，测试问题在本机翻译。不会读取 WiseLife 的个人记录。")
            Text(message).textSelection(.enabled)
            Button("准备中英翻译语言包") {
                running = true
                if configuration != nil { configuration?.invalidate() }
                else { configuration = .init(source: Locale.Language(identifier: "en"), target: Locale.Language(identifier: "zh-Hans")) }
            }.disabled(running)
        }
        .padding(28)
        .task {
            // Launching this explicit resource-preparation helper is the action
            // requesting the system consent sheet; no background query uses it.
            running = true
            configuration = .init(source: Locale.Language(identifier: "en"), target: Locale.Language(identifier: "zh-Hans"))
        }
        .translationTask(configuration) { session in
            do {
                message = "正在准备语言包…"
                try await session.prepareTranslation()
                let availability = LanguageAvailability()
                let forward = await availability.status(from: Locale.Language(identifier: "en"), to: Locale.Language(identifier: "zh-Hans"))
                let reverse = await availability.status(from: Locale.Language(identifier: "zh-Hans"), to: Locale.Language(identifier: "en"))
                message = "英文 → 中文：\(forward)\n中文 → 英文：\(reverse)"
            } catch { message = "准备失败：\(error.localizedDescription)" }
            running = false
        }
    }
}
