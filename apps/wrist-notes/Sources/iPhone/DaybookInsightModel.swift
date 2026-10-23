import Combine
import Foundation
import CryptoKit

@MainActor final class DaybookInsightModel: ObservableObject {
    struct RemoteRequest: Identifiable {
        let id = UUID()
        let evidence: DaybookRetrieval.Prepared
        let configuration: AIConfiguration
        let revision: Int
        let language: String
        let requiresConfirmation: Bool
        let now: Date
        var content: String { DaybookInsightService.content(evidence, now: now) }
    }
    @Published private(set) var remoteConfirmation: RemoteRequest?
    private var settings: AppSettings?
    private var configuration: AIConfiguration { settings?.ai ?? AIConfiguration() }
    private var revision: Int { settings?.aiRevision ?? 0 }
    private var requiresConfirmation: Bool { settings?.requiresRemoteAIConfirmation ?? true }
    var providerLabel: String { result?.provider ?? configuration.label }
    var usesRemoteProvider: Bool { configuration.isRemote }

    @Published private(set) var result: DaybookDailyInsight?
    @Published private(set) var message: String?
    @Published private(set) var storageError: String?
    @Published private(set) var isPending = false
    @Published private(set) var isDismissed = false
    @Published private(set) var dateLabel = ""
    @Published private(set) var hasEnoughSources = false
    private let store: DaybookInsightStore
    private let service: any DaybookInsightGenerating
    private var key: DaybookInsightKey?
    private var foreground = false
    private var capturing = false
    private var task: Task<Void, Never>?
    private var generation = UUID()
    private var automaticPending = false
    private struct Context {
        let records: [DayRecord]
        let selectedDate: Date
        let preferences: DaybookPreferences
        let language: String
        let now: Date
        let configuration: AIConfiguration
        let revision: Int
        var requiresConfirmation: Bool
    }
    private var context: Context?

    init(store: DaybookInsightStore? = nil, service: (any DaybookInsightGenerating)? = nil) {
        self.store = store ?? DaybookInsightStore(); self.service = service ?? DaybookInsightService()
    }
    static func prepare(records: [DayRecord], selectedDate: Date, allowedKinds: Set<DayRecord.Kind>, now: Date) throws -> DaybookRetrieval.Prepared {
        // Generic retrieval happens before the synthesis instruction; its words must not filter records.
        try DaybookRetrieval().prepare(question: "回顾这一天", records: records, selectedDate: selectedDate,
                                       now: now, allowedKinds: allowedKinds, usableTextOnly: true)
    }
    func synchronize(records: [DayRecord], selectedDate: Date, preferences: DaybookPreferences,
                     language: String, foreground: Bool, capturing: Bool, now: Date = .now, settings: AppSettings? = nil) {
        self.settings = settings
        if let context, context.configuration != configuration || context.revision != revision ||
            context.requiresConfirmation != requiresConfirmation || context.language != language { cancel() }
        self.foreground = foreground; self.capturing = capturing
        context = Context(records: records, selectedDate: selectedDate, preferences: preferences, language: language, now: now,
                          configuration: configuration, revision: revision, requiresConfirmation: requiresConfirmation)
        // Scope changes invalidate running/visible content even while durable storage is blocked.
        guard updateGenerationContext() != nil, let nextKey = key else { return }
        if let error = store.storageError { clearGenerationInputs(); storageError = error; return }
        do { try store.pruneStale(records: records, allowedKinds: preferences.allowedKinds); storageError = nil }
        catch { clearGenerationInputs(); storageError = DaybookInsightStore.message(error); return }
        if !foreground || capturing || (automaticPending && (!preferences.proactiveEnabled || preferences.isQuiet(at: now))) { cancel() }
        if let saved = store.entry(nextKey) {
            isDismissed = saved.dismissed
            if let cached = saved.result, (try? cached.output.validate(sources: cached.sources)) != nil, !saved.dismissed { result = cached }
            else { result = nil }
            if !isPending { message = saved.message }
            return
        }
        guard !configuration.isRemote || !requiresConfirmation else { return }
        guard hasEnoughSources, !isPending, foreground, !capturing, preferences.proactiveEnabled,
              !preferences.isQuiet(at: now), Calendar.current.isDate(selectedDate, inSameDayAs: now),
              store.automaticAttempts(now: now) < preferences.dailySuggestionLimit else { return }
        generate(automatic: true, now: now)
    }
    func currentResult(records: [DayRecord], selectedDate: Date, allowedKinds: Set<DayRecord.Kind>, language: String) -> DaybookDailyInsight? {
        guard storageError == nil, let key, key.providerIdentity == providerIdentity, key.language == language, Calendar.current.isDate(key.evidence.dayStart, inSameDayAs: selectedDate),
              key.evidence.isCurrent(records: records, allowedKinds: allowedKinds) else { return nil }
        return result
    }
    func refresh(now: Date = .now) {
        guard foreground, !capturing, hasEnoughSources else { return }
        cancel()
        if configuration.isRemote && requiresConfirmation {
            guard storageError == nil, let prepared = updateGenerationContext(), hasEnoughSources else { return }
            remoteConfirmation = RemoteRequest(evidence: prepared, configuration: configuration, revision: revision,
                language: context!.language, requiresConfirmation: requiresConfirmation, now: now)
        } else { generate(automatic: false, now: now) }
    }
    func cancelConfirmation() { remoteConfirmation = nil }
    func confirm(_ request: RemoteRequest, rememberChoice: Bool) {
        let prepared = updateGenerationContext()
        let matches = remoteConfirmation?.id == request.id && foreground && !capturing && storageError == nil &&
            prepared?.evidence == request.evidence.evidence && hasEnoughSources &&
            configuration == request.configuration && revision == request.revision &&
            context?.language == request.language && settings?.interfaceLanguage.rawValue == request.language &&
            requiresConfirmation == request.requiresConfirmation
        guard let settings, settings.authorizeRemoteAISend(confirmationIsCurrent: matches, rememberChoice: rememberChoice) else {
            remoteConfirmation = nil; return
        }
        remoteConfirmation = nil
        context?.requiresConfirmation = requiresConfirmation
        generate(automatic: false, now: request.now, confirmed: request)
    }
    func cancel() {
        generation = UUID(); task?.cancel(); task = nil; isPending = false; remoteConfirmation = nil; automaticPending = false
    }
    func dismiss() {
        cancel(); guard let key else { return }
        do { try store.dismiss(key); result = nil; message = nil; isDismissed = true; storageError = nil }
        catch { storageError = DaybookInsightStore.message(error) }
    }
    func retryStorage() {
        cancel()
        clearGenerationInputs()
        do { try store.reload(); storageError = nil; resynchronize() }
        catch { storageError = DaybookInsightStore.message(error) }
    }
    func resetStorage() {
        cancel()
        clearGenerationInputs()
        do { try store.reset(); storageError = nil; message = nil; isDismissed = false; resynchronize() }
        catch { storageError = DaybookInsightStore.message(error) }
    }
    private func clearGenerationInputs() {
        cancel(); key = nil; result = nil
    }
    private func resynchronize() {
        guard let context else { hasEnoughSources = false; dateLabel = ""; return }
        synchronize(records: context.records, selectedDate: context.selectedDate, preferences: context.preferences,
                    language: context.language, foreground: foreground, capturing: capturing, now: context.now, settings: settings)
    }
    /// Rebuild from latest inputs independently of persistence, including current permission values.
    private func updateGenerationContext() -> DaybookRetrieval.Prepared? {
        guard let context, let next = try? Self.prepare(records: context.records, selectedDate: context.selectedDate,
                    allowedKinds: context.preferences.allowedKinds, now: context.now) else {
            clearGenerationInputs(); hasEnoughSources = false; dateLabel = ""; message = nil; isDismissed = false
            return nil
        }
        let nextKey = DaybookInsightKey(evidence: next.evidence, language: context.language, providerIdentity: providerIdentity)
        if key != nextKey { cancel(); result = nil; message = nil; isDismissed = false }
        key = nextKey; dateLabel = next.dateLabel
        hasEnoughSources = Set(next.sources.map(\.id)).count >= 2
        return next
    }
    private var providerIdentity: String? {
        guard configuration.isRemote else { return nil }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        // AIConfiguration contains no secret. Key revisions guard in-flight work separately.
        let data = try! encoder.encode(configuration)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    private func requestIsCurrent(_ request: RemoteRequest, consent: Bool, key: DaybookInsightKey, token: UUID) -> Bool {
        let current = updateGenerationContext()
        return generation == token && self.key == key && foreground && !capturing && hasEnoughSources &&
            current?.evidence == request.evidence.evidence && configuration == request.configuration && revision == request.revision &&
            context?.language == request.language && (settings == nil || settings?.interfaceLanguage.rawValue == request.language) &&
            (!request.configuration.isRemote || requiresConfirmation == consent) &&
            (!automaticPending || (context?.preferences.proactiveEnabled == true && context?.preferences.isQuiet(at: .now) == false))
    }
    private func generate(automatic: Bool, now: Date, confirmed: RemoteRequest? = nil) {
        guard storageError == nil, store.storageError == nil, foreground, !capturing,
              let prepared = updateGenerationContext(), let key, hasEnoughSources else { return }
        guard !configuration.isRemote || !requiresConfirmation || confirmed != nil else { return }
        let request = confirmed ?? RemoteRequest(evidence: prepared, configuration: configuration, revision: revision,
            language: key.language, requiresConfirmation: requiresConfirmation, now: now)
        guard request.evidence.evidence == prepared.evidence, request.configuration == configuration, request.revision == revision else { return }
        let consent = requiresConfirmation
        do { try store.recordAttempt(key, automatic: automatic, now: now); storageError = nil }
        catch { clearGenerationInputs(); storageError = DaybookInsightStore.message(error); return }
        automaticPending = automatic; isPending = true; result = nil; message = nil; isDismissed = false
        let token = UUID(); generation = token
        task = Task { [weak self, service] in
            let isCurrent: @MainActor () -> Bool = { [weak self] in
                self?.requestIsCurrent(request, consent: consent, key: key, token: token) == true
            }
            do {
                try Task.checkCancellation(); guard isCurrent() else { throw CancellationError() }
                // Read a custom key only after consent and the scheduled-task scope check.
                let apiKey = request.configuration.mode == .custom ? try self?.settings?.apiKey() : nil
                let output = try await service.generate(request.evidence, configuration: request.configuration, apiKey: apiKey,
                    language: request.language, now: request.now, isCurrent: isCurrent)
                try Task.checkCancellation(); guard isCurrent() else { throw CancellationError() }
                try output.validate(sources: request.evidence.sources)
                guard let self else { return }
                let result = DaybookDailyInsight(output: output, sources: request.evidence.sources, provider: request.configuration.label)
                try self.store.finish(key, result: result); self.result = result
                self.isPending = false; self.task = nil; self.automaticPending = false
            } catch {
                guard let self, self.generation == token, self.key == key else { return }
                if error is CancellationError || !isCurrent() { self.cancel(); return }
                self.isPending = false; self.task = nil; self.automaticPending = false
                if let error = self.store.storageError { self.clearGenerationInputs(); self.storageError = error; return }
                let message = (error as? AIServiceError)?.localizedDescription ?? (error as? DaybookInsightFailure ?? .generation).message
                do { try self.store.finish(key, message: message); self.message = message }
                catch { self.storageError = DaybookInsightStore.message(error) }
            }
        }
    }
}
