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
struct WristNotesApp: App {
    @UIApplicationDelegateAdaptor(WiseLifeAppDelegate.self) private var appDelegate
    @StateObject private var sessions = WiseLifeRuntime.shared.sessions
    @StateObject private var model = WiseLifeRuntime.shared.notes
    @StateObject private var recorder = WiseLifeRuntime.shared.recorder
    @StateObject private var recording = WiseLifeRuntime.shared.recording
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
                .environmentObject(WiseLifeRuntime.shared.life)
                .environmentObject(model)
                .environmentObject(sessions)
                .environmentObject(model.settings)
                .environmentObject(recorder)
                .environmentObject(recording)
                .task { await WiseLifeRuntime.shared.prepare() }
#if WISELIFE_EUREKA_RING
                .environmentObject(ring)
                .task { ring.configure(notes: model); await ring.foreground() }
#endif
        }
    }
}
