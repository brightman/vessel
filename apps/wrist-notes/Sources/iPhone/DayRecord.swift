import Foundation

/// A searchable projection of existing stores. Original IDs and media remain in their repositories.
struct DayRecord: Codable, Equatable, Identifiable, Sendable {
    enum Kind: String, Codable, Sendable { case voice, thought, image, activity, sleep, calendar, location
        var isAudio: Bool { self == .voice || self == .thought }
        var isLife: Bool { !isAudio && self != .image } }
    let id: UUID
    var capturedAt: Date
    let kind: Kind
    var title: String
    var text: String
    var summary: String
    var duration: TimeInterval
    let metricValue: Double?
    var intervals: [DateInterval]?
    var captureDevice: String? = nil
    var location: CaptureLocation? = nil
    var parentRecordID: UUID? = nil
    var recordingSessionID: UUID? = nil
    var recordingContinuation: Bool? = nil
    var lifeMoment: LifeMomentDetails? = nil

    /// File URLs stay in the source repository; persisted citations carry frame provenance only.
    struct ContentProvenance: Codable, Equatable, Sendable {
        struct AudioRange: Codable, Equatable, Sendable {
            let chunkID: UUID
            let startFrame: Int64
            let endFrame: Int64
            let sampleRate: Double
            let sourceOffset: Double
            var duration: Double { Double(endFrame - startFrame) / sampleRate }
        }
        struct TextSpan: Codable, Equatable, Sendable {
            let start: Double
            let end: Double
            let text: String
        }
        let segmentID: UUID
        let sourceID: UUID
        let sourceKind: String
        let sourceRevision: Int
        var segmentRevision: Int
        let configurationKey: String
        let contentSignature: String
        let sourceDate: Date
        var ranges: [AudioRange]
        var transcript: [TextSpan]
    }
    var contentProvenance: ContentProvenance? = nil
    var contentScope: DateInterval? = nil
    var indexScopeIdentity: String {
        let scope = contentScope.map { "\($0.start.timeIntervalSinceReferenceDate)|\($0.end.timeIntervalSinceReferenceDate)" } ?? "unscoped"
        return "\(scope)|\(contentProvenance?.sourceRevision ?? 0)|\(contentProvenance?.segmentRevision ?? 0)|\(contentProvenance?.contentSignature ?? "")"
    }

    init(id: UUID, capturedAt: Date, kind: Kind, title: String, text: String,
         summary: String = "", duration: TimeInterval = 0, metricValue: Double? = nil, intervals: [DateInterval]? = nil) {
        self.id = id; self.capturedAt = capturedAt; self.kind = kind
        self.title = title; self.text = text; self.summary = summary; self.duration = duration; self.metricValue = metricValue; self.intervals = intervals
    }
}

// Optional detail payloads keep old projections and stored records decodable.
struct LifeMomentDetails: Codable, Equatable, Sendable {
    var steps: StepMoment? = nil
    var sleep: SleepMoment? = nil
    var movement: LocationMovement? = nil
}
struct StepMoment: Codable, Equatable, Sendable {
    let interval: DateInterval
    let count: Double?
    let updatedAt: Date?
    let archived: Bool
}
enum SleepStage: String, Codable, Sendable { case asleep, core, deep, rem, awake, inBed }
struct SleepMoment: Codable, Equatable, Sendable {
    let startedAt: Date?
    let endedAt: Date?
    let asleepSeconds: TimeInterval?
    let awakeSeconds: TimeInterval?
    let stages: [SleepStage: TimeInterval]
    let sourceName: String?
    let isMain: Bool
    var confirmed = false
}
struct LocationMovement: Codable, Equatable, Sendable {
    struct Evidence: Codable, Equatable, Sendable {
        let id: UUID
        let parentID: UUID?
        let capturedAt: Date
        let point: CaptureLocation
        let device: String?
    }
    let from: Evidence
    let to: Evidence
    let distance: Double
}

// Foundation-only so existing direct swiftc consumers do not gain presentation dependencies.
extension DayRecord {
    func recordingProjection(on date: Date, calendar: Calendar = .current) -> DayRecord? {
        guard let day = calendar.dateInterval(of: .day, for: date) else { return nil }
        return recordingProjection(from: day.start, to: day.end)
    }

    func recordingProjection(from start: Date, to end: Date) -> DayRecord? {
        guard end > start else { return nil }
        guard recordingSessionID != nil || contentProvenance != nil else { return capturedAt >= start && capturedAt < end ? self : nil }
        let clipped = (intervals ?? []).compactMap { interval -> DateInterval? in
            let low = max(start, interval.start), high = min(end, interval.end)
            return high > low ? DateInterval(start: low, end: high) : nil
        }
        guard let first = clipped.map(\.start).min() else { return nil }
        var result = self
        result.contentScope = DateInterval(start:start,end:end)
        result.capturedAt = first; result.intervals = clipped
        result.duration = clipped.reduce(0) { $0 + $1.duration }
        result.recordingContinuation = recordingContinuation == true || capturedAt < start
        if var provenance = contentProvenance {
            let low = start.timeIntervalSince(provenance.sourceDate), high = end.timeIntervalSince(provenance.sourceDate)
            provenance.ranges = provenance.ranges.compactMap { range in
                let a = max(low,range.sourceOffset), b = min(high,range.sourceOffset + range.duration)
                guard b > a else { return nil }
                let firstFrame = range.startFrame + Int64(ceil((a-range.sourceOffset)*range.sampleRate - 1e-7))
                let lastFrame = min(range.endFrame,range.startFrame + Int64(floor((b-range.sourceOffset)*range.sampleRate + 1e-7)))
                guard lastFrame > firstFrame else { return nil }
                return .init(chunkID:range.chunkID,startFrame:firstFrame,endFrame:lastFrame,sampleRate:range.sampleRate,sourceOffset:range.sourceOffset + Double(firstFrame-range.startFrame)/range.sampleRate)
            }
            // A timed utterance may cross physical files when their available audio is continuous.
            // Merge only overlapping/adjacent ranges; a positive missing-audio gap remains a gap.
            var coverage: [(start: Double, end: Double)] = []
            for range in provenance.ranges.sorted(by: { $0.sourceOffset < $1.sourceOffset }) {
                let end = range.sourceOffset + range.duration
                if let last = coverage.last, range.sourceOffset <= last.end {
                    coverage[coverage.count - 1].end = max(last.end,end)
                } else { coverage.append((range.sourceOffset,end)) }
            }
            provenance.transcript = provenance.transcript.filter { span in
                // Span timestamps cannot assign individual words across a date or audio gap.
                span.start >= low && span.end <= high && coverage.contains { span.start >= $0.start && span.end <= $0.end }
            }
            result.text = provenance.transcript.map(\.text).joined(separator:"\n")
            // Whole-segment generated descriptions cannot ground a narrower date's facts.
            if clipped != intervals { result.title = "录音片段"; result.summary = "" }
            result.contentProvenance = provenance
        }
        return result
    }

    static func evidenceRecords(_ records: [DayRecord], scope: DateInterval) -> [DayRecord] {
        let projected = records.compactMap { $0.recordingProjection(from:scope.start,to:scope.end) }
        let children = Set(projected.compactMap { $0.contentProvenance?.sourceID })
        var seen = Set<UUID>()
        return projected.compactMap { record in
            guard seen.insert(record.id).inserted else { return nil }
            if record.contentProvenance == nil && children.contains(record.recordingSessionID ?? record.id) { return nil }
            return record
        }
    }
}

/// Process-local fence for snapshots captured before durable source deletion.
/// Filtering at asynchronous publication and send boundaries also rejects old captured arrays.
final class LegacyAudioDeletionLedger: @unchecked Sendable {
    static let notification = Notification.Name("WiseLife.LegacyAudioSourceDeleted")
    static let shared = LegacyAudioDeletionLedger()
    private let lock = NSLock()
    private var ids = Set<UUID>()
    private var observer: NSObjectProtocol?
    private init() {
        observer = NotificationCenter.default.addObserver(forName:Self.notification,object:nil,queue:nil) { [weak self] note in
            guard let id = note.userInfo?["legacyNoteID"] as? UUID else { return }
            self?.record(id)
        }
    }
    func record(_ id: UUID) { lock.lock(); defer { lock.unlock() }; ids.insert(id) }
    func contains(_ id: UUID) -> Bool { lock.lock(); defer { lock.unlock() }; return ids.contains(id) }
    func filter(_ records: [DayRecord]) -> [DayRecord] {
        lock.lock(); let deleted = ids; lock.unlock()
        return records.filter { record in
            if let source = record.contentProvenance {
                return source.sourceKind != "legacyNote" || !deleted.contains(source.sourceID)
            }
            return record.recordingSessionID != nil || !deleted.contains(record.id)
        }
    }
}
