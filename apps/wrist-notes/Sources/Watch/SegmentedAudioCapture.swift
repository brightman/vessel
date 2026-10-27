import AVFAudio
import Foundation
import Darwin

enum RecordingStorageCapacity {
    // Best-effort safety margins, never an OS reservation or an ENOSPC guarantee.
    static let warningBytes: Int64 = 32 * 1024 * 1024
    static let stopBytes: Int64 = 16 * 1024 * 1024
    static func availableBytes(at root: URL) throws -> Int64 {
        var existing = root
        while !FileManager.default.fileExists(atPath: existing.path), existing.path != "/" { existing.deleteLastPathComponent() }
        let values = try FileManager.default.attributesOfFileSystem(forPath: existing.path)
        guard let bytes = values[.systemFreeSize] as? NSNumber else { throw SegmentedAudioCapture.Failure.storageUnavailable }
        return bytes.int64Value
    }
}

/// Serial-worker sink shared by the microphone adapter and synthetic PCM tests.
/// Only 16 kHz mono effective PCM frames contribute to time and rotation.
final class RecordingChunkWriter {
    enum Failure: Error { case stopped, invalidFormat, invalidBuffer }
    private let sessionID: UUID
    private var context: RecordingCaptureContext
    private var intent: RecordingCaptureIntent?
    private var checkpointFrames: Int64 = 0
    private let root: URL
    private let onSeal: (RecordingChunkDescriptor, URL) throws -> Void
    private let capacityReader: (URL) throws -> Int64
    private let onStorageWarning: () -> Void
    private var warnedAboutStorage = false
    private var nextStorageCheckFrame: Int64 = 16000
    private var file: AVAudioFile?
    private var partial: URL?
    private var ordinal = 0
    private var chunkFrames: Int64 = 0
    private var stopped = false
    private(set) var effectiveFrames: Int64 = 0
    private let scratch: AVAudioPCMBuffer
    static let sampleRate = RecordingChunkProtocol.captureSampleRate
    static let framesPerChunk = RecordingChunkProtocol.maximumChunkFrames

    init(sessionID: UUID, root: URL, startedAt: Date = .now,
         origin: RecordingOrigin = .init(device: "Watch", deviceID: "synthetic", fileName: "continuous-capture", recordingTimeIsEstimated: false),
         location: CaptureLocation? = nil,
         capacityReader: @escaping (URL) throws -> Int64 = RecordingStorageCapacity.availableBytes,
         onStorageWarning: @escaping () -> Void = {},
         onSeal: @escaping (RecordingChunkDescriptor, URL) throws -> Void) throws {
        self.sessionID = sessionID; self.root = root; self.onSeal = onSeal
        self.capacityReader = capacityReader; self.onStorageWarning = onStorageWarning
        context = .init(sessionID: sessionID, startedAt: startedAt, timeZoneIdentifier: TimeZone.current.identifier, origin: origin, location: location)
        try RecordingAudioFile.requireSafePath(root)
        let initialCapacity = try capacityReader(root)
        guard initialCapacity > RecordingStorageCapacity.stopBytes else { throw SegmentedAudioCapture.Failure.lowStorage }
        if initialCapacity <= RecordingStorageCapacity.warningBytes { warnedAboutStorage = true; onStorageWarning() }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let contextURL = root.appendingPathComponent("capture-context.json")
        try RecordingAudioFile.requireSafePath(contextURL)
        guard !FileManager.default.fileExists(atPath: contextURL.path) else { throw Failure.invalidBuffer }
        try JSONEncoder().encode(context).write(to: contextURL, options: .atomic)
        scratch = AVAudioPCMBuffer(pcmFormat: AVAudioFormat(standardFormatWithSampleRate: Self.sampleRate, channels: 1)!, frameCapacity: 8192)!
    }

    func append(_ pcm: AVAudioPCMBuffer) throws {
        guard !stopped else { throw Failure.stopped }
        if effectiveFrames >= nextStorageCheckFrame {
            let remaining = try capacityReader(root)
            guard remaining > RecordingStorageCapacity.stopBytes else { throw SegmentedAudioCapture.Failure.lowStorage }
            if remaining <= RecordingStorageCapacity.warningBytes, !warnedAboutStorage {
                warnedAboutStorage = true; onStorageWarning()
            }
            nextStorageCheckFrame = effectiveFrames + 16000
        }
        guard pcm.format.sampleRate == Self.sampleRate, pcm.format.channelCount == 1,
              let channel = pcm.floatChannelData?[0], pcm.frameLength <= scratch.frameCapacity else { throw Failure.invalidFormat }
        let slices = try RecordingFramePartition.split(inputStartFrame: effectiveFrames, frameCount: Int64(pcm.frameLength), framesPerChunk: Self.framesPerChunk)
        for slice in slices {
            if file == nil {
                ordinal = slice.ordinal
                intent = .init(id: UUID(), context: context, ordinal: ordinal, sessionStartOffset: Double(effectiveFrames) / Self.sampleRate, effectiveFrames: 0)
                checkpointFrames = 0
                let url = root.appendingPathComponent(intent!.partialFilename)
                try RecordingAudioFile.requireSafePath(url)
                guard !FileManager.default.fileExists(atPath: url.path) else { throw Failure.invalidBuffer }
                partial = url
                try checkpoint()
                file = try AVAudioFile(forWriting: url, settings: [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: Self.sampleRate, AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 32000])
                partial = url
            }
            scratch.frameLength = AVAudioFrameCount(slice.frameCount)
            scratch.floatChannelData![0].update(from: channel.advanced(by: Int(slice.inputOffset)), count: Int(slice.frameCount))
            try file!.write(from: scratch)
            effectiveFrames += slice.frameCount; chunkFrames += slice.frameCount
            if chunkFrames == Self.framesPerChunk { try seal() }
            else if chunkFrames - checkpointFrames >= 16000 { try checkpoint() }
        }
    }

    func finish() throws {
        guard !stopped else { return }
        stopped = true
        try seal()
    }

    func updateLocation(_ location: CaptureLocation) throws {
        context.location = location
        let contextURL = root.appendingPathComponent("capture-context.json")
        try RecordingAudioFile.requireSafePath(contextURL)
        try JSONEncoder().encode(context).write(to: contextURL, options: .atomic)
        if intent != nil { intent?.context = context; try checkpoint() }
    }

    private func checkpoint() throws {
        guard let partial, intent != nil else { return }
        intent?.effectiveFrames = chunkFrames
        let journal = partial.appendingPathExtension("capture.json")
        try RecordingAudioFile.requireSafePath(journal)
        try JSONEncoder().encode(intent!).write(to: journal, options: .atomic)
        checkpointFrames = chunkFrames
    }

    private func seal() throws {
        guard let url = partial, chunkFrames > 0 else { return }
        file = nil // Close AAC and its packet table before inspecting bytes.
        let info = try RecordingAudioFile.inspect(url)
        try checkpoint()
        let descriptor = intent!.descriptor(info: info)
        _ = try RecordingAudioFile.validate(descriptor, at: url)
        try onSeal(descriptor, url)
        // Delete the temporary only after the caller durably sealed its descriptor.
        try FileManager.default.removeItem(at: url)
        try FileManager.default.removeItem(at: url.appendingPathExtension("capture.json"))
        partial = nil; intent = nil; chunkFrames = 0
    }
}

/// Bounded preallocated handoff. The tap never waits, allocates a buffer, opens a
/// file, or enqueues a closure. DispatchSource coalesces wakeups on one worker.
final class RecordingPCMBufferPool: @unchecked Sendable {
    static let microphoneBufferDuration: Double = 10
    static let microphoneBufferFrameCapacity: AVAudioFrameCount = 8192
    static func microphoneBufferCount(sampleRate: Double) -> Int {
        max(1, Int(ceil(sampleRate * microphoneBufferDuration / Double(microphoneBufferFrameCapacity))))
    }
    enum OfferResult: Int32 {
        case accepted = 0
        case inputBufferTooLarge = 1
        case formatMismatch = 2
        case poolBusy = 3
        case bufferLayoutMismatch = 4
        var accepted: Bool { self == .accepted }
    }
    private let buffers: [AVAudioPCMBuffer]
    // Single producer / single consumer ring. Atomic state transitions publish
    // copied PCM with full memory barriers: free -> filling -> ready -> reading.
    // OSAtomic is available on the project's watchOS 10 deployment baseline.
    private let states: UnsafeMutablePointer<Int32>
    private var readIndex = 0 // consumer only
    private var writeIndex = 0 // producer only
    init(format: AVAudioFormat, count: Int = 8, frameCapacity: AVAudioFrameCount = 4096) {
        precondition(count > 0)
        buffers = (0..<count).map { _ in AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCapacity)! }
        states = .allocate(capacity: count)
        states.initialize(repeating: 0, count: count)
    }
    deinit { states.deinitialize(count: buffers.count); states.deallocate() }
    func offer(_ input: AVAudioPCMBuffer) -> Bool { offerDetailed(input).accepted }
    func offerDetailed(_ input: AVAudioPCMBuffer) -> OfferResult {
        let slot = writeIndex
        guard input.frameLength <= buffers[slot].frameCapacity else { return .inputBufferTooLarge }
        guard input.format == buffers[slot].format else { return .formatMismatch }
        guard OSAtomicCompareAndSwap32Barrier(0, 1, states.advanced(by: slot)) else { return .poolBusy }
        let target = buffers[slot]
        target.frameLength = input.frameLength
        let sourceBuffers = UnsafeMutableAudioBufferListPointer(input.mutableAudioBufferList)
        let targetBuffers = UnsafeMutableAudioBufferListPointer(target.mutableAudioBufferList)
        for index in 0..<sourceBuffers.count {
            guard let source = sourceBuffers[index].mData, let destination = targetBuffers[index].mData,
                  sourceBuffers[index].mDataByteSize <= targetBuffers[index].mDataByteSize else {
                _ = OSAtomicCompareAndSwap32Barrier(1, 0, states.advanced(by: slot))
                return .bufferLayoutMismatch
            }
            memcpy(destination, source, Int(sourceBuffers[index].mDataByteSize))
        }
        _ = OSAtomicCompareAndSwap32Barrier(1, 2, states.advanced(by: slot))
        writeIndex = (writeIndex + 1) % buffers.count
        return .accepted
    }
    func take() -> (Int, AVAudioPCMBuffer)? {
        let slot = readIndex
        guard OSAtomicCompareAndSwap32Barrier(2, 3, states.advanced(by: slot)) else { return nil }
        readIndex = (readIndex + 1) % buffers.count
        return (slot, buffers[slot])
    }
    func release(_ slot: Int) { _ = OSAtomicCompareAndSwap32Barrier(3, 0, states.advanced(by: slot)) }
}

/// One serial consumer owns converter, writer, completion and failure state. The
/// same production pipeline accepts native microphone buffers or synthetic PCM.
final class RecordingCapturePipeline: @unchecked Sendable {
    private let worker: DispatchQueue
    private let writer: RecordingChunkWriter
    private let converter: AVAudioConverter
    private let output: AVAudioPCMBuffer
    private let pool: RecordingPCMBufferPool
    private let signal: DispatchSourceUserDataAdd
    private let overflow: DispatchSourceUserDataAdd
    private let overflowReason: UnsafeMutablePointer<Int32>
    private let onFailure: (Error) -> Void
    private var terminalError: Error?
    private var finished = false
    private var nativeFrames: Int64 = 0
    private let nativeSampleRate: Double
    private let durationLock = NSLock()
    private var frames: Int64 = 0
    var sampledDuration: Double { durationLock.lock(); defer { durationLock.unlock() }; return Double(frames) / 16000 }

    init(format: AVAudioFormat, sessionID: UUID, root: URL, origin: RecordingOrigin,
         capacityReader: @escaping (URL) throws -> Int64 = RecordingStorageCapacity.availableBytes,
         onStorageWarning: @escaping () -> Void = {},
         onSeal: @escaping (RecordingChunkDescriptor, URL) throws -> Void,
         onFailure: @escaping (Error) -> Void) throws {
        guard format.sampleRate.isFinite, (8000...192000).contains(format.sampleRate), (1...8).contains(format.channelCount),
              let target = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1),
              let converter = AVAudioConverter(from: format, to: target) else { throw SegmentedAudioCapture.Failure.conversion }
        self.converter = converter; converter.primeMethod = .none
        nativeSampleRate = format.sampleRate
        output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: 8192)!
        let queue = DispatchQueue(label: "WiseLife.continuousAudioWriter", qos: .userInitiated)
        worker = queue
        writer = try queue.sync {
            try RecordingChunkWriter(sessionID: sessionID, root: root, origin: origin,
                capacityReader: capacityReader, onStorageWarning: { DispatchQueue.main.async(execute: onStorageWarning) }, onSeal: onSeal)
        }
        // Absorb short watchOS scheduling and file-I/O stalls without blocking
        // the real-time tap. Ten seconds at 48 kHz mono is about 1.9 MiB.
        pool = RecordingPCMBufferPool(format: format,
            count: RecordingPCMBufferPool.microphoneBufferCount(sampleRate: format.sampleRate),
            frameCapacity: RecordingPCMBufferPool.microphoneBufferFrameCapacity)
        overflowReason = .allocate(capacity: 1)
        overflowReason.initialize(to: RecordingPCMBufferPool.OfferResult.accepted.rawValue)
        self.onFailure = onFailure
        signal = DispatchSource.makeUserDataAddSource(queue: worker)
        overflow = DispatchSource.makeUserDataAddSource(queue: worker)
        signal.setEventHandler { [weak self] in self?.drain() }
        overflow.setEventHandler { [weak self] in if let self { self.fail(self.overflowFailure) } }
        signal.resume(); overflow.resume()
    }

    deinit { overflowReason.deinitialize(count: 1); overflowReason.deallocate() }

    private var overflowFailure: SegmentedAudioCapture.Failure {
        .bufferOverflow(RecordingPCMBufferPool.OfferResult(rawValue: OSAtomicAdd32Barrier(0, overflowReason)) ?? .poolBusy)
    }

    func submit(_ input: AVAudioPCMBuffer) {
        let result = pool.offerDetailed(input)
        if result.accepted { signal.add(data: 1) }
        else {
            _ = OSAtomicCompareAndSwap32Barrier(RecordingPCMBufferPool.OfferResult.accepted.rawValue, result.rawValue, overflowReason)
            overflow.add(data: 1)
        }
    }
    func updateLocation(_ location: CaptureLocation) {
        worker.async {
            guard !self.finished else { return }
            // Optional metadata must never enter the terminal audio failure path.
            try? self.writer.updateLocation(location)
        }
    }
    func interrupt(_ error: Error) { worker.async { self.fail(error) } }

    /// Producer must be stopped before finish. Concurrent/repeated stops serialize.
    func finish(onEnqueued: (() -> Void)? = nil) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            worker.async {
                if !self.finished {
                    if self.overflow.data > 0 { self.fail(self.overflowFailure) }
                    self.drain()
                    do {
                        if self.terminalError == nil { try self.convert(nil) }
                        try self.writer.finish()
                    } catch { self.fail(error) }
                    self.finished = true
                    self.signal.cancel(); self.overflow.cancel()
                }
                if let error = self.terminalError { continuation.resume(throwing: error) }
                else { continuation.resume() }
            }
            // A narrow synchronization point for callers that must establish
            // stop ordering while a seal callback holds the serial writer.
            onEnqueued?()
        }
    }
    private func drain() {
        guard !finished else { return }
        while let (slot, buffer) = pool.take() {
            do { if terminalError == nil { try convert(buffer) } }
            catch { fail(error) }
            pool.release(slot)
        }
    }
    private func convert(_ input: AVAudioPCMBuffer?) throws {
        var provided = false
        while true {
            var error: NSError?
            let status = converter.convert(to: output, error: &error) { _, flag in
                if let input, !provided {
                    provided = true; self.nativeFrames += Int64(input.frameLength)
                    flag.pointee = .haveData; return input
                }
                flag.pointee = input == nil ? .endOfStream : .noDataNow
                return nil
            }
            if let error { throw error }
            if status == .error { throw SegmentedAudioCapture.Failure.conversion }
            // Converter end-of-stream may emit filter tail (48k->16k fixture:
            // 16011 output for 48000 native frames). Tail is not capture time.
            let effectiveLimit = Int64((Double(nativeFrames) * 16000 / nativeSampleRate).rounded(.down))
            output.frameLength = AVAudioFrameCount(min(Int64(output.frameLength), max(0, effectiveLimit - writer.effectiveFrames)))
            if output.frameLength > 0 { try writer.append(output) }
            durationLock.lock(); frames = writer.effectiveFrames; durationLock.unlock()
            if status == .inputRanDry || status == .endOfStream || output.frameLength == 0 { break }
        }
    }
    private func fail(_ error: Error) {
        guard terminalError == nil, !finished else { return }
        terminalError = error
        DispatchQueue.main.async { self.onFailure(error) }
    }
}

/// Main-thread lifecycle adapter. Never starts until the user starts a recording.
final class SegmentedAudioCapture {
    enum Failure: LocalizedError {
        case bufferOverflow(RecordingPCMBufferPool.OfferResult), routeChanged, conversion, alreadyStarted, lowStorage, storageUnavailable
        var errorDescription: String? {
            switch self {
            case .bufferOverflow(let reason):
                switch reason {
                case .inputBufferTooLarge: "手表音频回调超出缓冲区容量，录音已中断；已保存的片段仍保留"
                case .formatMismatch: "手表音频格式发生变化，录音已中断；已保存的片段仍保留"
                case .bufferLayoutMismatch: "无法读取手表音频缓冲，录音已中断；已保存的片段仍保留"
                case .accepted, .poolBusy: "音频处理未及时跟上录音，录音已中断；已保存的片段仍保留"
                }
            case .routeChanged: "音频设备发生变化，录音已中断"
            case .conversion: "音频转换失败，录音已中断"
            case .alreadyStarted: "录音正在进行"
            case .lowStorage: "手表存储空间不足，录音已停止，正在保存已有音频"
            case .storageUnavailable: "无法确认剩余存储空间，录音已停止"
            }
        }
    }
    private let root: URL
    private let origin: RecordingOrigin
    private let engine = AVAudioEngine()
    private let onSeal: (RecordingChunkDescriptor, URL) throws -> Void
    var onFailure: ((Error) -> Void)?
    var onStorageWarning: (() -> Void)?
    private var pipeline: RecordingCapturePipeline?
    private var observer: NSObjectProtocol?
    private var interruptionObserver: NSObjectProtocol?
    private var tapInstalled = false
    var sampledDuration: Double { pipeline?.sampledDuration ?? 0 }

    init(root: URL, origin: RecordingOrigin, onSeal: @escaping (RecordingChunkDescriptor, URL) throws -> Void) {
        self.root = root; self.origin = origin; self.onSeal = onSeal
    }
    func start(sessionID: UUID) throws {
        guard pipeline == nil else { throw Failure.alreadyStarted }
        let format = engine.inputNode.outputFormat(forBus: 0)
        let pipeline = try RecordingCapturePipeline(format: format, sessionID: sessionID, root: root, origin: origin,
            onStorageWarning: { [weak self] in self?.onStorageWarning?() },
            onSeal: onSeal, onFailure: { [weak self] error in self?.onFailure?(error) })
        self.pipeline = pipeline
        engine.inputNode.installTap(onBus: 0, bufferSize: 2048, format: format) { buffer, _ in pipeline.submit(buffer) }
        tapInstalled = true
        observer = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil) { _ in
            pipeline.interrupt(Failure.routeChanged)
        }
#if os(watchOS) || os(iOS)
        interruptionObserver = NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: nil) { _ in
            pipeline.interrupt(Failure.routeChanged)
        }
#endif
        do { try engine.start() }
        catch { detach(); Task { try? await pipeline.finish() }; throw error }
    }
    func updateLocation(_ location: CaptureLocation) { pipeline?.updateLocation(location) }
    func stop() async throws { detach(); try await pipeline?.finish() }
    private func detach() {
        engine.stop()
        if tapInstalled { engine.inputNode.removeTap(onBus: 0); tapInstalled = false }
        if let observer { NotificationCenter.default.removeObserver(observer); self.observer = nil }
        if let interruptionObserver { NotificationCenter.default.removeObserver(interruptionObserver); self.interruptionObserver = nil }
    }
}
