import SwiftUI
import AppKit

@MainActor final class CompanionDelegate: NSObject, NSApplicationDelegate {
    weak var model: CompanionModel?
    private var terminating = false
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !terminating else { return .terminateLater }
        guard let model else { return .terminateNow }
        terminating = true
        Task { await model.shutdown(); sender.reply(toApplicationShouldTerminate: true) }
        return .terminateLater
    }
}

@main struct WiseLifeCompanionApp: App {
    @NSApplicationDelegateAdaptor(CompanionDelegate.self) private var delegate
    @StateObject private var model: CompanionModel
    @Environment(\.openWindow) private var openWindow
    init() {
        #if DEBUG
        let preview = CommandLine.arguments.contains("--preview") || CommandLine.arguments.contains("--snapshot")
        #else
        let preview = false
        #endif
        _model = StateObject(wrappedValue: CompanionModel(preview: preview))
    }
    var body: some Scene {
        Window("WiseLife Mac Companion", id: "main") {
            CompanionView(model: model).task {
                delegate.model = model
                await snapshotIfRequested()
            }
        }.windowStyle(.hiddenTitleBar).defaultSize(width: 1120, height: 850)
            .commands {
                CommandGroup(replacing: .appSettings) { Button("模型库…") { show(); model.page = .models }.keyboardShortcut(",") }
                CommandMenu("本地 AI") {
                    Button("配对 iPhone…") { show(); model.openPairing() }
                    Button(model.available ? "暂停本地 AI 服务" : "开启本地 AI 服务") { model.changeAvailability(!model.available) }
                    Button("卸载模型") { model.unload() }.disabled(!model.ready)
                }
            }
        MenuBarExtra("WiseLife 本地 AI", systemImage: "sparkles") {
            Text(model.state.title)
            Text(model.serviceMessage)
            Divider()
            Button("打开 WiseLife Mac Companion") { show() }
            Button("配对 iPhone…") { show(); model.openPairing() }
            Button(model.available ? "暂停本地 AI 服务" : "开启本地 AI 服务") { model.changeAvailability(!model.available) }
            Button("卸载模型") { model.unload() }.disabled(!model.ready)
            Divider()
            Button("退出 WiseLife Mac Companion") { NSApp.terminate(nil) }.keyboardShortcut("q")
        }
    }
    private func show() { openWindow(id: "main"); NSApp.activate(ignoringOtherApps: true) }
    @MainActor private func snapshotIfRequested() async {
        #if DEBUG
        let arguments = CommandLine.arguments
        if let index = arguments.firstIndex(of: "--page"), arguments.count > index + 1,
           let page = CompanionModel.Page.allCases.first(where: { $0.rawValue == arguments[index + 1] }) { model.page = page }
        guard let index = arguments.firstIndex(of: "--snapshot"), arguments.count > index + 1 else { return }
        try? await Task.sleep(for: .seconds(1))
        guard let window = NSApp.windows.first(where: { $0.contentView != nil && $0.title == "WiseLife Mac Companion" }),
              let view = window.contentView, let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        if let data = bitmap.representation(using: .png, properties: [:]) { try? data.write(to: URL(fileURLWithPath: arguments[index + 1])) }
        NSApp.terminate(nil)
        #endif
    }
}
