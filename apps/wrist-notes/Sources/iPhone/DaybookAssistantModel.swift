import Combine
import Foundation

@MainActor
final class DaybookAssistantModel: ObservableObject {
    typealias Answer = DaybookConversationTurn

    struct RemoteConfirmation: Identifiable {
        let id = UUID()
        let question: String
        let context: String
        let sourceCount: Int
        let destination: String
        var instruction: String { CustomAISummarizer.answerInstruction }
        var message: String { CustomAISummarizer.answerContent(question: prepared.providerQuestion, context: context) }
        fileprivate let prepared: DaybookRetrieval.Prepared
        fileprivate let configuration: AIConfiguration
        fileprivate let configurationRevision: Int
    }

    @Published private(set) var turns: [Answer] = []
    @Published private(set) var answer: Answer?
    @Published private(set) var prepared: DaybookRetrieval.Prepared?
    @Published private(set) var preparedTurnID: UUID?
    @Published private(set) var remoteConfirmation: RemoteConfirmation?
    @Published private(set) var isPending = false
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
    private var continuationDay: Date?
    private var continuationDays: [Date: Date] = [:]
    private enum PendingMutation {
        case save(Answer, day: Date)
        case reset
    }
    private var pendingMutation: PendingMutation?
    private var revokedKinds: Set<DayRecord.Kind> = []
    private var privacyCleanupPending = false
    private let store: DaybookConversationStore
    private var task: Task<Void, Never>?
    private var version = UUID()
    private var latestRecords: [DayRecord] = []
    private var latestDate: Date?
    private var latestAllowedKinds: Set<DayRecord.Kind> = []
    private var latestConfiguration: AIConfiguration?
    private var latestConfigurationRevision: Int?
    private let answerService: any DaybookAnswering
    private let semanticSearch: (any DaybookSemanticSearching)?

    init(answerService: (any DaybookAnswering)? = nil, store: DaybookConversationStore = .local(), semanticSearch: (any DaybookSemanticSearching)? = nil) {
        #if os(iOS)
        self.semanticSearch = semanticSearch ?? DaybookSemanticIndex.shared
        #else
        self.semanticSearch = semanticSearch
        #endif
        self.answerService = answerService ?? DaybookAnswerService()
        self.store = store
        do {
            try store.interruptPending()
            let page = try store.loadPage()
            savedTurns = page.turns; historyCursor = page.cursor; hasMoreHistory = page.hasMore
        }
        catch { storageError = error.localizedDescription; needsStorageReset = true }
        // Wait for the caller's current permissions before publishing any persisted answer.
    }

    func synchronize(records: [DayRecord], selectedDate: Date, allowedKinds: Set<DayRecord.Kind>, configuration: AIConfiguration, configurationRevision: Int? = nil) {
        let dayChanged = latestDate.map { !Calendar.current.isDate($0, inSameDayAs: selectedDate) } ?? true
        let configurationChanged = latestConfiguration.map { $0 != configuration } ?? false
        let revisionChanged = configurationRevision.map { latestConfigurationRevision != nil && latestConfigurationRevision != $0 } ?? false
        let sourcesChanged = prepared.map { !$0.isCurrent(records: records, allowedKinds: allowedKinds) } ?? false
        let permissionsChanged = latestDate == nil || latestAllowedKinds != allowedKinds
        if latestDate != nil { revokedKinds.formUnion(latestAllowedKinds.subtracting(allowedKinds)) }
        latestRecords = records; latestDate = selectedDate; latestAllowedKinds = allowedKinds
        latestConfiguration = configuration
        if let configurationRevision { latestConfigurationRevision = configurationRevision }
        if dayChanged || configurationChanged || revisionChanged || sourcesChanged,
           case .save(let turn, let day) = pendingMutation, turn.completionState == .completed {
            pendingMutation = .save(turn.replacing(text: "回答条件已变化，可重新提问。", state: .cancelled), day: day)
        }
        if dayChanged || configurationChanged || revisionChanged || sourcesChanged || permissionsChanged {
            cancel()
            prepared = nil; preparedTurnID = nil; answer = nil; errorMessage = nil
            statusMessage = sourcesChanged ? "资料已更新，历史对话已保留。后续回答会重新核对当前资料。" : nil
        }
        if dayChanged { continuationDay = continuationDays[Calendar.current.startOfDay(for: selectedDate)] }
        if permissionsChanged && !needsStorageReset { privacyCleanupPending = true; cleanupPermissions() }
        publishTurns()
    }

    func ask(_ question: String, records: [DayRecord], selectedDate: Date, allowedKinds: Set<DayRecord.Kind>, settings: AppSettings) {
        synchronize(records: records, selectedDate: selectedDate, allowedKinds: allowedKinds, configuration: settings.ai, configurationRevision: settings.aiRevision)
        guard storageError == nil else { statusMessage = "请先重试保存或读取本机对话，再发送新问题。"; return }
        cancel(); prepared = nil; preparedTurnID = nil; answer = nil; errorMessage = nil; statusMessage = nil
        let question = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, question.count <= 300 else { errorMessage = question.isEmpty ? "请输入问题。" : "请把问题缩短到 300 字以内。"; return }
        let day = Calendar.current.startOfDay(for: selectedDate)
        let end = Calendar.current.date(byAdding: .day, value: 1, to: day)!
        let history = turns.filter { $0.completionState == .completed }
        let draft = Answer(id: UUID(), question: question, text: "", generated: false, provider: "",
            evidence: DaybookEvidenceSnapshot(records: records, dayStart: day, dayEnd: end, allowedKinds: allowedKinds),
            sources: [], scopeDescription: "", state: .pending, createdAt: .now)
        activeTurnID = draft.id; activeTurnDay = day
        pendingMutation = .save(draft, day: day)
        guard commitPendingMutation() else {
            pendingMutation = .save(draft.replacing(text: "问题尚未开始处理，请重试保存后重新提问。", state: .cancelled), day: day)
            activeTurnID = nil; activeTurnDay = nil
            return
        }
        do {
            var date = selectedDate
            if !DaybookRetrieval.hasExplicitDate(question) {
                date = try continuationDay ?? store.latestEvidenceDay(selectedDay: day, allowedKinds: allowedKinds) ?? selectedDate
            }
            // A newly explicit day starts a new evidence scope; old answers never supply facts for it.
            let initial = try DaybookRetrieval().prepare(question: question, records: records, selectedDate: date, allowedKinds: allowedKinds)
            let history = history.suffix(3).filter { Calendar.current.isDate($0.evidence.dayStart, inSameDayAs: initial.dayStart) }
            let evidence = history.isEmpty ? initial : try DaybookRetrieval().prepare(question: question, records: records,
                selectedDate: date, allowedKinds: allowedKinds, priorTurns: history)
            prepared = evidence
            preparedTurnID = draft.id
            continuationDay = evidence.dayStart
            continuationDays[day] = evidence.dayStart
            if let semanticSearch, evidence.statistics.totalCount > 0,
               !DaybookRetrieval.isAggregateQuestion(question), !evidence.context.isEmpty {
                let token = UUID(); version = token; isPending = true
                let configuration = settings.ai, configurationRevision = settings.aiRevision
                task = Task { [weak self] in
                    let matches = await semanticSearch.search(query: question, records: records, dayStart: evidence.dayStart,
                        dayEnd: evidence.dayEnd, allowedKinds: allowedKinds, limit: 20)
                    guard let self, !Task.isCancelled, self.version == token,
                          self.latestConfiguration == configuration, self.latestConfigurationRevision == configurationRevision,
                          evidence.isCurrent(records: self.latestRecords, allowedKinds: self.latestAllowedKinds) else { return }
                    self.isPending = false; self.task = nil
                    do {
                        let enriched = try DaybookRetrieval().prepare(question: question, records: self.latestRecords,
                            selectedDate: date, allowedKinds: self.latestAllowedKinds, priorTurns: Array(history), semantic: matches)
                        self.present(enriched, configuration: configuration, revision: configurationRevision, settings: settings)
                    } catch { self.fail(error) }
                }
            } else { present(evidence, configuration: settings.ai, revision: settings.aiRevision, settings: settings) }
        } catch { fail(error) }
    }

    private func present(_ evidence: DaybookRetrieval.Prepared, configuration: AIConfiguration, revision: Int, settings: AppSettings) {
        prepared = evidence
        if let direct = evidence.directResponse {
            complete(evidence, text: direct, generated: false, provider: "本地检索与统计")
        } else if configuration.isRemote {
            let endpoint = URLComponents(string: configuration.baseURL)
            let destination = configuration.mode == .chatgpt ? "ChatGPT · \(configuration.chatGPTModel) · OpenAI" : "\(configuration.apiProtocol.rawValue) · \(configuration.model) · \(endpoint?.scheme ?? "https")://\(endpoint?.host ?? "已配置的模型服务")\(endpoint?.port.map { ":\($0)" } ?? "")\(endpoint?.path ?? "")/\(configuration.apiProtocol.endpointPath)"
            let confirmation = RemoteConfirmation(question: evidence.question, context: evidence.context,
                sourceCount: evidence.sources.count, destination: destination, prepared: evidence, configuration: configuration, configurationRevision: revision)
            if settings.requiresRemoteAIConfirmation { remoteConfirmation = confirmation }
            else { sendRemote(confirmation, settings: settings, confirmed: false) }
        } else { start(evidence, configuration: configuration, apiKey: nil) }
    }

    func confirmRemote(records: [DayRecord], selectedDate: Date, allowedKinds: Set<DayRecord.Kind>, settings: AppSettings, doNotAskAgain: Bool = false) {
        guard let confirmation = remoteConfirmation else { return }
        synchronize(records: records, selectedDate: selectedDate, allowedKinds: allowedKinds, configuration: settings.ai, configurationRevision: settings.aiRevision)
        guard remoteConfirmation?.id == confirmation.id, confirmation.configuration == settings.ai, confirmation.configurationRevision == settings.aiRevision,
              confirmation.prepared.isCurrent(records: records, allowedKinds: allowedKinds) else { return }
        remoteConfirmation = nil
        sendRemote(confirmation, settings: settings, confirmed: true, doNotAskAgain: doNotAskAgain)
    }

    private func sendRemote(_ confirmation: RemoteConfirmation, settings: AppSettings, confirmed: Bool, doNotAskAgain: Bool = false) {
        guard confirmation.configuration == settings.ai, confirmation.configurationRevision == settings.aiRevision,
              confirmation.prepared.isCurrent(records: latestRecords, allowedKinds: latestAllowedKinds) else { cancel(); return }
        do {
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

    func cancel() {
        let hadPending = isPending || remoteConfirmation != nil
        task?.cancel(); task = nil; version = UUID()
        isPending = false; remoteConfirmation = nil
        finishUnanswered(state: .cancelled, text: "本次回答已取消，可重新提问。")
        if hadPending { statusMessage = "已取消本次回答。" }
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
                if turn.completionState == .completed && !turn.evidence.isCurrent(records: latestRecords, allowedKinds: latestAllowedKinds) {
                    turn = turn.replacing(text: "资料已变化，本次回答未保存，可重新提问。", state: .cancelled)
                }
                try store.saveTurn(turn, day: day)
                if let index = savedTurns.firstIndex(where: { $0.id == turn.id }) { savedTurns[index] = turn }
                else { savedTurns.append(turn) }
                answer = turn.completionState == .completed ? turn : nil
            case .reset:
                try store.reset()
                savedTurns = []; historyCursor = nil; hasMoreHistory = false
                continuationDay = nil; continuationDays = [:]
                needsStorageReset = false; historyReadFailed = false; privacyCleanupPending = false
                answer = nil
            }
            pendingMutation = nil
            if !privacyCleanupPending && !historyReadFailed { storageError = nil }
            publishTurns()
            return true
        } catch { storageError = error.localizedDescription; publishTurns(); return false }
    }

    private func finishUnanswered(state: Answer.State, text: String) {
        guard let id = activeTurnID, let day = activeTurnDay,
              let turn = savedTurns.first(where: { $0.id == id }), turn.completionState == .pending else { return }
        activeTurnID = nil; activeTurnDay = nil
        pendingMutation = .save(turn.replacing(text: String(text.prefix(8_000)), state: state), day: day)
        commitPendingMutation()
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

    private func start(_ evidence: DaybookRetrieval.Prepared, configuration: AIConfiguration, apiKey: String?) {
        task?.cancel()
        let token = UUID(); version = token
        isPending = true; errorMessage = nil; statusMessage = nil
        let service = answerService
        let configurationRevision = latestConfigurationRevision
        task = Task { [weak self] in
            do {
                try Task.checkCancellation()
                guard let self, self.version == token,
                      evidence.isCurrent(records: self.latestRecords, allowedKinds: self.latestAllowedKinds),
                      self.latestConfiguration == configuration else { return }
                let result = try await service.answer(evidence, configuration: configuration, apiKey: apiKey,
                    isCurrent: { [weak self] in
                        guard let self else { return false }
                        return self.version == token && self.latestConfiguration == configuration &&
                            self.latestConfigurationRevision == configurationRevision &&
                            evidence.isCurrent(records: self.latestRecords, allowedKinds: self.latestAllowedKinds)
                    })
                try Task.checkCancellation()
                guard self.version == token else { return }
                guard evidence.isCurrent(records: self.latestRecords, allowedKinds: self.latestAllowedKinds),
                      self.latestConfiguration == configuration else { self.cancel(); return }
                self.complete(evidence, text: result, generated: true,
                    provider: configuration.mode == .local ? "Apple 本地模型" : configuration.label)
                self.isPending = false; self.task = nil
            } catch {
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
