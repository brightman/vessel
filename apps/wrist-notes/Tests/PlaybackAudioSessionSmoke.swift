import Foundation

/// Only the OS session calls are substituted; ordering, cancellation and ownership use production code.
private final class SessionProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [String] = []
    private var capturing = false
    let activationEntered = DispatchSemaphore(value: 0)
    let finishActivation = DispatchSemaphore(value: 0)
    var blockActivation = false
    var failActivation = false
    var history: [String] { lock.withLock { events } }
    var captureIsActive: Bool { lock.withLock { capturing } }
    func beginCapture() { lock.withLock { capturing = true } }
    func endCapture() { lock.withLock { capturing = false } }
    func awaitActivation() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async { self.activationEntered.wait(); continuation.resume() }
        }
    }
    func activate() throws {
        precondition(!Thread.isMainThread, "audio activation must not block the main thread")
        lock.withLock { events.append("activate") }
        activationEntered.signal()
        if blockActivation { finishActivation.wait() }
        if failActivation { throw CocoaError(.fileReadUnknown) }
    }
    func deactivate() {
        precondition(!Thread.isMainThread, "audio deactivation must not block the main thread")
        lock.withLock { events.append("deactivate") }
    }
    func makeSession() -> PlaybackAudioSession {
        PlaybackAudioSession(captureIsActive: { self.captureIsActive },
                             activate: { try self.activate() }, deactivate: { self.deactivate() })
    }
}

@main struct PlaybackAudioSessionSmoke {
    static func main() async throws {
        // An unopened detail's stop must never deactivate another audio owner.
        let idle = SessionProbe(), idleSession = idle.makeSession()
        idleSession.release(PlaybackAudioSession.Lease())
        await idleSession.prepareForCapture()
        precondition(idle.history.isEmpty, "release without activation must be a no-op")

        // Once a newer player acquires the session, a stale stop cannot deactivate it.
        let probe = SessionProbe(), session = probe.makeSession()
        let first = PlaybackAudioSession.Lease(), second = PlaybackAudioSession.Lease()
        try await session.activate(first)
        try await session.activate(second)
        session.release(first)
        await session.prepareForCapture()
        precondition(probe.history == ["activate", "activate"], "stale owner deactivated newer playback")
        session.release(second)
        session.release(second)
        await session.prepareForCapture()
        precondition(probe.history == ["activate", "activate", "deactivate"], "release must be owned and idempotent")

        // A queued start cancelled before execution cannot activate after the detail disappears.
        let cancelled = PlaybackAudioSession.Lease()
        session.release(cancelled)
        do { try await session.activate(cancelled); preconditionFailure("cancelled start activated") }
        catch is CancellationError {}
        precondition(probe.history.count == 3)

        // A user can stop and immediately restart while the first OS activation is blocked.
        let restart = SessionProbe(); restart.blockActivation = true
        let restartSession = restart.makeSession(), stopped = PlaybackAudioSession.Lease()
        let oldStart = Task { try await restartSession.activate(stopped) }
        await restart.awaitActivation()
        restartSession.release(stopped)
        let replacement = PlaybackAudioSession.Lease()
        let newStart = Task { try await restartSession.activate(replacement) }
        restart.finishActivation.signal()
        restart.finishActivation.signal()
        do { try await oldStart.value; preconditionFailure("stopped activation succeeded") }
        catch is CancellationError {}
        try await newStart.value
        restartSession.release(stopped)
        await restartSession.prepareForCapture()
        precondition(restart.history == ["activate", "deactivate", "activate"],
                     "late stop deactivated the immediate replacement")
        restartSession.release(replacement)
        await restartSession.prepareForCapture()
        precondition(restart.history == ["activate", "deactivate", "activate", "deactivate"])

        // Capture intent starts while playback activation is in flight. The recorder waits until
        // that operation drains, and stale playback cleanup cannot deactivate the recorder.
        let handoff = SessionProbe(); handoff.blockActivation = true
        let handoffSession = handoff.makeSession(), pending = PlaybackAudioSession.Lease()
        let start = Task { try await handoffSession.activate(pending) }
        await handoff.awaitActivation()
        handoff.beginCapture()
        handoffSession.release(pending)
        let drained = Task { await handoffSession.prepareForCapture() }
        handoff.finishActivation.signal()
        do { try await start.value; preconditionFailure("cancelled in-flight start succeeded") }
        catch is CancellationError {}
        await drained.value
        do { try await handoffSession.activate(PlaybackAudioSession.Lease()); preconditionFailure("playback stole capture session") }
        catch is CancellationError {}
        precondition(handoff.history == ["activate"], "late playback release must preserve recording")
        // A permission prompt can be cancelled without ever configuring a recorder. The delayed
        // release must then relinquish idle playback rather than leave other apps ducked.
        handoff.endCapture()
        handoffSession.captureStateDidChange()
        await handoffSession.prepareForCapture()
        precondition(handoff.history == ["activate", "deactivate"], "cancelled recording intent leaked playback activation")

        // A failed activation must not leave an owner that later deactivates another session.
        let failed = SessionProbe(); failed.failActivation = true
        let failedSession = failed.makeSession(), failedLease = PlaybackAudioSession.Lease()
        do { try await failedSession.activate(failedLease); preconditionFailure("activation error swallowed") }
        catch is CocoaError {}
        failedSession.release(failedLease)
        await failedSession.prepareForCapture()
        precondition(failed.history == ["activate"])
        print("Playback session: passed (off-main transitions, idle/stale/idempotent release, cancelled start, rapid restart, capture handoff/cancellation, activation failure)")
    }
}
