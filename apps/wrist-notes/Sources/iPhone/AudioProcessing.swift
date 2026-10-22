import Foundation

enum AudioSourceKind: String, Codable, Sendable { case session, legacyNote }
struct AudioSourceID: Hashable, Codable, Sendable {
    let kind: AudioSourceKind
    let id: UUID
    var key: String { "\(kind.rawValue):\(id.uuidString)" }
}
enum AudioProcessingError: Error { case invalidInput, staleJob, deletedSource, resourceUnavailable }
enum AudioJobState: String, Codable, Sendable { case pending, running, completed, missingResource, cancelled, failed }
enum AudioActivityKind: String, Codable, Sendable { case speech, noSpeech, uncertain }
enum AudioAnalysisOutcome: String, Codable, Sendable { case success, missingResource, failed, cancelled, notRequested }

struct AudioTimeRange: Codable, Equatable, Sendable {
    let start: Double
    let end: Double
    func validate() throws {
        guard start.isFinite, end.isFinite, start >= 0, end > start else { throw AudioProcessingError.invalidInput }
    }
}

/// Codable/Sendable snapshot of a RecordingSourceRange, with the immutable file hash.
/// sessionStartOffset is the source time of startFrame, including for sliced ranges.
struct AudioSourceRange: Codable, Equatable, Sendable {
    let chunkID: UUID
    let url: URL
    let startFrame: Int64
    let endFrame: Int64
    let sampleRate: Double
    let sessionStartOffset: Double
    let discontinuityBefore: String?
    let contentHash: String
    var duration: Double { Double(endFrame - startFrame) / sampleRate }
    var end: Double { sessionStartOffset + duration }
    var recordingRange: RecordingSourceRange {
        RecordingSourceRange(chunkID: chunkID, url: url, startFrame: startFrame, endFrame: endFrame, sampleRate: sampleRate, sessionStartOffset: sessionStartOffset, discontinuityBefore: discontinuityBefore)
    }
    init(range: RecordingSourceRange, contentHash: String) throws {
        try range.validate()
        guard contentHash.count == 64, contentHash.allSatisfy({ $0.isHexDigit }) else { throw AudioProcessingError.invalidInput }
        chunkID = range.chunkID; url = range.url; startFrame = range.startFrame; endFrame = range.endFrame
        sampleRate = range.sampleRate; sessionStartOffset = range.sessionStartOffset; discontinuityBefore = range.discontinuityBefore
        self.contentHash = contentHash.lowercased()
    }
    func validate() throws { _ = try Self(range: recordingRange, contentHash: contentHash) }
}

struct AudioSourceOrigin: Codable, Equatable, Sendable {
    let device: String
    let deviceID: String
    let fileName: String
    let recordingTimeIsEstimated: Bool
    init(recordingOrigin: RecordingOrigin) {
        device = recordingOrigin.device; deviceID = recordingOrigin.deviceID
        fileName = recordingOrigin.fileName; recordingTimeIsEstimated = recordingOrigin.recordingTimeIsEstimated
    }
    var recordingOrigin: RecordingOrigin {
        RecordingOrigin(device: device, deviceID: deviceID, fileName: fileName, recordingTimeIsEstimated: recordingTimeIsEstimated)
    }
}

struct AudioSourceSnapshot: Codable, Equatable, Sendable {
    let id: AudioSourceID
    let capturedAt: Date
    let title: String
    let origin: AudioSourceOrigin?
    let location: CaptureLocation?
    let ranges: [AudioSourceRange]
    let complete: Bool
    var fingerprint: String { AudioStableID.make(ranges) }
    init(id: AudioSourceID, capturedAt: Date, title: String, origin: AudioSourceOrigin? = nil, location: CaptureLocation? = nil, ranges: [AudioSourceRange], complete: Bool) throws {
        self.id = id; self.capturedAt = capturedAt; self.title = title; self.origin = origin; self.location = location
        self.ranges = ranges; self.complete = complete
        try validate()
    }
    func validate() throws {
        guard capturedAt.timeIntervalSinceReferenceDate.isFinite else { throw AudioProcessingError.invalidInput }
        var previous: AudioSourceRange?
        var raw: [String: [Range<Int64>]] = [:]
        for range in ranges {
            try range.validate()
            if let previous, range.sessionStartOffset < previous.end - 0.0000001 { throw AudioProcessingError.invalidInput }
            let frames = range.startFrame..<range.endFrame
            for key in ["chunk:" + range.chunkID.uuidString, "file:" + range.url.standardizedFileURL.path] {
                guard !(raw[key] ?? []).contains(where: { $0.overlaps(frames) }) else { throw AudioProcessingError.invalidInput }
                raw[key, default: []].append(frames)
            }
            previous = range
        }
    }
}

struct AudioProcessingWindow: Codable, Equatable, Sendable {
    let id: String
    let sourceID: AudioSourceID
    let configurationKey: String
    let coreStart: Double
    let coreEnd: Double
    let ranges: [AudioSourceRange]
    var inputStart: Double { ranges.first?.sessionStartOffset ?? coreStart }
    var inputEnd: Double { ranges.last?.end ?? coreEnd }
    var inputDuration: Double { ranges.reduce(0) { $0 + $1.duration } }
}
struct AudioTranscriptSpan: Codable, Equatable, Sendable {
    let start: Double
    let end: Double
    let text: String
    var speakerID: String? = nil
}
struct AudioActivityInterval: Codable, Equatable, Sendable {
    let start: Double
    let end: Double
    let kind: AudioActivityKind
}
/// IDs remain window-local until a later evidence-backed session mapping is established.
struct AudioSpeakerFeature: Codable, Equatable, Sendable {
    let localSpeakerID: String
    let modelVersion: String
    let vector: [Float]
}
struct AudioWindowResult: Codable, Equatable, Sendable {
    let spans: [AudioTranscriptSpan]
    let activities: [AudioActivityInterval]
    let asr: AudioAnalysisOutcome
    let vad: AudioAnalysisOutcome
    let speaker: AudioAnalysisOutcome
    let asrCoverage: [AudioTimeRange]
    let vadCoverage: [AudioTimeRange]
    var speakerFeatures: [AudioSpeakerFeature] = []
}
struct AudioProcessingJob: Codable, Equatable, Sendable {
    let window: AudioProcessingWindow
    let lease: UUID
}
struct AudioCompletedAnalysis: Codable, Equatable, Sendable {
    let window: AudioProcessingWindow
    /// Outcomes/coverage/features only; transcript/activity rows are read through repository queries.
    let result: AudioWindowResult
}
struct AudioProcessingProgress: Sendable {
    let states: [AudioJobState: Int]
    let revision: Int
    let configurationKey: String?
}

struct AudioInferenceStages: OptionSet, Sendable {
    let rawValue: Int
    static let asr = Self(rawValue:1)
    static let vad = Self(rawValue:2)
    static let speaker = Self(rawValue:4)
    static let all: Self = [.asr,.vad,.speaker]
}

/// A stage-selective retry has a persistable stage result and separate speaker label edits.
/// The worker revision-guards and merges these edits into its previously successful ASR rows.
struct AudioInferenceDelta: Sendable {
    let result: AudioWindowResult
    let speakerSpanUpdates: [AudioTranscriptSpan]
}


/// Unknown legacy duration is resolved from a bounded header on the worker before classifying a short thought.
enum AudioLegacyRouting {
    static func requiresDurableProcessing(kind: RecordingKind, duration: Double, measuredDuration: Double? = nil) -> Bool {
        if kind == .long || duration > 300 { return true }
        if duration > 0 { return false }
        guard let measuredDuration, measuredDuration.isFinite, measuredDuration > 0 else { return true }
        return measuredDuration > 300
    }
}

/// Combines explicit detector coverage. ASR text can invalidate silence, never establish it.
enum AudioActivityReconciler {
    static func reconcile(start: Double, end: Double, detections: [AudioActivityInterval],
                          coverage: [AudioTimeRange], spans: [AudioTranscriptSpan]) -> [AudioActivityInterval] {
        guard start.isFinite, end.isFinite, end > start else { return [] }
        struct Edge { let time: Double; let channel: Int; let delta: Int }
        var edges: [Edge] = [.init(time:start,channel:3,delta:0),.init(time:end,channel:3,delta:0)]
        func add(_ a: Double, _ b: Double, _ channel: Int) {
            guard a.isFinite, b.isFinite else { return }
            let low = max(start,a), high = min(end,b)
            guard high > low else { return }
            edges.append(.init(time:low,channel:channel,delta:1)); edges.append(.init(time:high,channel:channel,delta:-1))
        }
        for interval in detections {
            add(interval.start,interval.end,interval.kind == .speech ? 0 : interval.kind == .noSpeech ? 1 : 2)
        }
        for range in coverage { add(range.start,range.end,3) }
        for span in spans where !span.text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty { add(span.start,span.end,4) }
        edges.sort { $0.time < $1.time }
        var counts = [Int](repeating:0,count:5), previous = start
        var result: [AudioActivityInterval] = []
        for edge in edges {
            if edge.time-previous > 1e-9 {
                let kind: AudioActivityKind
                if counts[3] == 0 { kind = .uncertain }
                else if counts[0] > 0 { kind = .speech }
                else if counts[1] > 0 && counts[2] == 0 && counts[4] == 0 { kind = .noSpeech }
                else { kind = .uncertain }
                if let last = result.last, last.kind == kind, abs(last.end-previous) < 1e-7 {
                    result[result.count-1] = .init(start:last.start,end:edge.time,kind:kind)
                } else { result.append(.init(start:previous,end:edge.time,kind:kind)) }
            }
            counts[edge.channel] += edge.delta; previous = edge.time
        }
        return result
    }
}
