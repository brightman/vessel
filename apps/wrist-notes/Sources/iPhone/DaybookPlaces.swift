import Foundation

/// Independent location evidence ensures disabling AI's location source removes coordinates
/// from retrieval, even when voice/photo sources remain enabled.
enum DaybookPlaces {
    struct HomeSummary: Equatable {
        let placeCount: Int
        let recordCount: Int
        let labels: [String]
    }

    static func voice(_ note: VoiceNote) -> DayRecord {
        var record = DayRecord(id: note.id, capturedAt: note.capturedAt,
            kind: note.kind == .thought ? .thought : .voice, title: note.displayTitle,
            text: note.transcript, summary: note.summary, duration: note.duration)
        record.captureDevice = note.origin?.device ?? "设备未知"
        record.location = note.location
        return record
    }
    static func photo(_ moment: PhotoMoment) -> DayRecord {
        var record = DayRecord(id: moment.id, capturedAt: moment.capturedAt, kind: .image, title: moment.title, text: moment.searchableText)
        record.captureDevice = moment.captureDevice
        record.location = moment.photos.compactMap { $0.capture?.location }.first
        return record
    }
    static func records(notes: [VoiceNote], photos: [PhotoMoment]) -> [DayRecord] {
        let audio = notes.compactMap { note -> DayRecord? in
            guard let point = note.location else { return nil }
            return record(id: LifeAggregation.locationID(note.id), parentID: note.id, at: note.capturedAt,
                          point: point, device: note.origin?.device ?? "设备未知")
        }
        let images = photos.flatMap { moment in
            moment.photos.compactMap { photo -> DayRecord? in
                // A coordinate with no original time is visible in photo details only.
                guard let point = photo.capture?.location, let date = photo.capture?.capturedAt else { return nil }
                return record(id: LifeAggregation.locationID(photo.id), parentID: moment.id, at: date,
                              point: point, device: photo.capture?.device ?? "设备未知")
            }
        }
        return (audio + images).sorted { $0.capturedAt > $1.capturedAt }
    }
    private static func record(id: UUID, parentID: UUID, at date: Date, point: CaptureLocation, device: String) -> DayRecord {
        var record = DayRecord(id: id, capturedAt: date, kind: .location, title: point.displayTitle,
            text: "\(point.source.label) · \(point.displayTitle) · \(device)\n坐标：\(point.title)\n仅为一次采集点，不能推断连续行程或停留时长。")
        record.location = point; record.captureDevice = device; record.parentRecordID = parentID
        return record
    }
    static func placeCount(_ records: [DayRecord]) -> Int {
        // Coordinate cells are a compact overview, never inferred venue names.
        Set(records.compactMap { $0.location.map { String(format: "%.3f,%.3f", $0.latitude, $0.longitude) } }).count
    }

    static func homeSummary(_ records: [DayRecord]) -> HomeSummary {
        let located = records.filter { $0.kind == .location && $0.location != nil }
        var seenPlaces = Set<String>()
        var seenLabels = Set<String>()
        var labels: [String] = []
        for record in located {
            guard let point = record.location else { continue }
            let label = point.address?.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let identity: String
            if let label, !label.isEmpty {
                identity = "address:\(label.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX")))"
                if seenLabels.insert(label).inserted { labels.append(label) }
            } else {
                identity = "coordinate:\(String(format: "%.3f,%.3f", point.latitude, point.longitude))"
            }
            seenPlaces.insert(identity)
        }
        return HomeSummary(placeCount: seenPlaces.count, recordCount: located.count, labels: labels)
    }
}
