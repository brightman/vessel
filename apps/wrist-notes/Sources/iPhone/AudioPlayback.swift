import AVFAudio
import Combine
import Foundation

@MainActor
final class AudioPlayback: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @Published private(set) var isPlaying = false
    @Published private(set) var position: TimeInterval = 0
    @Published private(set) var duration: TimeInterval = 0
    @Published private(set) var waveform = [Float](repeating: 0.08, count: 68)
    @Published private(set) var error: String?
    private var player: AVAudioPlayer?
    private var timer: Timer?
    private var file: URL?

    func load(_ url: URL?, fallbackDuration: TimeInterval) async {
        file = url
        duration = fallbackDuration
        guard let url else { error = "录音文件不存在"; return }
        let result = await Task.detached(priority: .utility) { Self.readWaveform(url) }.value
        guard !Task.isCancelled else { return }
        if let result { waveform = result.peaks; duration = result.duration }
    }

    func toggle() {
        if isPlaying {
            player?.pause()
            timer?.invalidate()
            isPlaying = false
            return
        }
        guard let file else { error = "录音文件不存在"; return }
        do {
            if player == nil {
                try AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
                try AVAudioSession.sharedInstance().setActive(true)
                player = try AVAudioPlayer(contentsOf: file)
                player?.delegate = self
                duration = player?.duration ?? duration
                player?.currentTime = min(position, duration)
            }
            if position >= duration { player?.currentTime = 0; position = 0 }
            guard player?.play() == true else { error = "无法播放这段录音"; return }
            error = nil
            isPlaying = true
            timer?.invalidate()
            timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    guard let self, self.isPlaying else { return }
                    self.position = self.player?.currentTime ?? 0
                }
            }
        } catch { self.error = "无法播放录音：\(error.localizedDescription)" }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        player?.stop()
        player = nil
        isPlaying = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    func seek(to time: TimeInterval) {
        guard time.isFinite else { return }
        position = min(max(0, time), duration)
        player?.currentTime = position
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.timer?.invalidate()
            self.isPlaying = false
            self.position = self.duration
        }
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
