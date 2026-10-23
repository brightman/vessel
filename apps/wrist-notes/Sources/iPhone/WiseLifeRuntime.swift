import AVFAudio
import Combine
import UIKit

/// UI and system intents share one recorder and one repository in the app process.
@MainActor
final class WiseLifeRuntime {
    static let shared = WiseLifeRuntime()

    enum Command: Equatable { case start, toggle, stop, retry }
    enum Outcome { case recording, saved, unchanged }

    let life = LifeSourceModel()
    let sessions = RecordingSessionModel()
    let notes: NotesModel
    let content: ContentSegmentModel
    let processing: AudioProcessingModel
    let desktopSync: PhoneDesktopSyncModel
    let recorder: PhoneRecorder
    let recording: PhoneRecordingSession
    private let activities: RecordingActivityManager
    private var preparation: Task<Void, Never>?
    private var lifecycleObservation: AnyCancellable?
    private var foregroundObservation: AnyCancellable?

    private init() {
        let notes = NotesModel()
        let processing = AudioProcessingModel(settings:notes.settings)
        let recorder = PhoneRecorder()
        let activities = RecordingActivityManager()
        self.notes = notes
        self.processing = processing
        self.desktopSync = PhoneDesktopSyncModel(notes: notes)
        self.content = ContentSegmentModel(processing:processing)
        self.recorder = recorder
        self.activities = activities
        recording = PhoneRecordingSession(engine: recorder, activity: activities) { draft in
            guard notes.savePhoneRecording(id: draft.id, fileURL: draft.fileURL,
                                           capturedAt: draft.capturedAt, duration: draft.duration, location: draft.location) else {
                throw NSError(domain: "WiseLife.Recording.Save", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: notes.errorMessage ?? "录音保存未完成，请重试。"])
            }
        }
        notes.durableTranscription = { [weak processing] note,automatic in
            await processing?.route(note,automatic:automatic) ?? false
        }
        notes.durableAudioDeleted = { [weak processing] id in processing?.delete(.init(kind:.legacyNote,id:id)) }
        processing.onLegacyTranscript = { [weak notes] id,output,revision in
            notes?.applyDurableTranscription(id,output:output,expectedRevision:revision) ?? false
        }
        foregroundObservation = NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in Task { @MainActor [weak self] in self?.foreground() } }
        lifecycleObservation = NotificationCenter.default.publisher(for: UIApplication.protectedDataDidBecomeAvailableNotification)
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in await self?.recoverAfterUnlock() }
            }
    }

    /// A single startup task prevents stale-activity cleanup from ending a new capture.
    func prepare() async {
        if preparation == nil {
            preparation = Task {
                await activities.endObsoleteActivities()
                sessions.refresh(recover: true)
                try? await recording.recoverPendingRecordings()
                processing.refresh()
                content.refresh()
            }
        }
        await preparation?.value
    }

    private func recoverAfterUnlock() async {
        life.recoverAfterUnlock()
        processing.foreground()
        await prepare()
        notes.refreshWatchStatus()
        sessions.refresh(recover: true)
        try? await recording.recoverPendingRecordings()
    }

    func foreground() {
        processing.foreground()
        notes.refreshWatchStatus()
        sessions.refresh(recover: true)
    }

    @discardableResult
    func perform(_ command: Command, requireLiveActivity: Bool = true,
                 expectedSessionID: UUID? = nil) async throws -> Outcome {
        await prepare()
        try Task.checkCancellation()
        let priorSaved = recording.lastSaved?.id
        let wasRecording = recorder.isRecording
        if !wasRecording && (command == .start || command == .toggle) { await processing.suspendForCapture() }
        defer { processing.resumeAfterCapture() }
        switch command {
        case .start: try await recording.start(requireLiveActivity: requireLiveActivity)
        case .toggle: try await recording.toggle()
        case .stop: try await recording.stopAndSave(expectedSessionID: expectedSessionID)
        case .retry:
            notes.refreshWatchStatus()
            try await recording.retrySave()
        }
        if recorder.isRecording {
            if !wasRecording { UINotificationFeedbackGenerator().notificationOccurred(.success) }
            return .recording
        }
        if let saved = recording.lastSaved, saved.id != priorSaved {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            return .saved
        }
        return .unchanged
    }
}
