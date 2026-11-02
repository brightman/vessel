import Foundation
import Combine

@MainActor final class FlashCaptureModel: ObservableObject {
    @Published private(set) var assets: [FlashAsset] = []
    @Published private(set) var totals: [FlashCurrencyTotal] = []
    @Published private(set) var batches: [UUID: FlashBatch] = [:]
    @Published private(set) var processing = Set<UUID>()
    @Published var error: String?
    private var repository: FlashCaptureRepository?
    private weak var notes: NotesModel?
    private weak var actions: ActionStore?
    private var observation: AnyCancellable?
    private var draining = false
    private var retryAfterDrain = false

    func attach(notes: NotesModel, actions: ActionStore) {
        guard self.notes == nil else { return }
        self.notes = notes; self.actions = actions
        observation = notes.$notes.sink { [weak self] _ in
            Task { @MainActor in self?.resume() }
        }
        resume()
    }
    private func open() throws -> FlashCaptureRepository {
        if let repository { return repository }
        let opened = try FlashCaptureRepository(database: DaybookDatabase())
        // Seed only once from loaded durable notes. No old commands execute on upgrade.
        guard let notes, notes.storageIsAvailable else { throw ActionFailure.invalid("本机录音尚未加载。") }
        try opened.seedHistory(notes.notes.filter { $0.kind == .thought }.map(\.id))
        repository = opened
        return opened
    }
    func reload() {
        do {
            let repo = try open()
            assets = try repo.assets(); totals = try repo.totals()
            batches = Dictionary(uniqueKeysWithValues: try repo.batches().map { ($0.sourceID, $0) })
        } catch { self.error = error.localizedDescription }
    }
    func resume() {
        guard !draining else { retryAfterDrain = true; return }
        reload()
        guard repository != nil, let notes else { return }
        draining = true
        Task {
            defer { draining = false; if retryAfterDrain { retryAfterDrain = false; resume() } }
            for note in notes.notes where note.kind == .thought && note.transcriptionState == .ready && !note.transcript.isEmpty {
                let state = batches[note.id]?.state
                if state == nil, (try? repository?.isHistorical(note.capturedAt)) == true {
                    try? repository?.setBatch(.init(sourceID: note.id, state: .historical)); reload(); continue
                }
                if state == nil || state == .pending || state == .running { await process(note) }
            }
            await actions?.resumeFlashCommands()
        }
    }
    func process(_ opening: VoiceNote, confirmation: NotesModel.RemoteSummaryRequest? = nil, remember: Bool = false) async {
        guard let notes, opening.kind == .thought, !processing.contains(opening.id), batches[opening.id]?.state != .complete,
              let current = notes.note(opening.id), current.transcript == opening.transcript else { return }
        processing.insert(opening.id); defer { processing.remove(opening.id) }
        do {
            let repo = try open(), settings = notes.settings
            let old = try repo.batch(opening.id)
            let allowActions = try old.map { $0.state != .historical && $0.allowsAutomaticActions } ?? !repo.isHistorical(opening.capturedAt)
            let config = notes.summaryConfiguration(for: opening), revision = settings.aiRevision
            let confirmationIsCurrent = confirmation.map { $0.noteID == opening.id && $0.text == opening.transcript && $0.configuration == config && $0.revision == revision }
            if config.isRemote && !settings.authorizeRemoteAISend(confirmationIsCurrent: confirmationIsCurrent, rememberChoice: remember) {
                try repo.setBatch(.init(sourceID: opening.id, state: .awaitingConsent, message: "需确认发送全文到所选 AI 模型后整理。", allowsAutomaticActions: allowActions))
                reload(); return
            }
            try repo.setBatch(.init(sourceID: opening.id, state: .running, allowsAutomaticActions: allowActions)); reload()
            let zone = opening.origin?.timeZoneIdentifier
            let source = ActionSource(id: opening.id, title: opening.displayTitle, quote: opening.transcript, capturedAt: opening.capturedAt,
                timeZoneID: zone ?? TimeZone.current.identifier, recordingKind: "thought", timeZoneKnown: zone.flatMap(TimeZone.init(identifier:)) != nil, device: opening.origin?.device)
            let isCurrent: @MainActor () -> Bool = { [weak notes] in
                guard let notes, let latest = notes.note(opening.id) else { return false }
                return latest.transcript == opening.transcript && latest.kind == .thought && notes.summaryConfiguration(for: latest) == config
                    && (!config.isRemote || (notes.settings.aiRevision == revision && (confirmationIsCurrent == true || !notes.settings.requiresRemoteAIConfirmation)))
            }
            let extraction = try await FlashCaptureService().extract(source: source, settings: settings, configuration: config, isCurrent: isCurrent)
            guard isCurrent() else { throw CancellationError() }
            try repo.commit(extraction, source: source, allowsActions: allowActions)
            reload()
            NotificationCenter.default.post(name: ActionStore.itemsDidChange, object: nil)
            await actions?.resumeFlashCommands()
        } catch {
            self.error = error.localizedDescription
            if let repo = repository {
                let old = try? repo.batch(opening.id)
                try? repo.setBatch(.init(sourceID: opening.id, state: .failed, message: error.localizedDescription, allowsAutomaticActions: old?.allowsAutomaticActions ?? false))
                reload()
            }
        }
    }
    @discardableResult func save(_ asset: FlashAsset) -> Bool {
        do { _ = try open().save(asset); error = nil; reload(); return true }
        catch { self.error = error.localizedDescription; return false }
    }
    func toggle(_ asset: FlashAsset) { var value = asset; value.revoked.toggle(); _ = save(value) }
}
