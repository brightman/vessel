import Foundation

/// A searchable projection of existing stores. Original IDs and media remain in their repositories.
struct DayRecord: Codable, Equatable, Identifiable, Sendable {
    enum Kind: String, Codable, Sendable { case voice, thought, image, activity, sleep, calendar, location
        var isAudio: Bool { self == .voice || self == .thought }
        var isLife: Bool { !isAudio && self != .image } }
    let id: UUID
    let capturedAt: Date
    let kind: Kind
    var title: String
    var text: String
    let summary: String
    let duration: TimeInterval
    let metricValue: Double?
    let intervals: [DateInterval]?
    var captureDevice: String? = nil
    var location: CaptureLocation? = nil
    var parentRecordID: UUID? = nil
    var recordingSessionID: UUID? = nil
    var recordingContinuation: Bool? = nil
    var lifeMoment: LifeMomentDetails? = nil

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
        guard recordingSessionID != nil else { return capturedAt >= start && capturedAt < end ? self : nil }
        let day = DateInterval(start: start, end: end)
        let clipped = (intervals ?? []).compactMap { interval -> DateInterval? in
            let start = max(day.start, interval.start), end = min(day.end, interval.end)
            return end > start ? DateInterval(start: start, end: end) : nil
        }
        guard let first = clipped.map(\.start).min() else { return nil }
        var result = DayRecord(id: id, capturedAt: first, kind: kind, title: title, text: text,
            summary: summary, duration: clipped.reduce(0) { $0 + $1.duration }, metricValue: metricValue, intervals: clipped)
        result.captureDevice = captureDevice; result.location = location
        result.parentRecordID = parentRecordID; result.recordingSessionID = recordingSessionID
        result.recordingContinuation = recordingContinuation == true || capturedAt < start
        return result
    }
}
