import AVFAudio
import Foundation

@main struct CapturePoolConcurrencySmoke {
    static func main() async throws {
        verifyBufferOwnership()
        verifyConcurrentHandoff()
        try await verifyFirstFailureWins()
        print("Capture pool ownership, 100000 concurrent handoffs and first overflow passed")
    }

    // A slot cannot be reused until its consumer releases it, even after wrapping.
    private static func verifyBufferOwnership() {
        let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1)!
        let pool = RecordingPCMBufferPool(format: format, count: 2, frameCapacity: 64)
        let input = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 64)!
        input.frameLength = 64
        input.floatChannelData![0].update(repeating: 11, count: 64)
        precondition(pool.take() == nil)
        precondition(pool.offer(input))
        input.floatChannelData![0].update(repeating: 22, count: 64)
        precondition(pool.offer(input))
        let (firstSlot, first) = pool.take()!
        let (secondSlot, second) = pool.take()!
        precondition(firstSlot != secondSlot)
        precondition(first !== input && first !== second)
        precondition(first.floatChannelData![0][63] == 11)
        precondition(second.floatChannelData![0][63] == 22)
        precondition(pool.take() == nil, "a reading slot must not be consumed twice")
        pool.release(secondSlot)
        input.floatChannelData![0].update(repeating: 33, count: 64)
        precondition(pool.offerDetailed(input) == .poolBusy,
                     "producer cannot overwrite a held slot when the ring wraps")
        precondition(first.floatChannelData![0][63] == 11)
        pool.release(firstSlot)
        precondition(pool.offer(input))
        let (reusedSlot, reused) = pool.take()!
        precondition(reusedSlot == firstSlot && reused === first)
        precondition(reused.floatChannelData![0][63] == 33)
        pool.release(reusedSlot)
        precondition(pool.take() == nil)

    }

    // Wrong publication/reuse ordering exposes mixed frames, duplicates or drops.
    private static func verifyConcurrentHandoff() {
        let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!
        let pool = RecordingPCMBufferPool(format: format, count: 4, frameCapacity: 64)
        let group = DispatchGroup()
        let count = 100_000
        let deadline = DispatchTime.now() + .seconds(30)
        group.enter()
        DispatchQueue(label: "CapturePoolTest.producer").async {
            let input = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 64)!
            for sequence in 0..<count {
                let frameCount = sequence % 64 + 1
                input.frameLength = AVAudioFrameCount(frameCount)
                for channel in 0..<2 {
                    input.floatChannelData![channel].update(
                        repeating: Float(sequence) + Float(channel) * 0.25, count: frameCount)
                }
                while true {
                    let result = pool.offerDetailed(input)
                    if result == .accepted { break }
                    precondition(result == .poolBusy)
                    precondition(DispatchTime.now() < deadline, "producer stalled")
                }
            }
            group.leave()
        }
        group.enter()
        DispatchQueue(label: "CapturePoolTest.consumer").async {
            for sequence in 0..<count {
                var taken: (Int, AVAudioPCMBuffer)?
                while taken == nil {
                    taken = pool.take()
                    precondition(DispatchTime.now() < deadline, "consumer stalled")
                }
                let (slot, buffer) = taken!
                let frameCount = sequence % 64 + 1
                precondition(buffer.frameLength == AVAudioFrameCount(frameCount))
                for channel in 0..<2 {
                    let expected = Float(sequence) + Float(channel) * 0.25
                    for frame in 0..<frameCount {
                        precondition(buffer.floatChannelData![channel][frame] == expected,
                                     "PCM must remain intact and ordered until consumer release")
                    }
                }
                pool.release(slot)
            }
            precondition(pool.take() == nil)
            group.leave()
        }
        precondition(group.wait(timeout: deadline) == .success)
    }

    private static func verifyFirstFailureWins() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1)!
        let pipeline = try RecordingCapturePipeline(format: format, sessionID: UUID(), root: root,
            origin: .init(device: "Watch", deviceID: "synthetic", fileName: "atomic-test",
                          recordingTimeIsEstimated: false),
            capacityReader: { _ in 128 * 1024 * 1024 },
            onSeal: { _, _, _ in preconditionFailure("rejected input must not seal audio") },
            onFailure: { _ in })
        let oversized = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8193)!
        oversized.frameLength = 8193
        let wrongFormat = AVAudioPCMBuffer(
            pcmFormat: AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1)!,
            frameCapacity: 64)!
        wrongFormat.frameLength = 64
        pipeline.submit(oversized)
        pipeline.submit(wrongFormat)
        do {
            try await pipeline.finish()
            preconditionFailure("first rejected callback must terminate the pipeline")
        } catch SegmentedAudioCapture.Failure.bufferOverflow(let reason) {
            precondition(reason == .inputBufferTooLarge,
                         "later callback failures must preserve the first diagnostic")
        }
    }
}
