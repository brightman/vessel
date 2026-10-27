import AVFoundation
import Foundation

/// Bounded media verification in the simulator; not a UI playback test.
@main struct VerifyAudio {
    enum Failure: Error { case arguments, missingAudio, decode }
    static func main() async throws {
        let args=CommandLine.arguments
        guard args.count == 3 else { throw Failure.arguments }
        let asset=AVURLAsset(url:URL(fileURLWithPath:args[1]))
        let duration=try await asset.load(.duration).seconds
        guard let track=try await asset.loadTracks(withMediaType:.audio).first else { throw Failure.missingAudio }
        var samples: [[String:Any]]=[]
        for offset in [0.0,duration/2,max(0,duration-2)] {
            let reader=try AVAssetReader(asset:asset)
            reader.timeRange=CMTimeRange(start:CMTime(seconds:offset,preferredTimescale:16000),duration:CMTime(seconds:1,preferredTimescale:16000))
            let output=AVAssetReaderTrackOutput(track:track,outputSettings:[AVFormatIDKey:kAudioFormatLinearPCM,AVLinearPCMBitDepthKey:16,AVLinearPCMIsFloatKey:false,AVLinearPCMIsNonInterleaved:false])
            reader.add(output)
            guard reader.startReading() else { throw Failure.decode }
            var frames=0
            while let buffer=output.copyNextSampleBuffer() { frames += CMSampleBufferGetNumSamples(buffer) }
            guard reader.status == .completed, frames > 0 else { throw Failure.decode }
            samples.append(["start":offset,"decodedFrames":frames])
        }
        let result: [String:Any] = ["duration":duration,"sampleWindows":samples,"scope":"Simulator AVFoundation bounded decoding; UI playback not verified"]
        try JSONSerialization.data(withJSONObject:result,options:[.prettyPrinted,.sortedKeys]).write(to:URL(fileURLWithPath:args[2]),options:.atomic)
        print("audio_verified duration=\(duration) sample_windows=\(samples.count)")
    }
}
