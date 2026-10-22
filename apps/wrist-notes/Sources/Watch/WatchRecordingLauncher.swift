import Combine
import Foundation

@MainActor
final class WatchRecordingLauncher: ObservableObject {
    enum Phase { case active, inactive, background }
    enum Permission { case granted, denied, undetermined }
    enum Failure { case microphoneDenied, requestExpired }

    private struct Request {
        var deadline: TimeInterval
        var authorization: Permission?
    }
    private let isRecording: () -> Bool
    private let permission: () -> Permission
    private let requestPermission: (@escaping @MainActor (Bool) -> Void) -> Void
    private let startRecording: () -> Void
    private let reportFailure: (Failure) -> Void
    private let now: () -> TimeInterval
    private var phase: Phase = .inactive
    private var pending: Request?
    private var permissionInFlight = false
    private let activationWindow: TimeInterval = 10

    init(isRecording: @escaping () -> Bool,
         permission: @escaping () -> Permission,
         requestPermission: @escaping (@escaping @MainActor (Bool) -> Void) -> Void,
         startRecording: @escaping () -> Void,
         reportFailure: @escaping (Failure) -> Void,
         now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.isRecording = isRecording
        self.permission = permission
        self.requestPermission = requestPermission
        self.startRecording = startRecording
        self.reportFailure = reportFailure
        self.now = now
    }

    /// A deliberate widget launch can arrive before the cold-start scene becomes active.
    /// This route has no stop action: the app's recording button owns stopping/saving.
    @discardableResult
    func open(_ url: URL, phase: Phase) -> Bool {
        guard WatchRecordingLink.matches(url) else { return false }
        self.phase = phase
        guard !isRecording() else { pending = nil; return true }
        if pending == nil || (!permissionInFlight && now() > pending!.deadline) {
            pending = Request(deadline: now() + activationWindow)
        }
        drain()
        return true
    }

    func setPhase(_ phase: Phase) {
        self.phase = phase
        // Inactive can mean the system microphone prompt. Background means the user left.
        if phase == .background { pending = nil }
        drain()
    }

    private func drain() {
        guard phase == .active, let request = pending else { return }
        guard !isRecording() else { pending = nil; return }
        guard permissionInFlight || now() <= request.deadline else {
            pending = nil
            reportFailure(.requestExpired)
            return
        }
        switch request.authorization ?? permission() {
        case .granted:
            pending = nil // Consume before starting; lifecycle changes cannot replay the URL.
            startRecording()
        case .denied:
            pending = nil
            reportFailure(.microphoneDenied)
        case .undetermined:
            guard !permissionInFlight else { return }
            permissionInFlight = true
            requestPermission { [weak self] granted in
                guard let self else { return }
                self.permissionInFlight = false
                // No pending request after backgrounding: granting permission must not record.
                // A new, deliberate tap while the prompt is outstanding may reuse its result.
                guard self.pending != nil else { return }
                self.pending?.authorization = granted ? .granted : .denied
                self.pending?.deadline = self.now() + self.activationWindow
                self.drain()
            }
        }
    }
}
