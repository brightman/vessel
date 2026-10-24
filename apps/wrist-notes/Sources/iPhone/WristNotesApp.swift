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
    @State private var macPairingCode: String?
    @State private var showMacVerification = false
    @StateObject private var macVerification = NearbyMacSettingsModel()
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
                .environmentObject(WiseLifeRuntime.shared.content)
                .environmentObject(WiseLifeRuntime.shared.processing)
                .environmentObject(WiseLifeRuntime.shared.desktopSync)
                .environmentObject(model.settings)
                .environmentObject(recorder)
                .environmentObject(recording)
                .task { await WiseLifeRuntime.shared.prepare() }
                .onOpenURL { url in
                    if url.scheme == "wiselife-mac", url.host == "pair" { macPairingCode = url.absoluteString }
                    if url.scheme == "wiselife-mac", url.host == "settings" { macPairingCode = "" }
#if DEBUG
                    // Development acceptance hook: fixed synthetic text through the production provider, no user records.
                    if url.scheme == "wiselife-mac", url.host == "verify" {
                        showMacVerification = true; macPairingCode = nil
                        macVerification.verify(settings: model.settings)
                    }
#endif
                }
                .sheet(isPresented: Binding(get: { macPairingCode != nil || showMacVerification }, set: { if !$0 { macPairingCode = nil; showMacVerification = false } })) {
                    if showMacVerification { NearbyMacVerificationView(model: macVerification) }
                    else { AISettingsView(settings: model.settings, initialMacCode: macPairingCode ?? "", selectNearbyMac: true) }
                }
#if WISELIFE_EUREKA_RING
                .environmentObject(ring)
                .task { ring.configure(notes: model); await ring.foreground() }
#endif
        }
    }
}
