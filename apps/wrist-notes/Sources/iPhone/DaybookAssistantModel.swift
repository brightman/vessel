import Combine
import Foundation
#if os(iOS)
import UIKit
#endif

/// One finite OS execution lease; injectable so expiration and denial are deterministic in tests.
@MainActor
protocol AskAIBackgroundExecuting: AnyObject {
    func begin(expiration: @escaping @MainActor () -> Void) -> Bool
    func end()
}

@MainActor
private final class AskAIBackgroundExecution: AskAIBackgroundExecuting {
#if os(iOS)
    private var identifier: UIBackgroundTaskIdentifier = .invalid
    func begin(expiration: @escaping @MainActor () -> Void) -> Bool {
        identifier = UIApplication.shared.beginBackgroundTask(withName: "WiseLife Ask AI") {
            MainActor.assumeIsolated { expiration() }
        }
        return identifier != .invalid
    }
    func end() {
        guard identifier != .invalid else { return }
        let id = identifier; identifier = .invalid
        UIApplication.shared.endBackgroundTask(id)
    }
    deinit {
        let id = identifier
        if id != .invalid { Task { @MainActor in UIApplication.shared.endBackgroundTask(id) } }
    }
#else
    func begin(expiration: @escaping @MainActor () -> Void) -> Bool { true }
    func end() { }
#endif
}

@MainActor
final class DaybookAssistantModel: ObservableObject {
    typealias Answer = DaybookConversationTurn

    /// Content-free diagnostics, also persisted on an active runtime attempt.
    enum CancellationReason: String {
        case user, superseded, sourcesChanged, scopeUnavailable, sourceDeleted
        case configurationChanged, permissionsChanged, resourceChanged, inactive, viewClosed, backgroundExpired, backgroundUnavailable
        var message: String {
            switch self {
            case .sourcesChanged, .sourceDeleted: "本次使用的资料已变化，请点“重新回答”。"
            case .scopeUnavailable: "暂时无法核对本次资料，请稍后点“重新回答”。"
            case .configurationChanged: "AI 设置已变化，请点“重新回答”。"
            case .permissionsChanged: "资料读取权限已变化，请点“重新回答”。"
            case .resourceChanged: "本地检索资源已变化，请点“重新回答”。"
            case .backgroundExpired: "系统允许的后台时间已用尽，回答已中断，请返回后点“重新回答”。"
            case .backgroundUnavailable: "系统暂未允许后台继续处理，请返回后点“重新回答”。"
            case .inactive: "App 已离开前台，本次回答已中断，可重新回答。"
            case .viewClosed: "已离开 AI 页面，本次回答已中断，可重新回答。"
            case .user, .superseded: "本次回答已取消，可重新提问。"
            }
        }
    }

    struct RemoteConfirmation: Identifiable {
        let id = UUID()
        let question: String
        let context: String
        let sourceCount: Int
        let destination: String
        var isSupplemental = false
        var instructionOverride: String? = nil
        var instruction: String { isSupplemental ? "仅发送下方新增资料，继续当前回答。" : instructionOverride ?? CustomAISummarizer.answerInstruction }
        var message: String { isSupplemental ? context : CustomAISummarizer.answerContent(question: prepared.providerQuestion, context: context) }
        fileprivate let prepared: DaybookRetrieval.Prepared
        fileprivate let configuration: AIConfiguration
        fileprivate let configurationRevision: Int
    }

    @Published private(set) var turns: [Answer] = []
    @Published private(set) var answer: Answer?
    @Published private(set) var prepared: DaybookRetrieval.Prepared?
    @Published private(set) var preparedTurnID: UUID?
    @Published private(set) var remoteConfirmation: RemoteConfirmation? { didSet { scheduleBackgroundReconciliation() } }
    @Published private(set) var retrievalStatus = "正在查找相关记录…"
    @Published private(set) var isPending = false { didSet { scheduleBackgroundReconciliation() } }
    @Published private(set) var errorMessage: String?
    @Published private(set) var statusMessage: String?
    @Published private(set) var storageError: String?
    @Published private(set) var needsStorageReset = false
    @Published private(set) var hasMoreHistory = false

    private var savedTurns: [Answer] = []
    private var historyCursor: DaybookConversationStore.Cursor?
    private var historyReadFailed = false
    private var activeTurnID: UUID?
    private var activeTurnDay: Date?
    var processingTurnID: UUID? { isPending || remoteConfirmation != nil ? activeTurnID : nil }
    private enum PendingMutation {
        case save(Answer, day: Date)
        case reset
    }
    private var pendingMutation: PendingMutation?
    private var revokedKinds: Set<DayRecord.Kind> = []
    private var privacyCleanupPending = false
    private let store: DaybookConversationStore
    private let runtimeStore: AskAIRuntimeStore
    private let usesRuntime: Bool
    private var runtime: AskAIRuntime?
    private var runtimeRecovery: Task<Void, Error>?
    private var supplementalConsent: CheckedContinuation<Void, Error>?
    private var pendingRuntimePublication: (engine: AskAIRuntime, turn: Answer, evidence: DaybookRetrieval.Prepared)?
    private let backgroundExecution: any AskAIBackgroundExecuting
    private var applicationInBackground = false
    private var backgroundLease: UUID?
    private var backgroundReconciliationScheduled = false
    private var task: Task<Void, Never>?
    private var version = UUID()
    /// UI selection and requested evidence coverage are deliberately independent.
    var scopeLoader: ((DateInterval) async throws -> [DayRecord])?
    private var loadedScopeRecords: [DayRecord] = []
    /// Before the initial read finishes there is no evidence to invalidate yet.
    /// Repository notifications dirty that read; they are not a user cancellation.
    private var initialScopeRevision: UUID?
    private var scopeRevalidation: Task<Void, Error>?
    private var scopeValidationVersion = UUID()
    private var deletionObservation: AnyCancellable?
    func recordsForEvidence(_ records: [DayRecord]) -> [DayRecord] {
        let loadedIDs = Set(loadedScopeRecords.map(\.id))
        return LegacyAudioDeletionLedger.shared.filter(records.filter { !loadedIDs.contains($0.id) } + loadedScopeRecords)
    }
    func isCurrent(_ evidence:DaybookEvidenceSnapshot,records:[DayRecord],allowedKinds:Set<DayRecord.Kind>) -> Bool {
        if let contactID=evidence.speakerContactID,let fingerprint=evidence.speakerFingerprint {
            guard evidence.allowedKinds.isSubset(of:allowedKinds) else { return false }
            return (try? speakerAsk?.currentFingerprint(contactID:contactID)) == fingerprint
        }
        guard evidence.allowedKinds == allowedKinds else { return false }
        return evidence.isCurrent(records:records,allowedKinds:allowedKinds)
    }
    func isCurrent(_ prepared:DaybookRetrieval.Prepared,records:[DayRecord],allowedKinds:Set<DayRecord.Kind>) -> Bool {
        isCurrent(prepared.evidence,records:records,allowedKinds:allowedKinds)
    }
    func isCurrent(_ turn:Answer,records:[DayRecord],allowedKinds:Set<DayRecord.Kind>) -> Bool {
        isCurrent(turn.evidence,records:records,allowedKinds:allowedKinds)
    }
    func invalidateLoadedScope(force: Bool = false) {
        if !force, isPending, initialScopeRevision != nil {
            initialScopeRevision = UUID()
            return
        }
        guard !force, (isPending || remoteConfirmation != nil || pendingRuntimePublication != nil),
              let evidence = prepared, let activeTurnID, preparedTurnID == activeTurnID, let scopeLoader else {
            loadedScopeRecords = []; cancel(reason: force ? .sourceDeleted : .sourcesChanged); prepared = nil; preparedTurnID = nil; return
        }
        // A repository revision is only a hint. Re-read this run's exact scope before
        // its next model request; unrelated dates must not cancel a useful answer.
        scopeRevalidation?.cancel()
        let validation = UUID(); scopeValidationVersion = validation
        let validatingRuntime = runtime
        // Close the queued-publication window before any asynchronous scope read starts.
        validatingRuntime?.suspendPublication(validation: validation)
        let runVersion = version
        scopeRevalidation = Task { [weak self] in
            do {
                let current = try await Self.loadStableScope(DateInterval(start: evidence.dayStart, end: evidence.dayEnd), loader: scopeLoader)
                try Task.checkCancellation()
                guard let self, self.version == runVersion, self.scopeValidationVersion == validation else { throw CancellationError() }
                guard self.isCurrent(evidence, records: current, allowedKinds: self.latestAllowedKinds) else {
                    self.loadedScopeRecords = []; self.cancel(reason: .sourcesChanged); self.prepared = nil; self.preparedTurnID = nil
                    self.statusMessage = "本次使用的资料已变化，请重新回答。"
                    throw CancellationError()
                }
                self.loadedScopeRecords = current
                self.latestRecords = self.recordsForEvidence(self.latestRecords)
                validatingRuntime?.resumePublication(validation: validation)
            } catch {
                if let self, self.version == runVersion, self.scopeValidationVersion == validation {
                    self.cancel(reason: .scopeUnavailable); self.prepared = nil; self.preparedTurnID = nil
                }
                throw error
            }
        }
    }
    private static func loadStableScope(_ scope: DateInterval,
                                        loader: (DateInterval) async throws -> [DayRecord]) async throws -> [DayRecord] {
        for attempt in 0..<3 {
            try Task.checkCancellation()
            do { return try await loader(scope) }
            catch ContentSegmentError.staleRevision {
                try Task.checkCancellation()
                guard attempt < 2 else { throw ContentSegmentError.staleRevision }
                await Task.yield()
            }
        }
        throw ContentSegmentError.staleRevision
    }
    func validateSourceChanges() async throws {
        while let validation = scopeRevalidation {
            let token = scopeValidationVersion
            do { try await validation.value }
            catch { if token == scopeValidationVersion { throw error }; continue }
            if token == scopeValidationVersion { scopeRevalidation = nil; return }
        }
    }
    private var latestRecords: [DayRecord] = []
    private var latestDate: Date?
    private var latestAllowedKinds: Set<DayRecord.Kind> = []
    private var latestConfiguration: AIConfiguration?
    private var latestConfigurationRevision: Int?
    private let answerService: any DaybookAnswering
    private let semanticSearch: (any DaybookSemanticSearching)?
    private let speakerAsk: DaybookSpeakerAskRepository?

    init(answerService: (any DaybookAnswering)? = nil, store: DaybookConversationStore = .local(), semanticSearch: (any DaybookSemanticSearching)? = nil, backgroundExecution: (any AskAIBackgroundExecuting)? = nil) {
        #if os(iOS)
        self.semanticSearch = semanticSearch ?? DaybookSemanticIndex.shared
        #else
        self.semanticSearch = semanticSearch
        #endif
        self.backgroundExecution = backgroundExecution ?? AskAIBackgroundExecution()
        self.answerService = answerService ?? DaybookAnswerService()
        self.store = store
        self.runtimeStore = AskAIRuntimeStore(conversationStore: store)
        self.usesRuntime = answerService == nil
        #if os(iOS)
        speakerAsk = try? DaybookSpeakerAskRepository()
        #else
        speakerAsk = nil
        #endif
        _ = LegacyAudioDeletionLedger.shared
        deletionObservation = NotificationCenter.default.publisher(for:LegacyAudioDeletionLedger.notification).sink { [weak self] note in
            if let id = note.userInfo?["legacyNoteID"] as? UUID { LegacyAudioDeletionLedger.shared.record(id) }
            if Thread.isMainThread { MainActor.assumeIsolated { self?.sourceDeleted() } }
            else { Task { @MainActor [weak self] in self?.sourceDeleted() } }
        }
        do {
            try store.interruptPending()
            let page = try store.loadPage()
            savedTurns = page.turns; historyCursor = page.cursor; hasMoreHistory = page.hasMore
        }
        catch { storageError = error.localizedDescription; needsStorageReset = true }
        let runtimeStore = self.runtimeStore
        runtimeRecovery = Task { try await runtimeStore.interruptUnfinishedAttempts() }
        // Wait for the caller's current permissions before publishing any persisted answer.
    }

    private func sourceDeleted() {
        invalidateLoadedScope(force: true)
        latestRecords = LegacyAudioDeletionLedger.shared.filter(latestRecords)
        answer = nil; publishTurns()
    }

    func synchronize(records: [DayRecord], selectedDate: Date, allowedKinds: Set<DayRecord.Kind>, configuration: AIConfiguration, configurationRevision: Int? = nil) {
        let records = recordsForEvidence(records)
        let configurationChanged = latestConfiguration.map { $0 != configuration } ?? false
        let revisionChanged = configurationRevision.map { latestConfigurationRevision != nil && latestConfigurationRevision != $0 } ?? false
        let pendingEvidence = activeTurnID.flatMap { id in savedTurns.first { $0.id == id }?.evidence }
        let loadingInitialScope = initialScopeRevision != nil
        if loadingInitialScope, self.latestRecords != records { initialScopeRevision = UUID() }
        let sourcesChanged = !loadingInitialScope && (prepared.map { !isCurrent($0,records:records,allowedKinds:allowedKinds) }
            ?? (isPending && (pendingEvidence.map { !isCurrent($0,records:records,allowedKinds:allowedKinds) } ?? (self.latestRecords != records))))
        let permissionsChanged = latestDate == nil || latestAllowedKinds != allowedKinds
        if latestDate != nil { revokedKinds.formUnion(latestAllowedKinds.subtracting(allowedKinds)) }
        latestRecords = records; latestDate = selectedDate; latestAllowedKinds = allowedKinds
        latestConfiguration = configuration
        if let configurationRevision { latestConfigurationRevision = configurationRevision }
        if configurationChanged || revisionChanged || sourcesChanged,
           case .save(let turn, let day) = pendingMutation, turn.completionState == .completed {
            pendingMutation = .save(turn.replacing(text: "回答条件已变化，可重新提问。", state: .cancelled), day: day)
        }
        if configurationChanged || revisionChanged || sourcesChanged || permissionsChanged {
            cancel(reason: permissionsChanged ? .permissionsChanged : (configurationChanged || revisionChanged ? .configurationChanged : .sourcesChanged))
            prepared = nil; preparedTurnID = nil; answer = nil; errorMessage = nil
            statusMessage = sourcesChanged ? "资料已更新，历史对话已保留。后续回答会重新核对当前资料。" : nil
        }
        if permissionsChanged && !needsStorageReset { privacyCleanupPending = true; cleanupPermissions() }
        publishTurns()
    }

    /// Returns once the question is durably accepted, independently of answer completion.
    @discardableResult
    func ask(_ question: String, records: [DayRecord], selectedDate: Date, allowedKinds: Set<DayRecord.Kind>, settings: AppSettings) -> Bool {
        beginQuestion(question, records: records, selectedDate: selectedDate, allowedKinds: allowedKinds, settings: settings)
    }

    @discardableResult
    func retry(turnID: UUID, records: [DayRecord], selectedDate: Date, allowedKinds: Set<DayRecord.Kind>, settings: AppSettings) -> Bool {
        guard !isPending, remoteConfirmation == nil, let original = savedTurns.first(where: { $0.id == turnID }) else { return false }
        return beginQuestion(original.question, records: records, selectedDate: selectedDate, allowedKinds: allowedKinds, settings: settings, existingDraft: original)
    }

    private func acceptDraft(_ draft: Answer, day: Date) -> Bool {
        activeTurnID = draft.id; activeTurnDay = day
        // A completed answer stays durable and visible while its new attempt runs.
        if draft.completionState == .completed { return true }
        let pending = draft.replacing(text: "", state: .pending)
        pendingMutation = .save(pending, day: day)
        return commitPendingMutation()
    }

    private func beginQuestion(_ question: String, records: [DayRecord], selectedDate: Date, allowedKinds: Set<DayRecord.Kind>, settings: AppSettings, existingDraft: Answer? = nil) -> Bool {
        if let speakerAsk,(!allowedKinds.intersection([.voice,.thought]).isEmpty),let resolution=try? speakerAsk.resolve(question:question,priorTurns:Array(turns.filter{$0.completionState == .completed}.suffix(3))) {
            switch resolution {
            case .unrelated: break
            default:
                return askSpeaker(question,records:records,selectedDate:selectedDate,allowedKinds:allowedKinds,settings:settings,resolution:resolution,existingDraft:existingDraft)
            }
        }
        guard let scopeLoader else { return askLoaded(question,records:records,selectedDate:selectedDate,allowedKinds:allowedKinds,settings:settings,existingDraft:existingDraft) }
        synchronize(records:records,selectedDate:selectedDate,allowedKinds:allowedKinds,configuration:settings.ai,configurationRevision:settings.aiRevision)
        cancel(reason: .superseded)
        // The new question has not loaded its evidence yet. A completed prior turn's
        // scope must not be mistaken for the active read during repository invalidation.
        prepared = nil; preparedTurnID = nil; answer = nil; errorMessage = nil; statusMessage = nil
        do {
            let selectedDay = Calendar.current.startOfDay(for:selectedDate)
            let history = Array(turns.filter { $0.completionState == .completed }.suffix(3))
            let retrieval = DaybookRetrieval()
            let queryNow = Date.now
            let plan = try retrieval.automaticScope(question, now: queryNow, priorTurns: history)
            let resolved = try retrieval.prepare(question:question,records:[],selectedDate:selectedDate,now:queryNow,allowedKinds:allowedKinds,priorTurns:history,automatic:true)
            retrievalStatus = "正在查找相关记录 · \(plan.label)"
            let draft = existingDraft ?? Answer(id:UUID(),question:question.trimmingCharacters(in:.whitespacesAndNewlines),text:"",generated:false,provider:"",
                evidence:DaybookEvidenceSnapshot(records:records,dayStart:resolved.dayStart,dayEnd:resolved.dayEnd,allowedKinds:allowedKinds),
                sources:[],scopeDescription:"",state:.pending,createdAt:.now)
            guard acceptDraft(draft, day: selectedDay) else {
                pendingMutation = .save(draft.replacing(text:"问题尚未开始处理，请重试保存后重新提问。",state:.cancelled),day:selectedDay)
                activeTurnID = nil; activeTurnDay = nil; return false
            }
            let token = UUID(); version = token; isPending = true; initialScopeRevision = UUID()
            let configuration = settings.ai, revision = settings.aiRevision
            task = Task { [weak self] in
                do {
                    guard let self else { return }
                    var loaded = try await self.loadInitialScope(DateInterval(start:resolved.dayStart,end:resolved.dayEnd), token: token, loader: scopeLoader)
                    guard !Task.isCancelled, self.version == token, settings.ai == configuration, settings.aiRevision == revision else { return }
                    var expanded = false
                    let candidate = try retrieval.prepare(question:question, records:loaded, selectedDate:selectedDate, now:queryNow, allowedKinds:allowedKinds, priorTurns:history, automatic:true)
                    if plan.canExpand && candidate.matchedCount == 0 {
                        expanded = true
                        let broader = try retrieval.automaticScope(question, now:queryNow, priorTurns:history, expanded:true)
                        self.retrievalStatus = "近期没有匹配，正在查找更早记录…"
                        loaded = try await self.loadInitialScope(DateInterval(start:broader.start,end:broader.end), token: token, loader: scopeLoader)
                        guard !Task.isCancelled, self.version == token, settings.ai == configuration, settings.aiRevision == revision else { return }
                    }
                    self.loadedScopeRecords = loaded; self.initialScopeRevision = nil; self.isPending = false; self.task = nil
                    // Reuse the already durable question; source synchronization must not cancel it.
                    self.activeTurnID = nil; self.activeTurnDay = nil
                    self.askLoaded(question,records:self.recordsForEvidence(records),selectedDate:selectedDate,allowedKinds:allowedKinds,settings:settings,existingDraft:draft,expanded:expanded,queryNow:queryNow)
                } catch {
                    guard let self, self.version == token, !Task.isCancelled else { return }
                    self.initialScopeRevision = nil; self.isPending = false; self.task = nil
                    if error is InitialScopeFailure { self.fail(error) }
                    else { self.fail(NSError(domain:"ContentScope",code:1,userInfo:[NSLocalizedDescriptionKey:"无法完整读取本次查找范围的资料，请解锁后重试。"])) }
                }
            }
            return true
        } catch { errorMessage = error.localizedDescription; return false }
    }

    private enum InitialScopeFailure: LocalizedError {
        case updating
        var errorDescription: String? { "资料正在持续更新，本次尚未发送给 AI，请稍后点“重新回答”。" }
    }

    private func loadInitialScope(_ scope: DateInterval, token: UUID,
                                  loader: (DateInterval) async throws -> [DayRecord]) async throws -> [DayRecord] {
        for _ in 0..<3 {
            try Task.checkCancellation()
            guard version == token, let revision = initialScopeRevision else { throw CancellationError() }
            do {
                let loaded = try await loader(scope)
                try Task.checkCancellation()
                guard version == token, initialScopeRevision != nil else { throw CancellationError() }
                guard initialScopeRevision == revision else { continue }
                return loaded
            } catch {
                try Task.checkCancellation()
                guard version == token, initialScopeRevision != nil else { throw CancellationError() }
                // A concurrent repository update may make its consistency read fail.
                // Coalesce the notifications and retry before any model/consent step.
                if initialScopeRevision != revision { continue }
                if case ContentSegmentError.staleRevision = error { continue }
                throw error
            }
        }
        throw InitialScopeFailure.updating
    }

    private func askSpeaker(_ question:String,records:[DayRecord],selectedDate:Date,allowedKinds:Set<DayRecord.Kind>,settings:AppSettings,resolution:DaybookSpeakerAskRepository.Resolution,existingDraft:Answer? = nil) -> Bool {
        if let required=resolution.requiredKind,!allowedKinds.contains(required) {
            errorMessage=required == .thought ? "请先在 AI 设置中允许读取闪念记录。" : "请先在 AI 设置中允许读取录音。"
            return false
        }
        let records=recordsForEvidence(records)
        synchronize(records:records,selectedDate:selectedDate,allowedKinds:allowedKinds,configuration:settings.ai,configurationRevision:settings.aiRevision)
        guard storageError==nil else { statusMessage="请先重试保存或读取本机对话，再发送新问题。";return false }
        cancel();prepared=nil;preparedTurnID=nil;answer=nil;errorMessage=nil;statusMessage=nil
        let question=question.trimmingCharacters(in:.whitespacesAndNewlines)
        guard !question.isEmpty,question.count<=300 else { errorMessage=question.isEmpty ? "请输入一个问题。" : "请把问题缩短到 300 字以内。";return false }
        guard let contactID=resolution.contactID,let speakerAsk else { errorMessage="无法读取本机说话人资料。";return false }
        let day=Calendar.current.startOfDay(for:selectedDate),end=Calendar.current.date(byAdding:.day,value:1,to:day)!
        let draft=existingDraft ?? Answer(id:UUID(),question:question,text:"",generated:false,provider:"",evidence:DaybookEvidenceSnapshot(records:records,dayStart:day,dayEnd:end,allowedKinds:allowedKinds),sources:[],scopeDescription:"",state:.pending,createdAt:.now)
        guard acceptDraft(draft, day: day) else { pendingMutation = .save(draft.replacing(text:"问题尚未开始处理，请重试保存后重新提问。",state:.cancelled),day:day);activeTurnID=nil;activeTurnDay=nil;return false }
        let token=UUID();version=token;isPending=true;retrievalStatus="正在查找已关联说话人的录音…"
        let configuration=settings.ai,revision=settings.aiRevision
        let queryNow=Date.now
        task=Task { [weak self] in
            do {
                let snapshot=try await Task.detached(priority:.userInitiated) { try speakerAsk.snapshot(contactID:contactID) }.value
                let fingerprint=snapshot.fingerprint
                let evidence=try DaybookRetrieval().prepareSpeaker(question:question,items:snapshot.items,records:records,contactID:contactID,contactName:resolution.contactName,fingerprint:fingerprint,selectedDate:selectedDate,now:queryNow,directResponse:resolution.directResponse)
                guard let self,!Task.isCancelled,self.version==token,self.latestConfiguration==configuration,self.latestConfigurationRevision==revision else { return }
                self.isPending=false;self.task=nil;self.prepared=evidence;self.preparedTurnID=draft.id
                self.present(evidence,configuration:configuration,revision:revision,settings:settings)
            } catch {
                guard let self,self.version==token,!Task.isCancelled else{return}
                self.isPending=false;self.task=nil;self.fail(error)
            }
        }
        return true
    }

    @discardableResult
    private func askLoaded(_ question: String, records: [DayRecord], selectedDate: Date, allowedKinds: Set<DayRecord.Kind>, settings: AppSettings, existingDraft: Answer? = nil, expanded: Bool = false, queryNow: Date = .now) -> Bool {
        synchronize(records: records, selectedDate: selectedDate, allowedKinds: allowedKinds, configuration: settings.ai, configurationRevision: settings.aiRevision)
        guard storageError == nil else { statusMessage = "请先重试保存或读取本机对话，再发送新问题。"; return false }
        cancel(); prepared = nil; preparedTurnID = nil; answer = nil; errorMessage = nil; statusMessage = nil
        let question = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, question.count <= 300 else { errorMessage = question.isEmpty ? "请输入问题。" : "请把问题缩短到 300 字以内。"; return false }
        let day = Calendar.current.startOfDay(for: selectedDate)
        let end = Calendar.current.date(byAdding: .day, value: 1, to: day)!
        let history = Array(turns.filter { $0.completionState == .completed }.suffix(3))
        let draft = existingDraft ?? Answer(id: UUID(), question: question, text: "", generated: false, provider: "",
            evidence: DaybookEvidenceSnapshot(records: records, dayStart: day, dayEnd: end, allowedKinds: allowedKinds),
            sources: [], scopeDescription: "", state: .pending, createdAt: .now)
        guard acceptDraft(draft, day: day) else {
            pendingMutation = .save(draft.replacing(text: "问题尚未开始处理，请重试保存后重新提问。", state: .cancelled), day: day)
            activeTurnID = nil; activeTurnDay = nil
            return false
        }
        do {
            let date = selectedDate
            let retrieval = DaybookRetrieval()
            let plan = try retrieval.automaticScope(question, now:queryNow, priorTurns:history)
            let initial = try retrieval.prepare(question:question,records:records,selectedDate:date,now:queryNow,allowedKinds:allowedKinds,priorTurns:history,automatic:true,expanded:expanded)
            let shouldExpand = expanded || (scopeLoader == nil && plan.canExpand && initial.matchedCount == 0)
            let evidence = shouldExpand && !expanded ? try retrieval.prepare(question:question,records:records,selectedDate:date,now:queryNow,allowedKinds:allowedKinds,priorTurns:history,automatic:true,expanded:true) : initial
            retrievalStatus = "正在查找相关记录 · \(evidence.dateLabel)"
            prepared = evidence
            preparedTurnID = draft.id
            if let semanticSearch, evidence.statistics.totalCount > 0,
               !DaybookRetrieval.isAggregateQuestion(question), !evidence.context.isEmpty {
                let token = UUID(); version = token; isPending = true
                let configuration = settings.ai, configurationRevision = settings.aiRevision
                task = Task { [weak self] in
                    let matches = await semanticSearch.search(query: question, records: records, dayStart: evidence.dayStart,
                        dayEnd: evidence.dayEnd, allowedKinds: allowedKinds, limit: 20)
                    guard let self, !Task.isCancelled, self.version == token,
                          self.latestConfiguration == configuration, self.latestConfigurationRevision == configurationRevision,
                          self.isCurrent(evidence,records:self.latestRecords,allowedKinds:self.latestAllowedKinds) else { return }
                    self.isPending = false; self.task = nil
                    do {
                        let enriched = try DaybookRetrieval().prepare(question: question, records: self.latestRecords,
                            selectedDate: date, now:queryNow, allowedKinds: self.latestAllowedKinds, priorTurns: Array(history), semantic: matches, automatic:true, expanded:shouldExpand)
                        self.present(enriched, configuration: configuration, revision: configurationRevision, settings: settings)
                    } catch { self.fail(error) }
                }
            } else { present(evidence, configuration: settings.ai, revision: settings.aiRevision, settings: settings) }
        } catch { fail(error) }
        return true
    }

    private func present(_ evidence: DaybookRetrieval.Prepared, configuration: AIConfiguration, revision: Int, settings: AppSettings) {
        prepared = evidence
        guard usesRuntime, evidence.directResponse == nil, let turnID = activeTurnID else {
            presentReady(evidence, configuration: configuration, revision: revision, settings: settings); return
        }
        let token = UUID(); version = token; isPending = true
        retrievalStatus = "正在整理对话上下文…"
        let current: @MainActor () -> Bool = { [weak self] in
            guard let self else { return false }
            return self.version == token && self.latestConfiguration == configuration && self.latestConfigurationRevision == revision && self.isCurrent(evidence, records: self.latestRecords, allowedKinds: self.latestAllowedKinds)
        }
        let engine = AskAIRuntime(prepared: evidence, records: latestRecords, configuration: configuration, configurationRevision: revision, turnID: turnID, store: runtimeStore,
            isCurrent: current, ensureFresh: { [weak self] in
                guard let self else { throw CancellationError() }
                try await self.validateSourceChanges()
                guard current() else { throw CancellationError() }
            }, onStage: { [weak self] stage in if current() { self?.retrievalStatus = stage } },
            authorizeAdditional: { [weak self, weak settings] text in
                guard let self, let settings, current() else { throw CancellationError() }
                guard settings.requiresRemoteAIConfirmation else { return }
                try await withCheckedThrowingContinuation { continuation in
                    self.supplementalConsent = continuation
                    self.remoteConfirmation = RemoteConfirmation(question: evidence.question, context: text, sourceCount: 0,
                        destination: configuration.destinationDescription, isSupplemental: true, prepared: evidence,
                        configuration: configuration, configurationRevision: revision)
                    self.retrievalStatus = "等待确认新增资料…"
                }
            })
        runtime = engine
        task = Task { [weak self] in
            do {
                try await self?.runtimeRecovery?.value
                guard current() else { throw CancellationError() }
                let bounded = try await engine.prepare()
                guard let self, current() else { throw CancellationError() }
                self.task = nil; self.isPending = false
                self.presentReady(bounded, configuration: configuration, revision: revision, settings: settings)
            } catch {
                await engine.fail(error)
                guard let self, self.version == token else { return }
                self.task = nil; self.isPending = false; self.runtime = nil; self.fail(error)
            }
        }
    }

    private func presentReady(_ evidence: DaybookRetrieval.Prepared, configuration: AIConfiguration, revision: Int, settings: AppSettings) {
        prepared = evidence
        if let direct = evidence.directResponse {
            complete(evidence, text: direct, generated: false, provider: "本地检索与统计")
        } else if configuration.isRemote {
            let endpoint = URLComponents(string: configuration.baseURL)
            let destination = configuration.mode == .nearbyMac ? configuration.destinationDescription : configuration.mode == .chatgpt ? "ChatGPT · \(configuration.chatGPTModel) · OpenAI" : "\(configuration.apiProtocol.rawValue) · \(configuration.model) · \(endpoint?.scheme ?? "https")://\(endpoint?.host ?? "已配置的模型服务")\(endpoint?.port.map { ":\($0)" } ?? "")\(endpoint?.path ?? "")/\(configuration.apiProtocol.endpointPath)"
            let confirmation = RemoteConfirmation(question: evidence.question, context: evidence.context,
                sourceCount: evidence.sources.count, destination: destination, instructionOverride: runtime?.instruction, prepared: evidence, configuration: configuration, configurationRevision: revision)
            if settings.requiresRemoteAIConfirmation { remoteConfirmation = confirmation }
            else { sendRemote(confirmation, settings: settings, confirmed: false) }
        } else { start(evidence, configuration: configuration, apiKey: nil) }
    }

    func confirmRemote(records: [DayRecord], selectedDate: Date, allowedKinds: Set<DayRecord.Kind>, settings: AppSettings, doNotAskAgain: Bool = false) {
        let records = recordsForEvidence(records)
        guard let confirmation = remoteConfirmation else { return }
        synchronize(records: records, selectedDate: selectedDate, allowedKinds: allowedKinds, configuration: settings.ai, configurationRevision: settings.aiRevision)
        guard remoteConfirmation?.id == confirmation.id, confirmation.configuration == settings.ai, confirmation.configurationRevision == settings.aiRevision,
              isCurrent(confirmation.prepared,records:records,allowedKinds:allowedKinds) else { return }
        remoteConfirmation = nil
        if confirmation.isSupplemental {
            guard settings.authorizeRemoteAISend(confirmationIsCurrent: true, rememberChoice: doNotAskAgain) else { cancel(); return }
            let waiting = supplementalConsent; supplementalConsent = nil
            waiting?.resume(); return
        }
        sendRemote(confirmation, settings: settings, confirmed: true, doNotAskAgain: doNotAskAgain)
    }

    private func sendRemote(_ confirmation: RemoteConfirmation, settings: AppSettings, confirmed: Bool, doNotAskAgain: Bool = false) {
        guard confirmation.configuration == settings.ai, confirmation.configurationRevision == settings.aiRevision,
              isCurrent(confirmation.prepared,records:latestRecords,allowedKinds:latestAllowedKinds) else { cancel(); return }
        do {
            if confirmation.configuration.mode == .nearbyMac {
                _ = try confirmation.configuration.validated(apiKey: "")
                guard settings.authorizeRemoteAISend(confirmationIsCurrent: confirmed ? true : nil, rememberChoice: doNotAskAgain) else { cancel(); return }
                start(confirmation.prepared, configuration: confirmation.configuration, apiKey: nil)
                return
            }
            if confirmation.configuration.mode == .chatgpt {
                guard settings.chatGPT.isReady, settings.chatGPT.selectedID == confirmation.configuration.chatGPTAccountID else {
                    throw AIServiceError.invalidConfiguration("ChatGPT 当前不可用，请在 AI 模型设置中重新连接或管理用量。")
                }
                guard settings.authorizeRemoteAISend(confirmationIsCurrent: confirmed ? true : nil, rememberChoice: doNotAskAgain) else { cancel(); return }
                start(confirmation.prepared, configuration: confirmation.configuration, apiKey: nil)
                return
            }
            let key = try settings.apiKey()
            _ = try confirmation.configuration.validated(apiKey: key)
            guard settings.authorizeRemoteAISend(confirmationIsCurrent: confirmed ? true : nil, rememberChoice: doNotAskAgain) else { cancel(); return }
            start(confirmation.prepared, configuration: confirmation.configuration, apiKey: key)
        } catch { fail(error) }
    }

    func dismissRemoteConfirmation() {
        guard remoteConfirmation != nil else { return }
        cancel(); statusMessage = "已取消发送，可继续查看本地检索结果。"
    }

    /// Temporary inactive states and navigation do not change the answer lifetime.
    /// Call only for actual foreground/background transitions.
    func setApplicationInBackground(_ background: Bool) {
        applicationInBackground = background
        reconcileBackgroundExecution()
    }

    private func scheduleBackgroundReconciliation() {
        guard !backgroundReconciliationScheduled else { return }
        backgroundReconciliationScheduled = true
        // Retrieval -> context -> generation may toggle isPending in one synchronous
        // transition. Reconcile once so those stages do not renew the OS deadline.
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.backgroundReconciliationScheduled = false
            self.reconcileBackgroundExecution()
        }
    }

    private func endBackgroundExecution() {
        guard backgroundLease != nil else { return }
        backgroundLease = nil
        backgroundExecution.end()
    }

    private func reconcileBackgroundExecution() {
        guard applicationInBackground, isPending, remoteConfirmation == nil else {
            endBackgroundExecution(); return
        }
        guard backgroundLease == nil else { return }
        let lease = UUID(); backgroundLease = lease
        let granted = backgroundExecution.begin { [weak self] in
            guard let self, self.backgroundLease == lease else { return }
            if self.applicationInBackground, self.isPending, self.remoteConfirmation == nil {
                self.cancel(reason: .backgroundExpired)
            }
            // Invalidate/persist before returning the lease to iOS. Old callbacks
            // cannot interrupt a new question or a subsequent background period.
            self.endBackgroundExecution()
        }
        if !granted, backgroundLease == lease {
            backgroundLease = nil
            cancel(reason: .backgroundUnavailable)
        }
    }

    func cancel(reason: CancellationReason = .user) {
        let hadPending = isPending || remoteConfirmation != nil
        let hadActiveTurn = activeTurnID != nil || hadPending
        initialScopeRevision = nil
        scopeRevalidation?.cancel(); scopeRevalidation = nil; scopeValidationVersion = UUID()
        runtime?.cancel(reason: reason.rawValue); runtime = nil
        pendingRuntimePublication = nil
        let waiting = supplementalConsent; supplementalConsent = nil; waiting?.resume(throwing: CancellationError())
        task?.cancel(); task = nil; version = UUID()
        isPending = false; remoteConfirmation = nil
        let alreadyCompleted = finishUnanswered(state: .cancelled, text: reason.message)
        if hadActiveTurn { endBackgroundExecution() }
        if hadPending && !alreadyCompleted { statusMessage = reason.message }
    }

    func clearHistory() {
        cancel(); prepared = nil; preparedTurnID = nil; errorMessage = nil; statusMessage = nil
        pendingMutation = .reset
        commitPendingMutation()
    }

    func resetStorage() {
        cancel(); prepared = nil; preparedTurnID = nil; errorMessage = nil; statusMessage = nil
        pendingMutation = .reset
        commitPendingMutation()
    }

    func retryPersistence() {
        if let pending = pendingRuntimePublication {
            guard !isPending else { return }
            isPending = true
            let token = version
            task = Task { [weak self] in
                do {
                    try await pending.engine.publish(pending.turn)
                    guard let self, self.version == token else { return }
                    self.applyRuntimePublication(pending.turn, evidence: pending.evidence)
                    self.storageError = nil
                } catch {
                    guard let self, self.version == token else { return }
                    self.storageError = "回答已生成，但尚未保存。请重试保存。"
                }
                guard let self, self.version == token else { return }
                self.isPending = false; self.task = nil
            }
            return
        }
        if case .reset = pendingMutation { commitPendingMutation(); return }
        if needsStorageReset {
            do {
                try store.interruptPending()
                let page = try store.loadPage()
                savedTurns = page.turns; historyCursor = page.cursor; hasMoreHistory = page.hasMore
                needsStorageReset = false; storageError = nil; pendingMutation = nil
                privacyCleanupPending = latestDate != nil
            } catch { storageError = error.localizedDescription; return }
        }
        // A failed page read blocks writes until a successful read verifies storage again.
        // Preserve the pending mutation while repairing that read first.
        if historyReadFailed { loadMoreHistory(); if historyReadFailed { return } }
        if privacyCleanupPending { cleanupPermissions() }
        if pendingMutation != nil { commitPendingMutation() }
        publishTurns()
    }

    func loadMoreHistory() {
        guard hasMoreHistory, !needsStorageReset else { return }
        do {
            let page = try store.loadPage(before: historyCursor)
            let known = Set(savedTurns.map(\.id))
            savedTurns.insert(contentsOf: page.turns.filter { !known.contains($0.id) }, at: 0)
            historyCursor = page.cursor; hasMoreHistory = page.hasMore; historyReadFailed = false
            if pendingMutation == nil && !privacyCleanupPending { storageError = nil }
            publishTurns()
        } catch { historyReadFailed = true; storageError = error.localizedDescription }
    }

    func isSynchronized(selectedDate: Date) -> Bool {
        latestDate.map { Calendar.current.isDate($0, inSameDayAs: selectedDate) } ?? false
    }

    /// Evidence freshness gates new answers, not the user's historical conversation.
    func validatedTurns(records: [DayRecord], selectedDate: Date, allowedKinds: Set<DayRecord.Kind>) -> [Answer] {
        savedTurns.map { permitted($0, allowedKinds: allowedKinds) }
    }

    private func permitted(_ turn: Answer, allowedKinds: Set<DayRecord.Kind>) -> Answer {
        if turn.completionState == .redacted { return turn }
        return turn.evidence.allowedKinds.isSubset(of: allowedKinds) && turn.evidence.allowedKinds.isDisjoint(with: revokedKinds)
            ? turn : turn.redacted()
    }

    private func publishTurns() {
        guard let date = latestDate else { turns = []; return }
        turns = validatedTurns(records: latestRecords, selectedDate: date, allowedKinds: latestAllowedKinds)
    }

    private func cleanupPermissions() {
        do {
            try store.redactDisallowed(latestAllowedKinds.subtracting(revokedKinds))
            savedTurns = savedTurns.map { permitted($0, allowedKinds: latestAllowedKinds) }
            privacyCleanupPending = false
            revokedKinds = []
            if pendingMutation == nil && !historyReadFailed { storageError = nil }
        } catch { privacyCleanupPending = true; storageError = error.localizedDescription }
    }

    @discardableResult
    private func commitPendingMutation() -> Bool {
        guard let mutation = pendingMutation else { return true }
        do {
            switch mutation {
            case .save(let candidate, let day):
                var turn = permitted(candidate, allowedKinds: latestAllowedKinds)
                if turn.completionState == .completed && !isCurrent(turn.evidence,records:latestRecords,allowedKinds:latestAllowedKinds) {
                    turn = turn.replacing(text: "资料已变化，本次回答未保存，可重新提问。", state: .cancelled)
                }
                try store.saveTurn(turn, day: day)
                if let index = savedTurns.firstIndex(where: { $0.id == turn.id }) { savedTurns[index] = turn }
                else { savedTurns.append(turn) }
                answer = turn.completionState == .completed ? turn : nil
            case .reset:
                try store.reset()
                savedTurns = []; historyCursor = nil; hasMoreHistory = false
                needsStorageReset = false; historyReadFailed = false; privacyCleanupPending = false
                answer = nil
            }
            pendingMutation = nil
            if !privacyCleanupPending && !historyReadFailed { storageError = nil }
            publishTurns()
            return true
        } catch { storageError = error.localizedDescription; publishTurns(); return false }
    }

    @discardableResult
    private func finishUnanswered(state: Answer.State, text: String) -> Bool {
        let id = activeTurnID, day = activeTurnDay
        activeTurnID = nil; activeTurnDay = nil
        guard let id, let day, let turn = savedTurns.first(where: { $0.id == id }), turn.completionState == .pending else { return false }
        // Runtime publication commits on its worker before its MainActor callback.
        // The publication fence is already invalidated by cancel/fail: any winning
        // commit is now visible and must never be replaced by a late interruption.
        if let stored = try? store.runtimeTurn(id: id), stored.completionState == .completed {
            let completed = permitted(stored, allowedKinds: latestAllowedKinds)
            if let index = savedTurns.firstIndex(where: { $0.id == id }) { savedTurns[index] = completed }
            answer = completed.completionState == .completed ? completed : nil
            publishTurns()
            return true
        }
        pendingMutation = .save(turn.replacing(text: String(text.prefix(8_000)), state: state), day: day)
        commitPendingMutation()
        return false
    }

    private func fail(_ error: Error) {
        errorMessage = error.localizedDescription
        finishUnanswered(state: .failed, text: error.localizedDescription)
    }

    private func complete(_ evidence: DaybookRetrieval.Prepared, text: String, generated: Bool, provider: String) {
        guard let id = activeTurnID, let day = activeTurnDay,
              let draft = savedTurns.first(where: { $0.id == id }) else { return }
        let turn = Answer(id: id, question: evidence.question, text: text, generated: generated,
            provider: String(provider.prefix(300)), evidence: evidence.evidence,
            sources: evidence.sources, scopeDescription: evidence.scopeDescription,
            questionReferenceIDs: evidence.questionReferenceIDs, state: .completed, createdAt: draft.createdAt)
        activeTurnID = nil; activeTurnDay = nil
        pendingMutation = .save(turn, day: day)
        commitPendingMutation()
    }

    private func applyRuntimePublication(_ completed: Answer, evidence: DaybookRetrieval.Prepared) {
        prepared = evidence
        if let index = savedTurns.firstIndex(where: { $0.id == completed.id }) { savedTurns[index] = completed }
        answer = completed; activeTurnID = nil; activeTurnDay = nil; runtime = nil
        pendingRuntimePublication = nil; storageError = nil
        publishTurns()
    }

    private func start(_ evidence: DaybookRetrieval.Prepared, configuration: AIConfiguration, apiKey: String?) {
        task?.cancel()
        let engine = runtime
        let token = engine == nil ? UUID() : version; version = token
        isPending = true; errorMessage = nil; statusMessage = nil
        retrievalStatus = "正在整理回答…"
        let service = answerService
        let configurationRevision = latestConfigurationRevision
        task = Task { [weak self] in
            do {
                try Task.checkCancellation()
                guard let self, self.version == token,
                      self.isCurrent(evidence,records:self.latestRecords,allowedKinds:self.latestAllowedKinds),
                      self.latestConfiguration == configuration else { return }
                if let engine {
                    let result = try await engine.generate(apiKey: apiKey, fallback: service)
                    try Task.checkCancellation()
                    guard self.version == token, self.isCurrent(result.prepared, records:self.latestRecords, allowedKinds:self.latestAllowedKinds),
                          let id = self.activeTurnID, let draft = self.savedTurns.first(where: { $0.id == id }) else { throw CancellationError() }
                    let completed = Answer(id: id, question: result.prepared.question, text: result.text, generated: true,
                        provider: String((configuration.mode == .local ? "Apple Intelligence" : configuration.label).prefix(300)),
                        evidence: result.prepared.evidence, sources: result.sources, scopeDescription: result.prepared.scopeDescription,
                        questionReferenceIDs: result.prepared.questionReferenceIDs, state: .completed, createdAt: draft.createdAt)
                    do { try await engine.publish(completed) }
                    catch is DaybookDatabase.Failure {
                        guard self.version == token else { return }
                        self.pendingRuntimePublication = (engine, completed, result.prepared)
                        self.storageError = "回答已生成，但尚未保存。请重试保存。"
                        self.isPending = false; self.task = nil; return
                    } catch is DaybookConversationFailure {
                        guard self.version == token else { return }
                        self.pendingRuntimePublication = (engine, completed, result.prepared)
                        self.storageError = "回答已生成，但尚未保存。请重试保存。"
                        self.isPending = false; self.task = nil; return
                    }
                    guard self.version == token else { return }
                    self.applyRuntimePublication(completed, evidence: result.prepared)
                } else {
                    let result = try await service.answer(evidence, configuration: configuration, apiKey: apiKey,
                        isCurrent: { [weak self] in
                            guard let self else { return false }
                            return self.version == token && self.latestConfiguration == configuration &&
                                self.latestConfigurationRevision == configurationRevision &&
                                self.isCurrent(evidence,records:self.latestRecords,allowedKinds:self.latestAllowedKinds)
                        })
                    try Task.checkCancellation()
                    guard self.version == token else { return }
                    guard self.isCurrent(evidence,records:self.latestRecords,allowedKinds:self.latestAllowedKinds),
                          self.latestConfiguration == configuration else { self.cancel(); return }
                    self.complete(evidence, text: result, generated: true,
                        provider: configuration.mode == .local ? "Apple Intelligence" : configuration.label)
                }
                self.isPending = false; self.task = nil
            } catch {
                await engine?.fail(error)
                guard let self, self.version == token else { return }
                self.isPending = false; self.task = nil
                if error is CancellationError {
                    self.statusMessage = "已取消本次回答。"
                    self.finishUnanswered(state: .cancelled, text: "本次回答已取消，可重新提问。")
                } else { self.fail(error) }
            }
        }
    }
}
