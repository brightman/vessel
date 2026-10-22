import AVFAudio
import Foundation

enum BoundedAudioError: Error { case invalidWindow, invalidFormat, shortRead, conversionFailed }

/// Owns a protected, bounded 16 kHz mono PCM file. Source files are never changed.
final class BoundedAudioFile: @unchecked Sendable {
    struct Mapping: Sendable {
        let inputStart: Double
        let inputEnd: Double
        let sourceStart: Double
        let sourceEnd: Double
    }
    let url: URL
    let duration: Double
    let maximumSourceBufferFrames: Int
    private let mappings: [Mapping]
    init(url: URL, frames: Int64, mappings: [Mapping], maximumSourceBufferFrames: Int) {
        self.url = url; duration = Double(frames) / 16_000
        self.mappings = mappings; self.maximumSourceBufferFrames = maximumSourceBufferFrames
    }
    deinit { cleanup() }
    func cleanup() { try? FileManager.default.removeItem(at: url) }

    /// Convert bounded-file times to absolute source times, retaining gaps if supplied.
    func sourceRanges(start: Double, end: Double) -> [AudioTimeRange] {
        guard start.isFinite, end.isFinite, end > start else { return [] }
        var result: [AudioTimeRange] = []
        for mapping in mappings {
            let low = max(start, mapping.inputStart), high = min(end, mapping.inputEnd)
            guard high > low else { continue }
            let scale = (mapping.sourceEnd - mapping.sourceStart) / (mapping.inputEnd - mapping.inputStart)
            let a = mapping.sourceStart + (low - mapping.inputStart) * scale
            let b = high == mapping.inputEnd ? mapping.sourceEnd : mapping.sourceStart + (high - mapping.inputStart) * scale
            if let last = result.last, abs(last.end - a) < 1e-7 {
                result[result.count - 1] = .init(start:last.start,end:b)
            } else { result.append(.init(start:a,end:b)) }
        }
        return result
    }

    func inputRanges(start: Double, end: Double) -> [AudioTimeRange] {
        guard start.isFinite, end.isFinite, end > start else { return [] }
        return mappings.compactMap { mapping in
            let low = max(start,mapping.sourceStart), high = min(end,mapping.sourceEnd)
            guard high > low else { return nil }
            let scale = (mapping.inputEnd-mapping.inputStart)/(mapping.sourceEnd-mapping.sourceStart)
            return .init(start:mapping.inputStart+(low-mapping.sourceStart)*scale,
                         end:high == mapping.sourceEnd ? mapping.inputEnd : mapping.inputStart+(high-mapping.sourceStart)*scale)
        }
    }

    func samples(maximumFrames: Int) throws -> [Float] {
        let file = try AVAudioFile(forReading:url)
        guard maximumFrames > 0, file.length <= maximumFrames else { throw BoundedAudioError.invalidWindow }
        var result: [Float] = []; result.reserveCapacity(Int(file.length))
        try forEachBlock(maximumFrames:4096) { _, block in result.append(contentsOf:block) }
        return result
    }

    /// Sequential bounded reads; VAD requests at most 30s, conversion requests at most 4096 frames.
    func forEachBlock(maximumFrames: Int, _ body: (Double, [Float]) throws -> Void) throws {
        guard maximumFrames > 0, maximumFrames <= 480_000 else { throw BoundedAudioError.invalidWindow }
        let file = try AVAudioFile(forReading:url)
        guard let buffer = AVAudioPCMBuffer(pcmFormat:file.processingFormat,frameCapacity:4096) else { throw BoundedAudioError.invalidFormat }
        while file.framePosition < file.length {
            try Task.checkCancellation()
            let position = file.framePosition
            let count = min(Int64(maximumFrames),file.length-position)
            var block: [Float] = []; block.reserveCapacity(Int(count))
            // AVAudioFile may return a packet-aligned short read for a large request.
            // Read fixed small chunks, demanding exact coverage rather than assuming EOF.
            while block.count < count {
                try Task.checkCancellation()
                let request = AVAudioFrameCount(min(4096,Int(count)-block.count))
                try file.read(into:buffer,frameCount:request)
                guard buffer.frameLength == request, let channel = buffer.floatChannelData?[0] else { throw BoundedAudioError.shortRead }
                block.append(contentsOf:UnsafeBufferPointer(start:channel,count:Int(request)))
            }
            try body(Double(position)/16_000,block)
        }
    }
}

struct BoundedAudioReader: Sendable {
    let temporaryRoot: URL
    init(temporaryRoot: URL = FileManager.default.temporaryDirectory.appendingPathComponent("WristNotesBoundedPCM",isDirectory:true)) {
        self.temporaryRoot = temporaryRoot
    }

    func materialize(_ window: AudioProcessingWindow) throws -> BoundedAudioFile {
        try Task.checkCancellation()
        guard !window.ranges.isEmpty, window.coreStart.isFinite, window.coreEnd.isFinite,
              window.coreStart >= 0, window.coreEnd > window.coreStart,
              window.coreEnd - window.coreStart <= 300.0000001,
              window.inputDuration <= 304.0000001,
              window.inputStart <= window.coreStart, window.inputEnd >= window.coreEnd,
              window.coreStart-window.inputStart <= 2.0000001, window.inputEnd-window.coreEnd <= 2.0000001 else { throw BoundedAudioError.invalidWindow }
        var previous: AudioSourceRange?
        for range in window.ranges {
            try range.validate()
            if let previous, abs(previous.end - range.sessionStartOffset) > 1e-7 || range.discontinuityBefore != nil {
                throw BoundedAudioError.invalidWindow
            }
            previous = range
        }
        let manager = FileManager.default
        try manager.createDirectory(at:temporaryRoot,withIntermediateDirectories:true)
        try protect(temporaryRoot)
        let url = temporaryRoot.appendingPathComponent(UUID().uuidString).appendingPathExtension("caf")
        var complete = false
        defer { if !complete { try? manager.removeItem(at:url) } }
        guard let format = AVAudioFormat(standardFormatWithSampleRate:16_000,channels:1) else { throw BoundedAudioError.invalidFormat }
        var frames: Int64 = 0, maximum = 0
        var mappings: [BoundedAudioFile.Mapping] = []
        // Scope closes the AVAudioFile before the caller opens it.
        do {
            let output = try AVAudioFile(forWriting:url,settings:format.settings)
            try protect(url)
            for range in window.ranges {
                let before = frames
                let file = try AVAudioFile(forReading:range.url)
                guard file.processingFormat.sampleRate == range.sampleRate, file.processingFormat.channelCount > 0,
                      range.endFrame <= file.length else { throw BoundedAudioError.shortRead }
                guard let converter = AVAudioConverter(from:file.processingFormat,to:format),
                      let input = AVAudioPCMBuffer(pcmFormat:file.processingFormat,frameCapacity:4096),
                      let buffer = AVAudioPCMBuffer(pcmFormat:format,frameCapacity:4096) else { throw BoundedAudioError.invalidFormat }
                converter.primeMethod = .none
                file.framePosition = range.startFrame
                let targetFrames = max(1,Int64((range.duration*16_000).rounded(.down)))
                var remaining = range.endFrame-range.startFrame
                var readError: Error?
                var finished = false
                while !finished {
                    try Task.checkCancellation()
                    let position = file.framePosition
                    var conversionError: NSError?
                    let status = converter.convert(to:buffer,error:&conversionError) { requested, status in
                        do {
                            try Task.checkCancellation()
                            guard remaining > 0 else { status.pointee = .endOfStream; return nil }
                            let count = AVAudioFrameCount(min(Int64(min(requested,4096)),remaining))
                            guard count > 0 else { throw BoundedAudioError.conversionFailed }
                            try file.read(into:input,frameCount:count)
                            guard input.frameLength == count else { throw BoundedAudioError.shortRead }
                            remaining -= Int64(count); maximum = max(maximum,Int(count))
                            status.pointee = .haveData
                            return input
                        } catch { readError = error; status.pointee = .endOfStream; return nil }
                    }
                    if let readError { throw readError }
                    if let conversionError { throw conversionError }
                    guard status != .error else { throw BoundedAudioError.conversionFailed }
                    let produced = buffer.frameLength
                    // Resamplers can emit a short filter tail beyond the requested end.
                    // Drain it, but write only frames belonging to the requested source range.
                    buffer.frameLength = AVAudioFrameCount(min(Int64(produced),max(0,targetFrames-(frames-before))))
                    if buffer.frameLength > 0 {
                        try output.write(from:buffer); frames += Int64(buffer.frameLength)
                        guard frames <= 4_864_000 + Int64(window.ranges.count) else { throw BoundedAudioError.invalidWindow }
                    }
                    finished = status == .endOfStream
                    guard finished || produced > 0 || file.framePosition > position else { throw BoundedAudioError.conversionFailed }
                }
                guard remaining == 0, frames-before == targetFrames else { throw BoundedAudioError.shortRead }
                mappings.append(.init(inputStart:Double(before)/16_000,inputEnd:Double(frames)/16_000,sourceStart:range.sessionStartOffset,sourceEnd:range.end))
            }
        }
        try Task.checkCancellation()
        guard Double(frames)/16_000 <= 304.0000001 else { throw BoundedAudioError.invalidWindow }
        complete = true
        return BoundedAudioFile(url:url,frames:frames,mappings:mappings,maximumSourceBufferFrames:maximum)
    }

    private func protect(_ url: URL) throws {
        var mutable = url
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        try mutable.setResourceValues(values)
        #if os(iOS)
        try FileManager.default.setAttributes([.protectionKey:FileProtectionType.complete],ofItemAtPath:url.path)
        #endif
    }
}
