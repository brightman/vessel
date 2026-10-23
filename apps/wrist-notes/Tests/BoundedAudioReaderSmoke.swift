import AVFAudio
import Foundation
import Darwin

@main struct BoundedAudioReaderSmoke {
    static func main() async throws {
        setbuf(stdout,nil)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("bounded-reader-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let rate = 16_000.0
        let source = root.appendingPathComponent("six-hours.wav")
        // Sparse, valid PCM WAV: 6.5 hours in its header and on disk, no full decode/allocation.
        let frameCount: UInt32 = 23_400 * 16_000
        var header = Data("RIFF".utf8)
        func u32(_ n: UInt32) { var n = n.littleEndian; withUnsafeBytes(of: &n) { header.append(contentsOf: $0) } }
        func u16(_ n: UInt16) { var n = n.littleEndian; withUnsafeBytes(of: &n) { header.append(contentsOf: $0) } }
        u32(36 + frameCount * 2); header.append(Data("WAVEfmt ".utf8)); u32(16); u16(1); u16(1)
        u32(16_000); u32(32_000); u16(2); u16(16); header.append(Data("data".utf8)); u32(frameCount * 2)
        try header.write(to: source)
        let handle = try FileHandle(forWritingTo: source)
        try handle.truncate(atOffset: 44 + UInt64(frameCount) * 2)
        // Distinct markers at first/middle/last requested positions.
        for (frame, value): (Int64, Int16) in [(0,8192), (187_200_000,16384), (374_368_000,24576)] {
            try handle.seek(toOffset: 44 + UInt64(frame) * 2)
            var value = value.littleEndian
            try handle.write(contentsOf: withUnsafeBytes(of: &value) { Data($0) })
        }
        try handle.close()
        let id = AudioSourceID(kind: .legacyNote, id: UUID())
        func range(_ file: URL, _ start: Int64, _ end: Int64, _ offset: Double, rate: Double = 16_000) throws -> AudioSourceRange {
            try .init(range: RecordingSourceRange(chunkID: UUID(), url: file, startFrame: start, endFrame: end,
                sampleRate: rate, sessionStartOffset: offset, discontinuityBefore: nil), contentHash: String(repeating: "a", count: 64))
        }
        func window(_ ranges: [AudioSourceRange], start: Double, end: Double) -> AudioProcessingWindow {
            .init(id: "test", sourceID: id, configurationKey: "test", coreStart: start, coreEnd: end, ranges: ranges)
        }
        let reader = BoundedAudioReader(temporaryRoot: root.appendingPathComponent("pcm"))
        for (frame, marker): (Int64, Float) in [(0,0.25),(187_200_000,0.5),(374_368_000,0.75)] {
            let start = Double(frame) / rate
            let audio = try reader.materialize(window([try range(source, frame, frame + 32_000, start)], start: start, end: start + 2))
            let url = audio.url
            let samples = try audio.samples(maximumFrames: 32_000)
            precondition(samples.count == 32_000 && abs(samples[0] - marker) < 0.0001, "seek/marker or end bound lost")
            precondition(audio.maximumSourceBufferFrames <= 4096)
            precondition(audio.sourceRanges(start: 0, end: 2) == [.init(start: start, end: start + 2)])
            audio.cleanup(); precondition(!FileManager.default.fileExists(atPath: url.path))
        }
        let second = root.appendingPathComponent("second.caf")
        let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1)!
        do {
            let file = try AVAudioFile(forWriting: second, settings: format.settings)
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16_000)!
            buffer.frameLength = 16_000
            for i in 0..<16_000 { buffer.floatChannelData![0][i] = -0.25 }
            try file.write(from: buffer)
        }
        let joined = try reader.materialize(window([try range(source, 0, 16_000, 100), try range(second, 0,16_000,101)], start: 100,end: 102))
        let joinedSamples = try joined.samples(maximumFrames: 32_000)
        precondition(joinedSamples.count == 32_000 && joinedSamples[16_000] == -0.25, "cross-file source samples lost")
        precondition(joined.sourceRanges(start: 0.5,end: 1.5) == [.init(start: 100.5,end: 101.5)])
        joined.cleanup()
        let stereo = root.appendingPathComponent("stereo-44k.caf")
        let stereoFormat = AVAudioFormat(standardFormatWithSampleRate:44_100,channels:2)!
        do {
            var settings = stereoFormat.settings; settings[AVLinearPCMIsNonInterleaved] = false
            let file = try AVAudioFile(forWriting:stereo,settings:settings,commonFormat:.pcmFormatFloat32,interleaved:false)
            let buffer = AVAudioPCMBuffer(pcmFormat:stereoFormat,frameCapacity:88_200)!
            buffer.frameLength = 88_200
            for i in 0..<88_200 { buffer.floatChannelData![0][i] = 0.25; buffer.floatChannelData![1][i] = 0.25 }
            try file.write(from:buffer)
        }
        let converted = try reader.materialize(window([try range(stereo,0,88_200,10,rate:44_100)],start:10,end:12))
        let resampled = try converted.samples(maximumFrames:32_002)
        precondition(abs(resampled.count-32_000)<=2 && abs(resampled[16_000]-0.25)<0.001,"stereo conversion/resampling lost samples")
        precondition(converted.sourceRanges(start:0,end:converted.duration) == [.init(start:10,end:12)])
        precondition(converted.inputRanges(start:10,end:12) == [.init(start:0,end:converted.duration)])
        converted.cleanup()
        let long = try reader.materialize(window([try range(source, 0,4_864_000,0)],start: 2,end: 302))
        precondition(long.duration <= 304.0001 && long.maximumSourceBufferFrames <= 4096)
        var analyzedFrames = 0
        try long.forEachBlock(maximumFrames:480_000) { _, block in
            precondition(block.count <= 480_000)
            analyzedFrames += block.count
        }
        precondition(analyzedFrames == 4_864_000,"block iteration dropped a partial AVAudioFile read")
        long.cleanup()
        func rejects(_ ranges: [AudioSourceRange], start: Double = 0, end: Double = 1) {
            do { let audio = try reader.materialize(window(ranges,start:start,end:end)); audio.cleanup(); fatalError("accepted invalid/missing input") }
            catch { }
        }
        rejects([try range(source, Int64(frameCount)-10,Int64(frameCount)+10,0)])
        rejects([try range(root.appendingPathComponent("missing.wav"),0,16_000,0)])
        rejects([try range(source,0,16_000,0),try range(root.appendingPathComponent("missing-second.wav"),0,16_000,1)],start:0,end:2)
        rejects([try range(source,0,4_880_000,0)],start:0,end:300)
        rejects([try range(source,0,16_000,0),try range(second,0,16_000,2)],start:0,end:3)
        rejects([try range(source,0,16_000,0,rate:8_000)])
        let cancellation = Task {
            while !Task.isCancelled { await Task.yield() }
            return try reader.materialize(window([try range(source,0,16_000,0)],start:0,end:1))
        }
        cancellation.cancel()
        do { _ = try await cancellation.value; fatalError("cancelled materialization succeeded") } catch is CancellationError { }
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("pcm").path)
        precondition(leftovers.isEmpty, "temporary files leaked")
        var usage = rusage(); getrusage(RUSAGE_SELF,&usage)
        print("Bounded reader: passed (6.5h sparse source, 4096 source frames, <=304s input, markers/cleanup/error/cancel); synthetic peak RSS bytes:",usage.ru_maxrss)
    }
}
