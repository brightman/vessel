import AVFAudio
import Combine
import Foundation

@MainActor
final class AudioPlayback: NSObject, ObservableObject {
    @Published private(set) var isPlaying = false
    @Published private(set) var position: TimeInterval = 0
    @Published private(set) var duration: TimeInterval = 0
    @Published private(set) var waveform = [Float](repeating: 0.08, count: 68)
    @Published private(set) var error: String?
    private var timer: Timer?
    private var file: URL?
    private var sessionLease: PlaybackAudioSession.Lease?
    private var startTask: Task<Void, Never>?
    private var snapshotGeneration = UUID()
    private let session: PlaybackAudioSession
    private let captureIsActive: @Sendable () -> Bool

    #if os(iOS)
    override convenience init() {
        self.init(session: .shared, captureIsActive: { !AudioCaptureActivity.activeIDs.isEmpty })
    }
    #endif
    init(session: PlaybackAudioSession, captureIsActive: @escaping @Sendable () -> Bool) {
        self.session = session; self.captureIsActive = captureIsActive
        super.init()
    }

    deinit {
        startTask?.cancel(); timer?.invalidate()
        if let sessionLease { session.release(sessionLease) }
    }

    func load(_ url: URL?, fallbackDuration: TimeInterval) async {
        if file != url { stop(); position = 0 }
        file = url
        duration = fallbackDuration
        guard let url else { error = "录音文件不存在"; return }
        let result = await Task.detached(priority: .utility) { Self.readWaveform(url) }.value
        guard !Task.isCancelled, file == url else { return }
        if let result { waveform = result.peaks; duration = result.duration }
    }

    func toggle() {
        let session = self.session
        if startTask != nil { stop(); return }
        snapshotGeneration = UUID()
        let generation = snapshotGeneration
        if isPlaying {
            timer?.invalidate(); timer = nil
            isPlaying = false
            if let sessionLease {
                session.pauseFile(sessionLease) { [weak self] snapshot in
                    Task { @MainActor in
                        guard let self, self.sessionLease === sessionLease,
                              self.snapshotGeneration == generation, let snapshot else { return }
                        self.position = snapshot.position
                    }
                }
            }
            return
        }
        guard let file else { error = "录音文件不存在"; return }
        let lease = sessionLease ?? PlaybackAudioSession.Lease()
        sessionLease = lease
        startTask = Task { [weak self] in
            do {
                let snapshot = try await session.startFile(lease, url: file)
                guard let self else { session.release(lease); return }
                guard !Task.isCancelled, self.sessionLease === lease,
                      self.snapshotGeneration == generation, !self.captureIsActive() else {
                    if self.sessionLease === lease { self.stop() }
                    else { session.release(lease) }
                    return
                }
                self.startTask = nil
                self.duration = snapshot.duration; self.position = snapshot.position
                self.isPlaying = snapshot.isPlaying; self.error = nil
                self.timer?.invalidate()
                self.timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                    session.fileSnapshot(lease) { [weak self] snapshot in
                        Task { @MainActor in
                            guard let self, self.sessionLease === lease,
                                  self.snapshotGeneration == generation, let snapshot else { return }
                            self.position = snapshot.position; self.isPlaying = snapshot.isPlaying
                            if !snapshot.isPlaying { self.timer?.invalidate(); self.timer = nil }
                        }
                    }
                }
            } catch {
                session.release(lease)
                guard let self, self.sessionLease === lease else { return }
                self.startTask = nil; self.sessionLease = nil
                if !(error is CancellationError) { self.error = "无法播放录音：\(error.localizedDescription)" }
            }
        }
    }

    func stop() {
        snapshotGeneration = UUID()
        startTask?.cancel(); startTask = nil
        timer?.invalidate(); timer = nil
        isPlaying = false
        if let sessionLease { session.release(sessionLease) }
        sessionLease = nil
    }

    private nonisolated static func readWaveform(_ url: URL) -> (peaks: [Float], duration: TimeInterval)? {
        guard let audio = try? AVAudioFile(forReading: url),
              audio.length > 0, audio.processingFormat.sampleRate > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: audio.processingFormat, frameCapacity: 4096)
        else { return nil }
        var peaks = [Float](repeating: 0, count: 68)
        let total = audio.length
        do {
            for index in peaks.indices {
                if Task.isCancelled { return nil }
                // Sample bounded windows, so opening a multi-hour note stays inexpensive.
                audio.framePosition = Int64(index) * total / Int64(peaks.count)
                try audio.read(into: buffer, frameCount: AVAudioFrameCount(min(4096, total - audio.framePosition)))
                guard buffer.frameLength > 0, let channels = buffer.floatChannelData else { break }
                for frame in 0..<Int(buffer.frameLength) {
                    for channel in 0..<Int(buffer.format.channelCount) {
                        peaks[index] = max(peaks[index], abs(channels[channel][frame]))
                    }
                }
            }
            let maximum = max(peaks.max() ?? 0, 0.001)
            return (peaks.map { max(0.08, sqrt($0 / maximum)) }, Double(total) / audio.processingFormat.sampleRate)
        } catch { return nil }
    }
}
