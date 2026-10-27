import AVFAudio
import Combine
import UIKit

/// Serializes local chunk publication and session closure independently from Watch receipts.
private final class PhoneNativeRecordingCommitter {
    private let queue=DispatchQueue(label:"WiseLife.PhoneRecordingChunks",qos:.utility)
    private let voiceNotesRoot:URL
    private var repository:RecordingSessionRepository?
    init(voiceNotesRoot:URL) { self.voiceNotesRoot=voiceNotesRoot }
    private func currentRepository() throws -> RecordingSessionRepository {
        if let repository { return repository }
        let db=try DaybookDatabase(url:DaybookDatabase.metadataURL(forRoot:voiceNotesRoot))
        let opened=try RecordingSessionRepository(root:voiceNotesRoot.appendingPathComponent("RecordingSessions",isDirectory:true),database:db)
        repository=opened; return opened
    }
    private func descriptor(_ chunk:PhoneRecordingChunkFile,draft:PhoneRecordingDraft) -> RecordingChunkDescriptor {
        RecordingChunkDescriptor(id:chunk.id,sessionID:draft.id,ordinal:chunk.ordinal,sessionStartedAt:draft.capturedAt,
            capturedAt:chunk.capturedAt,timeZoneIdentifier:draft.timeZoneIdentifier,sessionStartOffset:chunk.sessionStartOffset,
            frameCount:chunk.frameCount,sampleRate:chunk.sampleRate,byteCount:chunk.byteCount,sha256:chunk.sha256,
            origin:RecordingOrigin(device:"iPhone",deviceID:"",fileName:String(format:"chunk-%04d.m4a",chunk.ordinal),recordingTimeIsEstimated:false),location:chunk.location)
    }
    func store(_ chunk:PhoneRecordingChunkFile,from url:URL,draft:PhoneRecordingDraft) {
        queue.async {
            do {
                try self.currentRepository().storeLocalChunk(self.descriptor(chunk,draft:draft),from:url)
                NotificationCenter.default.post(name:RecordingChunkReceiver.didChange,object:nil,userInfo:["localSessionID":draft.id])
            } catch {
                // The source and its manifest remain in Application Support; final save retries it.
            }
        }
    }
    func finish(_ draft:PhoneRecordingDraft) throws {
        try queue.sync {
            let repo=try currentRepository(), existing=try repo.chunks(sessionID:draft.id)
            let parent=draft.fileURL.deletingLastPathComponent()
            for chunk in draft.chunks {
                let value=descriptor(chunk,draft:draft)
                if existing.first(where:{$0.id==value.id}) == value { continue }
                let url=parent.appendingPathComponent(String(format:"chunk-%04d.m4a",chunk.ordinal))
                try repo.storeLocalChunk(value,from:url)
            }
            try repo.applyEnd(.init(sessionID:draft.id,finalOrdinal:draft.chunks.last?.ordinal,endedAt:.now,interrupted:false,revision:0))
        }
        NotificationCenter.default.post(name:RecordingChunkReceiver.didChange,object:nil,userInfo:["localSessionID":draft.id])
    }
}

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
    let recorder: PhoneRecorder
    let recording: PhoneRecordingSession
    private let activities: RecordingActivityManager
    private var preparation: Task<Void, Never>?
    private var lifecycleObservation: AnyCancellable?
    private var foregroundObservation: AnyCancellable?

    private init() {
        let notes = NotesModel()
        let processing = AudioProcessingModel(settings:notes.settings)
        let draftStore=PhoneRecordingDraftStore()
        let voiceNotesRoot=FileManager.default.urls(for:.documentDirectory,in:.userDomainMask)[0].appendingPathComponent("VoiceNotes",isDirectory:true)
        let recorder = PhoneRecorder(draftStore:draftStore)
        let activities = RecordingActivityManager()
        self.notes = notes
        self.processing = processing
        self.content = ContentSegmentModel(processing:processing)
        self.recorder = recorder
        self.activities = activities
        let committer=PhoneNativeRecordingCommitter(voiceNotesRoot:voiceNotesRoot)
        recorder.onChunkSealed={ draft,chunk,url in committer.store(chunk,from:url,draft:draft) }
        recording = PhoneRecordingSession(engine: recorder, activity: activities,store:draftStore) { draft in
            if draft.isChunked && !draft.chunks.isEmpty {
                try committer.finish(draft)
                return
            }
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
