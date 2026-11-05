import Foundation
#if os(iOS)
import AVFAudio
#endif

/// Implementations are accessed only on PlaybackAudioSession's serial queue.
protocol PlaybackFilePlaying: AnyObject, Sendable {
    var duration: TimeInterval { get }
    var currentTime: TimeInterval { get set }
    var isPlaying: Bool { get }
    var didFinish: Bool { get }
    func prepareToPlay() -> Bool
    func play() -> Bool
    func pause()
    func stop()
}

struct PlaybackFileSnapshot: Sendable {
    let duration: TimeInterval
    let position: TimeInterval
    let isPlaying: Bool
}

/// A stopped hardware clock is not necessarily EOF: interruptions preserve the listening point.
struct PlaybackFileCompletion {
    private var startedAt: TimeInterval?
    private var startPosition: TimeInterval = 0
    private(set) var interrupted = false
    private(set) var interruptionGeneration = 0
    mutating func start(position: TimeInterval, now: TimeInterval, expectedInterruptionGeneration: Int? = nil) {
        if let expectedInterruptionGeneration, expectedInterruptionGeneration != interruptionGeneration { return }
        startedAt = now; startPosition = position; interrupted = false
    }
    mutating func pause() { startedAt = nil }
    mutating func interrupt() { interruptionGeneration &+= 1; interrupted = true }
    func didFinish(isPlaying: Bool, position: TimeInterval, duration: TimeInterval, now: TimeInterval) -> Bool {
        guard !isPlaying, !interrupted, let startedAt, duration > 0 else { return false }
        if position >= duration { return true }
        // AVAudioPlayer normally rewinds to zero at EOF. Do not treat an early stopped clock as
        // completion while an interruption notification is still being delivered.
        return position == 0 && now - startedAt >= max(0, duration - startPosition - 0.02)
    }
}

/// Serializes the blocking OS calls without making a disappearing view wait for audio hardware.
/// A lease is cancelled synchronously, before its queued start can run or publish playback state.
final class PlaybackAudioSession: @unchecked Sendable {
    final class Lease: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false
        var isCancelled: Bool { lock.withLock { cancelled } }
        func cancel() { lock.withLock { cancelled = true } }
    }

    private let queue = DispatchQueue(label: "WiseLife.playback-audio-session", qos: .userInitiated)
    private let captureIsActive: @Sendable () -> Bool
    private let activateSession: @Sendable () throws -> Void
    private let deactivateSession: @Sendable () -> Void
    private let makeFilePlayer: (@Sendable (URL) throws -> any PlaybackFilePlaying)?
    private var captureObserver: NSObjectProtocol?
    // Accessed exclusively on queue.
    private var owner: Lease?
    private var filePlayers: [ObjectIdentifier: any PlaybackFilePlaying] = [:]

    init(captureIsActive: @escaping @Sendable () -> Bool,
         activate: @escaping @Sendable () throws -> Void,
         deactivate: @escaping @Sendable () -> Void,
         makeFilePlayer: (@Sendable (URL) throws -> any PlaybackFilePlaying)? = nil) {
        self.captureIsActive = captureIsActive
        activateSession = activate
        deactivateSession = deactivate
        self.makeFilePlayer = makeFilePlayer
    }

    func activate(_ lease: Lease) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                do {
                    guard !lease.isCancelled, !self.captureIsActive() else { throw CancellationError() }
                    try self.activateSession()
                    self.owner = lease
                    guard !lease.isCancelled, !self.captureIsActive() else { throw CancellationError() }
                    continuation.resume()
                } catch { continuation.resume(throwing: error) }
            }
        }
    }

    func release(_ lease: Lease) {
        lease.cancel()
        queue.async {
            self.filePlayers[ObjectIdentifier(lease)]?.stop(); self.filePlayers[ObjectIdentifier(lease)] = nil
            guard self.owner === lease else { return }
            // Capture intent is registered before the recorder waits for this queue to drain.
            self.releaseCancelledOwner()
        }
    }

    func startFile(_ lease: Lease, url: URL) async throws -> PlaybackFileSnapshot {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    guard !lease.isCancelled, !self.captureIsActive() else { throw CancellationError() }
                    try self.activateSession()
                    self.owner = lease
                    guard !lease.isCancelled, !self.captureIsActive() else { throw CancellationError() }
                    if self.filePlayers[ObjectIdentifier(lease)] == nil {
                        guard let makeFilePlayer = self.makeFilePlayer else { throw CocoaError(.featureUnsupported) }
                        self.filePlayers[ObjectIdentifier(lease)] = try makeFilePlayer(url)
                        guard self.filePlayers[ObjectIdentifier(lease)]?.prepareToPlay() == true else { throw CocoaError(.fileReadUnknown) }
                    }
                    guard !lease.isCancelled, !self.captureIsActive(), let player = self.filePlayers[ObjectIdentifier(lease)] else { throw CancellationError() }
                    if player.didFinish { player.currentTime = 0 }
                    guard player.play() else { throw CocoaError(.fileReadUnknown) }
                    guard !lease.isCancelled, !self.captureIsActive() else {
                        throw CancellationError()
                    }
                    continuation.resume(returning: self.snapshot(player))
                } catch {
                    // Finish hardware cleanup before a queued recorder barrier can pass.
                    self.filePlayers[ObjectIdentifier(lease)]?.stop(); self.filePlayers[ObjectIdentifier(lease)] = nil
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Enqueue synchronously so a rapid resume cannot overtake this pause.
    func pauseFile(_ lease: Lease, completion: @escaping @Sendable (PlaybackFileSnapshot?) -> Void) {
        queue.async {
            guard !lease.isCancelled, let player = self.filePlayers[ObjectIdentifier(lease)] else { completion(nil); return }
            player.pause()
            completion(self.snapshot(player))
        }
    }

    func fileSnapshot(_ lease: Lease, completion: @escaping @Sendable (PlaybackFileSnapshot?) -> Void) {
        queue.async {
            guard !lease.isCancelled, let player = self.filePlayers[ObjectIdentifier(lease)] else { completion(nil); return }
            completion(self.snapshot(player))
        }
    }

    private func snapshot(_ player: any PlaybackFilePlaying) -> PlaybackFileSnapshot {
        // Sample playing first: if hardware finishes during the remaining reads, keep one more
        // timer tick so a transient zero clock cannot become the final published snapshot.
        let playing = player.isPlaying
        return PlaybackFileSnapshot(duration: player.duration, position: !playing && player.didFinish ? player.duration : player.currentTime,
                                    isPlaying: playing)
    }

    func captureStateDidChange() {
        queue.async {
            if self.captureIsActive() { self.filePlayers.values.forEach { $0.pause() } }
            self.releaseCancelledOwner()
        }
    }

    private func releaseCancelledOwner() {
        guard owner?.isCancelled == true, !captureIsActive() else { return }
        owner = nil
        deactivateSession()
    }

    /// Capture intent must already be registered. This drains transitions already in flight;
    /// subsequent playback work observes captureIsActive and cannot change the recorder's session.
    func prepareForCapture() async {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume() }
        }
    }

    deinit {
        if let captureObserver { NotificationCenter.default.removeObserver(captureObserver) }
        // The last AVAudioPlayer reference and its blocking hardware teardown stay on the queue.
        let remaining = Array(filePlayers.values)
        queue.async { remaining.forEach { $0.stop() } }
    }
}

#if os(iOS)
private final class QueuedAudioFilePlayer: PlaybackFilePlaying, @unchecked Sendable {
    private let player: AVAudioPlayer
    private let completionLock = NSLock()
    private var completion = PlaybackFileCompletion()
    private var interruptionObserver: NSObjectProtocol?
    private var lastPosition: TimeInterval = 0
    var duration: TimeInterval { player.duration }
    var currentTime: TimeInterval {
        get {
            let value = player.currentTime
            if value == 0, lastPosition > 0, !didFinish { return lastPosition }
            lastPosition = value; return value
        }
        set { player.currentTime = newValue; lastPosition = newValue }
    }
    var isPlaying: Bool { player.isPlaying }
    // GCD queues have no persistent run loop; completion must not depend on delegate delivery.
    var didFinish: Bool {
        let playing = player.isPlaying, position = player.currentTime, duration = player.duration
        return completionLock.withLock {
            completion.didFinish(isPlaying: playing, position: position, duration: duration, now: ProcessInfo.processInfo.systemUptime)
        }
    }
    init(url: URL) throws {
        player = try AVAudioPlayer(contentsOf: url)
        interruptionObserver = NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: nil) { [weak self] note in
            guard let value = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  value == AVAudioSession.InterruptionType.began.rawValue else { return }
            self?.completionLock.withLock { self?.completion.interrupt() }
        }
    }
    func prepareToPlay() -> Bool { player.prepareToPlay() }
    func play() -> Bool {
        let position = currentTime, now = ProcessInfo.processInfo.systemUptime
        let interruptionGeneration = completionLock.withLock { completion.interruptionGeneration }
        if player.currentTime == 0, position > 0 { player.currentTime = position }
        let started = player.play()
        completionLock.withLock {
            if started { completion.start(position: position, now: now, expectedInterruptionGeneration: interruptionGeneration) }
            else { completion.pause() }
        }
        return started
    }
    func pause() { completionLock.withLock { completion.pause() }; player.pause() }
    func stop() { completionLock.withLock { completion.pause() }; player.stop() }
    deinit { if let interruptionObserver { NotificationCenter.default.removeObserver(interruptionObserver) } }
}

extension PlaybackAudioSession {
    static let shared: PlaybackAudioSession = {
        let coordinator = PlaybackAudioSession(captureIsActive: { !AudioCaptureActivity.activeIDs.isEmpty }, activate: {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .spokenAudio)
            try session.setActive(true)
        }, deactivate: {
            let session = AVAudioSession.sharedInstance()
            guard session.category == .playback else { return }
            try? session.setActive(false, options: .notifyOthersOnDeactivation)
        }, makeFilePlayer: { try QueuedAudioFilePlayer(url: $0) })
        coordinator.captureObserver = NotificationCenter.default.addObserver(
            forName: .init("WiseLife.AudioCaptureActivity"), object: nil, queue: nil
        ) { [weak coordinator] _ in coordinator?.captureStateDidChange() }
        return coordinator
    }()
}
#endif
