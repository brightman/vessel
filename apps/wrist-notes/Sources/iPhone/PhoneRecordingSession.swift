import Combine
import Foundation

@MainActor protocol RecordingActivityManaging: AnyObject {
    var onDismiss: ((UUID) -> Void)? { get set }
    func start(sessionID: UUID, startedAt: Date) async throws
    func finish(sessionID: UUID, saved: Bool) async
}
@MainActor protocol PhoneRecordingEngine: AnyObject {
    var onRecordingEnded: (() -> Void)? { get set }
    var onDraftUpdated: ((PhoneRecordingDraft) -> Void)? { get set }
    var recordingWarning: String? { get }
    func startRecording(_ draft: PhoneRecordingDraft) async throws
    func stopRecording() -> PhoneRecordingDraft?
    func discardRecording()
    func recordingWasSaved()
    func recoveredDuration(at url: URL) -> TimeInterval
    func recoveredDuration(for draft: PhoneRecordingDraft) -> TimeInterval
    func recoverDraft(_ draft: PhoneRecordingDraft) throws -> PhoneRecordingDraft
}

extension PhoneRecordingEngine {
    var recordingWarning: String? { nil }
    var onDraftUpdated: ((PhoneRecordingDraft) -> Void)? { get { nil } set {} }
    func recoveredDuration(for draft: PhoneRecordingDraft) -> TimeInterval { max(draft.duration, recoveredDuration(at: draft.fileURL)) }
    func recoverDraft(_ draft: PhoneRecordingDraft) throws -> PhoneRecordingDraft {
        PhoneRecordingDraft(id:draft.id,fileURL:draft.fileURL,duration:recoveredDuration(for:draft),capturedAt:draft.capturedAt,
            location:draft.location,chunks:draft.chunks,activeChunkOrdinal:draft.activeChunkOrdinal,isChunked:draft.isChunked,
            timeZoneIdentifier:draft.timeZoneIdentifier)
    }
}

@MainActor final class PhoneRecordingSession: ObservableObject {
    enum Phase: Equatable { case idle, starting, recording, saving, failed }
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var lastSaved: PhoneRecordingDraft?
    @Published private(set) var errorMessage: String?
    private let engine: PhoneRecordingEngine
    private let activity: RecordingActivityManaging
    private let store: PhoneRecordingDraftStore
    private let save: (PhoneRecordingDraft) throws -> Void
    var currentSessionID: UUID? { current?.id }
    var pendingDraft: PhoneRecordingDraft? { current }
    func clearError() { errorMessage = nil }
    private var pendingWarning: String?
    private var current: PhoneRecordingDraft?
    private var tail: Task<Void, Never>?

    init(engine: PhoneRecordingEngine, activity: RecordingActivityManaging,
         store: PhoneRecordingDraftStore = PhoneRecordingDraftStore(), save: @escaping (PhoneRecordingDraft) throws -> Void) {
        self.engine = engine; self.activity = activity; self.store = store; self.save = save
        engine.onDraftUpdated = { [weak self] draft in
            guard let self, self.current?.id == draft.id,
                  self.phase == .starting || self.phase == .recording else { return }
            self.current = draft
            // Metadata failure must never interrupt an otherwise valid recording.
            try? self.store.persist(draft)
        }
        engine.onRecordingEnded = { [weak self] in
            guard let self, let id = self.current?.id else { return }
            self.pendingWarning = self.engine.recordingWarning
            Task { try? await self.stopAndSave(expectedSessionID: id) }
        }
        activity.onDismiss = { [weak self] id in Task { try? await self?.stopAndSave(expectedSessionID: id) } }
        do {
            if let draft = try store.load().first {
                current = try engine.recoverDraft(draft)
                phase = .failed; errorMessage = "发现未保存的录音，请重试保存或丢弃。"
            }
            if let warning = store.recoveryWarning { errorMessage = warning }
        } catch { phase = .failed; errorMessage = error.localizedDescription }
    }
    func recoverPendingRecordings() async throws { try await serialized { try await self.recoverFromStore() } }
    private func recoverFromStore() async throws {
        guard self.phase != .recording else { return }
        let drafts = try self.store.load()
        if drafts.isEmpty && self.current == nil { self.phase = .idle; self.errorMessage = self.store.recoveryWarning }
        for draft in drafts {
            self.current = try self.engine.recoverDraft(draft)
            self.phase = .failed
            // An empty manifest means the process stopped before any samples were captured.
            if self.current!.duration <= 0.2 && !FileManager.default.fileExists(atPath: draft.fileURL.path) {
                try self.store.remove(draft); self.current = nil; self.phase = .idle
                await self.activity.finish(sessionID: draft.id, saved: false)
            } else { try await self.finish(expected: draft.id) }
        }
        if let warning = self.store.recoveryWarning { self.errorMessage = warning }
    }
    func start(requireLiveActivity: Bool) async throws { try await serialized { try await self.begin(requireLiveActivity: requireLiveActivity) } }
    func toggle() async throws {
        try await serialized {
            if self.phase == .recording { try await self.finish(expected: nil) }
            else { try await self.begin(requireLiveActivity: true) }
        }
    }
    func stopAndSave(expectedSessionID: UUID? = nil) async throws { try await serialized { try await self.finish(expected: expectedSessionID) } }
    func retrySave() async throws {
        try await serialized {
            if self.current == nil && self.phase == .failed { try await self.recoverFromStore() }
            else { try await self.finish(expected: nil) }
        }
    }
    func discard() async {
        try? await serialized {
            self.engine.discardRecording()
            if let d = self.current { try self.store.remove(d); await self.activity.finish(sessionID: d.id, saved: false) }
            self.current = nil; self.phase = .idle; self.errorMessage = nil
        }
    }
    private func serialized(_ operation: @escaping @MainActor () async throws -> Void) async throws {
        let previous = tail
        let work = Task { @MainActor in
            await previous?.value
            try Task.checkCancellation()
            try await operation()
        }
        tail = Task { _ = try? await work.value }
        try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
    }
    private func begin(requireLiveActivity: Bool) async throws {
        if phase == .recording { return }
        guard phase == .idle else { throw failure("请先保存或丢弃上一段录音。") }
        phase = .starting; errorMessage = nil; lastSaved = nil; pendingWarning = nil
        var prepared: PhoneRecordingDraft?
        do {
            let d = try store.prepare(id: UUID(), at: .now); prepared = d; current = d
            if requireLiveActivity { try await activity.start(sessionID: d.id, startedAt: d.capturedAt) }
            else { try? await activity.start(sessionID: d.id, startedAt: d.capturedAt) }
            try Task.checkCancellation()
            try await engine.startRecording(d)
            try Task.checkCancellation()
            phase = .recording
        } catch {
            // A cancelled start may already have captured audio. Preserve it through the same save path.
            if let captured = engine.stopRecording(), captured.duration > 0.2 {
                current = captured; phase = .failed
                try? store.persist(captured)
                try? await finish(expected: nil)
            } else {
                engine.discardRecording()
                if let d = prepared { try? store.remove(d); await activity.finish(sessionID: d.id, saved: false) }
                current = nil; phase = .idle
            }
            errorMessage = error.localizedDescription; throw error
        }
    }
    private func finish(expected: UUID?) async throws {
        guard let original = current else { return }
        guard expected == nil || expected == original.id else { return }
        if phase == .recording {
            guard let captured = engine.stopRecording() else {
                try? store.remove(original); current = nil; phase = .idle
                await activity.finish(sessionID: original.id, saved: false)
                throw failure("录音太短或未生成音频，请重试。")
            }
            current = captured
        }
        if let draft = current, phase == .failed {
            current = try engine.recoverDraft(draft)
        }
        guard let draft = current, draft.duration > 0.2 else {
            phase = .failed
            await activity.finish(sessionID: original.id, saved: false)
            throw failure("录音太短或音频尚不可用，请重试或丢弃。")
        }
        phase = .saving
        do {
            try store.persist(draft)
            try save(draft)
            // Import is idempotent by UUID. A crash before cleanup retries this same note.
            try store.remove(draft)
            engine.recordingWasSaved(); lastSaved = draft; current = nil; phase = .idle; errorMessage = pendingWarning
            await activity.finish(sessionID: draft.id, saved: true)
        } catch {
            phase = .failed; errorMessage = "录音保存未完成：\(error.localizedDescription)"
            await activity.finish(sessionID: draft.id, saved: false)
            throw error
        }
    }
    private func failure(_ message: String) -> NSError { errorMessage = message; return NSError(domain: "WiseLife.Recording", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
}
