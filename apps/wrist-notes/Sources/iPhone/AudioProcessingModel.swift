import AVFAudio
import Combine
import Foundation
import UIKit
import OSLog

struct ContentEnrichmentConfirmation: Identifiable {
    let id = UUID()
    let scope: ContentEnrichmentScope
    let configuration: AIConfiguration
    let configurationRevision: Int
}

/// App-lifetime observable facade. File discovery, validation, hashing and SQLite run on its actor worker.
@MainActor final class AudioProcessingModel: ObservableObject {
    private static let contentV2Logger = Logger(subsystem:"cloud.karama.wisenote",category:"ContentV2")
    static let enrichmentDidChange = Notification.Name("WiseLife.ContentEnrichmentDidChange")
    static let contentDidChange = Notification.Name("WiseLife.ContentSegmentsDidChange")
    static let didCommit = Notification.Name("WiseLife.AudioProcessingDidCommit")
    static let sourceDidChange = Notification.Name("WiseLife.AudioSourceDidChange")
    static let resourcesDidChange = Notification.Name("WiseLife.TranscriptionResourcesDidChange")
    @Published private(set) var enrichmentStatuses: [AudioSourceID:ContentEnrichmentStatus] = [:]
    @Published private(set) var enrichmentProgress: [AudioSourceID:ContentEnrichmentProgress] = [:]
    @Published private(set) var fieldGenerationStatuses: [UUID:ContentEnrichmentStatus] = [:]
    @Published private(set) var statuses: [AudioSourceID:AudioProcessingStatus] = [:]
    @Published private(set) var revision = 0
    @Published private(set) var storageUnavailable = false
    @Published private(set) var reprocessingSources = Set<AudioSourceID>()
    @Published private(set) var reprocessingErrors: [AudioSourceID: String] = [:]
    var onLegacyTranscript: ((UUID,TranscriptionOutput,UUID?) -> Bool)?
    var onGroupedTranscripts: ((UUID,[UUID:TranscriptionOutput]) -> Bool)?
    private let root: URL
    private let settings: AppSettings
    private var observations: [AnyCancellable] = []
    private var expectedLegacyRevisions: [UUID:UUID?] = [:]
    private var projectedVersions: [UUID:String] = [:]
    private var captureIDs = Set<UUID>()
    private var deletedSources = Set<AudioSourceID>()
    private var pendingDerivation = Set<AudioSourceID>()
    private var derivationTask: Task<Void,Never>?
    private var pendingEnrichment = Set<AudioSourceID>()
    private var enrichmentTask: Task<Void,Never>?
    private var enrichmentSuspended = false
    private var enrichmentCapturePaused = false
    private var enrichmentApprovals: [AudioSourceID:ContentEnrichmentConfirmation] = [:]
    private let discovery: AudioSourceDiscovery
    private lazy var coordinator = AudioProcessingCoordinator(open: { [discovery] in try discovery.open() },
        configuration:settings.transcription,discover: { [discovery] ids in try discovery.sources(explicit:ids) },
        infer: { window,configuration,stages,duration,prior,budget in
            do {
                return try await LocalTranscriptionService.shared.process(window:window,configuration:configuration,stages:stages,
                    sourceDuration:duration,priorSpans:prior,maximumCoreDuration:budget)
            } catch is CancellationError { throw CancellationError() }
            catch { throw AudioProcessingError.resourceUnavailable }
        },discoveryUnavailable: { [discovery] in discovery.unavailableSources },availabilityChanged: { [weak self] unavailable in
            Task { @MainActor [weak self] in self?.storageUnavailable = unavailable }
        },changed: { [weak self] change in Task { @MainActor [weak self] in await self?.accept(change) } })

    init(root: URL? = nil, settings: AppSettings) {
        self.root = root ?? FileManager.default.urls(for:.documentDirectory,in:.userDomainMask)[0].appendingPathComponent("VoiceNotes",isDirectory:true)
        self.settings = settings
        discovery = AudioSourceDiscovery(root:self.root)
        for name in [Self.sourceDidChange,Notification.Name.recordingSourcesDidChange] {
            observations.append(NotificationCenter.default.publisher(for:name).sink { [weak self] notification in
                let deleted = notification.userInfo?["deletedSessionID"] as? UUID
                let located = notification.userInfo?["locationUpdated"] as? Bool == true ? notification.userInfo?["sessionID"] as? UUID : nil
                Task { @MainActor [weak self] in
                    if let deleted { self?.delete(.init(kind:.session,id:deleted)) }
                    else {
                        self?.refresh()
                        // Locations have their own durable rows and never change the audio
                        // fingerprint. Explicitly wake text enrichment for a late fix.
                        if let located { self?.scheduleEnrichment(.init(kind:.session,id:located)) }
                    }
                }
            })
        }
        observations.append(settings.$transcription.dropFirst().sink { [weak self] configuration in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.enrichmentTask?.cancel()
                await self.coordinator.refresh(configuration:configuration)
            }
        })
        observations.append(Publishers.CombineLatest(settings.$aiRevision,settings.$requiresRemoteAIConfirmation)
            .dropFirst().sink { [weak self] _ in
                self?.enrichmentApprovals.removeAll()
                self?.enrichmentTask?.cancel()
                Task { @MainActor [weak self] in await self?.retryEnrichmentAvailability() }
            })
        observations.append(NotificationCenter.default.publisher(for:Self.resourcesDidChange).sink { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                await self.coordinator.resourcesAvailable()
                await self.retryEnrichmentAvailability()
            }
        })
        observations.append(NotificationCenter.default.publisher(for:UIApplication.didReceiveMemoryWarningNotification).sink { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.enrichmentSuspended=true; self?.enrichmentTask?.cancel()
                await self?.coordinator.memoryPressure()
            }
        })
        observations.append(NotificationCenter.default.publisher(for:UIApplication.protectedDataWillBecomeUnavailableNotification).sink { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.enrichmentSuspended=true; self?.enrichmentTask?.cancel()
                await self?.coordinator.suspend(.protectedData)
            }
        })
        observations.append(NotificationCenter.default.publisher(for:Notification.Name("WiseLife.AudioCaptureActivity")).sink { [weak self] notification in
            guard notification.userInfo?["id"] is UUID else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.captureIDs = AudioCaptureActivity.activeIDs
                self.enrichmentCapturePaused = !self.captureIDs.isEmpty
                if self.captureIDs.isEmpty {
                    await self.coordinator.resume(.capture)
                    self.startEnrichment()
                } else { self.enrichmentTask?.cancel(); await self.coordinator.suspend(.capture) }
            }
        })
        captureIDs = AudioCaptureActivity.activeIDs
        if !captureIDs.isEmpty { Task { await coordinator.suspend(.capture) } }
    }
    func refresh() {
#if WISELIFE_CONTENT_LAB && targetEnvironment(simulator)
        // The simulator pilot publishes validated inputs/results separately. Opening
        // its UI must not run the legacy algorithm over those experiment results.
        return
#else
        Task { await coordinator.refresh(); await synchronizeStorageState() }
#endif
    }
    func retry(_ sourceID: AudioSourceID) { Task { await coordinator.retry(sourceID); await synchronizeStorageState() } }
    func reprocess(_ sourceID: AudioSourceID) {
        guard reprocessingSources.insert(sourceID).inserted else { return }
        reprocessingErrors.removeValue(forKey: sourceID)
        Task {
            defer { reprocessingSources.remove(sourceID) }
            if case let .failure(error) = await coordinator.reprocess(sourceID) {
                reprocessingErrors[sourceID] = error.localizedDescription
            }
            await synchronizeStorageState()
        }
    }
    func cancel(_ sourceID: AudioSourceID) { Task { await coordinator.cancel(sourceID) } }
    func delete(_ sourceID: AudioSourceID) {
        pendingEnrichment.remove(sourceID)
        enrichmentApprovals.removeValue(forKey:sourceID)
        enrichmentStatuses.removeValue(forKey:sourceID)
        pendingDerivation.remove(sourceID)
        deletedSources.insert(sourceID)
        statuses.removeValue(forKey:sourceID); revision += 1
        expectedLegacyRevisions.removeValue(forKey:sourceID.id)
        Task { await coordinator.delete(sourceID) }
    }
    func foreground() {
#if WISELIFE_CONTENT_LAB && targetEnvironment(simulator)
        return
#else
        Task {
            let protectedDataAvailable = UIApplication.shared.isProtectedDataAvailable
            let capturing = !AudioCaptureActivity.activeIDs.isEmpty
            if !protectedDataAvailable { await coordinator.suspend(.protectedData) }
            if capturing { await coordinator.suspend(.capture) }
            if protectedDataAvailable { await coordinator.resume(.protectedData) }
            if !capturing { await coordinator.resume(.capture) }
            await coordinator.resume(.memoryPressure)
            await coordinator.refresh(configuration:settings.transcription)
            await synchronizeStorageState()
            self.enrichmentSuspended = !protectedDataAvailable
            self.enrichmentCapturePaused = capturing
            await self.retryEnrichmentAvailability()
        }
#endif
    }
    func suspendForCapture() async { enrichmentCapturePaused=true; enrichmentTask?.cancel(); await coordinator.suspend(.capture) }
    func resumeAfterCapture() { if AudioCaptureActivity.activeIDs.isEmpty { enrichmentCapturePaused=false; startEnrichment(); Task { await coordinator.resume(.capture) } } }
    func shutdown() { enrichmentSuspended=true; enrichmentTask?.cancel(); Task { await coordinator.shutdown() } }
    func withRepository<T: Sendable>(_ operation: @escaping @Sendable (AudioProcessingRepository) throws -> T) async throws -> T {
        try await coordinator.withRepository(operation)
    }

    /// Explicit manual/resource/foreground retries release the local-model availability latch.
    func retryEnrichment(_ sourceID: AudioSourceID) {
        scheduleEnrichment(sourceID)
    }
    func rebuildContent(_ sourceID: AudioSourceID) { scheduleDerivation(sourceID) }
    private func retryEnrichmentAvailability() async {
        for id in statuses.keys where !deletedSources.contains(id) { pendingEnrichment.insert(id) }
        startEnrichment()
    }
    func prepareEnrichment(_ sourceID: AudioSourceID) async throws -> ContentEnrichmentConfirmation? {
        let configuration=settings.ai, revision=settings.aiRevision
        if !configuration.isRemote || !settings.requiresRemoteAIConfirmation { retryEnrichment(sourceID); return nil }
        guard let scope=try await withRepository({ try ContentEnrichmentAuthorization.scope(database:$0.derivedDatabase,sourceID:sourceID) }),
              settings.ai == configuration, settings.aiRevision == revision else { throw ContentSegmentError.staleRevision }
        return .init(scope:scope,configuration:configuration,configurationRevision:revision)
    }
    func prepareFieldGeneration(sourceID: AudioSourceID, segmentID: UUID, field: ContentEnrichmentField? = nil) async throws -> ContentEnrichmentConfirmation? {
        let configuration=settings.ai, revision=settings.aiRevision
        guard let scope=try await withRepository({ try ContentEnrichmentAuthorization.scope(database:$0.derivedDatabase,sourceID:sourceID,segmentID:segmentID,field:field) }),
              settings.ai == configuration, settings.aiRevision == revision else { throw ContentSegmentError.staleRevision }
        if configuration.isRemote && settings.requiresRemoteAIConfirmation {
            return .init(scope:scope,configuration:configuration,configurationRevision:revision)
        }
        Task { @MainActor [weak self] in _ = await self?.performFieldGeneration(sourceID:sourceID,segmentID:segmentID,field:field,confirmation:nil) }
        return nil
    }
    func approveEnrichment(_ confirmation: ContentEnrichmentConfirmation, rememberChoice: Bool) async throws {
        let id=confirmation.scope.sourceID
        let current=try await withRepository { try ContentEnrichmentAuthorization.scope(database:$0.derivedDatabase,sourceID:id,segmentID:confirmation.scope.segmentID,field:confirmation.scope.field) }
        let matches=current == confirmation.scope && settings.ai == confirmation.configuration && settings.aiRevision == confirmation.configurationRevision
        guard settings.authorizeRemoteAISend(confirmationIsCurrent:matches,rememberChoice:rememberChoice) else { throw ContentSegmentError.staleRevision }
        enrichmentApprovals[id]=confirmation
        if let segmentID=confirmation.scope.segmentID {
            if await performFieldGeneration(sourceID:id,segmentID:segmentID,field:confirmation.scope.field,confirmation:confirmation) == .stale { throw ContentSegmentError.staleRevision }
        } else { scheduleEnrichment(id) }
    }
    private func enrichSource(_ id: AudioSourceID) async -> ContentEnrichmentStatus {
        do {
            let configuration=settings.ai, revision=settings.aiRevision
            guard let scope=try await withRepository({ try ContentEnrichmentAuthorization.scope(database:$0.derivedDatabase,sourceID:id) }) else { return .stale }
            let approval=enrichmentApprovals[id]
            let confirmed=approval.map { $0.scope == scope && $0.configuration == configuration && $0.configurationRevision == revision } ?? false
            let allowed: @MainActor () async throws -> Bool = { [weak self] in
                guard let self, self.enrichmentConfigurationCurrent(id,configuration:configuration,revision:revision) else { return false }
                if !self.enrichmentCurrent(id,configuration:configuration,revision:revision,confirmationID:confirmed ? approval?.id : nil) {
                    throw ContentEnrichmentFailure.confirmationRequired
                }
                let current=try await self.withRepository { try ContentEnrichmentAuthorization.scope(database:$0.derivedDatabase,sourceID:id) }
                return current == scope && self.enrichmentCurrent(id,configuration:configuration,revision:revision,confirmationID:confirmed ? approval?.id : nil)
            }
            let router=ConfiguredContentTextModel(configuration:configuration,authorized:allowed,
                apiKey:{ [settings] in try settings.apiKey() },
                local:{ try await FoundationContentTextModel().respond($0) },
                chat:{ [weak self,settings] instruction,text,configuration in
                    try await settings.chatGPT.complete(instruction:instruction,content:text,modelID:configuration.chatGPTModel,
                        accountID:configuration.chatGPTAccountID,isCurrent:{ [weak self] in
                            self?.enrichmentCurrent(id,configuration:configuration,revision:revision,confirmationID:confirmed ? approval?.id : nil) ?? false
                        },sourceIsCurrent:allowed)
                })
            let worker=coordinator
            guard let topicAction=try await worker.withRepository({ repository -> ContentSegmentationV2.LongRecordingTopicPolicy.Action? in
                guard let source=try repository.currentSource(id) else { return nil }
                let duration=source.ranges.reduce(0) { $0 + $1.duration }
                return ContentSegmentationV2.LongRecordingTopicPolicy.action(
                    duration:duration,sourceComplete:source.complete)
            }) else { return .stale }
            guard topicAction != .waitForSourceCompletion else { return .idle }
            let modelKey=ConfiguredContentTextModel.configurationKey(configuration)
            let fields=ContentEnrichmentService(modelKey:modelKey,model:{ try await router.respond($0) },store:{ [weak self] command in
                try Task.checkCancellation()
                guard await self?.enrichmentConfigurationCurrent(id,configuration:configuration,revision:revision) == true else { throw CancellationError() }
                return try await worker.withRepository { try ContentSegmentRepository(database:$0.derivedDatabase).enrichment(command) }
            },budget:{ context in await router.summaryBudget(context:context) },progress:{ [weak self] value in await self?.publishEnrichmentProgress(id,value) })
            if topicAction == .keepWholeRecording {
                // The complete ASR/VAD source already has one final boundary from the
                // deterministic whole-recording policy. Generate display fields later;
                // this path never asks AI to split or classify the recording.
                let result=await fields.generateMissingFields(sourceID:id)
                if result == .complete { enrichmentApprovals.removeValue(forKey:id) }
                return result
            }
            // Short recordings intentionally have no Content V2 input: they skip
            // topic splitting and classification, but still need title and summary.
            guard let input=try await worker.withRepository({ try ContentSegmentRepository(database:$0.derivedDatabase).contentV2Input(sourceID:id) }) else { return .idle }
            let budget=router.summaryBudget(context:"")
            let requestLimit=max(4_096,min(1_000_000,budget.availableTranscriptTokens))
            let modelIdentity=modelKey+"|"+(configuration.model)
            let topicSplitting=topicAction == .splitTopics
            let alreadyPublished=try await worker.withRepository {
                try ContentSegmentRepository(database:$0.derivedDatabase).hasPublishedContentV2(sourceID:id,input:input,modelIdentity:modelIdentity,topicSplitting:topicSplitting)
            }
            if alreadyPublished {
                let result=await fields.generateMissingFields(sourceID:id)
                if result == .complete { enrichmentApprovals.removeValue(forKey:id) }
                return result
            }
            let output=try await ContentSegmentationV2Production.run(input:input,modelIdentity:modelIdentity,requestCharacterLimit:requestLimit,
                topicSplitting:topicSplitting,
                model:{ instruction,content in try await router.respond(instruction:instruction,content:content) },
                loadCheckpoint:{ key in try await worker.withRepository { try ContentSegmentRepository(database:$0.derivedDatabase).contentV2Checkpoint(sourceID:id,key:key) } },
                saveCheckpoint:{ key,data in try await worker.withRepository { try ContentSegmentRepository(database:$0.derivedDatabase).saveContentV2Checkpoint(sourceID:id,key:key,data:data) } },
                progress:{ stage in
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        if stage == "complete" { self.publishEnrichmentProgress(id,nil) }
                        else { self.publishEnrichmentProgress(id,.init(stage:stage == "final" ? .classification : .topicUnification,segmentID:nil)) }
                    }
                },
                publish:{ value in
                    guard self.enrichmentConfigurationCurrent(id,configuration:configuration,revision:revision) else { throw CancellationError() }
                    try await worker.withRepository { try ContentSegmentRepository(database:$0.derivedDatabase).publishContentV2(sourceID:id,input:input,output:value,model:configuration.model,modelIdentity:modelIdentity,topicSplitting:topicSplitting) }
                    NotificationCenter.default.post(name:Self.contentDidChange,object:nil,userInfo:["sourceID":id])
                })
            _ = output
            let fieldResult=await fields.generateMissingFields(sourceID:id)
            guard fieldResult == .complete || fieldResult == .idle else { return fieldResult }
            enrichmentApprovals.removeValue(forKey:id)
            return .complete
        } catch is CancellationError { return .cancelled }
        catch ContentSegmentError.staleRevision { return .stale }
        catch let failure as ContentSegmentationV2.Failure {
            Self.contentV2Logger.error("V2 failed: \(failure.description, privacy: .public)")
            return .failed
        }
        catch ContentSegmentError.invalidEdit {
            Self.contentV2Logger.error("V2 rejected input due to protected edit history")
            return .stale
        }
        catch let failure as ContentSegmentRepository.ContentV2PublishError {
            let reason: String
            switch failure {
            case .protectedHistory: reason = "protectedHistory"
            case .emptyGeneratedRange: reason = "emptyGeneratedRange"
            case .spanOutsideGeneratedRange(let detail): reason = "spanOutsideGeneratedRange/" + detail
            case .invalidGeneratedID: reason = "invalidGeneratedID"
            }
            Self.contentV2Logger.error("V2 rejected publication: \(reason, privacy: .public)")
            return .failed
        }
        catch {
            let safeError=error as NSError
            Self.contentV2Logger.error("V2 failed before publication: domain=\(safeError.domain, privacy: .public) code=\(safeError.code, privacy: .public)")
            return .failed
        }
    }
    private func performFieldGeneration(sourceID id: AudioSourceID, segmentID: UUID, field: ContentEnrichmentField?, confirmation: ContentEnrichmentConfirmation?) async -> ContentEnrichmentStatus {
        let configuration=settings.ai, revision=settings.aiRevision
        fieldGenerationStatuses[segmentID] = .running
        do {
            guard let scope=try await withRepository({ try ContentEnrichmentAuthorization.scope(database:$0.derivedDatabase,sourceID:id,segmentID:segmentID,field:field) }),
                  settings.ai == configuration,settings.aiRevision == revision else { throw ContentSegmentError.staleRevision }
            let confirmed=confirmation.map { $0.scope == scope && $0.configuration == configuration && $0.configurationRevision == revision } ?? false
            let allowed: @MainActor () async throws -> Bool = { [weak self] in
                guard let self,self.enrichmentConfigurationCurrent(id,configuration:configuration,revision:revision) else { return false }
                if !self.enrichmentCurrent(id,configuration:configuration,revision:revision,confirmationID:confirmed ? confirmation?.id : nil) { throw ContentEnrichmentFailure.confirmationRequired }
                let current=try await self.withRepository { try ContentEnrichmentAuthorization.scope(database:$0.derivedDatabase,sourceID:id,segmentID:segmentID,field:field) }
                return current == scope && self.enrichmentCurrent(id,configuration:configuration,revision:revision,confirmationID:confirmed ? confirmation?.id : nil)
            }
            let router=ConfiguredContentTextModel(configuration:configuration,authorized:allowed,
                apiKey:{ [settings] in try settings.apiKey() },
                local:{ try await FoundationContentTextModel().respond($0) },
                chat:{ [weak self,settings] instruction,text,configuration in
                    try await settings.chatGPT.complete(instruction:instruction,content:text,modelID:configuration.chatGPTModel,
                        accountID:configuration.chatGPTAccountID,isCurrent:{ [weak self] in
                            self?.enrichmentCurrent(id,configuration:configuration,revision:revision,confirmationID:confirmed ? confirmation?.id : nil) ?? false
                        },sourceIsCurrent:allowed)
                })
            let worker=coordinator
            let service=ContentEnrichmentService(modelKey:ConfiguredContentTextModel.configurationKey(configuration),model:{ try await router.respond($0) },store:{ [weak self] command in
                try Task.checkCancellation()
                guard await self?.enrichmentConfigurationCurrent(id,configuration:configuration,revision:revision) == true else { throw CancellationError() }
                return try await worker.withRepository { try ContentSegmentRepository(database:$0.derivedDatabase).enrichment(command) }
            },budget:{ context in await router.summaryBudget(context:context) },progress:{ [weak self] value in await self?.publishEnrichmentProgress(id,value) })
            let result=await service.generateFields(sourceID:id,segmentID:segmentID,field:field)
            if let confirmation,enrichmentApprovals[id]?.id == confirmation.id { enrichmentApprovals.removeValue(forKey:id) }
            fieldGenerationStatuses[segmentID]=result
            if result == .complete { NotificationCenter.default.post(name:Self.contentDidChange,object:nil,userInfo:["sourceID":id]) }
            return result
        } catch is CancellationError { fieldGenerationStatuses[segmentID] = .cancelled; return .cancelled }
        catch ContentSegmentError.staleRevision { fieldGenerationStatuses[segmentID] = .stale; return .stale }
        catch { fieldGenerationStatuses[segmentID] = .failed; return .failed }
    }
    private func publishEnrichmentProgress(_ sourceID: AudioSourceID, _ value: ContentEnrichmentProgress?) {
        if let value { enrichmentProgress[sourceID]=value }
        else { enrichmentProgress.removeValue(forKey:sourceID) }
    }
    private func enrichmentCurrent(_ id: AudioSourceID, configuration: AIConfiguration, revision: Int, confirmationID: UUID?) -> Bool {
        guard enrichmentConfigurationCurrent(id,configuration:configuration,revision:revision) else { return false }
        return !configuration.isRemote || !settings.requiresRemoteAIConfirmation ||
            (confirmationID != nil && enrichmentApprovals[id]?.id == confirmationID)
    }
    private func enrichmentConfigurationCurrent(_ id: AudioSourceID, configuration: AIConfiguration, revision: Int) -> Bool {
        !deletedSources.contains(id) && !enrichmentSuspended && !enrichmentCapturePaused && captureIDs.isEmpty &&
            settings.ai == configuration && settings.aiRevision == revision
    }
    private func scheduleEnrichment(_ sourceID: AudioSourceID) {
        guard !deletedSources.contains(sourceID) else { return }
        pendingEnrichment.insert(sourceID); startEnrichment()
    }
    private func startEnrichment() {
#if WISELIFE_CONTENT_LAB && targetEnvironment(simulator)
        return
#else
        guard enrichmentTask == nil, !enrichmentSuspended, !enrichmentCapturePaused, captureIDs.isEmpty else { return }
        enrichmentTask=Task { [weak self] in
            guard let self else { return }
            defer { self.enrichmentTask=nil; if !self.pendingEnrichment.isEmpty { self.startEnrichment() } }
            while !Task.isCancelled, !self.enrichmentSuspended, !self.enrichmentCapturePaused, self.captureIDs.isEmpty, let id=self.pendingEnrichment.first {
                self.pendingEnrichment.remove(id)
                guard !self.deletedSources.contains(id) else { continue }
                self.publishEnrichment(id,status:.running)
                let result=await self.enrichSource(id)
                guard !self.deletedSources.contains(id) else { continue }
                self.publishEnrichment(id,status:result)
                if result == .cancelled && Task.isCancelled { self.pendingEnrichment.insert(id) }
                if result == .complete, let progress=try? await self.coordinator.withRepository({ try $0.progress(sourceID:id) }) {
                    NotificationCenter.default.post(name:Self.contentDidChange,object:nil,userInfo:["sourceID":id,"revision":progress.revision,"configurationKey":progress.configurationKey ?? ""])
                }
            }
        }
#endif
    }
    private func publishEnrichment(_ id: AudioSourceID, status: ContentEnrichmentStatus) {
        enrichmentStatuses[id]=status; revision += 1
        NotificationCenter.default.post(name:Self.enrichmentDidChange,object:nil,userInfo:["sourceID":id,"status":status.rawValue])
    }

    /// Return true when the durable worker owns this request. Existing injected/short thought paths remain in NotesModel.
    func route(_ note: VoiceNote, automatic: Bool) async -> Bool {
        guard AudioLegacyRouting.requiresDurableProcessing(kind:note.kind,duration:note.duration) else { return false }
        if note.kind != .long && note.duration <= 0 {
            let url = root.appendingPathComponent("Audio",isDirectory:true).appendingPathComponent(note.audioFilename)
            let duration = await Task.detached(priority:.utility) { () -> Double? in
                guard (try? RecordingAudioFile.requireSafePath(url)) != nil,
                      let file = try? AVAudioFile(forReading:url), file.processingFormat.sampleRate > 0 else { return nil }
                return Double(file.length) / file.processingFormat.sampleRate
            }.value
            if !AudioLegacyRouting.requiresDurableProcessing(kind:note.kind,duration:note.duration,measuredDuration:duration) { return false }
        }
        let id = AudioSourceID(kind:.legacyNote,id:note.id)
        let manual = note.transcriptionState == .ready || !note.transcript.isEmpty
        if manual {
            if !automatic { reprocess(id) }
            return true
        }
        if note.recordingGroupID == nil, expectedLegacyRevisions[note.id] == nil { expectedLegacyRevisions[note.id] = .some(note.transcriptRevision) }
        if automatic { refresh() } else { retry(id) }
        return true
    }
    /// Coalesce result, registration, retry, configuration and progress wakes on the existing worker.
    /// The repository reads its current version inside the transaction; notification versions are advisory.
    private func scheduleDerivation(_ id: AudioSourceID) {
        pendingDerivation.insert(id)
        guard derivationTask == nil else { return }
        derivationTask = Task { [weak self] in
            guard let self else { return }
            defer { self.derivationTask = nil }
            while let id = self.pendingDerivation.first {
                self.pendingDerivation.remove(id)
                do {
                    let progress = try await self.coordinator.withRepository { repository in
                        try ContentSegmentRepository(database:repository.derivedDatabase).reconcile(sourceID:id)
                        return try repository.progress(sourceID:id)
                    }
                    guard !self.deletedSources.contains(id) else { continue }
                    self.revision += 1
                    self.scheduleEnrichment(id)
                    NotificationCenter.default.post(name:Self.contentDidChange,object:nil,userInfo:["sourceID":id,"revision":progress.revision,"configurationKey":progress.configurationKey ?? ""])
                } catch ContentSegmentError.staleRevision {
                    // Another connection edited the source/chapters while the read
                    // snapshot was being derived. Recompute against its committed state.
                    self.pendingDerivation.insert(id)
                    await Task.yield()
                } catch { self.storageUnavailable = true }
            }
        }
    }
    private func synchronizeStorageState() async { storageUnavailable = await coordinator.storageUnavailable }
    private func accept(_ change: AudioProcessingChange) async {
        let id = change.status.sourceID
        guard !deletedSources.contains(id) else { return }
        if let previous = statuses[id], previous.progress.revision > change.status.progress.revision { return }
        statuses[id] = change.status; revision += 1
        scheduleDerivation(id)
        if change.committed {
            NotificationCenter.default.post(name:Self.didCommit,object:nil,userInfo:["sourceID":id,"revision":change.status.progress.revision,"configurationKey":change.status.progress.configurationKey ?? ""])
        }
        // Grouped Watch recordings use one ASR/topic source while originals remain
        // individually addressable. Project the completed timed transcript back to files.
        if id.kind == .legacyNote,
           let key = change.status.progress.configurationKey, !key.contains("~r:"),
           change.status.asr.success == change.status.progress.states.values.reduce(0,+),
           change.status.asr.success > 0,
           let source = try? await coordinator.withRepository({ try $0.currentSource(id) }),
           let groupID = source.recordingGroupID,
           let output = try? await coordinator.completedTranscript(id,configurationKey:key) {
            let projectionVersion = "\(key)~r:\(change.status.progress.revision)"
            guard projectedVersions[id.id] != projectionVersion else { return }
            var projected: [UUID:TranscriptionOutput] = [:]
            for range in source.ranges {
                let values = output.segments.filter { midpoint($0) >= range.sessionStartOffset && midpoint($0) < range.end }
                    .map { TranscriptSegment(start:max(0,$0.start-range.sessionStartOffset),end:max(0,$0.end-range.sessionStartOffset),text:$0.text,speakerID:$0.speakerID) }
                projected[range.chunkID] = .init(text:values.map(\.text).joined(),segments:values,engineName:output.engineName)
            }
            if statuses[id]?.progress.configurationKey == key, !deletedSources.contains(id),
               onGroupedTranscripts?(groupID,projected) == true { projectedVersions[id.id] = projectionVersion }
            return
        }
        // Registration/recovery wakes also reconcile already committed initial transcripts.
        guard id.kind == .legacyNote, let expected = expectedLegacyRevisions[id.id],
              let key = change.status.progress.configurationKey, !key.contains("~r:"),
              projectedVersions[id.id] != key,
              change.status.asr.success == change.status.progress.states.values.reduce(0,+),
              change.status.asr.success > 0 else { return }
        if let output = try? await coordinator.completedTranscript(id,configurationKey:key),
           !deletedSources.contains(id), statuses[id]?.progress.configurationKey == key,
           projectedVersions[id.id] != key,
           onLegacyTranscript?(id.id,output,expected) == true {
            projectedVersions[id.id] = key
        }
    }
    private func midpoint(_ segment: TranscriptSegment) -> Double { (segment.start + segment.end) / 2 }
}
