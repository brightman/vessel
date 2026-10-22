import Foundation
import CryptoKit

/// A disposable projection of existing capture points, never a route or a location request.
enum LocationMovementBuilder {
    static func records(points: [DayRecord]) -> [DayRecord] {
        var seen: Set<UUID> = []
        let valid = points.filter { record in
            guard record.kind == .location, record.lifeMoment?.movement == nil,
                  record.capturedAt.timeIntervalSinceReferenceDate.isFinite,
                  let point = record.location else { return false }
            return point.accuracy.map { $0 <= 1_000 } ?? (point.source == .photoMetadata)
        }.sorted {
            $0.capturedAt == $1.capturedAt ? $0.id.uuidString < $1.id.uuidString : $0.capturedAt < $1.capturedAt
        }.filter { seen.insert($0.id).inserted }

        // Remove the middle sample of a short return to the original vicinity before pairing.
        // This also prevents a rejected jump from becoming the start of a second false movement.
        var bounces: Set<UUID> = []
        if valid.count >= 3 {
            for index in 1..<(valid.count - 1) {
                let a = valid[index - 1], b = valid[index], c = valid[index + 1]
                let gap = c.capturedAt.timeIntervalSince(a.capturedAt)
                guard gap > 0, gap <= 30 * 60,
                      a.capturedAt < b.capturedAt, b.capturedAt < c.capturedAt,
                      distance(a.location!, c.location!) <= 5_000,
                      exceedsThreshold(distance(a.location!, b.location!)),
                      exceedsThreshold(distance(b.location!, c.location!)) else { continue }
                bounces.insert(b.id)
            }
        }
        let captures = valid.filter { !bounces.contains($0.id) }
        return zip(captures, captures.dropFirst()).compactMap { from, to in
            let seconds = to.capturedAt.timeIntervalSince(from.capturedAt)
            guard seconds > 0, seconds <= 48 * 3600 else { return nil }
            let metres = distance(from.location!, to.location!)
            guard exceedsThreshold(metres), metres / seconds <= 350 else { return nil }
            var record = DayRecord(id: pairID(from: from.id, to: to.id), capturedAt: to.capturedAt,
                kind: .location, title: title(from: from.location!, to: to.location!),
                text: "两次记录相距约 \(Int((metres / 1_000).rounded())) km · \(clock(from.capturedAt)) → \(clock(to.capturedAt))")
            record.lifeMoment = .init(movement: .init(from: evidence(from), to: evidence(to), distance: metres))
            return record
        }
    }

    private static func evidence(_ record: DayRecord) -> LocationMovement.Evidence {
        .init(id: record.id, parentID: record.parentRecordID, capturedAt: record.capturedAt,
              point: record.location!, device: record.captureDevice)
    }
    private static func title(from: CaptureLocation, to: CaptureLocation) -> String {
        guard let first = from.address?.city, let second = to.address?.city else { return "地点待解析" }
        if first == second, let firstRegion = from.address?.region, let secondRegion = to.address?.region, firstRegion != secondRegion {
            return "从\(first)（\(firstRegion)）到\(second)（\(secondRegion)）"
        }
        return first == second ? "\(first)内的位置变化" : "从\(first)到\(second)"
    }
    private static func clock(_ date: Date) -> String { date.formatted(date: .omitted, time: .shortened) }
    private static func exceedsThreshold(_ metres: Double) -> Bool {
        // Suppress only floating-point roundoff at exactly 50 km (less than a nanometre).
        metres - 50_000 > Double(50_000).ulp * 4
    }

    /// Haversine great-circle distance in metres, using the IUGG mean Earth radius.
    private static func distance(_ a: CaptureLocation, _ b: CaptureLocation) -> Double {
        let radians = Double.pi / 180
        let lat = (b.latitude - a.latitude) * radians, lon = (b.longitude - a.longitude) * radians
        let value = pow(sin(lat / 2), 2) + cos(a.latitude * radians) * cos(b.latitude * radians) * pow(sin(lon / 2), 2)
        return 6_371_008.8 * 2 * atan2(sqrt(max(0, min(1, value))), sqrt(max(0, 1 - min(1, value))))
    }
    private static func pairID(from: UUID, to: UUID) -> UUID {
        let key = "life-v1|location-movement|\(from.uuidString)|\(to.uuidString)"
        let bytes = Array(SHA256.hash(data: Data(key.utf8)).prefix(16))
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }
}
