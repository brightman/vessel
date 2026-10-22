import Combine
import AVFAudio
import Foundation
import UIKit

@MainActor
final class NotesModel: ObservableObject {
    @Published private(set) var notes: [VoiceNote] = []
    @Published var errorMessage: String?
    @Published private(set) var watchStatus = PhoneWatchStatus()
    @Published private(set) var watchRetryError: String?
    @Published private(set) var summaryModels: [UUID: String] = [:]
    @Published private(set) var generatingTitleIDs = Set<UUID>()
    @Published private(set) var titleErrors: [UUID: String] = [:]
    let settings: AppSettings
    let voiceProfile: MyVoiceProfileModel
    /// Installed by WiseLifeRuntime synchronously before startup recovery Tasks run.
    var durableTranscription: ((VoiceNote, Bool) async -> Bool)?
    var durableAudioDeleted: ((UUID) -> Void)?

    private var repository: NoteRepository?
    private var connectivity: PhoneConnectivity?
    private let openRepository: () throws -> NoteRepository
    private let openConnectivity: (() throws -> PhoneConnectivity)?
    private var lifecycleObservation: AnyCancellable?
    private var queuedRecovery: Set<UUID> = []
    private var storageOpenError: String?
    private var activeTranscriptions: Set<UUID> = []
    private var persistenceFailures: [UUID: String] = [:]
    private let transcribeAudio: (URL, TranscriptionConfiguration) async throws -> TranscriptionOutput
    private let diarizeAudio: (URL, [TranscriptSegment], VoiceProfile?) async throws -> VoiceDiarizationOutput
    private let summarizeOnDevice: (String, RecordingKind) async throws -> String
    private let generateRecordingTitle: (String) async -> String?
    typealias RemoteTitleRequest = RecordingTitleCoordinator.Request
    private lazy var titleCoordinator = RecordingTitleCoordinator(settings: settings, notes: { [weak self] in
        guard let self else { return [] }
        return (self.repository?.notes ?? []).filter { !self.activeTranscriptions.contains($0.id) }
    }, save: { [weak self] opening, content, source, manual in
        guard let self else { return false }
        return self.edit(opening.id) { note in
            _ = note.applyGeneratedRecordingTitle(content, source: source, expectedRevision: opening.transcriptRevision,
                expectedTitle: opening.title, replacingExisting: manual)
        }
    }, generate: { [weak self] transcript, configuration, isCurrent in
        guard let self, isCurrent() else { throw CancellationError() }
        switch configuration.mode {
        case .local: return await self.generateRecordingTitle(transcript)
        case .custom:
            return try await CustomAISummarizer().recordingTitle(transcript, configuration: configuration,
                apiKey: self.settings.apiKey(), isCurrent: isCurrent)
        case .chatgpt:
            return try await self.settings.chatGPT.complete(instruction: CustomAISummarizer.recordingTitleInstruction,
                content: CustomAISummarizer.recordingTitleExcerpts(transcript), modelID: configuration.chatGPTModel,
                accountID: configuration.chatGPTAccountID, isCurrent: isCurrent)
        }
    }, stateChanged: { [weak self] id, running, error in
        if running { self?.generatingTitleIDs.insert(id) } else { self?.generatingTitleIDs.remove(id) }
        self?.titleErrors[id] = error
    })

    init(repository suppliedRepository: NoteRepository? = nil, settings: AppSettings? = nil, connectWatch: Bool = true,
         transcribe: ((URL, TranscriptionConfiguration) async throws -> String)? = nil,
         summarizeLocally: ((String, RecordingKind) async throws -> String)? = nil,
         generateTitleLocally: ((String) async -> String?)? = nil,
         transcribeWithSegments: ((URL, TranscriptionConfiguration) async throws -> TranscriptionOutput)? = nil,
         diarize: ((URL, [TranscriptSegment]) async throws -> [TranscriptSegment])? = nil,
         voiceProfile: MyVoiceProfileModel? = nil,
         diarizeWithIdentity: ((URL, [TranscriptSegment], VoiceProfile?) async throws -> VoiceDiarizationOutput)? = nil,
         root: URL? = nil, openRepository: (() throws -> NoteRepository)? = nil,
         connectivity suppliedConnectivity: PhoneConnectivity? = nil) {
        self.settings = settings ?? AppSettings()
        let directory = root ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("VoiceNotes", isDirectory: true)
        self.openRepository = openRepository ?? { try suppliedRepository ?? NoteRepository(root: directory) }
        self.openConnectivity = connectWatch ? { try suppliedConnectivity ?? PhoneConnectivity(inbox: directory.appendingPathComponent("Inbox", isDirectory: true)) } : nil
        let transcriber = LocalTranscriptionService.shared
        self.voiceProfile = voiceProfile ?? MyVoiceProfileModel(enroll: { try await transcriber.enrollVoice(fileURL: $0) })
        if let transcribeWithSegments { transcribeAudio = transcribeWithSegments }
        else if let transcribe { transcribeAudio = { .init(text: try await transcribe($0, $1)) } }
        else { transcribeAudio = { try await transcriber.transcribeWithSegments(fileURL: $0, configuration: $1) } }
        if let diarizeWithIdentity { diarizeAudio = diarizeWithIdentity }
        else if let diarize { diarizeAudio = { file, segments, _ in .init(segments: try await diarize(file, segments)) } }
        else { diarizeAudio = { try await transcriber.diarizeWithIdentity(fileURL: $0, segments: $1, profile: $2) } }
        summarizeOnDevice = summarizeLocally ?? { try await OnDeviceSummarizer().summarize($0, kind: $1) }
        generateRecordingTitle = generateTitleLocally ?? { await OnDeviceRecordingTitleGenerator().generate(from: $0) }
        lifecycleObservation = NotificationCenter.default.publisher(for: UIApplication.protectedDataDidBecomeAvailableNotification)
            .merge(with: NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification))
            .sink { [weak self] _ in Task { @MainActor [weak self] in self?.refreshWatchStatus() } }
        refreshWatchStatus()
    }

    func note(_ id: UUID) -> VoiceNote? { notes.first { $0.id == id } }

    /// Storage and reception recover independently; a protected database must not disable WCSession.
    func refreshWatchStatus() {
        if connectivity == nil, let openConnectivity {
            do {
                let receiver = try openConnectivity()
                connectivity = receiver
                receiver.onReceive = { [weak self] metadata, audio in
                    Task { @MainActor [weak self] in self?.receive(metadata, audio: audio) }
                }
                receiver.onStatusChange = { [weak self] status in
                    Task { @MainActor [weak self] in self?.watchStatus = status }
                }
            } catch { errorMessage = "无法打开录音接收：\(error.localizedDescription)" }
        }
        connectivity?.refreshStatus()
        connectivity?.resumeRecordingInbox()
        do {
            let opened = try openRepository()
            repository = opened
            refresh()
            if errorMessage == storageOpenError { errorMessage = nil }
            storageOpenError = nil
            connectivity?.drainInbox()
            resumePendingProcessing()
        } catch {
            repository = nil
            let message = "无法打开本地笔记：\(error.localizedDescription)"
            storageOpenError = message
            errorMessage = message
        }
    }

    private func resumePendingProcessing() {
        // Decide from durable states, while preserving visible failure overlays until a write succeeds.
        for note in repository?.notes ?? [] {
            let needsTranscription = note.transcriptionState == .pending || note.transcriptionState == .running
            let needsDiarization = note.transcriptionState == .ready && note.diarizationState == .running
            let needsSummary = note.usesLocalThoughtAI && note.transcriptionState == .ready &&
                (note.summaryState == .pending || note.summaryState == .running)
            guard needsTranscription || needsDiarization || needsSummary, queuedRecovery.insert(note.id).inserted else { continue }
            Task { [weak self] in
                guard let self else { return }
                defer { self.queuedRecovery.remove(note.id) }
                guard let current = self.repository?.notes.first(where: { $0.id == note.id }) else { return }
                if current.transcriptionState == .pending || current.transcriptionState == .running { await self.transcribe(note.id, automatic:true) }
                else if current.transcriptionState == .ready && current.diarizationState == .running { await self.identifySpeakers(note.id) }
                if let current = self.repository?.notes.first(where: { $0.id == note.id }), current.usesLocalThoughtAI && current.transcriptionState == .ready &&
                    (current.summaryState == .pending || current.summaryState == .running) { await self.summarize(note.id) }
            }
        }
    }

    func retryWatchSync() {
        watchRetryError = nil
        // Reopen protected storage and retry already-received files before asking Watch to resend.
        refreshWatchStatus()
        do {
            guard let connectivity else { throw PhoneConnectivity.RetryError.unavailable }
            try connectivity.requestSyncRetry()
        } catch { watchRetryError = error.localizedDescription }
    }

    func audioURL(_ id: UUID) -> URL? {
        guard let repository, let note = note(id) else { return nil }
        return repository.audioURL(for: note)
    }

    @discardableResult
    func save(id: UUID, title: String, transcript: String) -> Bool {
        edit(id) { $0.applyEdit(title: title, transcript: transcript) }
    }

    @discardableResult
    func renameSpeaker(noteID: UUID, speakerID: String, name: String) -> Bool {
        guard !activeTranscriptions.contains(noteID), note(noteID)?.transcriptSegments?.contains(where: { $0.speakerID == speakerID }) == true else {
            errorMessage = "说话人信息已更新，请处理完成后再编辑。"
            return false
        }
        return edit(noteID) { $0.renameSpeaker(speakerID, name: name) }
    }

    @discardableResult
    func setSpeakerContact(noteID: UUID, speakerID: String, contact: SpeakerContactSnapshot?, expectedRevision: UUID?, expectedSegments: [TranscriptSegment]) -> Bool {
        guard !activeTranscriptions.contains(noteID), let current = note(noteID),
              current.canEditSpeaker(speakerID, expectedRevision: expectedRevision, expectedSegments: expectedSegments) else {
            errorMessage = "说话人信息已更新，请处理完成后再编辑。"
            return false
        }
        return edit(noteID) { _ = $0.setSpeakerContact(speakerID, contact: contact, expectedRevision: expectedRevision, expectedSegments: expectedSegments) }
    }

    @discardableResult
    func editSegment(noteID: UUID, segmentID: UUID, text: String) -> Bool {
        guard !activeTranscriptions.contains(noteID), note(noteID)?.transcriptSegments?.contains(where: { $0.id == segmentID }) == true else {
            errorMessage = "这段全文已更新，请处理完成后重新打开编辑。"
            return false
        }
        return edit(noteID) { $0.editSegment(segmentID, text: text) }
    }

    func delete(_ id: UUID) {
        do {
            try repository?.delete(id: id)
            durableAudioDeleted?(id)
            refresh()
        } catch { errorMessage = error.localizedDescription }
    }

    @discardableResult
    func setAddress(_ address: CaptureAddress, noteID: UUID, matching point: CaptureLocation) -> Bool {
        do {
            guard let repository else { return false }
            let saved = try repository.setAddress(address, noteID: noteID, matching: point)
            refresh()
            return saved
        } catch { errorMessage = "地点地址未保存：\(error.localizedDescription)"; return false }
    }

    func importAudioFile(_ source: URL) async {
        guard let repository else { return }
        let access = source.startAccessingSecurityScopedResource()
        defer { if access { source.stopAccessingSecurityScopedResource() } }
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).m4a")
        do {
            try FileManager.default.copyItem(at: source, to: temporary)
            let file = try AVAudioFile(forReading: temporary)
            let duration = Double(file.length) / file.processingFormat.sampleRate
            let note = try repository.importRecording(
                id: UUID(), from: temporary, kind: .long, capturedAt: .now, duration: duration
            )
            try repository.update(id: note.id) {
                $0.title = source.deletingPathExtension().lastPathComponent
            }
            refresh()
            await transcribe(note.id, automatic:true)
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            errorMessage = "导入录音失败：\(error.localizedDescription)"
        }
    }

    /// Commits audio before starting ASR so a failed transcription never loses the recording.
    @discardableResult
    func savePhoneRecording(id: UUID, fileURL: URL, capturedAt: Date, duration: TimeInterval, location: CaptureLocation? = nil) -> Bool {
        guard let repository else { errorMessage = "本地笔记暂不可用，请解锁设备后重试。"; return false }
        do {
            let note = try repository.importRecording(id: id, from: fileURL, kind: .long,
                                                       capturedAt: capturedAt, duration: duration,
                origin: RecordingOrigin(device: "iPhone", deviceID: "", fileName: fileURL.lastPathComponent, recordingTimeIsEstimated: false), location: location)
            refresh()
            Task { await self.transcribe(note.id, automatic:true) }
            return true
        } catch {
            errorMessage = "录音保存未完成：\(error.localizedDescription)"
            return false
        }
    }

    func transcribe(_ id: UUID, automatic: Bool = false) async {
        if let opening = note(id), let durableTranscription, await durableTranscription(opening,automatic) { return }
        guard !activeTranscriptions.contains(id), let file = audioURL(id) else { return }
        let revisionBeforeRun = note(id)?.transcriptRevision
        let configuration = settings.transcription
        activeTranscriptions.insert(id)
        defer { activeTranscriptions.remove(id); startTitleGeneration() }
        guard edit(id, { $0.transcriptionState = .running; $0.processingMessage = nil }) else { return }
        do {
            let output = try await transcribeAudio(file, configuration)
            var applied = false
            let committed = edit(id) {
                if $0.transcriptRevision == revisionBeforeRun {
                    $0.applyTranscription(output)
                    applied = true
                }
                $0.transcriptionState = .ready
                $0.processingMessage = nil
            }
            guard committed else { return }
            if applied { await runDiarization(id, file: file) }
            if note(id)?.usesLocalThoughtAI == true, note(id)?.summary.isEmpty == true { await summarize(id) }
        } catch {
            edit(id) {
                $0.transcriptionState = error is TranscriptionFailure ? .unavailable : .failed
                $0.processingMessage = error.localizedDescription
            }
        }
    }

    /// Projection is allowed only for the initial empty, unchanged legacy transcript.
    @discardableResult
    func applyDurableTranscription(_ id: UUID, output: TranscriptionOutput, expectedRevision: UUID?) -> Bool {
        guard let opening = note(id), opening.transcriptRevision == expectedRevision,
              opening.transcript.isEmpty, opening.transcriptionState != .ready else { return false }
        var applied = false
        let committed = edit(id) { note in
            guard note.transcriptRevision == expectedRevision, note.transcript.isEmpty, note.transcriptionState != .ready else { return }
            note.applyTranscription(output)
            note.transcriptionState = .ready
            note.processingMessage = nil
            applied = true
        }
        return committed && applied
    }

    func identifySpeakers(_ id: UUID) async {
        guard !activeTranscriptions.contains(id), let file = audioURL(id),
              note(id)?.transcriptionState != .running else { return }
        activeTranscriptions.insert(id)
        defer { activeTranscriptions.remove(id); startTitleGeneration() }
        await runDiarization(id, file: file)
    }

    private func runDiarization(_ id: UUID, file: URL) async {
        guard let snapshot = note(id) else { return }
        guard let segments = snapshot.transcriptSegments, !segments.isEmpty else {
            edit(id) { $0.diarizationState = .unavailable; $0.diarizationMessage = SpeakerDiarizationError.missingTimestamps.localizedDescription }
            return
        }
        let revision = snapshot.transcriptRevision
        let enrolled = voiceProfile.profile
        guard edit(id, { $0.diarizationState = .running; $0.diarizationMessage = nil }) else { return }
        do {
            let output = try await diarizeAudio(file, segments, enrolled)
            edit(id) {
                if $0.applyDiarization(output.segments, expectedRevision: revision) {
                    if let profileID = output.profileID, profileID == enrolled?.id, profileID == voiceProfile.profile?.id {
                        $0.ownerSpeakerIDs = output.ownerSpeakerIDs.intersection(Set(output.segments.compactMap(\.speakerID)))
                        $0.voiceIdentityMessage = output.identityMessage
                    }
                } else if $0.diarizationState == .running {
                    $0.diarizationState = .pending
                    $0.diarizationMessage = "全文已修改，可重新区分说话人。"
                }
            }
        } catch {
            edit(id) {
                guard $0.transcriptRevision == revision else {
                    if $0.diarizationState == .running { $0.diarizationState = .pending }
                    return
                }
                $0.diarizationState = error is SpeakerDiarizationError ? .unavailable : .failed
                $0.diarizationMessage = error.localizedDescription
            }
        }
    }

#if WISELIFE_EUREKA_RING
    /// Ring files join the same durable local library and local ASR queue as Watch recordings.
    func saveRingRecording(job: RingTransferJob, fileURL: URL, duration: TimeInterval) throws {
        guard let repository else { throw BRLocalRecordingError.libraryUnavailable }
        let isNew = !repository.notes.contains { $0.id == job.id }
        _ = try repository.importRecording(id: job.id, from: fileURL, kind: job.recordingKind,
            capturedAt: job.capturedAt, duration: duration,
            origin: RecordingOrigin(device: "EurekaRing", deviceID: job.deviceID, fileName: job.file.name,
                recordingTimeIsEstimated: job.file.recordedAt == nil))
        refresh()
        if isNew { Task { await self.transcribe(job.id, automatic:true) } }
    }
#endif

    struct RemoteSummaryRequest: Identifiable {
        let id = UUID()
        let noteID: UUID
        let title: String
        let text: String
        let configuration: AIConfiguration
        let revision: Int
    }

    func prepareRemoteSummary(_ id: UUID) -> RemoteSummaryRequest? {
        guard let note = note(id), summaryConfiguration(for: note).isRemote else { return nil }
        return RemoteSummaryRequest(noteID: id, title: note.displayTitle, text: note.transcript,
            configuration: summaryConfiguration(for: note), revision: settings.aiRevision)
    }

    func summarize(_ id: UUID, confirmation: RemoteSummaryRequest? = nil, doNotAskAgain: Bool = false) async {
        guard let note = note(id), summaryModels[id] == nil else { return }
        let text = note.transcript
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let configuration = summaryConfiguration(for: note)
        let revision = settings.aiRevision
        if configuration.isRemote {
            let confirmationIsCurrent = confirmation.map {
                $0.noteID == id && $0.text == text && $0.configuration == configuration && $0.revision == revision
            }
            guard settings.authorizeRemoteAISend(confirmationIsCurrent: confirmationIsCurrent, rememberChoice: doNotAskAgain) else {
                edit(id) { $0.processingMessage = "模型或原文已变化，请重新确认本次发送的文字。" }
                return
            }
        }
        summaryModels[id] = configuration.label
        defer { summaryModels[id] = nil }
        edit(id) { $0.summaryState = .running; $0.processingMessage = nil }
        do {
            let summary: String
            let isCurrent: @MainActor () -> Bool = { [weak self] in
                guard let self, let current = self.note(id) else { return false }
                return current.transcript == text && self.summaryConfiguration(for: current) == configuration
                    && (!configuration.isRemote || self.settings.aiRevision == revision)
            }
            if configuration.mode == .local {
                summary = try await summarizeOnDevice(text, note.kind)
            } else if configuration.mode == .chatgpt {
                summary = try await ChatGPTSummarizer(account: settings.chatGPT).summarize(text, configuration: configuration, isCurrent: isCurrent)
            } else {
                summary = try await CustomAISummarizer().summarize(text, configuration: configuration, apiKey: settings.apiKey(), isCurrent: isCurrent)
            }
            if configuration.isRemote && (settings.ai != configuration || settings.aiRevision != revision) { throw CancellationError() }
            edit(id) {
                guard $0.transcript == text else { return }
                $0.summary = summary
                $0.summaryState = .ready
                $0.processingMessage = nil
            }
        } catch {
            edit(id) {
                guard $0.transcript == text else { return }
                $0.summaryState = error is SummaryFailure ? .unavailable : .failed
                $0.processingMessage = error.localizedDescription
            }
        }
    }

    func summaryConfiguration(for note: VoiceNote) -> AIConfiguration {
        // Hardware flash ideas always stay local, even when other notes use a custom service.
        note.usesLocalThoughtAI ? AIConfiguration() : settings.ai
    }

    private func receive(_ metadata: IncomingRecording, audio: URL) {
        guard let repository else {
            connectivity?.reportSaveFailure(metadata.id, pairingID: metadata.pairingID)
            return
        }
        do {
            _ = try repository.importRecording(
                id: metadata.id, from: audio, kind: metadata.kind,
                capturedAt: metadata.capturedAt, duration: metadata.duration,
                origin: RecordingOrigin(device: "Apple Watch", deviceID: "", fileName: audio.lastPathComponent, recordingTimeIsEstimated: false), location: metadata.location
            )
            // A duplicate transfer leaves its inbox copy untouched; the durable copy is already indexed.
            if FileManager.default.fileExists(atPath: audio.path) {
                try? FileManager.default.removeItem(at: audio)
            }
            refresh()
            connectivity?.acknowledge(metadata.id, pairingID: metadata.pairingID)
            resumePendingProcessing()
        } catch {
            errorMessage = "录音接收失败：\(error.localizedDescription)"
            connectivity?.reportSaveFailure(metadata.id, pairingID: metadata.pairingID)
        }
    }

    @discardableResult
    private func edit(_ id: UUID, _ change: (inout VoiceNote) -> Void) -> Bool {
        do {
            guard let repository else { return false }
            try repository.update(id: id) {
                if let message = persistenceFailures[id] { markWriteFailure(&$0, message: message) }
                change(&$0)
            }
            persistenceFailures.removeValue(forKey: id)
            refresh()
            return true
        } catch {
            errorMessage = error.localizedDescription
            persistenceFailures[id] = "处理结果未能保存，请检查可用存储空间后重试。\(error.localizedDescription)"
            // Publish the failure overlay without inventing a persisted source change.
            // A later lifecycle/source wake can retry a failed durable projection.
            refresh(notifyAudioSource:false)
            return false
        }
    }

    private func refresh(notifyAudioSource: Bool = true) {
        guard let repository else { return }
        notes = repository.notes.sorted { $0.capturedAt > $1.capturedAt }
        for index in notes.indices {
            if let message = persistenceFailures[notes[index].id] { markWriteFailure(&notes[index], message: message) }
        }
        startTitleGeneration()
        if notifyAudioSource { NotificationCenter.default.post(name:.init("WiseLife.AudioSourceDidChange"),object:nil) }
    }

    private func startTitleGeneration() { titleCoordinator.refresh() }

    func prepareRemoteTitle(_ id: UUID) -> RemoteTitleRequest? { titleCoordinator.request(for: id) }

    func generateTitle(_ id: UUID, confirmation: RemoteTitleRequest? = nil, doNotAskAgain: Bool = false) async {
        await titleCoordinator.generate(id, confirmation: confirmation, doNotAskAgain: doNotAskAgain)
    }

    /// A failed disk write cannot persist its own failure marker. Keep a visible,
    /// retryable overlay until a later successful write or process restart.
    private func markWriteFailure(_ note: inout VoiceNote, message: String) {
        if note.transcriptionState == .running { note.transcriptionState = .failed; note.processingMessage = message }
        if note.diarizationState == .running { note.diarizationState = .failed; note.diarizationMessage = message }
        if note.summaryState == .running { note.summaryState = .failed; note.processingMessage = message }
    }
}

#if WISELIFE_EUREKA_RING
private enum BRLocalRecordingError: LocalizedError {
    case libraryUnavailable
    var errorDescription: String? { "本地笔记暂不可用，请解锁设备后重试。" }
}
#endif
