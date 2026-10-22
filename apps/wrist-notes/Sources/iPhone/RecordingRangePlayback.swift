import Foundation
import AVFAudio

/// Compact recorded-audio time; gaps are markers, never padded PCM or ordinal * 300.
struct RecordingRangePlan {
    struct Position: Equatable { let rangeIndex: Int; let frame: Int64 }
    let ranges: [RecordingSourceRange]
    let starts: [Double]
    let duration: Double
    let gaps: [Double]

    init(_ ranges: [RecordingSourceRange]) throws {
        var starts: [Double] = [], gaps: [Double] = [], total = 0.0
        for range in ranges {
            try range.validate()
            starts.append(total)
            if range.discontinuityBefore != nil { gaps.append(total) }
            total += range.duration
            guard total.isFinite else { throw RecordingSessionValidationError.invalidField("duration") }
        }
        self.ranges = ranges; self.starts = starts; self.duration = total; self.gaps = gaps
    }

    func locate(_ seconds: Double) -> Position? {
        guard seconds.isFinite, duration > 0, seconds < duration else { return nil }
        let seconds = max(0, seconds)
        var low = 0, high = starts.count
        while low < high {
            let middle = (low + high) / 2
            if starts[middle] <= seconds { low = middle + 1 } else { high = middle }
        }
        let index = max(0, low - 1), range = ranges[index]
        let offset = min(Double(range.endFrame - range.startFrame - 1), floor(max(0, seconds - starts[index]) * range.sampleRate))
        guard offset >= 0, offset < Double(Int64.max) else { return nil }
        return Position(rangeIndex: index, frame: range.startFrame + Int64(offset))
    }

    func window(at index: Int) -> Range<Int> {
        let start = min(max(0, index), ranges.count)
        return start..<min(start + 2, ranges.count)
    }
}

/// Fixed output and one small PCM buffer irrespective of recording length.
enum RecordingRangeWaveform {
    static func read(_ plan: RecordingRangePlan) throws -> [Float] {
        var peaks = [Float](repeating: 0, count: 68)
        var openedIndex: Int?, audio: AVAudioFile?, buffer: AVAudioPCMBuffer?
        for point in peaks.indices {
            try Task.checkCancellation()
            guard let position = plan.locate(Double(point) * plan.duration / Double(peaks.count)) else { continue }
            let range = plan.ranges[position.rangeIndex]
            if openedIndex != position.rangeIndex {
                audio = nil; buffer = nil
                let file = try AVAudioFile(forReading: range.url)
                guard file.processingFormat.sampleRate == range.sampleRate, file.length >= range.endFrame,
                      let pcm = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 4096) else {
                    throw RecordingSessionValidationError.invalidField("audioRange")
                }
                audio = file; buffer = pcm; openedIndex = position.rangeIndex
            }
            guard let audio, let buffer else { continue }
            audio.framePosition = position.frame
            try audio.read(into: buffer, frameCount: AVAudioFrameCount(min(4096, range.endFrame - position.frame)))
            if let channels = buffer.floatChannelData {
                for channel in 0..<Int(buffer.format.channelCount) {
                    for frame in 0..<Int(buffer.frameLength) { peaks[point] = max(peaks[point], abs(channels[channel][frame])) }
                }
            }
        }
        let maximum = max(peaks.max() ?? 0, 0.001)
        return peaks.map { max(0.08, sqrt($0 / maximum)) }
    }
}

#if os(iOS)
import Combine

@MainActor final class RecordingRangePlayback: ObservableObject {
    @Published private(set) var isPlaying = false
    @Published private(set) var position = 0.0
    @Published private(set) var duration = 0.0
    @Published private(set) var waveform = [Float](repeating: 0.08, count: 68)
    @Published private(set) var gapPositions: [Double] = []
    @Published private(set) var error: String?
    private var plan: RecordingRangePlan?
    private var engine: AVAudioEngine?
    private var node: AVAudioPlayerNode?
    private var files: [Int: AVAudioFile] = [:]
    private var generation = UUID()
    private var waveformTask: Task<Void, Never>?
    private var timer: Timer?
    private var anchorPosition = 0.0
    private var ownsAudioSession = false

    func load(_ ranges: [RecordingSourceRange]) {
        stop(); plan = nil; position = 0; duration = 0; gapPositions = []; error = nil
        waveform = [Float](repeating: 0.08, count: 68)
        do {
            let plan = try RecordingRangePlan(ranges)
            self.plan = plan; duration = plan.duration; gapPositions = plan.gaps
            let token = generation
            waveformTask = Task { [weak self] in
                let work = Task.detached(priority: .utility) { try RecordingRangeWaveform.read(plan) }
                let peaks = await withTaskCancellationHandler(operation: { try? await work.value }, onCancel: { work.cancel() })
                guard !Task.isCancelled, let self, self.generation == token, let peaks else { return }
                self.waveform = peaks
            }
        } catch { self.error = "无法播放这段录音" }
    }

    func toggle() {
        if isPlaying { pause() } else { play() }
    }

    func seek(_ value: Double) {
        guard value.isFinite else { return }
        let resume = isPlaying
        releaseMedia(); position = min(max(0, value), duration)
        if resume && position < duration { play() }
    }

    func stop() {
        waveformTask?.cancel(); waveformTask = nil
        releaseMedia()
    }

    private func pause() {
        updatePosition(); releaseMedia()
    }

    private func releaseMedia() {
        generation = UUID(); timer?.invalidate(); timer = nil
        node?.stop(); engine?.stop(); node = nil; engine = nil; files.removeAll(); isPlaying = false
        if ownsAudioSession {
            ownsAudioSession = false
            // A recorder may already have taken over the shared session before UI updates.
            if AVAudioSession.sharedInstance().category == .playback {
                try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            }
        }
    }

    private func play() {
        guard let plan, plan.duration > 0 else { return }
        if position >= duration { position = 0 }
        guard let location = plan.locate(position) else { return }
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
            try AVAudioSession.sharedInstance().setActive(true)
            ownsAudioSession = true
            let file = try AVAudioFile(forReading: plan.ranges[location.rangeIndex].url)
            let engine = AVAudioEngine(), node = AVAudioPlayerNode()
            engine.attach(node); engine.connect(node, to: engine.mainMixerNode, format: file.processingFormat)
            self.engine = engine; self.node = node
            files[location.rangeIndex] = file
            for index in plan.window(at: location.rangeIndex) {
                try schedule(index, start: index == location.rangeIndex ? location.frame : plan.ranges[index].startFrame)
            }
            try engine.start(); node.play()
            error = nil; isPlaying = true; anchorPosition = position
            timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.updatePosition() }
            }
        } catch { releaseMedia(); self.error = "无法播放这段录音" }
    }

    private func schedule(_ index: Int, start: Int64) throws {
        guard let plan, let node else { return }
        let range = plan.ranges[index]
        let file = try files[index] ?? AVAudioFile(forReading: range.url)
        guard file.processingFormat.sampleRate == range.sampleRate, file.length >= range.endFrame,
              range.endFrame - start <= Int64(UInt32.max) else { throw RecordingSessionValidationError.invalidField("audioRange") }
        files[index] = file
        let token = generation
        node.scheduleSegment(file, startingFrame: start, frameCount: AVAudioFrameCount(range.endFrame - start), at: nil,
                             completionCallbackType: .dataPlayedBack) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.generation == token else { return }
                self.files.removeValue(forKey: index)
                if index + 1 == plan.ranges.count {
                    self.releaseMedia(); self.position = plan.duration
                } else if index + 2 < plan.ranges.count {
                    do { try self.schedule(index + 2, start: plan.ranges[index + 2].startFrame) }
                    catch { self.releaseMedia(); self.error = "无法播放这段录音" }
                }
            }
        }
    }

    private func updatePosition() {
        guard isPlaying, let node, let rendered = node.lastRenderTime,
              let played = node.playerTime(forNodeTime: rendered), played.sampleRate > 0 else { return }
        position = min(duration, anchorPosition + max(0, Double(played.sampleTime) / played.sampleRate))
    }
}
#endif
