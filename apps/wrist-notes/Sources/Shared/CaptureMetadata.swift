import Foundation

/// A derived Apple Maps address cached with its original capture in SQLite.
struct CaptureAddress: Codable, Equatable, Sendable {
    static let currentResolutionVersion = 1
    let text: String
    let localeIdentifier: String
    let city: String?
    let region: String?
    /// Version zero is the legacy full-address-only cache. A current result may still have no city.
    let resolutionVersion: Int
    init?(text: String, localeIdentifier: String, city: String? = nil, region: String? = nil,
          resolutionVersion: Int = currentResolutionVersion) {
        let text = text.split(whereSeparator: { $0.isNewline }).joined(separator: ", ").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.count <= 1024, !localeIdentifier.isEmpty, localeIdentifier.count < 100 else { return nil }
        self.text = text; self.localeIdentifier = localeIdentifier
        self.city = Self.component(city); self.region = Self.component(region)
        self.resolutionVersion = max(0, resolutionVersion)
    }
    func isCurrent(for locale: String) -> Bool {
        localeIdentifier == locale && resolutionVersion >= Self.currentResolutionVersion
    }
    private static func component(_ value: String?) -> String? {
        guard let value else { return nil }
        let clean = value.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        return !clean.isEmpty && clean.count <= 256 ? clean : nil
    }
    private enum CodingKeys: String, CodingKey { case text, localeIdentifier, city, region, resolutionVersion }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard let value = try Self(text: c.decode(String.self, forKey: .text), localeIdentifier: c.decode(String.self, forKey: .localeIdentifier),
                                  city: c.decodeIfPresent(String.self, forKey: .city), region: c.decodeIfPresent(String.self, forKey: .region),
                                  resolutionVersion: c.decodeIfPresent(Int.self, forKey: .resolutionVersion) ?? 0) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Invalid cached address"))
        }
        self = value
    }
}

/// A capture point, never an inferred route or the phone's location at import time.
struct CaptureLocation: Codable, Equatable, Sendable {
    enum Source: String, Codable, Sendable {
        case watchRecording, phoneRecording, photoMetadata, phoneCamera
        var label: String {
            switch self {
            case .watchRecording, .phoneRecording: "录音开始位置"
            case .photoMetadata: "照片原始位置"
            case .phoneCamera: "拍照时的位置"
            }
        }
    }
    let latitude: Double
    let longitude: Double
    let accuracy: Double?
    let measuredAt: Date?
    let source: Source
    var address: CaptureAddress? = nil
    var title: String { String(format: "%.4f, %.4f", latitude, longitude) }
    var displayTitle: String { address?.text ?? "地点待解析" }
    /// Exact coordinate identity avoids attributing a neighbouring building's address.
    var coordinateKey: String { "\(latitude.bitPattern):\(longitude.bitPattern)" }
    func matchesCapture(_ other: Self) -> Bool {
        latitude == other.latitude && longitude == other.longitude && accuracy == other.accuracy && measuredAt == other.measuredAt && source == other.source
    }
    init?(latitude: Double, longitude: Double, accuracy: Double? = nil, measuredAt: Date? = nil, source: Source) {
        guard latitude.isFinite, longitude.isFinite, (-90...90).contains(latitude), (-180...180).contains(longitude),
              accuracy.map({ $0.isFinite && $0 >= 0 }) ?? true,
              measuredAt.map({ $0.timeIntervalSinceReferenceDate.isFinite }) ?? true else { return nil }
        self.latitude = latitude; self.longitude = longitude; self.accuracy = accuracy
        self.measuredAt = measuredAt; self.source = source
    }
    private enum CodingKeys: String, CodingKey { case latitude, longitude, accuracy, measuredAt, source, address }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard let value = try Self(latitude: c.decode(Double.self, forKey: .latitude), longitude: c.decode(Double.self, forKey: .longitude),
            accuracy: c.decodeIfPresent(Double.self, forKey: .accuracy), measuredAt: c.decodeIfPresent(Date.self, forKey: .measuredAt), source: c.decode(Source.self, forKey: .source)) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Invalid capture coordinates"))
        }
        self = value
        // A damaged derived cache must not discard the original capture coordinate.
        address = try? c.decodeIfPresent(CaptureAddress.self, forKey: .address)
    }
    func isNearCapture(_ date: Date) -> Bool {
        guard let measuredAt else { return false }
        return (-10...30).contains(measuredAt.timeIntervalSince(date))
    }
    var transferData: Data? { try? JSONEncoder().encode(self) }
    static func decodeTransfer(_ data: Any?) -> Self? {
        guard let data = data as? Data, data.count < 4096 else { return nil }
        return try? JSONDecoder().decode(Self.self, from: data)
    }
}

struct PhotoCaptureMetadata: Codable, Equatable, Sendable {
    enum ImportMethod: String, Codable, Sendable {
        case library, camera
        var label: String { self == .library ? "从相册选择" : "本机相机" }
    }
    var capturedAt: Date?
    var device: String?
    var importMethod: ImportMethod
    var location: CaptureLocation?
    var timeZoneKnown: Bool? = nil
}

/// Independent observation: late fixes never rewrite immutable audio descriptors.
struct RecordingLocationSample: Codable, Equatable, Sendable, Identifiable {
    let id: UUID
    let sessionID: UUID
    /// Requested audio-boundary association, not a claim that GPS fixed at this exact offset.
    /// The actual observation time is location.measuredAt; requestedAt is the boundary date.
    let sessionOffset: TimeInterval
    let requestedAt: Date
    let location: CaptureLocation
    let sourceDevice: String

    func validate() throws {
        guard sessionOffset.isFinite, sessionOffset >= 0,
              requestedAt.timeIntervalSinceReferenceDate.isFinite,
              !sourceDevice.isEmpty, sourceDevice.utf8.count <= 256,
              [.watchRecording, .phoneRecording].contains(location.source),
              location.accuracy != nil, location.isNearCapture(requestedAt) else {
            throw RecordingLocationError.invalidSample
        }
    }
    private enum CodingKeys: String, CodingKey { case id, sessionID, sessionOffset, requestedAt, location, sourceDevice }
    init(id: UUID = UUID(), sessionID: UUID, sessionOffset: TimeInterval, requestedAt: Date,
         location: CaptureLocation, sourceDevice: String) {
        self.id = id; self.sessionID = sessionID; self.sessionOffset = sessionOffset
        self.requestedAt = requestedAt; self.location = location; self.sourceDevice = sourceDevice
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(id: try c.decode(UUID.self, forKey: .id), sessionID: try c.decode(UUID.self, forKey: .sessionID),
                  sessionOffset: try c.decode(Double.self, forKey: .sessionOffset), requestedAt: try c.decode(Date.self, forKey: .requestedAt),
                  location: try c.decode(CaptureLocation.self, forKey: .location), sourceDevice: try c.decode(String.self, forKey: .sourceDevice))
        try validate()
    }
}
enum RecordingLocationError: Error { case invalidSample }

/// Sampled audio time drives ten-minute requests, independent of wall-clock changes.
struct RecordingLocationSchedule {
    private var nextBoundary: TimeInterval = 0
    private var stopped = false
    mutating func dueOffsets(through duration: TimeInterval) -> [TimeInterval] {
        guard !stopped, duration.isFinite, duration >= 0 else { return [] }
        var result: [TimeInterval] = []
        while nextBoundary <= duration {
            result.append(nextBoundary); nextBoundary += 600
        }
        return result
    }
    mutating func stopOffset(at duration: TimeInterval) -> TimeInterval? {
        guard !stopped, duration.isFinite, duration >= 0 else { return nil }
        stopped = true
        return duration
    }

}
