import Combine
import SwiftUI
import UIKit

/// A separate opaque window also covers sheets and full-screen presentations.
/// The existing content and recording services stay alive beneath it.
struct AppLockWindowBridge: UIViewRepresentable {
    @ObservedObject var model: AppLockModel
    var colorScheme: ColorScheme?

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }
    func makeUIView(context: Context) -> AttachmentView {
        let view = AttachmentView()
        view.attach = { [weak coordinator = context.coordinator] window in coordinator?.attach(to: window) }
        return view
    }
    func updateUIView(_ view: AttachmentView, context: Context) {
        context.coordinator.colorScheme = colorScheme
        context.coordinator.refresh()
    }
    static func dismantleUIView(_ view: AttachmentView, coordinator: Coordinator) { coordinator.tearDown() }

    final class AttachmentView: UIView {
        var attach: ((UIWindow) -> Void)?
        override func didMoveToWindow() {
            super.didMoveToWindow()
            if let window { attach?(window) }
        }
    }

    @MainActor final class Coordinator {
        let model: AppLockModel
        weak var baseWindow: UIWindow?
        var lockWindow: UIWindow?
        var colorScheme: ColorScheme?
        private var renderedColorScheme: ColorScheme?
        private var hosting: UIHostingController<AnyView>?
        private var observation: AnyCancellable?
        private var notifications: [NSObjectProtocol] = []
        private var didStart = false
        init(model: AppLockModel) { self.model = model }

        func attach(to window: UIWindow) {
            guard lockWindow == nil, let scene = window.windowScene else { return }
            baseWindow = window
            let overlay = UIWindow(windowScene: scene)
            overlay.frame = scene.coordinateSpace.bounds
            overlay.windowLevel = .alert + 1
            overlay.backgroundColor = .systemBackground
            overlay.isOpaque = true
            let controller = UIHostingController(rootView: AnyView(root))
            hosting = controller
            renderedColorScheme = colorScheme
            overlay.rootViewController = controller
            overlay.rootViewController?.view.accessibilityViewIsModal = true
            lockWindow = overlay
            observation = model.objectWillChange.sink { [weak self] _ in
                DispatchQueue.main.async { self?.refresh() }
            }
            observe(UIApplication.willResignActiveNotification) { [weak self] in
                self?.model.willResignActive(); self?.refresh()
            }
            observe(UIApplication.didEnterBackgroundNotification) { [weak self] in
                self?.model.didEnterBackground(); self?.refresh()
            }
            observe(UIApplication.didBecomeActiveNotification) { [weak self] in
                self?.model.didBecomeActive(); self?.refresh()
            }
            if UIApplication.shared.applicationState == .active { model.didBecomeActive() }
            refresh()
            if !didStart { didStart = true; Task { await model.load() } }
        }

        private var root: some View {
            AppLockWindowContent(model: model).preferredColorScheme(colorScheme)
        }
        func refresh() {
            guard let lockWindow else { return }
            if renderedColorScheme != colorScheme {
                hosting?.rootView = AnyView(root)
                renderedColorScheme = colorScheme
            }
            let shouldShow = model.privacyCovered || model.phase != .unlocked
            if shouldShow {
                if lockWindow.isHidden {
                    baseWindow?.endEditing(true)
                    lockWindow.makeKeyAndVisible()
                }
            } else if !lockWindow.isHidden {
                lockWindow.isHidden = true
                baseWindow?.makeKey()
            }
        }
        private func observe(_ name: Notification.Name, action: @escaping @MainActor () -> Void) {
            notifications.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { action() }
            })
        }
        func tearDown() {
            observation?.cancel()
            notifications.forEach(NotificationCenter.default.removeObserver)
            lockWindow?.isHidden = true; lockWindow = nil
            hosting = nil
        }
    }
}

private struct AppLockWindowContent: View {
    @ObservedObject var model: AppLockModel
    var body: some View {
        Group {
            if model.privacyCovered {
                VStack(spacing: 18) {
                    WiseLifeMark(ink: DaybookStyle.accent).frame(width: 72, height: 72)
                    Text("WiseLife").font(.system(size: 20, weight: .semibold))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                switch model.phase {
                case .onboarding:
                    AppPasscodeEditor(model: model, mode: .setup, allowsSkip: true)
                case .locked:
                    AppPasscodeUnlockView(model: model).id(model.lockCycle)
                case .loading:
                    ProgressView("正在准备…").frame(maxWidth: .infinity, maxHeight: .infinity)
                case .unavailable:
                    VStack(spacing: 18) {
                        Image(systemName: "lock.shield").font(.system(size: 40)).foregroundStyle(DaybookStyle.accent)
                        Text("暂时无法读取密码").font(.title3.bold())
                        Text(model.message ?? "请解锁设备后重试。").font(.subheadline).foregroundStyle(.secondary)
                        Button("重试") { Task { await model.load() } }.buttonStyle(.borderedProminent)
                    }.padding(32).frame(maxWidth: .infinity, maxHeight: .infinity)
                case .unlocked: Color.clear
                }
            }
        }
        .background(DaybookStyle.paper.ignoresSafeArea())
        .tint(DaybookStyle.accent)
    }
}
