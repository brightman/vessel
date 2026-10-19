import Foundation
import HealthKit

@MainActor
final class HeartRateService {
    private let store = HKHealthStore()
    private let type = HKQuantityType(.heartRate)
    private let hrvType = HKQuantityType(.heartRateVariabilitySDNN)
    private let stateOfMindType = HKObjectType.stateOfMindType()
    private var observers: [String: HKObserverQuery] = [:]
    var onChange: (() async -> Void)?

    func requestAccess(includeHRV: Bool = false) async throws {
        guard HKHealthStore.isHealthDataAvailable() else { throw TimelineError.unavailable }
        // A successful request means the sheet completed, not that read access was granted.
        let types: Set<HKObjectType> = includeHRV ? [type, hrvType] : [type]
        try await store.requestAuthorization(toShare: [], read: types)
        startObserving(includeHRV: includeHRV)
    }

    func requestStateOfMindAccess() async throws {
        guard HKHealthStore.isHealthDataAvailable() else { throw TimelineError.unavailable }
        try await store.requestAuthorization(toShare: [], read: [stateOfMindType])
        observe(stateOfMindType)
    }

    func startObserving(includeHRV: Bool = false, includeStateOfMind: Bool = false, includeHeartRate: Bool = true) {
        guard HKHealthStore.isHealthDataAvailable() else { return }
        if includeHeartRate { observe(type) }
        if includeHeartRate && includeHRV { observe(hrvType) }
        if includeStateOfMind { observe(stateOfMindType) }
    }

    private func observe(_ type: HKSampleType) {
        guard observers[type.identifier] == nil else { return }
        let query = HKObserverQuery(sampleType: type, predicate: nil) { [weak self] _, completion, error in
            Task { @MainActor in
                defer { completion() }
                guard error == nil else { return }
                await self?.onChange?()
            }
        }
        observers[type.identifier] = query
        store.execute(query)
        store.enableBackgroundDelivery(for: type, frequency: .immediate) { _, _ in }
    }

    func stopHeartRateObserving() async {
        await stopObserving(type)
        await stopObserving(hrvType)
    }

    func stopHRVObserving() async {
        await stopObserving(hrvType)
    }

    func stopStateOfMindObserving() async { await stopObserving(stateOfMindType) }

    private func stopObserving(_ type: HKSampleType) async {
        if let observer = observers.removeValue(forKey: type.identifier) { store.stop(observer) }
        try? await store.disableBackgroundDelivery(for: type)
    }

    func points(for note: VoiceNote) async throws -> [HeartRatePoint] {
        guard HKHealthStore.isHealthDataAvailable() else { throw TimelineError.unavailable }
        guard note.recordingClock?.canAlign(capturedAt: note.capturedAt, duration: note.duration) == true else { return [] }
        let predicate = HKQuery.predicateForSamples(withStart: note.capturedAt,
            end: note.capturedAt.addingTimeInterval(note.duration), options: [.strictStartDate, .strictEndDate])
        let query = HKSampleQueryDescriptor(predicates: [.quantitySample(type: type, predicate: predicate)],
            sortDescriptors: [SortDescriptor(\HKQuantitySample.startDate)], limit: 20_001)
        let samples = try await query.result(for: store)
        guard samples.count <= 20_000 else { throw TimelineError.tooManySamples }
        let unit = HKUnit.count().unitDivided(by: .minute())
        return samples.compactMap { sample in
            let product = sample.sourceRevision.productType ?? ""
            // Product type identifies the device that measured it, rather than an app/source display name.
            guard product.hasPrefix("Watch"), sample.metadata?[HKMetadataKeyWasUserEntered] as? Bool != true else { return nil }
            return HeartRatePoint(id: sample.uuid, start: sample.startDate, end: sample.endDate,
                bpm: sample.quantity.doubleValue(for: unit), sourceName: sample.sourceRevision.source.name,
                sourceBundle: sample.sourceRevision.source.bundleIdentifier, productType: product,
                deviceName: sample.device?.name,
                motionContext: Self.motionContext(from: sample))
        }
    }

    static func motionContext(from sample: HKQuantitySample) -> Int? {
        (sample.metadata?[HKMetadataKeyHeartRateMotionContext] as? NSNumber)?.intValue
    }

    func hrvPoints(for note: VoiceNote) async throws -> [HRVPoint] {
        guard HKHealthStore.isHealthDataAvailable() else { throw TimelineError.unavailable }
        guard note.recordingClock?.canAlign(capturedAt: note.capturedAt, duration: note.duration) == true else { return [] }
        // Query overlaps and preserve the original window; clipping its time must never change its SDNN value.
        let predicate = HKQuery.predicateForSamples(withStart: note.capturedAt,
            end: note.capturedAt.addingTimeInterval(note.duration), options: [])
        let query = HKSampleQueryDescriptor(predicates: [.quantitySample(type: hrvType, predicate: predicate)],
            sortDescriptors: [SortDescriptor(\HKQuantitySample.startDate)], limit: 20_001)
        let samples = try await query.result(for: store)
        guard samples.count <= 20_000 else { throw TimelineError.tooManySamples }
        return samples.compactMap { sample in
            let product = sample.sourceRevision.productType ?? ""
            guard product.hasPrefix("Watch"), sample.metadata?[HKMetadataKeyWasUserEntered] as? Bool != true else { return nil }
            return HRVPoint(id: sample.uuid, start: sample.startDate, end: sample.endDate,
                sdnnMilliseconds: sample.quantity.doubleValue(for: .secondUnit(with: .milli)),
                sourceName: sample.sourceRevision.source.name, sourceBundle: sample.sourceRevision.source.bundleIdentifier,
                productType: product, deviceName: sample.device?.name)
        }
    }

    func statesOfMind(for note: VoiceNote) async throws -> [StateOfMindPoint] {
        guard HKHealthStore.isHealthDataAvailable() else { throw TimelineError.unavailable }
        guard note.recordingClock?.canAlign(capturedAt: note.capturedAt, duration: note.duration) == true else { return [] }
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: note.capturedAt)
        guard let end = calendar.dateInterval(of: .day, for: note.capturedAt.addingTimeInterval(note.duration))?.end else { return [] }
        let momentary = NSCompoundPredicate(andPredicateWithSubpredicates: [
            HKQuery.predicateForStatesOfMind(with: HKStateOfMind.Kind.momentaryEmotion),
            HKQuery.predicateForSamples(withStart: note.capturedAt,
                end: note.capturedAt.addingTimeInterval(note.duration), options: [.strictStartDate])
        ])
        let daily = NSCompoundPredicate(andPredicateWithSubpredicates: [
            HKQuery.predicateForStatesOfMind(with: HKStateOfMind.Kind.dailyMood),
            HKQuery.predicateForSamples(withStart: start, end: end, options: [.strictStartDate])
        ])
        let predicate = NSCompoundPredicate(orPredicateWithSubpredicates: [momentary, daily])
        let query = HKSampleQueryDescriptor(predicates: [.stateOfMind(predicate)],
            sortDescriptors: [SortDescriptor(\HKStateOfMind.startDate)], limit: 20_001)
        let samples = try await query.result(for: store)
        guard samples.count <= 20_000 else { throw TimelineError.tooManySamples }
        return samples.compactMap { sample in
            guard let point = Self.stateOfMindPoint(from: sample, calendar: calendar) else { return nil }
            // Self-reports may originate from Health on iPhone or Mindfulness on Watch. Do not filter them as sensor readings.
            return point.isRelevant(to: note) ? point : nil
        }
    }

    static func stateOfMindPoint(from sample: HKStateOfMind, calendar: Calendar) -> StateOfMindPoint? {
        guard let kind = StateOfMindPoint.Kind(rawValue: sample.kind.rawValue) else { return nil }
        let day = calendar.dateInterval(of: .day, for: sample.startDate)
        return StateOfMindPoint(id: sample.uuid, date: sample.startDate, kind: kind,
            valence: sample.valence, classification: sample.valenceClassification.rawValue,
            labels: sample.labels.map(\.rawValue).sorted(), associations: sample.associations.map(\.rawValue).sorted(),
            sourceName: sample.sourceRevision.source.name, sourceBundle: sample.sourceRevision.source.bundleIdentifier,
            dayStart: kind == .dailyMood ? day?.start : nil, dayEnd: kind == .dailyMood ? day?.end : nil,
            timeZoneIdentifier: kind == .dailyMood ? calendar.timeZone.identifier : nil)
    }
}
