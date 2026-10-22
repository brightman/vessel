import Combine
import Foundation

@MainActor final class DaybookInsightModel: ObservableObject {
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
                     language: String, foreground: Bool, capturing: Bool, now: Date = .now) {
        self.foreground = foreground; self.capturing = capturing
        context = Context(records: records, selectedDate: selectedDate, preferences: preferences, language: language, now: now)
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
        guard hasEnoughSources, !isPending, foreground, !capturing, preferences.proactiveEnabled,
              !preferences.isQuiet(at: now), Calendar.current.isDate(selectedDate, inSameDayAs: now),
              store.automaticAttempts(now: now) < preferences.dailySuggestionLimit else { return }
        generate(automatic: true, now: now)
    }
    func currentResult(records: [DayRecord], selectedDate: Date, allowedKinds: Set<DayRecord.Kind>, language: String) -> DaybookDailyInsight? {
        guard storageError == nil, let key, key.language == language, Calendar.current.isDate(key.evidence.dayStart, inSameDayAs: selectedDate),
              key.evidence.isCurrent(records: records, allowedKinds: allowedKinds) else { return nil }
        return result
    }
    func refresh(now: Date = .now) {
        guard foreground, !capturing, hasEnoughSources else { return }
        cancel(); generate(automatic: false, now: now)
    }
    func cancel() {
        generation = UUID(); task?.cancel(); task = nil; isPending = false
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
                    language: context.language, foreground: foreground, capturing: capturing, now: context.now)
    }
    /// Rebuild from latest inputs independently of persistence, including current permission values.
    private func updateGenerationContext() -> DaybookRetrieval.Prepared? {
        guard let context, let next = try? Self.prepare(records: context.records, selectedDate: context.selectedDate,
                    allowedKinds: context.preferences.allowedKinds, now: context.now) else {
            clearGenerationInputs(); hasEnoughSources = false; dateLabel = ""; message = nil; isDismissed = false
            return nil
        }
        let nextKey = DaybookInsightKey(evidence: next.evidence, language: context.language)
        if key != nextKey { cancel(); result = nil; message = nil; isDismissed = false }
        key = nextKey; dateLabel = next.dateLabel
        hasEnoughSources = Set(next.sources.map(\.id)).count >= 2
        return next
    }
    private func generate(automatic: Bool, now: Date) {
        guard storageError == nil, store.storageError == nil, foreground, !capturing,
              let prepared = updateGenerationContext(), let key, hasEnoughSources else { return }
        do { try store.recordAttempt(key, automatic: automatic, now: now); storageError = nil }
        catch { clearGenerationInputs(); storageError = DaybookInsightStore.message(error); return }
        automaticPending = automatic; isPending = true; result = nil; message = nil; isDismissed = false
        let token = UUID(); generation = token
        task = Task { [weak self, service] in
            do {
                try Task.checkCancellation()
                guard let current = self?.updateGenerationContext(), current.evidence == prepared.evidence,
                      self?.generation == token, self?.key == key else { throw CancellationError() }
                let output = try await service.generate(prepared, language: key.language, now: now)
                try Task.checkCancellation(); try output.validate(sources: prepared.sources)
                guard let self, self.generation == token, self.key == key else { return }
                let result = DaybookDailyInsight(output: output, sources: prepared.sources)
                try self.store.finish(key, result: result); self.result = result
                self.isPending = false; self.task = nil
            } catch {
                guard let self, self.generation == token, self.key == key else { return }
                self.isPending = false; self.task = nil
                if error is CancellationError { return }
                if let error = self.store.storageError { self.clearGenerationInputs(); self.storageError = error; return }
                let message = (error as? DaybookInsightFailure ?? .generation).message
                do { try self.store.finish(key, message: message); self.message = message }
                catch { self.storageError = DaybookInsightStore.message(error) }
            }
        }
    }
}
