import Combine
import Foundation

/// SQLite stays on its own actor; geocoding never participates in audio or inference work.
private actor RecordingLocationAddressWorker {
    private let open: () throws -> RecordingSessionRepository
    private var repository: RecordingSessionRepository?
    init(open: @escaping () throws -> RecordingSessionRepository) { self.open = open }
    private func current() throws -> RecordingSessionRepository {
        if let repository { return repository }
        let value = try open(); repository = value; return value
    }
    func samples(_ ids: [UUID]) throws -> [RecordingLocationSample] {
        try Task.checkCancellation()
        let repository = try current()
        return try ids.flatMap { try repository.locationSamples(sessionID: $0) }
    }
    func apply(_ address: CaptureAddress, sample: RecordingLocationSample) throws -> Bool {
        try Task.checkCancellation()
        return try current().applyLocationAddress(address, sampleID: sample.id, matching: sample.location)
    }
}

/// One foreground Apple Maps request at a time, with durable coordinates retained offline.
/// Failed lookups retry on a new day/locale/foreground scope, never on every UI render.
@MainActor final class RecordingLocationAddressModel: ObservableObject {
    private let resolver: any CaptureAddressResolving
    private let worker: RecordingLocationAddressWorker
    private let requestSpacing: Duration
    private var task: Task<Void, Never>?
    private var generation = UUID()
    private var scope = ""
    private var attempted = Set<UUID>()
    private var reloadRequested = false

    #if os(iOS)
    convenience init() {
        let root = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("VoiceNotes", isDirectory: true)
        self.init(resolver: AppleCaptureAddressResolver(), openRepository: {
            try RecordingSessionRepository(root: root.appendingPathComponent("RecordingSessions", isDirectory: true),
                database: DaybookDatabase(url: DaybookDatabase.metadataURL(forRoot: root)))
        })
    }
    #endif
    init(resolver: any CaptureAddressResolving, requestSpacing: Duration = .seconds(1),
         openRepository: @escaping () throws -> RecordingSessionRepository) {
        self.resolver = resolver; self.requestSpacing = requestSpacing
        worker = RecordingLocationAddressWorker(open: openRepository)
    }

    func synchronize(sessionIDs: [UUID], day: Date, localeIdentifier: String, enabled: Bool, foreground: Bool) {
        // Bound each visible scope; unresolved observations keep their raw coordinates.
        let ids = Array(Set(sessionIDs)).sorted { $0.uuidString < $1.uuidString }.prefix(200)
        let day = Calendar.current.startOfDay(for: day)
        let nextScope = "\(enabled)|\(foreground)|\(day.timeIntervalSinceReferenceDate)|\(localeIdentifier)|\(ids.map(\.uuidString).joined(separator: ","))"
        if scope != nextScope {
            generation = UUID(); task?.cancel(); task = nil; resolver.cancel()
            scope = nextScope; attempted = []
        }
        guard enabled, foreground, !ids.isEmpty else { return }
        reloadRequested = true
        guard task == nil else { return }
        let token = generation
        task = Task { [weak self] in
            guard let self else { return }
            defer { if self.generation == token { self.task = nil } }
            repeat {
                self.reloadRequested = false
                let samples: [RecordingLocationSample]
                do { samples = try await self.worker.samples(Array(ids)) }
                catch { return } // Protected/unavailable storage never interrupts media processing.
                guard self.generation == token, !Task.isCancelled else { return }
                var cache: [String: CaptureAddress] = [:]
                for sample in samples {
                    if let address = sample.location.address, address.isCurrent(for: localeIdentifier) { cache[sample.location.coordinateKey] = address }
                }
                let candidates = samples.filter {
                    Calendar.current.isDate($0.location.measuredAt ?? $0.requestedAt, inSameDayAs: day)
                        && $0.location.address?.isCurrent(for: localeIdentifier) != true && !self.attempted.contains($0.id)
                }.prefix(128)
                for sample in candidates {
                    guard self.generation == token, !Task.isCancelled else { return }
                    self.attempted.insert(sample.id)
                    let wasCached = cache[sample.location.coordinateKey] != nil
                    do {
                        let address: CaptureAddress
                        if let cached = cache[sample.location.coordinateKey] { address = cached }
                        else { address = try await self.resolver.resolve(sample.location, localeIdentifier: localeIdentifier) }
                        try Task.checkCancellation()
                        guard self.generation == token, address.isCurrent(for: localeIdentifier) else { return }
                        cache[sample.location.coordinateKey] = address
                        if try await self.worker.apply(address, sample: sample) {
                            NotificationCenter.default.post(name: RecordingChunkReceiver.didChange, object: nil,
                                userInfo: ["sessionID": sample.sessionID, "locationUpdated": true])
                        }
                    } catch {
                        guard self.generation == token, !Task.isCancelled else { return }
                    }
                    if !wasCached {
                        do { try await Task.sleep(for: self.requestSpacing) } catch { return }
                    }
                }
            } while self.reloadRequested && self.generation == token && !Task.isCancelled
        }
    }
}
