import SwiftUI
import UIKit
import LocalAuthentication

@MainActor
final class FaceIDLockCoordinator: ObservableObject {
    @Published private(set) var isLocked: Bool
    @Published private(set) var isAuthenticating = false
    @Published private(set) var errorMessage: String?

    private let settings: AppSettings
    private var handledInitialForeground = false

    init(settings: AppSettings) {
        self.settings = settings
        isLocked = settings.requiresFaceID
    }

    func setEnabled(_ enabled: Bool) async {
        errorMessage = nil
        guard !isAuthenticating else { return }
        if !enabled {
            settings.requiresFaceID = false
            isLocked = false
            return
        }
        guard !settings.requiresFaceID else { return }

        guard await authenticate(reason: localized("Enable Face ID for WiseLife"), requireFaceID: true) else { return }
        settings.requiresFaceID = true
        isLocked = false
    }

    func handleInitialForeground() async {
        guard !handledInitialForeground else { return }
        handledInitialForeground = true
        guard settings.requiresFaceID else { return }
        isLocked = true
        _ = await authenticate(reason: localized("Unlock WiseLife"), requireFaceID: false)
    }

    func retryUnlock() async {
        guard isLocked, !isAuthenticating else { return }
        _ = await authenticate(reason: localized("Unlock WiseLife"), requireFaceID: false)
    }

    private func authenticate(reason: String, requireFaceID: Bool) async -> Bool {
        let context = LAContext()
        if requireFaceID {
            var error: NSError?
            guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error),
                  context.biometryType == .faceID else {
                errorMessage = "Face ID is unavailable. Set up Face ID in iPhone Settings and try again."
                return false
            }
        }

        isAuthenticating = true
        defer { isAuthenticating = false }
        do {
            let accepted = try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)
            guard accepted else {
                errorMessage = "Authentication was not completed. Try again."
                return false
            }
            errorMessage = nil
            if !requireFaceID { isLocked = false }
            return true
        } catch {
            errorMessage = "Authentication was not completed. Try again."
            return false
        }
    }

    private func localized(_ key: String) -> String {
        String(localized: String.LocalizationValue(key), locale: settings.interfaceLanguage.locale)
    }
}

private struct FaceIDLockGate<Content: View>: View {
    @ObservedObject var coordinator: FaceIDLockCoordinator
    @Environment(\.scenePhase) private var scenePhase
    @ViewBuilder var content: Content

    init(coordinator: FaceIDLockCoordinator, @ViewBuilder content: () -> Content) {
        self.coordinator = coordinator
        self.content = content()
    }

    var body: some View {
        ZStack {
            if coordinator.isLocked {
                FaceIDUnlockView(coordinator: coordinator)
            } else {
                content
            }
            if scenePhase != .active {
                ZStack {
                    DaybookStyle.paper.ignoresSafeArea()
                    VStack(spacing: 12) {
                        Image(systemName: "lock.shield.fill").font(.system(size: 34)).foregroundStyle(DaybookStyle.accent)
                        Text("WiseLife is protected").font(.system(size: 15, weight: .semibold))
                    }
                }.frame(maxWidth: .infinity, maxHeight: .infinity).zIndex(2)
            }
        }
        .task(id: scenePhase) {
            guard scenePhase == .active else { return }
            await coordinator.handleInitialForeground()
        }
    }
}

private struct FaceIDUnlockView: View {
    @ObservedObject var coordinator: FaceIDLockCoordinator

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "faceid").font(.system(size: 46, weight: .light)).foregroundStyle(DaybookStyle.accent)
            Text("Unlock WiseLife").font(.system(size: 23, weight: .semibold))
            Text("Authenticate to view your records.").font(.system(size: 13)).foregroundStyle(DaybookStyle.secondary)
            if let errorMessage = coordinator.errorMessage {
                Text(LocalizedStringKey(errorMessage)).font(.system(size: 12)).foregroundStyle(.orange)
                    .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            }
            Button {
                Task { await coordinator.retryUnlock() }
            } label: {
                if coordinator.isAuthenticating {
                    ProgressView().tint(.white).frame(maxWidth: .infinity).frame(height: 22)
                } else {
                    Label("Unlock with Face ID", systemImage: "faceid").frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(.borderedProminent).tint(DaybookStyle.accent).disabled(coordinator.isAuthenticating)
            .frame(maxWidth: 250)
        }
        .padding(28).frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(DaybookStyle.paper.ignoresSafeArea()).foregroundStyle(DaybookStyle.ink)
    }
}

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
    @StateObject private var appLock = FaceIDLockCoordinator(settings: WiseLifeRuntime.shared.notes.settings)
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
            FaceIDLockGate(coordinator: appLock) {
            DaybookView()
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
#if WISELIFE_EUREKA_RING
                .environmentObject(ring)
                .task { ring.configure(notes: model); await ring.foreground() }
#endif
            }
        }
    }
}
