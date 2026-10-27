import AVFAudio
import Foundation

@main struct CapturePoolRejectionSmoke {
    static func main() {
        let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1)!
        let pool = RecordingPCMBufferPool(format: format, count: 1, frameCapacity: 4096)

        let oversized = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8192)!
        oversized.frameLength = 8192
        precondition(pool.offerDetailed(oversized) == .inputBufferTooLarge,
                     "callback size rejection must be distinguishable from pool saturation")

        let mismatched = AVAudioPCMBuffer(pcmFormat: AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1)!, frameCapacity: 1024)!
        mismatched.frameLength = 1024
        precondition(pool.offerDetailed(mismatched) == .formatMismatch,
                     "format rejection must be distinguishable from pool saturation")

        let expected = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4096)!
        expected.frameLength = 4096
        precondition(pool.offerDetailed(expected) == .accepted)
        precondition(pool.offerDetailed(expected) == .poolBusy,
                     "a full ring must be reported as backpressure")

        let liveCount = RecordingPCMBufferPool.microphoneBufferCount(sampleRate: format.sampleRate)
        let livePool = RecordingPCMBufferPool(format: format, count: liveCount,
            frameCapacity: RecordingPCMBufferPool.microphoneBufferFrameCapacity)
        let callback = AVAudioPCMBuffer(pcmFormat: format,
            frameCapacity: RecordingPCMBufferPool.microphoneBufferFrameCapacity)!
        callback.frameLength = callback.frameCapacity
        for _ in 0..<liveCount {
            precondition(livePool.offerDetailed(callback) == .accepted,
                         "producer may run ten seconds ahead while the serial worker is briefly stalled")
        }
        precondition(livePool.offerDetailed(callback) == .poolBusy)
        let bufferedSeconds = Double(liveCount * Int(callback.frameCapacity)) / format.sampleRate
        precondition(bufferedSeconds >= RecordingPCMBufferPool.microphoneBufferDuration)
        print("Capture pool rejection diagnostics passed")
    }
}
