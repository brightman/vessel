import Combine
import Foundation

extension Notification.Name { static let daybookSemanticChanged = Notification.Name("DaybookSemanticChanged") }

enum DaybookSemanticResourceChange: Sendable {
    case refreshed, downloadCompleted, resetStarted, rebuilt, languageChanged, cleared
    @MainActor func publish() {
        // Resource readiness can change without source/date changes. Reject the older generation first.
        DaybookSemanticIndex.shared.invalidateResources()
        NotificationCenter.default.post(name: .daybookSemanticChanged, object: self)
    }
}

/// Presentation validity includes query, day, permissions, all current source revisions and index generation.
@MainActor final class DaybookSemanticSearchModel: ObservableObject {
    @Published private(set) var result: DaybookSemanticMatches?
    @Published private(set) var isSearching = false
    private var task: Task<Void, Never>?
    private var version = UUID()
    private var records: [DayRecord] = []
    private var allowed: Set<DayRecord.Kind> = []
    private var day: Date?
    private var query = ""
    private var needsRetrieval = true
    private var waitingAfterClear = false
    private var resetInProgress = false
    private var active = true
    private let index: DaybookSemanticIndex?
    private let search: any DaybookSemanticSearching
    private let debounce: Duration
    init(search: (any DaybookSemanticSearching)? = nil, debounce: Duration = .milliseconds(250)) {
        self.search = search ?? DaybookSemanticIndex.shared
        self.index = search == nil ? DaybookSemanticIndex.shared : nil
        self.debounce = debounce
    }
    func synchronize(query: String, records: [DayRecord], date: Date, allowedKinds: Set<DayRecord.Kind>,
                     active: Bool = true, resume: Bool = false) {
        let start = Calendar.current.startOfDay(for: date)
        let scopeChanged = self.records != records || allowed != allowedKinds || day != start
        let intentChanged = self.query != query || day != start
        if scopeChanged || intentChanged { cancel() }
        if (scopeChanged || intentChanged) && !resetInProgress { index?.invalidate(records: DayRecord.evidenceRecords(records,scope:Calendar.current.dateInterval(of:.day,for:date)!), allowedKinds: allowedKinds) }
        if intentChanged { waitingAfterClear = false }
        self.records = records; allowed = allowedKinds; day = start; self.query = query; self.active = active
        if resume { cancel(); waitingAfterClear = false }
        guard active else { cancel(); return }
        guard needsRetrieval, !waitingAfterClear, !resetInProgress, !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        needsRetrieval = false
        let end = Calendar.current.date(byAdding: .day, value: 1, to: start)!
        let token = version; isSearching = true
        let service = self.search, delay = debounce
        task = Task { [weak self] in
            do { try await Task.sleep(for: delay); try Task.checkCancellation() } catch { return }
            var previousFinished: Int?
            var previousPending: Int?
            while !Task.isCancelled {
                let result = await service.search(query: query, records: records, dayStart: start, dayEnd: end, allowedKinds: allowedKinds, limit: 20)
                guard let self, !Task.isCancelled, self.version == token else { return }
                guard self.active, (self.index?.isCurrent(result) ?? true),
                      result.evidence.isCurrent(records: self.records, allowedKinds: self.allowed) else {
                    self.isSearching = false; self.task = nil; self.needsRetrieval = true; return
                }
                self.result = result
                let progress = result.coverage
                let advanced = previousFinished == nil || progress?.finished != previousFinished || (progress?.pending ?? 0) < (previousPending ?? 0)
                guard progress?.canContinue == true, advanced else {
                    self.isSearching = false; self.task = nil; return
                }
                previousFinished = progress?.finished; previousPending = progress?.pending
                await Task.yield()
            }
        }
    }
    func validated(query: String, records: [DayRecord], date: Date, allowedKinds: Set<DayRecord.Kind>) -> DaybookSemanticMatches? {
        guard active, query == self.query, day == Calendar.current.startOfDay(for: date), let result, (index?.isCurrent(result) ?? true),
              result.evidence.isCurrent(records: records, allowedKinds: allowedKinds) else { return nil }
        return result
    }
    func resourcesChanged(_ change: DaybookSemanticResourceChange, active: Bool) {
        cancel()
        self.active = active
        if change == .resetStarted { resetInProgress = true; return }
        if change == .cleared || change == .rebuilt || change == .languageChanged { resetInProgress = false }
        waitingAfterClear = change == .cleared
        // A deliberate clear does not repopulate on incidental source/sheet synchronization.
        guard change != .cleared, let day else { return }
        synchronize(query: query, records: records, date: day, allowedKinds: allowed, active: active)
    }
    func cancel() {
        task?.cancel(); task = nil; version = UUID(); result = nil; isSearching = false; needsRetrieval = true
    }
}
