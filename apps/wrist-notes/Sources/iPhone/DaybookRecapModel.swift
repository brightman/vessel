import Combine
import Foundation

@MainActor final class DaybookRecapModel: ObservableObject {
    struct RemoteRequest: Identifiable {
        let id = UUID()
        let input: DaybookRecapInput
        let configuration: AIConfiguration
        let revision: Int
        let language: String
    }
    private struct Context: Equatable {
        let day: Date
        let recordFingerprint: String
        let revisions: [Int]
        let configuration: AIConfiguration
        let revision: Int
        let language: String
        var requiresConfirmation: Bool
        let allowedKinds: Set<DayRecord.Kind>
        let foreground: Bool
        let capturing: Bool
    }
    @Published private(set) var entries: [DaybookRecapEntry] = []
    @Published private(set) var isLoading = false
    @Published private(set) var isGenerating = false
    @Published private(set) var storageError: String?
    @Published private(set) var message: String?
    var scopeLoader: (@MainActor (DateInterval) async throws -> [DayRecord])?
    private let store: DaybookRecapStore
    private let service: any DaybookRecapGenerating
    private var context: Context?
    private var settings: AppSettings?
    private var inputs: [String: DaybookRecapInput] = [:]
    private var sourceRecords: [String: [UUID: DayRecord]] = [:]
    private var task: Task<Void, Never>?
    private var generationTask: Task<Void, Never>?
    private var epoch = UUID()
    private var generation = UUID()
    private var activeAttempt: DaybookRecapEntry?

    init(store: DaybookRecapStore = DaybookRecapStore(), service: (any DaybookRecapGenerating)? = nil) {
        self.store = store; self.service = service ?? DaybookRecapService()
    }
    var current: DaybookRecapEntry? { entries.first { $0.dayKey == dayKey } }
    var dayKey: String { context.map { DaybookRecapInput.key($0.day) } ?? "" }
    var input: DaybookRecapInput? { inputs[dayKey] }
    var isStale: Bool { current.map { entry in input.map { entry.relationship(to: $0) != .current } ?? true } ?? false }
    var canGenerate: Bool { storageError == nil && !isLoading && !isGenerating && context?.foreground == true && context?.capturing == false && input?.sources.isEmpty == false }
    func isStale(_ entry: DaybookRecapEntry) -> Bool { inputs[entry.dayKey].map { entry.relationship(to: $0) != .current } ?? true }
    func record(_ id: UUID) -> DayRecord? { sourceRecords[dayKey]?[id] }

    func synchronize(day: Date, records: [DayRecord], revisions: [Int], settings: AppSettings, allowedKinds: Set<DayRecord.Kind>, foreground: Bool, capturing: Bool) {
        self.settings = settings
        let recordFingerprint = DaybookRecapInput.digest(records.map(DaybookRecapInput.factDigest).sorted())
        let next = Context(day: Calendar.current.startOfDay(for: day), recordFingerprint: recordFingerprint, revisions: revisions,
            configuration: settings.ai, revision: settings.aiRevision, language: settings.interfaceLanguage.rawValue,
            requiresConfirmation: settings.requiresRemoteAIConfirmation, allowedKinds: allowedKinds, foreground: foreground, capturing: capturing)
        guard context != next else { return }
        context = next; reload()
    }
    func reload() {
        cancel(); task?.cancel(); epoch = UUID()
        entries = []; inputs = [:]; sourceRecords = [:]; message = nil; storageError = nil
        if let old = context, let settings {
            context = Context(day: old.day, recordFingerprint: old.recordFingerprint, revisions: old.revisions,
                configuration: settings.ai, revision: settings.aiRevision, language: settings.interfaceLanguage.rawValue,
                requiresConfirmation: settings.requiresRemoteAIConfirmation, allowedKinds: old.allowedKinds,
                foreground: old.foreground, capturing: old.capturing)
        }
        guard let context, context.foreground, scopeLoader != nil else { isLoading = false; return }
        let token = epoch; isLoading = true
        task = Task { [weak self] in
            guard let self else { return }
            do {
                let saved = try store.load()
                var validated: [DaybookRecapEntry] = [], prepared: [String: DaybookRecapInput] = [:], sourceMap: [String: [UUID: DayRecord]] = [:]
                // Full dated reads are required even for historical archive entries outside UI pagination.
                for var entry in saved {
                    // Interpret the saved civil date in today's calendar; travel must not silently
                    // delete the previous day's archive or validate against yesterday's time zone.
                    guard let date = DaybookRecapInput.date(for: entry.dayKey),
                          let scope = Calendar.current.dateInterval(of: .day, for: date) else { throw DaybookRecapFailure.storage }
                    let records = try await readRecords(scope)
                    try Task.checkCancellation(); guard epoch == token else { return }
                    let next = DaybookRecapInput.prepare(records: records, day: date, allowedKinds: context.allowedKinds)
                    if next.references.isEmpty {
                        // Keep a data-free day marker so an earlier generation does not run again
                        // automatically after records are deleted or permissions are revoked.
                        let marker = DaybookRecapEntry(input: next)
                        try store.save(marker); prepared[next.dayKey] = next; validated.append(marker); continue
                    }
                    if entry.relationship(to: next) == .invalid {
                        entry = DaybookRecapEntry(input: next); try store.save(entry)
                    }
                    prepared[next.dayKey] = next
                    for record in records { sourceMap[next.dayKey, default: [:]][record.id] = record }
                    validated.append(entry)
                }
                let key = DaybookRecapInput.key(context.day)
                if prepared[key] == nil {
                    let scope = Calendar.current.dateInterval(of: .day, for: context.day)!
                    let records = try await readRecords(scope)
                    try Task.checkCancellation(); guard epoch == token else { return }
                    prepared[key] = DaybookRecapInput.prepare(records: records, day: context.day, allowedKinds: context.allowedKinds)
                    for record in records { sourceMap[key, default: [:]][record.id] = record }
                }
                inputs = prepared; sourceRecords = sourceMap
                entries = validated.sorted { $0.dayKey > $1.dayKey }; isLoading = false; task = nil
                message = current?.message
                if let input, !input.sources.isEmpty, !context.capturing,
                   (!context.configuration.isRemote || !context.requiresConfirmation),
                   current == nil {
                    startGeneration(automatic: true)
                }
            } catch {
                guard epoch == token else { return }
                isLoading = false; task = nil
                if !(error is CancellationError) {
                    storageError = (error as? DaybookRecapFailure == .changed ? DaybookRecapFailure.changed : .storage).localizedDescription
                }
            }
        }
    }
    func remoteRequest() -> RemoteRequest? {
        guard canGenerate, let input, let context, context.configuration.isRemote else { return nil }
        return RemoteRequest(input: input, configuration: context.configuration, revision: context.revision, language: context.language)
    }
    func cancel() {
        generation = UUID(); generationTask?.cancel(); generationTask = nil; isGenerating = false
        if var entry = activeAttempt {
            entry.message = "生成已取消，可手动重试。"
            do { try store.save(entry); publish(entry) }
            catch { storageError = DaybookRecapFailure.storage.localizedDescription; entries = [] }
        }
        activeAttempt = nil
    }
    func generate(confirmation: RemoteRequest? = nil, rememberChoice: Bool = false) {
        startGeneration(confirmation: confirmation, rememberChoice: rememberChoice, automatic: false)
    }
    private func startGeneration(confirmation: RemoteRequest? = nil, rememberChoice: Bool = false, automatic: Bool) {
        guard canGenerate, let input, let context, let settings else { return }
        guard !automatic || !context.configuration.isRemote || !settings.requiresRemoteAIConfirmation else { return }
        let token = UUID(); generation = token; isGenerating = true; message = nil
        let capturedEpoch = epoch
        var initialAttempt = current ?? DaybookRecapEntry(input: input)
        initialAttempt.attemptKey = attemptKey(input, context: context)
        initialAttempt.message = "上次生成未完成，可手动重试。"
        do {
            // Persist before any suspension. A records/configuration update during generation
            // must see that this date has already had its automatic attempt.
            guard try store.beginAttempt(initialAttempt, automatic: automatic) else {
                isGenerating = false; generationTask = nil
                message = "该日期已自动尝试过，可手动生成或更新回顾。"
                return
            }
            activeAttempt = initialAttempt; publish(initialAttempt)
        } catch {
            isGenerating = false; generationTask = nil
            storageError = DaybookRecapFailure.storage.localizedDescription
            return
        }
        generationTask = Task { [weak self] in
            guard let self else { return }
            let attempt: DaybookRecapEntry? = initialAttempt
            do {
                let latest = try await readRecords(input.scope)
                try Task.checkCancellation()
                guard generation == token, epoch == capturedEpoch,
                      settings.ai == context.configuration, settings.aiRevision == context.revision,
                      settings.interfaceLanguage.rawValue == context.language,
                      DaybookRecapInput.prepare(records: latest, day: context.day, allowedKinds: context.allowedKinds).fingerprint == input.fingerprint else { throw DaybookRecapFailure.changed }
                if context.configuration.isRemote {
                    let confirmed = confirmation.map { $0.input.fingerprint == input.fingerprint && $0.configuration == context.configuration && $0.revision == context.revision && $0.language == context.language }
                    guard settings.authorizeRemoteAISend(confirmationIsCurrent: confirmed, rememberChoice: rememberChoice) else { throw DaybookRecapFailure.changed }
                }
                self.context?.requiresConfirmation = settings.requiresRemoteAIConfirmation
                let consentAtSend = settings.requiresRemoteAIConfirmation
                let current: @MainActor () -> Bool = { [weak self, weak settings] in
                    guard let self, let settings else { return false }
                    return self.generation == token && self.epoch == capturedEpoch && self.context?.foreground == true && self.context?.capturing == false
                        && settings.ai == context.configuration && settings.aiRevision == context.revision
                        && settings.interfaceLanguage.rawValue == context.language && settings.requiresRemoteAIConfirmation == consentAtSend
                }
                let apiKey = context.configuration.mode == .custom ? try settings.apiKey() : nil
                let text = try await service.generate(input, configuration: context.configuration, apiKey: apiKey, language: context.language, isCurrent: current)
                try Task.checkCancellation(); guard current() else { throw CancellationError() }
                let fresh = try await readRecords(input.scope)
                try Task.checkCancellation(); guard current(), DaybookRecapInput.prepare(records: fresh, day: context.day, allowedKinds: context.allowedKinds).fingerprint == input.fingerprint else { throw DaybookRecapFailure.changed }
                try DaybookRecapInput.validate(text, sourceNumbers: Set(input.sources.map(\.number)))
                var result = DaybookRecapEntry(input: input)
                result.text = text; result.generatedAt = .now; result.provider = context.configuration.label; result.language = context.language
                result.coverage = input.coverage; result.attemptKey = initialAttempt.attemptKey
                try store.save(result); publish(result); message = nil
            } catch {
                guard generation == token else { return }
                if let failure = error as? DaybookRecapFailure, case .changed = failure {
                    // A repository may change before its UI notification arrives. Revalidate the
                    // archive immediately instead of leaving old private claims visible.
                    activeAttempt = nil; generationTask = nil; isGenerating = false; reload(); return
                }
                if error is DaybookDatabase.Failure || error as? DaybookRecapFailure == .storage {
                    // Failed evidence reads cannot establish deletion or validate the earlier prose.
                    // Keep the durable archive for recovery, but hide it until a successful reread.
                    entries = []; inputs = [:]; sourceRecords = [:]
                    storageError = DaybookRecapFailure.storage.localizedDescription
                    activeAttempt = nil; generationTask = nil; isGenerating = false; return
                }
                if !(error is CancellationError) {
                    let safe = (error as? DaybookRecapFailure)?.localizedDescription ?? (error as? AIServiceError)?.localizedDescription ?? DaybookRecapFailure.generation.localizedDescription
                    message = safe
                    if var entry = attempt {
                        entry.message = safe
                        do { try store.save(entry); publish(entry) }
                        catch { storageError = DaybookRecapFailure.storage.localizedDescription; entries = [] }
                    } else if error is DaybookDatabase.Failure { storageError = DaybookRecapFailure.storage.localizedDescription; entries = [] }
                }
            }
            guard generation == token else { return }
            isGenerating = false; generationTask = nil; activeAttempt = nil
        }
    }
    private func attemptKey(_ input: DaybookRecapInput, context: Context) -> String {
        DaybookRecapInput.digest([input.fingerprint, DaybookRecapInput.digest(context.configuration), context.language, "daily-recap-v1"])
    }
    private func readRecords(_ scope: DateInterval) async throws -> [DayRecord] {
        guard let scopeLoader else { throw DaybookRecapFailure.storage }
        // Registration/segmentation may publish while a complete date is loading.
        // Retry only that stale read, never inference or an actual storage failure.
        for attempt in 0..<3 {
            try Task.checkCancellation()
            do { return try await scopeLoader(scope) }
            catch is CancellationError { throw CancellationError() }
            catch DaybookRecapFailure.changed {
                guard attempt < 2 else { throw DaybookRecapFailure.changed }
                await Task.yield()
            }
            catch { throw DaybookRecapFailure.storage }
        }
        throw DaybookRecapFailure.changed
    }
    private func publish(_ entry: DaybookRecapEntry) {
        entries.removeAll { $0.dayKey == entry.dayKey }; entries.append(entry); entries.sort { $0.dayKey > $1.dayKey }
    }
}
