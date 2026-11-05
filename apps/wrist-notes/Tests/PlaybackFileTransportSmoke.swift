import Foundation

private final class FilePlayerProbe: PlaybackFilePlaying, @unchecked Sendable {
    private let lock = NSLock()
    private var events: [String] = []
    private var position = 0.0
    private var playing = false
    private var finished = false
    let preparationEntered = DispatchSemaphore(value: 0), finishPreparation = DispatchSemaphore(value: 0)
    let pauseEntered = DispatchSemaphore(value: 0), finishPause = DispatchSemaphore(value: 0)
    var blockPreparation = false, blockPause = false, failPlay = false
    var history: [String] { lock.withLock { events } }
    var duration: TimeInterval { precondition(!Thread.isMainThread); return 10 }
    var currentTime: TimeInterval {
        get { precondition(!Thread.isMainThread); return lock.withLock { position } }
        set { precondition(!Thread.isMainThread); lock.withLock { position = newValue } }
    }
    var isPlaying: Bool { precondition(!Thread.isMainThread); return lock.withLock { playing } }
    var didFinish: Bool { lock.withLock { finished } }
    func finishNaturally() { lock.withLock { finished = true; playing = false; position = 0 } }
    func prepareToPlay() -> Bool {
        precondition(!Thread.isMainThread); lock.withLock { events.append("prepare") }
        preparationEntered.signal()
        if blockPreparation { finishPreparation.wait() }
        return true
    }
    func play() -> Bool {
        precondition(!Thread.isMainThread)
        return lock.withLock { events.append("play"); playing = !failPlay; finished = false; return playing }
    }
    func pause() {
        precondition(!Thread.isMainThread)
        lock.withLock { events.append("pause"); playing = false; position = 7 }
        pauseEntered.signal()
        if blockPause { finishPause.wait() }
    }
    func stop() { precondition(!Thread.isMainThread); lock.withLock { events.append("stop"); playing = false } }
    func awaitPreparation() async { await wait(preparationEntered) }
    func awaitPause() async { await wait(pauseEntered) }
    private func wait(_ semaphore: DispatchSemaphore) async {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async { semaphore.wait(); continuation.resume() }
        }
    }
}

@main struct PlaybackFileTransportSmoke {
    @MainActor static func until(_ condition: () -> Bool) async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !condition(), ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(1)) }
        precondition(condition(), "async playback did not settle")
    }
    @MainActor static func main() async throws {
        var completion = PlaybackFileCompletion()
        completion.start(position: 4, now: 100)
        precondition(!completion.didFinish(isPlaying: false, position: 4.2, duration: 10, now: 100.2), "an interrupted nonzero clock is not EOF")
        precondition(!completion.didFinish(isPlaying: false, position: 0, duration: 10, now: 100.2), "an early stopped clock cannot rewind the listening point")
        completion.interrupt()
        precondition(!completion.didFinish(isPlaying: false, position: 0, duration: 10, now: 120), "long interruptions must not become EOF")
        completion.start(position: 4.2, now: 120)
        precondition(completion.didFinish(isPlaying: false, position: 0, duration: 10, now: 126), "natural EOF after resumed remaining audio must complete")
        completion.pause()
        precondition(!completion.didFinish(isPlaying: false, position: 0, duration: 10, now: 130), "explicit pause cannot become EOF")
        let beforePlay = completion.interruptionGeneration
        completion.interrupt()
        completion.start(position: 4.2, now: 130, expectedInterruptionGeneration: beforePlay)
        precondition(completion.interrupted && !completion.didFinish(isPlaying: false, position: 0, duration: 10, now: 150),
                     "an interruption during hardware start must survive its late successful return")
        let file = FilePlayerProbe()
        let session = PlaybackAudioSession(captureIsActive: { false }, activate: {}, deactivate: {}, makeFilePlayer: { _ in file })
        let lease = PlaybackAudioSession.Lease(), url = URL(fileURLWithPath: "/unused-synthetic-audio")
        let started = try await session.startFile(lease, url: url)
        precondition(started.isPlaying && started.position == 0 && started.duration == 10)
        let paused = await withCheckedContinuation { continuation in session.pauseFile(lease) { continuation.resume(returning: $0) } }
        precondition(paused?.position == 7 && paused?.isPlaying == false)
        let resumed = try await session.startFile(lease, url: url)
        precondition(resumed.position == 7 && file.history == ["prepare", "play", "pause", "play"], "resume reuses the prepared queue-owned player")
        file.finishNaturally()
        let finished = await withCheckedContinuation { continuation in session.fileSnapshot(lease) { continuation.resume(returning: $0) } }
        precondition(finished?.position == 10 && finished?.isPlaying == false, "natural completion must display duration even if the audio player rewinds its clock")
        let replay = try await session.startFile(lease, url: url)
        precondition(replay.position == 0 && replay.isPlaying, "replay after completion must restart at the beginning")
        session.release(lease)
        let stoppedSnapshot = await withCheckedContinuation { continuation in session.fileSnapshot(lease) { continuation.resume(returning: $0) } }
        precondition(stoppedSnapshot == nil && file.history.last == "stop", "stopped leases cannot publish snapshots")

        let blocked = FilePlayerProbe(); blocked.blockPreparation = true
        let blockedSession = PlaybackAudioSession(captureIsActive: { false }, activate: {}, deactivate: {}, makeFilePlayer: { _ in blocked })
        let cancelled = PlaybackAudioSession.Lease()
        let pending = Task { try await blockedSession.startFile(cancelled, url: url) }
        await blocked.awaitPreparation()
        blockedSession.release(cancelled)
        blocked.finishPreparation.signal()
        do { _ = try await pending.value; preconditionFailure("cancelled preparation started audio") }
        catch is CancellationError {}
        await blockedSession.prepareForCapture()
        precondition(blocked.history == ["prepare", "stop"], "cancelled preparation must stop hardware before a capture barrier completes")

        // Exercise actual AudioPlayback generation guards: old pause returns after another file
        // starts preparing. It must not change the new file's position while its start is pending.
        let old = FilePlayerProbe(); old.blockPause = true
        let next = FilePlayerProbe(); next.blockPreparation = true
        let uiSession = PlaybackAudioSession(captureIsActive: { false }, activate: {}, deactivate: {},
                                            makeFilePlayer: { $0.lastPathComponent == "old" ? old : next })
        let playback = AudioPlayback(session: uiSession, captureIsActive: { false })
        await playback.load(URL(fileURLWithPath: "/old"), fallbackDuration: 10)
        playback.toggle(); await until { playback.isPlaying }
        playback.toggle(); await old.awaitPause()
        playback.stop()
        await playback.load(URL(fileURLWithPath: "/next"), fallbackDuration: 10)
        playback.toggle()
        old.finishPause.signal()
        await next.awaitPreparation()
        for _ in 0..<30 { await Task.yield() }
        precondition(playback.position == 0 && !playback.isPlaying, "late pause snapshot changed the replacement player")
        next.finishPreparation.signal()
        await until { playback.isPlaying }
        playback.stop(); await uiSession.prepareForCapture()

        let failing = FilePlayerProbe(); failing.failPlay = true
        let failureSession = PlaybackAudioSession(captureIsActive: { false }, activate: {}, deactivate: {}, makeFilePlayer: { _ in failing })
        let failedPlayback = AudioPlayback(session: failureSession, captureIsActive: { false })
        await failedPlayback.load(url, fallbackDuration: 10)
        failedPlayback.toggle(); await until { failedPlayback.error != nil }
        await failureSession.prepareForCapture()
        precondition(!failedPlayback.isPlaying && failing.history == ["prepare", "play", "stop"], "play failure must clean up the active lease")
        print("File playback transport: passed (all hardware/reads off-main, pause/resume, cancelled preparation, capture barrier, stale snapshots, play failure)")
    }
}
