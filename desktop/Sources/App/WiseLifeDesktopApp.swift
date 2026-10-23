import SwiftUI
import AppKit

final class DesktopAppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

@main struct WiseLifeDesktopApp: App {
    @NSApplicationDelegateAdaptor(DesktopAppDelegate.self) private var delegate
    @StateObject private var model: DesktopModel
    @Environment(\.openWindow) private var openWindow
    init() {
        #if DEBUG
        let preview = ProcessInfo.processInfo.arguments.contains("--preview") || ProcessInfo.processInfo.arguments.contains("--snapshot")
        #else
        let preview = false
        #endif
        _model = StateObject(wrappedValue: DesktopModel(preview: preview))
    }
    var body: some Scene {
        WindowGroup("WiseLife", id: "main") {
            DesktopLibraryView(model: model)
                .task { await snapshotIfRequested() }
        }.windowStyle(.hiddenTitleBar).defaultSize(width: 1300, height: 850)
            .commands {
                CommandGroup(replacing: .appSettings) { Button("AI 模型设置…") { model.showModelSettings = true }.keyboardShortcut(",") }
                CommandMenu("同步") { Button("同步与配对…") { model.showPairing = true }; Button("刷新记录") { model.refresh() }.keyboardShortcut("r") }
            }
        MenuBarExtra("WiseLife", systemImage: "book.pages") {
            Button("打开 WiseLife") { openWindow(id: "main"); NSApp.activate(ignoringOtherApps: true) }
            Button("同步与配对") { openWindow(id: "main"); model.showPairing = true; NSApp.activate(ignoringOtherApps: true) }
            Text(model.serverStatus)
            Divider()
            Button("退出 WiseLife") { model.shutdown(); NSApp.terminate(nil) }.keyboardShortcut("q")
        }
    }
    @MainActor private func snapshotIfRequested() async {
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "--snapshot"), arguments.count > index + 1 else { return }
        do { try await Task.sleep(nanoseconds: 1_000_000_000) } catch { return }
        guard let window = NSApp.windows.first(where: { $0.contentView != nil }), let view = window.contentView,
              let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        if let data = bitmap.representation(using: .png, properties: [:]) { try? data.write(to: URL(fileURLWithPath: arguments[index + 1])) }
        NSApp.terminate(nil)
        #endif
    }
}
