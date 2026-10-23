import CoreLocation
import EventKit
import HealthKit
import Foundation

/// Read APIs only. Observation is explicitly started from the persisted source setting.
@MainActor
final class LifeSourceReader: NSObject, CLLocationManagerDelegate, LifeSourceReading {
    var onLocationAuthorizationChange: (() -> Void)?
    private let health = HKHealthStore()
    private let events = EKEventStore()
    private let location = CLLocationManager()
    private var locationWaiters: [CheckedContinuation<CLLocation, Error>] = []
    private var timeout: Task<Void, Never>?
    private var healthObservers: [HKObserverQuery] = []
    private var observationID = UUID()
    private var observationError: ((Error) -> Void)?
    private var backgroundDeliveryTask: Task<Void, Never>?
    private var configuredBackgroundGeneration: UUID?
    private var healthReadCancellations: [UUID: () -> Void] = [:]

    private var observedHealthTypes: [HKSampleType] { [HKQuantityType(.stepCount), HKCategoryType(.sleepAnalysis)] }

    override init() { super.init(); location.delegate = self; location.desiredAccuracy = kCLLocationAccuracyHundredMeters }
    func authorize(_ source: LifeSource) async throws {
        switch source {
        case .health:
            guard HKHealthStore.isHealthDataAvailable() else { throw failure(.unavailable, "此设备不支持 Apple 健康。") }
            // HealthKit deliberately hides read authorization. Success means the prompt completed only.
            try await health.requestAuthorization(toShare: [], read: [HKQuantityType(.stepCount), HKCategoryType(.sleepAnalysis)])
        case .calendar:
            if EKEventStore.authorizationStatus(for: .event) == .notDetermined { _ = try await events.requestFullAccessToEvents() }
            try checkCalendar()
        case .location:
            guard CLLocationManager.locationServicesEnabled() else { throw failure(.unavailable, "系统定位服务未开启。") }
            if location.authorizationStatus == .notDetermined { location.requestWhenInUseAuthorization() }
            else { try checkLocation() }
        }
    }
    func read(_ source: LifeSource, day: Date, calendar: Calendar = .current) async throws -> [DayRecord] {
        let interval = LifeAggregation.dayInterval(day, calendar: calendar)
        switch source {
        case .health:
            guard HKHealthStore.isHealthDataAvailable() else { throw failure(.unavailable, "此设备不支持 Apple 健康。") }
            try Task.checkCancellation()
            let steps = try await stepCount(interval)
            try Task.checkCancellation()
            let start = calendar.date(byAdding: .day, value: -1, to: interval.start)!
            let end = calendar.date(byAdding: .day, value: 1, to: interval.end)!
            let sleep = try await sleepSamples(.init(start: start, end: end))
            return LifeMomentBuilder.health(day: day, steps: steps, samples: sleep, now: .now, calendar: calendar)
        case .calendar:
            try checkCalendar()
            let found = events.events(matching: events.predicateForEvents(withStart: interval.start, end: interval.end, calendars: nil))
            return found.filter { $0.status != .canceled && $0.startDate < interval.end && $0.endDate > interval.start }.map { event in
                let key = event.calendarItemIdentifier + "|" + (event.occurrenceDate.map { String($0.timeIntervalSince1970) } ?? "single")
                let time = event.isAllDay ? "全天" : event.startDate.formatted(date: .omitted, time: .shortened) + "–" + event.endDate.formatted(date: .omitted, time: .shortened)
                let title = event.title?.isEmpty == false ? event.title! : "未命名日程"
                return DayRecord(id: LifeAggregation.recordID(source: .calendar, key: key, day: interval.start), capturedAt: max(interval.start, event.startDate), kind: .calendar, title: title,
                    text: "日历：\(event.calendar.title) · \(time)\n\(title)" + (event.location.map { "\n地点：\($0)" } ?? ""))
            }
        case .location: return [] // Location is attached only after a record is saved.
        }
    }
    func oneShotLocation() async throws -> LifeCoordinate {
        try checkLocation()
        let value: CLLocation = try await withCheckedThrowingContinuation { continuation in
            locationWaiters.append(continuation)
            guard locationWaiters.count == 1 else { return }
            location.requestLocation()
            timeout = Task { [weak self] in
                try? await Task.sleep(for: .seconds(20))
                guard !Task.isCancelled else { return }
                self?.finishLocation(.failure(self?.failure(.error, "定位超时，请在前台保存下一条记录时重试。") ?? CancellationError()))
            }
        }
        return LifeCoordinate(latitude: value.coordinate.latitude, longitude: value.coordinate.longitude, accuracy: value.horizontalAccuracy)
    }
    func locationAvailabilityIssue() -> LifeSourceReadFailure? {
        do { try checkLocation(); return nil }
        catch { return error as? LifeSourceReadFailure }
    }
    func stop(_ source: LifeSource) {
        if source == .health {
            let cancellations = Array(healthReadCancellations.values)
            healthReadCancellations.removeAll()
            cancellations.forEach { $0() }
        }
        if source == .location { location.stopUpdatingLocation(); finishLocation(.failure(CancellationError())) }
    }

    func startHealthObservation(onChange: @escaping (@escaping () -> Void) -> Void, onError: @escaping (Error) -> Void) {
        guard healthObservers.isEmpty else { return }
        guard HKHealthStore.isHealthDataAvailable() else { onError(failure(.unavailable, "此设备不支持 Apple 健康")); return }
        let id = UUID(); observationID = id; observationError = onError
        for type in observedHealthTypes {
            let query = HKObserverQuery(sampleType: type, predicate: nil) { [weak self] _, completion, error in
                Task { @MainActor [weak self] in
                    guard let self, self.observationID == id else { completion(); return }
                    if let error { onError(error); completion(); return }
                    onChange(completion)
                }
            }
            healthObservers.append(query)
            health.execute(query)
        }
        reconcileBackgroundDelivery()
    }

    func stopHealthObservation() {
        observationID = UUID(); observationError = nil
        healthObservers.forEach { health.stop($0) }; healthObservers.removeAll()
        stop(.health)
        reconcileBackgroundDelivery()
    }

    /// Keep enable/disable operations serialized. A quick pause/re-enable must not leave a
    /// late disable call winning over the user's most recent setting.
    private func reconcileBackgroundDelivery() {
        guard backgroundDeliveryTask == nil, HKHealthStore.isHealthDataAvailable() else { return }
        backgroundDeliveryTask = Task { [weak self] in
            guard let self else { return }
            while self.configuredBackgroundGeneration != self.observationID {
                let enabled = !self.healthObservers.isEmpty
                let id = self.observationID
                for type in self.observedHealthTypes {
                    do {
                        if enabled {
                            let frequency: HKUpdateFrequency = type == HKQuantityType(.stepCount) ? .hourly : .immediate
                            try await self.health.enableBackgroundDelivery(for: type, frequency: frequency)
                        } else { try await self.health.disableBackgroundDelivery(for: type) }
                    } catch {
                        if enabled, self.observationID == id { self.observationError?(error) }
                    }
                }
                self.configuredBackgroundGeneration = id
            }
            self.backgroundDeliveryTask = nil
        }
    }

    /// HealthKit does not promise a callback after stop(query). Own the continuation so pause,
    /// timeout, and a racing query callback can resume it exactly once.
    private func healthQuery<Value>(_ makeQuery: (@escaping (Result<Value, Error>) -> Void) -> HKQuery) async throws -> Value {
        let id = UUID()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                let query = makeQuery { [weak self] result in
                    Task { @MainActor [weak self] in
                        guard let self, self.healthReadCancellations.removeValue(forKey: id) != nil else { return }
                        continuation.resume(with: result)
                    }
                }
                healthReadCancellations[id] = { [health] in
                    health.stop(query)
                    continuation.resume(throwing: CancellationError())
                }
                health.execute(query)
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.healthReadCancellations.removeValue(forKey: id)?() }
        }
    }
    private func stepCount(_ interval: DateInterval) async throws -> Double? {
        try await healthQuery { complete in
            // HKStatisticsQuery uses HealthKit's cumulative merge across sources; never sum raw Watch/iPhone samples.
            HKStatisticsQuery(quantityType: HKQuantityType(.stepCount), quantitySamplePredicate: HKQuery.predicateForSamples(withStart: interval.start, end: interval.end, options: [.strictStartDate]), options: .cumulativeSum) { _, result, error in
                if let error { complete(.failure(error)) }
                else { complete(.success(result?.sumQuantity()?.doubleValue(for: .count()))) }
            }
        }
    }
    private func sleepSamples(_ interval: DateInterval) async throws -> [LifeSleepSample] {
        try await healthQuery { complete in
            HKSampleQuery(sampleType: HKCategoryType(.sleepAnalysis), predicate: HKQuery.predicateForSamples(withStart: interval.start, end: interval.end), limit: HKObjectQueryNoLimit, sortDescriptors: nil) { _, samples, error in
                if let error { complete(.failure(error)); return }
                let stages: [Int: SleepStage] = [HKCategoryValueSleepAnalysis.asleepUnspecified.rawValue: .asleep,
                    HKCategoryValueSleepAnalysis.asleepCore.rawValue: .core, HKCategoryValueSleepAnalysis.asleepDeep.rawValue: .deep,
                    HKCategoryValueSleepAnalysis.asleepREM.rawValue: .rem, HKCategoryValueSleepAnalysis.awake.rawValue: .awake,
                    HKCategoryValueSleepAnalysis.inBed.rawValue: .inBed]
                complete(.success((samples as? [HKCategorySample] ?? []).compactMap { sample in
                    guard let stage = stages[sample.value] else { return nil }
                    let source = sample.sourceRevision.source
                    return LifeSleepSample(start: sample.startDate, end: sample.endDate, stage: stage,
                        sourceID: source.bundleIdentifier + "|" + (sample.device?.localIdentifier ?? ""), sourceName: source.name)
                }))
            }
        }
    }
    private func checkCalendar() throws {
        guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else { throw failure(.denied, "未获日历读取权限。请在系统设置中允许完整访问；本应用只读取日程，不会写入日历。") }
    }
    private func checkLocation() throws {
        guard CLLocationManager.locationServicesEnabled() else { throw failure(.unavailable, "系统定位服务未开启。") }
        switch location.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse: return
        case .notDetermined: throw failure(.awaitingAuthorization, "等待定位授权；之后仅在前台保存新记录时获取一次地点。")
        default: throw failure(.denied, "未获定位权限。请前往系统设置。")
        }
    }
    private func failure(_ status: LifeSourceStatus, _ message: String) -> LifeSourceReadFailure { LifeSourceReadFailure(status: status, message: message) }
    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in self.onLocationAuthorizationChange?() }
    }
    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        Task { @MainActor in
            guard let value = locations.last, value.horizontalAccuracy >= 0, abs(value.timestamp.timeIntervalSinceNow) < 60 else { self.finishLocation(.failure(self.failure(.error, "没有获得新的有效地点。"))); return }
            self.finishLocation(.success(value))
        }
    }
    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) { Task { @MainActor in self.finishLocation(.failure(error)) } }
    private func finishLocation(_ result: Result<CLLocation, Error>) {
        timeout?.cancel(); timeout = nil
        let waiters = locationWaiters; locationWaiters.removeAll()
        waiters.forEach { $0.resume(with: result) }
    }
}
