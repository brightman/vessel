import Combine
import Foundation

/// Serial automatic work with per-request consent and stale-result checks.
@MainActor
final class RecordingTitleCoordinator {
    typealias Generator = (String, AIConfiguration, @escaping @MainActor () -> Bool) async throws -> String?
    struct Request: Identifiable {
        let id = UUID()
        let note: VoiceNote
        let configuration: AIConfiguration
        let configurationRevision: Int
        var text: String { CustomAISummarizer.recordingTitleExcerpts(note.transcript) }
    }
    private struct Attempt: Hashable {
        let id: UUID
        let transcriptRevision: UUID?
        let transcriptHash: Int
        let configurationRevision: Int
        let requiresConfirmation: Bool
    }
    private let settings: AppSettings
    private let notes: () -> [VoiceNote]
    private let save: (VoiceNote, String, RecordingTitleSource, Bool) -> Bool
    private let generator: Generator
    private let stateChanged: (UUID, Bool, String?) -> Void
    private var observation: AnyCancellable?
    private var worker: Task<Void, Never>?
    private var running = Set<UUID>()
    private var attempted = Set<Attempt>()

    init(settings: AppSettings, notes: @escaping () -> [VoiceNote],
         save: @escaping (VoiceNote, String, RecordingTitleSource, Bool) -> Bool,
         generate: @escaping Generator, stateChanged: @escaping (UUID, Bool, String?) -> Void = { _, _, _ in }) {
        self.settings = settings; self.notes = notes; self.save = save
        generator = generate; self.stateChanged = stateChanged
        observation = Publishers.CombineLatest(settings.$aiRevision, settings.$requiresRemoteAIConfirmation)
            .removeDuplicates { $0.0 == $1.0 && $0.1 == $1.1 }
            .dropFirst().sink { [weak self] _ in
                // Clear synchronously so a delayed observer cannot erase a new manual attempt.
                self?.attempted.removeAll()
                // Published emits before the new value is stored; scheduling work must wait.
                Task { @MainActor [weak self] in
                    self?.refresh()
                }
            }
    }

    func request(for id: UUID) -> Request? {
        guard !running.contains(id), let note = notes().first(where: { $0.id == id }),
              note.kind == .long, note.transcriptionState == .ready,
              !note.transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return Request(note: note, configuration: settings.ai, configurationRevision: settings.aiRevision)
    }

    func generate(_ id: UUID, confirmation: Request? = nil, doNotAskAgain: Bool = false) async {
        guard let current = request(for: id) else { return }
        let matches = confirmation.map { $0.note == current.note && $0.configuration == current.configuration &&
            $0.configurationRevision == current.configurationRevision }
        if matches == false {
            stateChanged(id, false, "模型或原文已变化，请重新确认本次发送的文字。")
            return
        }
        if current.configuration.isRemote {
            guard settings.authorizeRemoteAISend(confirmationIsCurrent: matches, rememberChoice: doNotAskAgain) else {
                stateChanged(id, false, "模型或原文已变化，请重新确认本次发送的文字。")
                return
            }
        }
        // This explicit attempt also consumes the automatic attempt for the same input and policy.
        // A failure remains retryable by tapping the action, without an immediate background duplicate.
        attempted.insert(attempt(for: current.note))
        await perform(current, manual: true, explicitlyConfirmed: confirmation != nil)
        refresh()
    }

    func refresh() {
        guard worker == nil, nextAutomaticNote() != nil else { return }
        worker = Task { [weak self] in
            guard let self else { return }
            defer { self.worker = nil }
            while !Task.isCancelled, let note = self.nextAutomaticNote() {
                self.attempted.insert(self.attempt(for: note))
                let request = Request(note: note, configuration: self.settings.ai, configurationRevision: self.settings.aiRevision)
                await self.perform(request, manual: false, explicitlyConfirmed: false)
            }
        }
    }

    private func attempt(for note: VoiceNote) -> Attempt {
        Attempt(id: note.id, transcriptRevision: note.transcriptRevision, transcriptHash: note.transcript.hashValue,
                configurationRevision: settings.aiRevision, requiresConfirmation: settings.requiresRemoteAIConfirmation)
    }

    private func nextAutomaticNote() -> VoiceNote? {
        guard !settings.ai.isRemote || !settings.requiresRemoteAIConfirmation else { return nil }
        return notes().first {
            $0.needsModelRecordingTitle && $0.diarizationState != .running && !running.contains($0.id) && !attempted.contains(attempt(for: $0))
        }
    }

    private func isCurrent(_ request: Request, manual: Bool, explicitlyConfirmed: Bool) -> Bool {
        guard request.configuration == settings.ai, request.configurationRevision == settings.aiRevision,
              let current = notes().first(where: { $0.id == request.note.id }), current.transcriptionState == .ready,
              current.transcriptRevision == request.note.transcriptRevision, current.transcript == request.note.transcript,
              current.title == request.note.title, current.titleManuallyEdited == request.note.titleManuallyEdited else { return false }
        if !manual && !current.needsModelRecordingTitle { return false }
        return !request.configuration.isRemote || explicitlyConfirmed || !settings.requiresRemoteAIConfirmation
    }

    private func perform(_ request: Request, manual: Bool, explicitlyConfirmed: Bool) async {
        let id = request.note.id
        guard !running.contains(id), isCurrent(request, manual: manual, explicitlyConfirmed: explicitlyConfirmed) else { return }
        running.insert(id); stateChanged(id, true, nil)
        var failure: String?
        defer { running.remove(id); stateChanged(id, false, failure) }
        let current: @MainActor () -> Bool = { [weak self] in
            self?.isCurrent(request, manual: manual, explicitlyConfirmed: explicitlyConfirmed) == true
        }
        do {
            let proposal = try await generator(request.note.transcript, request.configuration, current)
            guard !Task.isCancelled, current() else { return }
            if let title = proposal.flatMap(RecordingTitleText.normalized) {
                if !save(request.note, title, .model, manual) { failure = "标题未能保存，请稍后重试。" }
                return
            }
            failure = "AI 暂未生成有效标题，可稍后重试。"
        } catch {
            guard !(error is CancellationError), !Task.isCancelled, current() else { return }
            failure = "标题生成失败：\(error.localizedDescription)"
        }
        // A temporary excerpt remains eligible for a future model attempt, but never loops in this pass.
        if !manual, request.note.needsRecordingTitle, let fallback = RecordingTitleText.fallback(from: request.note.transcript) {
            if !save(request.note, fallback, .transcriptExcerpt, false) { failure = "标题未能保存，请稍后重试。" }
        }
    }
}
