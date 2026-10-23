import Foundation

@MainActor private final class MovementGeocoder: CaptureAddressResolving {
    var calls = 0
    var pending: CheckedContinuation<CaptureAddress, Error>?
    func resolve(_ point: CaptureLocation, localeIdentifier: String) async throws -> CaptureAddress {
        calls += 1
        return try await withCheckedThrowingContinuation { pending = $0 }
    }
    func cancel() {}
    func finish(_ address: CaptureAddress) { pending?.resume(returning: address); pending = nil }
}

@main struct LocationMovementSmoke {
    static let start = Date(timeIntervalSince1970: 1_760_000_000)

    static func address(_ city: String?, region: String? = "中国", version: Int? = 1) throws -> CaptureAddress {
        var json: [String: Any] = ["text": "原始完整地址，不能从这里推断城市", "localeIdentifier": "zh-Hans"]
        json["city"] = city; json["region"] = region; json["resolutionVersion"] = version
        return try JSONDecoder().decode(CaptureAddress.self, from: JSONSerialization.data(withJSONObject: json))
    }

    static func point(_ suffix: Int, longitude: Double, minutes: Double = 0, accuracy: Double? = 10,
                      source: CaptureLocation.Source = .phoneRecording, city: String? = nil) throws -> DayRecord {
        let id = UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", suffix))!
        var record = DayRecord(id: id, capturedAt: start.addingTimeInterval(minutes * 60), kind: .location,
                               title: "采集位置", text: "原始地点依据")
        record.location = CaptureLocation(latitude: 0, longitude: longitude, accuracy: accuracy,
                                          measuredAt: record.capturedAt, source: source)!
        record.location?.address = try address(city)
        record.parentRecordID = UUID(uuidString: String(format: "10000000-0000-0000-0000-%012d", suffix))!
        record.captureDevice = "iPhone"
        return record
    }

    static func movementRules() throws {
        let a = try point(1, longitude: 0, city: "上海")
        let under = try point(2, longitude: 0.44965, minutes: 60, city: "苏州")
        let exact = try point(2, longitude: 0.449660181862269, minutes: 60, city: "苏州")
        let b = try point(2, longitude: 0.45, minutes: 60, city: "苏州")
        precondition(LocationMovementBuilder.records(points: [a, under]).isEmpty, "below 50 km is not movement")
        precondition(LocationMovementBuilder.records(points: [a, exact]).isEmpty, "50 km itself must not trigger")
        let records = LocationMovementBuilder.records(points: [a, b])
        precondition(records.count == 1, "strictly more than 50 km creates one movement")
        let record = records[0], movement = record.lifeMoment!.movement!
        precondition((50_037...50_038).contains(movement.distance), "distance is straight-line metres")
        precondition(record.capturedAt == b.capturedAt && record.kind == .location && record.metricValue == nil && record.parentRecordID == nil)
        precondition(movement.from.id == a.id && movement.to.id == b.id && movement.from.parentID == a.parentRecordID)
        precondition(movement.from.point == a.location && movement.to.point == b.location && movement.to.device == b.captureDevice)
        precondition(record.title == "从上海到苏州", "city labels come from structured cached fields")
        precondition(LocationMovementBuilder.records(points: [b, a, a, b, record]) == records, "input ordering, repeated IDs and derived records cannot duplicate movement")
        precondition(LocationMovementBuilder.records(points: [a]).isEmpty, "deleting a source removes the derived movement")
        let corrected = try point(2, longitude: 0.1, minutes: 60, city: "苏州")
        precondition(LocationMovementBuilder.records(points: [a, corrected]).isEmpty, "corrected coordinates recalculate distance")
        let sameCity = try point(2, longitude: 0.45, minutes: 60, city: "上海")
        let within = LocationMovementBuilder.records(points: [a, sameCity])[0]
        precondition(within.title == "上海内的位置变化" && within.id == record.id, "resolving city names must update the same source-pair record")
        var londonUK = a, londonCanada = b
        londonUK.location?.address = try address("London", region: "英国")
        londonCanada.location?.address = try address("London", region: "加拿大")
        let crossRegion = LocationMovementBuilder.records(points: [londonUK, londonCanada])[0]
        precondition(crossRegion.title == "从London（英国）到London（加拿大）" && crossRegion.id == record.id,
                     "same-name cities in different known regions cannot be called a city-internal change")
        londonCanada.location?.address = try address("London", region: "英国")
        precondition(LocationMovementBuilder.records(points: [londonUK, londonCanada])[0].title == "London内的位置变化",
                     "matching known regions preserve same-city wording")
        londonCanada.location?.address = try address("London", region: nil)
        precondition(LocationMovementBuilder.records(points: [londonUK, londonCanada])[0].title == "London内的位置变化",
                     "one unknown region preserves same-city wording")
        let unresolved = try point(2, longitude: 0.45, minutes: 60)
        precondition(LocationMovementBuilder.records(points: [a, unresolved])[0].title == "地点待解析", "full-address text must not fabricate a city")
        let lowAccuracy = try point(2, longitude: 0.45, minutes: 60, accuracy: 1001)
        let boundaryAccuracy = try point(2, longitude: 0.45, minutes: 60, accuracy: 1000)
        precondition(LocationMovementBuilder.records(points: [a, lowAccuracy]).isEmpty)
        precondition(LocationMovementBuilder.records(points: [a, boundaryAccuracy]).count == 1)
        let unknownRecording = try point(2, longitude: 0.45, minutes: 60, accuracy: nil)
        let unknownPhoto = try point(2, longitude: 0.45, minutes: 60, accuracy: nil, source: .photoMetadata)
        precondition(LocationMovementBuilder.records(points: [a, unknownRecording]).isEmpty, "recordings require known accuracy")
        precondition(LocationMovementBuilder.records(points: [a, unknownPhoto]).count == 1, "photo metadata can retain unknown precision")
        let fast = try point(2, longitude: 0.45, minutes: 1)
        let justTooFast = try point(2, longitude: 0.45, minutes: 2.38)
        let plausibleFlight = try point(2, longitude: 0.45, minutes: 2.39)
        let simultaneous = try point(2, longitude: 0.45)
        let distantTime = try point(2, longitude: 0.45, minutes: 48 * 60 + 1)
        let boundaryTime = try point(2, longitude: 0.45, minutes: 48 * 60)
        precondition(LocationMovementBuilder.records(points: [a, fast]).isEmpty, "impossible speed is rejected")
        precondition(LocationMovementBuilder.records(points: [a, justTooFast]).isEmpty, "speed above 350 m/s is rejected")
        precondition(LocationMovementBuilder.records(points: [a, plausibleFlight]).count == 1, "speed below 350 m/s is retained")
        precondition(LocationMovementBuilder.records(points: [a, simultaneous]).isEmpty, "zero time gap is rejected")
        precondition(LocationMovementBuilder.records(points: [a, distantTime]).isEmpty, "stale captures are not joined across more than 48 hours")
        precondition(LocationMovementBuilder.records(points: [a, boundaryTime]).count == 1)
        let jump = try point(2, longitude: 0.6, minutes: 10)
        let returnPoint = try point(3, longitude: 0.01, minutes: 20)
        precondition(LocationMovementBuilder.records(points: [a, jump, returnPoint]).isEmpty, "A-B-A bounce within 30 minutes is discarded")
        let stableReturn = try point(3, longitude: 0.01, minutes: 31)
        precondition(LocationMovementBuilder.records(points: [a, jump, stableReturn]).count == 2, "a later return is not silently treated as a bounce")
        let end = try point(4, longitude: 1.2, minutes: 90)
        var invalidTime = DayRecord(id: UUID(), capturedAt: Date(timeIntervalSinceReferenceDate: .infinity),
                                    kind: .location, title: "", text: "")
        invalidTime.location = b.location
        precondition(LocationMovementBuilder.records(points: [a, invalidTime]).isEmpty, "non-finite capture time is rejected")
        let filtered = LocationMovementBuilder.records(points: [end, lowAccuracy, a])
        precondition(filtered.count == 1 && filtered[0].lifeMoment?.movement?.from.id == a.id && filtered[0].lifeMoment?.movement?.to.id == end.id,
                     "adjacency is over valid captures")
        print("Location movements: threshold, source evidence, stable identity, city labels, accuracy, speed, bounce and deletion passed")
    }

    @MainActor static func spin() async { for _ in 0..<200 { await Task.yield() } }
    @MainActor static func cacheUpgrade() async throws {
        var legacy = try point(1, longitude: 0)
        legacy.location?.address = try address(nil, version: nil)
        precondition(legacy.location?.address?.text == "原始完整地址，不能从这里推断城市" && legacy.location?.address?.resolutionVersion == 0,
                     "legacy cached address text survives migration")
        let structured = try address(" 上海 ", region: " 中国 ")
        let reopened = try JSONDecoder().decode(CaptureAddress.self, from: JSONEncoder().encode(structured))
        precondition(reopened.city == "上海" && reopened.region == "中国" && reopened.text == structured.text,
                     "structured city and region survive persistence without changing the full address")
        let geo = MovementGeocoder()
        let active = CaptureAddressModel(resolver: geo, requestSpacing: .zero)
        let request = CaptureAddressRequest(owner: .voice(legacy.parentRecordID!), date: start, point: legacy.location!)
        var saved: CaptureAddress?
        active.synchronize(requests: [request], day: start, localeIdentifier: "zh-Hans", enabled: true, foreground: true) { _, value in saved = value; return true }
        await spin()
        precondition(geo.calls == 1, "old full-address caches need one structured-city refresh")
        let noCity = try address(nil)
        geo.finish(noCity); await spin()
        precondition(saved == noCity, "a successful no-city result is persisted as resolved")
        var resolved = request
        resolved.point.address = try JSONDecoder().decode(CaptureAddress.self, from: JSONEncoder().encode(saved!))
        let restartedGeo = MovementGeocoder()
        let guarded = CaptureAddressModel(resolver: restartedGeo, requestSpacing: .zero)
        guarded.synchronize(requests: [resolved], day: start, localeIdentifier: "zh-Hans", enabled: true, foreground: true) { _, _ in fatalError("resolved no-city result retried") }
        await spin()
        precondition(restartedGeo.calls == 0, "no-city resolution must survive restart without repeated requests")
        print("Structured addresses: legacy cache refresh and durable no-city completion passed")
    }

    @MainActor static func main() async throws {
        try movementRules()
        try await cacheUpgrade()
    }
}
