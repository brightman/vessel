import SwiftUI
import UIKit

/// HealthKit background launches must install their observer queries before launch finishes.
final class WiseLifeAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        _ = WiseLifeRuntime.shared.life
        return true
    }
}

@main
@MainActor
struct WristNotesApp: App {
    @UIApplicationDelegateAdaptor(WiseLifeAppDelegate.self) private var appDelegate
    @StateObject private var sessions = WiseLifeRuntime.shared.sessions
    @StateObject private var model = WiseLifeRuntime.shared.notes
    @StateObject private var recorder = WiseLifeRuntime.shared.recorder
    @StateObject private var recording = WiseLifeRuntime.shared.recording
    @StateObject private var appLock = AppLockModel()
#if WISELIFE_EUREKA_RING
    @StateObject private var ring = EurekaRingModel()
#endif

    init() {
#if DEBUG
        UIApplication.shared.isIdleTimerDisabled = true
#endif
    }

    var body: some Scene {
        WindowGroup {
            DaybookView()
                .opacity(appLock.phase == .unlocked ? 1 : 0)
                .allowsHitTesting(appLock.phase == .unlocked && !appLock.privacyCovered)
                .accessibilityHidden(appLock.phase != .unlocked || appLock.privacyCovered)
                .background(AppLockWindowBridge(model: appLock, colorScheme: model.settings.appearance.colorScheme))
                .environmentObject(appLock)
                .environmentObject(WiseLifeRuntime.shared.life)
                .environmentObject(model)
                .environmentObject(sessions)
                .environmentObject(WiseLifeRuntime.shared.content)
                .environmentObject(WiseLifeRuntime.shared.processing)
                .environmentObject(model.settings)
                .environmentObject(recorder)
                .environmentObject(recording)
                .task { await WiseLifeRuntime.shared.prepare() }
                .alert("App 密码", isPresented: Binding(get: { appLock.feedback != nil },
                    set: { if !$0 { appLock.feedback = nil } })) {
                    Button("好") { appLock.feedback = nil }
                } message: { Text(appLock.feedback ?? "") }
#if WISELIFE_EUREKA_RING
                .environmentObject(ring)
                .task { ring.configure(notes: model); await ring.foreground() }
#endif
        }
    }
}
