import Foundation

struct AudioStageProgress: Sendable {
    var success = 0
    var missingResource = 0
    var failed = 0
    var cancelled = 0
    var notRequested = 0
    mutating func add(_ outcome: AudioAnalysisOutcome) {
        switch outcome {
        case .success: success += 1
        case .missingResource: missingResource += 1
        case .failed: failed += 1
        case .cancelled: cancelled += 1
        case .notRequested: notRequested += 1
        }
    }
}
struct AudioProcessingStatus: Sendable {
    let sourceID: AudioSourceID
    let progress: AudioProcessingProgress
    let asr: AudioStageProgress
    let vad: AudioStageProgress
    let speaker: AudioStageProgress
    var sourceUnavailable = false
    var asrEngineNames: [String] = []
}
struct AudioProcessingChange: Sendable {
    let status: AudioProcessingStatus
    /// True only after a committed result; downstream consumers must check configuration/revision.
    let committed: Bool
}

/// Owns discovery, SQLite and the only durable queue pump, away from the main actor.
/// Actor reentrancy lets cancellation revoke a lease while native work is still unwinding.
enum AudioProcessingPauseReason: Hashable, Sendable { case capture, protectedData, memoryPressure, manual }

actor AudioProcessingCoordinator {
    typealias Discovery = ([AudioSourceID]) throws -> [AudioSourceSnapshot]
    typealias Inference = @Sendable (AudioProcessingWindow, TranscriptionConfiguration, AudioInferenceStages, Double?, [AudioTranscriptSpan], Double) async throws -> AudioInferenceDelta
    private let open: () throws -> AudioProcessingRepository
    private let discover: Discovery
    private let infer: Inference
    private let discoveryUnavailable: () -> [AudioSourceID]
    private var unavailableSources = Set<AudioSourceID>()
    private let changed: @Sendable (AudioProcessingChange) -> Void
    private let availabilityChanged: @Sendable (Bool) -> Void
    private var repository: AudioProcessingRepository?
    private var configuration: TranscriptionConfiguration
    private var pump: Task<Void,Never>?
    private var inference: Task<AudioInferenceDelta,Error>?
    private var current: AudioProcessingJob?
    private var requested = false
    private var explicitSources = Set<AudioSourceID>()
    private var pauseReasons = Set<AudioProcessingPauseReason>()
    private var suspended: Bool { !pauseReasons.isEmpty }
    private var stopped = false
    private(set) var maximumCoreDuration: Double = 300
    private(set) var storageUnavailable = false {
        didSet { if storageUnavailable != oldValue { availabilityChanged(storageUnavailable) } }
    }

    init(open: @escaping () throws -> AudioProcessingRepository,
         configuration: TranscriptionConfiguration,
         discover: @escaping Discovery,
         infer: @escaping Inference,
         discoveryUnavailable: @escaping () -> [AudioSourceID] = { [] },
         availabilityChanged: @escaping @Sendable (Bool) -> Void = { _ in },
         changed: @escaping @Sendable (AudioProcessingChange) -> Void = { _ in }) {
        self.open = open; self.configuration = configuration; self.discover = discover
        self.infer = infer; self.changed = changed; self.discoveryUnavailable = discoveryUnavailable; self.availabilityChanged = availabilityChanged
    }
    static func configurationKey(_ value: TranscriptionConfiguration) -> String {
        // Language is part of the version even when the underlying model resource is shared.
        AudioStableID.make(value) + ":" + AudioWindowPlanner.algorithmVersion + ":native-vad-speaker-v1"
    }
    private func storage() throws -> AudioProcessingRepository {
        if let repository { return repository }
        let opened = try open()
        try opened.recoverInterrupted()
        repository = opened
        return opened
    }
    func refresh(configuration newConfiguration: TranscriptionConfiguration? = nil) {
        guard !stopped else { return }
        if let newConfiguration, newConfiguration != configuration {
            configuration = newConfiguration
            // Revoke first: an adapter ignoring cancellation cannot publish old settings.
            if let current { try? repository?.fail(job:current,state:.missingResource) }
            inference?.cancel()
        }
        requested = true
        startPump()
    }
    private func startPump() {
        guard pump == nil, !stopped else { return }
        pump = Task { await self.run() }
    }
    func waitUntilIdle() async { await pump?.value }
    func retry(_ sourceID: AudioSourceID) {
        guard !stopped else { return }
        do {
            explicitSources.insert(sourceID)
            pauseReasons.remove(.memoryPressure)
            try registerDiscovered()
            guard try storage().currentSource(sourceID) != nil else { return }
            try storage().retryIncompleteStages(sourceID:sourceID)
            try publish(sourceID,committed:false)
            requested = true; startPump()
        } catch { storageUnavailable = true }
    }
    /// Resource events retry missing stages only and never override persisted cancellation.
    func resourcesAvailable() {
        guard !stopped else { return }
        do {
            try registerDiscovered()
            let repository = try storage()
            for source in try repository.sources() { try repository.retryIncompleteStages(sourceID:source.id,resourceOnly:true) }
            requested = true; startPump()
        } catch { storageUnavailable = true }
    }
    func reprocess(_ sourceID: AudioSourceID) {
        guard !stopped else { return }
        do {
            explicitSources.insert(sourceID)
            let repository = try storage()
            let sources = try discover(Array(explicitSources))
            unavailableSources = Set(discoveryUnavailable())
            for id in unavailableSources { try publish(id,committed:false) }
            guard let source = try sources.first(where: { $0.id == sourceID }) ?? repository.currentSource(sourceID) else { return }
            let key = Self.configurationKey(configuration) + "~r:" + UUID().uuidString
            try repository.register(source:source,configurationKey:key,windows:AudioWindowPlanner.plan(source:source,configurationKey:key))
            try repository.retry(sourceID:sourceID)
            try publish(sourceID,committed:false)
            requested = true; startPump()
        } catch { storageUnavailable = true }
    }
    func cancel(_ sourceID: AudioSourceID) {
        do { try storage().cancel(sourceID:sourceID); try publish(sourceID,committed:false) }
        catch { storageUnavailable = true }
        if current?.window.sourceID == sourceID { inference?.cancel() }
    }
    func delete(_ sourceID: AudioSourceID) {
        do { try storage().delete(sourceID:sourceID) } catch { storageUnavailable = true }
        explicitSources.remove(sourceID)
        if current?.window.sourceID == sourceID { inference?.cancel() }
    }
    /// Suspension does not change user cancellation and never starts its own timed retry.
    func suspend(_ reason: AudioProcessingPauseReason = .manual) {
        pauseReasons.insert(reason)
        if let current { try? repository?.fail(job:current,state:.missingResource); try? publish(current.window.sourceID,committed:false) }
        inference?.cancel()
    }
    func memoryPressure() { maximumCoreDuration = max(30,maximumCoreDuration / 2); suspend(.memoryPressure) }
    func resume(_ reason: AudioProcessingPauseReason = .manual) {
        guard !stopped else { return }
        pauseReasons.remove(reason)
        resourcesAvailable()
    }
    func shutdown() {
        stopped = true
        if let current { try? repository?.deferInterrupted(job:current) }
        inference?.cancel()
    }

    func status(_ sourceID: AudioSourceID) throws -> AudioProcessingStatus {
        let repository = try storage()
        var asr = AudioStageProgress(), vad = AudioStageProgress(), speaker = AudioStageProgress()
        let results = try repository.results(sourceID:sourceID)
        for result in results { asr.add(result.asr); vad.add(result.vad); speaker.add(result.speaker) }
        let engineNames = Set(results.filter { $0.asr == .success }.compactMap(\.asrEngineName)).sorted()
        return AudioProcessingStatus(sourceID:sourceID,progress:try repository.progress(sourceID:sourceID),asr:asr,vad:vad,speaker:speaker,
            sourceUnavailable:unavailableSources.contains(sourceID),asrEngineNames:engineNames)
    }
    /// Synchronous operations execute only on this worker. Never retain the repository across this closure.
    func withRepository<T: Sendable>(_ operation: @Sendable (AudioProcessingRepository) throws -> T) throws -> T {
        try operation(storage())
    }
    func completedTranscript(_ sourceID: AudioSourceID, configurationKey: String) throws -> TranscriptionOutput? {
        let repository = try storage()
        let state = try status(sourceID)
        guard state.progress.configurationKey == configurationKey, state.asr.success > 0,
              state.asr.success == state.progress.states.values.reduce(0,+) else { return nil }
        var spans: [AudioTranscriptSpan] = [], offset = 0
        while true {
            let page = try repository.spans(sourceID:sourceID,limit:1000,offset:offset)
            spans += page; offset += page.count
            if page.count < 1000 { break }
        }
        return TranscriptionOutput(text:spans.map(\.text).joined(),segments:spans.map { .init(start:$0.start,end:$0.end,text:$0.text,speakerID:$0.speakerID) },
            engineName:state.asrEngineNames.joined(separator:" / "))
    }
    private func publish(_ sourceID: AudioSourceID, committed: Bool) throws {
        changed(AudioProcessingChange(status:try status(sourceID),committed:committed))
    }
    private func registerDiscovered() throws {
        let repository = try storage()
        let base = Self.configurationKey(configuration)
        let sources = try discover(Array(explicitSources))
        unavailableSources = Set(discoveryUnavailable())
        for id in unavailableSources { try publish(id,committed:false) }
        for source in sources {
            let old = try repository.progress(sourceID:source.id).configurationKey
            let key = old?.hasPrefix(base + "~r:") == true ? old! : base
            do {
                try repository.register(source:source,configurationKey:key,windows:AudioWindowPlanner.plan(source:source,configurationKey:key))
                try publish(source.id,committed:false)
            } catch AudioProcessingError.deletedSource { continue }
        }
        storageUnavailable = false
    }
    private func run() async {
        defer { pump = nil }
        do {
            let repository = try storage()
            while !stopped {
                if requested { requested = false; try registerDiscovered() }
                guard !suspended else { break }
                guard let job = try repository.claimNext() else {
                    if requested { continue }
                    break
                }
                current = job
                try publish(job.window.sourceID,committed:false)
                let stages = try repository.stages(for:job)
                var prior: [AudioTranscriptSpan] = [], offset = 0
                if !stages.contains(.asr) {
                    while true {
                        let page = try repository.spans(sourceID:job.window.sourceID,overlapping:.init(start:job.window.inputStart,end:job.window.inputEnd),limit:1000,offset:offset)
                        prior += page; offset += page.count
                        if page.count < 1000 { break }
                    }
                }
                let snapshot = try repository.currentSource(job.window.sourceID)
                // A receiving tail is not the full eventual recording extent.
                let duration = snapshot?.complete == true ? snapshot?.ranges.last?.end : nil
                let config = configuration, budget = maximumCoreDuration, infer = self.infer
                let task = Task { try await infer(job.window,config,stages,duration,prior,budget) }
                inference = task
                do {
                    let delta = try await task.value
                    try Task.checkCancellation()
                    // Commit verifies the active input, version and lease even when native calls ignored cancellation.
                    try repository.commit(job:job,delta:delta)
                    try publish(job.window.sourceID,committed:true)
                    storageUnavailable = false
                } catch {
                    let state: AudioJobState
                    switch error {
                    case is CancellationError, AudioProcessingError.resourceUnavailable: state = .missingResource
                    default: state = suspended ? .missingResource : .failed
                    }
                    try? repository.fail(job:job,state:state)
                    try? publish(job.window.sourceID,committed:false)
                }
                inference = nil; current = nil
            }
        } catch { storageUnavailable = true }
    }
}
