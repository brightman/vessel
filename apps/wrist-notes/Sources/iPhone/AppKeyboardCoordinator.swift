import Combine
import SwiftUI
import UIKit

/// One owner per app window, including its presented sheets and navigation destinations.
@MainActor final class AppKeyboardCoordinator: NSObject, ObservableObject, UIGestureRecognizerDelegate {
    @Published private(set) var isVisible = false
    private weak var window: UIWindow?
    private weak var editingViewAtTouch: UIView?
    private var observers: [NSObjectProtocol] = []
    private lazy var outsideTap: UITapGestureRecognizer = {
        let gesture = UITapGestureRecognizer(target: self, action: #selector(dismissFromOutsideTap))
        gesture.cancelsTouchesInView = false
        gesture.delaysTouchesBegan = false
        gesture.delaysTouchesEnded = false
        gesture.delegate = self
        return gesture
    }()

    func attach(to window: UIWindow) {
        guard self.window !== window else { return }
        detach()
        self.window = window
        window.addGestureRecognizer(outsideTap)
        for name in [UIResponder.keyboardWillChangeFrameNotification, UIResponder.keyboardWillHideNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
                MainActor.assumeIsolated { self?.keyboardChanged(notification) }
            })
        }
    }

    func detach() {
        window?.removeGestureRecognizer(outsideTap)
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
        editingViewAtTouch = nil; window = nil
        if isVisible { isVisible = false }
    }

    func dismiss() {
        // A navigation action may focus a new field after this call. The same tap
        // must not subsequently dismiss that newly focused field.
        editingViewAtTouch = nil
        window?.endEditing(true)
    }

    private func keyboardChanged(_ notification: Notification) {
        guard let window,
              (notification.userInfo?[UIResponder.keyboardIsLocalUserInfoKey] as? Bool) != false else { return }
        let visible: Bool
        if notification.name == UIResponder.keyboardWillHideNotification { visible = false }
        else if let frame = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect {
            let keyboard = window.convert(frame, from: window.screen.coordinateSpace)
            let overlap = window.bounds.intersection(keyboard)
            visible = !overlap.isNull && overlap.height > 0 && overlap.width > 0
        } else { return }
        if isVisible != visible { isVisible = visible }
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        editingViewAtTouch = nil
        guard let window, let responder = firstResponder(in: window) else { return false }
        var candidate = touch.view
        while let view = candidate {
            // Leave field focus changes, caret/selection gestures, system search,
            // and press-to-talk entirely with their own controls.
            if view is UITextInput || view is UISearchBar || view === responder
                || view.accessibilityIdentifier == "daybook.assistant.voice" { return false }
            if let accessory = responder.inputAccessoryView,
               view === accessory || view.isDescendant(of: accessory) { return false }
            candidate = view.superview
        }
        editingViewAtTouch = responder
        return true
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool { true }

    @objc private func dismissFromOutsideTap() {
        let responder = editingViewAtTouch
        editingViewAtTouch = nil
        // Never steal focus from a field that the tapped control just opened.
        if responder?.isFirstResponder == true { responder?.resignFirstResponder() }
    }

    private func firstResponder(in view: UIView) -> UIView? {
        if view.isFirstResponder { return view }
        for child in view.subviews { if let result = firstResponder(in: child) { return result } }
        return nil
    }
}

/// This view only attaches the window-level observer; it doesn't intercept hit testing.
struct AppKeyboardAttachment: UIViewRepresentable {
    let keyboard: AppKeyboardCoordinator
    func makeUIView(context: Context) -> AttachmentView { AttachmentView(keyboard: keyboard) }
    func updateUIView(_ uiView: AttachmentView, context: Context) {}
    static func dismantleUIView(_ uiView: AttachmentView, coordinator: ()) { uiView.keyboard?.detach() }

    final class AttachmentView: UIView {
        weak var keyboard: AppKeyboardCoordinator?
        init(keyboard: AppKeyboardCoordinator) {
            self.keyboard = keyboard
            super.init(frame: .zero)
            isUserInteractionEnabled = false
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override func didMoveToWindow() {
            super.didMoveToWindow()
            if let window { keyboard?.attach(to: window) } else { keyboard?.detach() }
        }
    }
}
