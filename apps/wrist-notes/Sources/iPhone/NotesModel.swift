import Combine
import AVFAudio
import Foundation

@MainActor
final class NotesModel: ObservableObject {
    @Published private(set) var notes: [VoiceNote] = []
    @Published var errorMessage: String?
    @Published private(set) var watchStatus = PhoneWatchStatus()
    @Published private(set) var summaryModels: [UUID: String] = [:]
    let settings: AppSettings

    private var repository: NoteRepository?
    private var connectivity: PhoneConnectivity?
    private var activeTranscriptions: Set<UUID> = []
    private let transcribeAudio: (URL, TranscriptionConfiguration) async throws -> String
    private let summarizeOnDevice: (String, RecordingKind) async throws -> String

    init(repository suppliedRepository: NoteRepository? = nil, settings: AppSettings? = nil, connectWatch: Bool = true,
         transcribe: ((URL, TranscriptionConfiguration) async throws -> String)? = nil,
         summarizeLocally: ((String, RecordingKind) async throws -> String)? = nil) {
        self.settings = settings ?? AppSettings()
        let transcriber = LocalTranscriptionService()
        transcribeAudio = transcribe ?? { try await transcriber.transcribe(fileURL: $0, configuration: $1) }
        summarizeOnDevice = summarizeLocally ?? { try await OnDeviceSummarizer().summarize($0, kind: $1) }
        do {
            let root = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("VoiceNotes", isDirectory: true)
            let repository = try suppliedRepository ?? NoteRepository(root: root)
            self.repository = repository
            self.notes = repository.notes.sorted { $0.capturedAt > $1.capturedAt }
            if connectWatch {
                let inbox = root.appendingPathComponent("Inbox", isDirectory: true)
                let connectivity = try PhoneConnectivity(inbox: inbox)
                self.connectivity = connectivity
                connectivity.onReceive = { [weak self] metadata, audio in
                    Task { @MainActor [weak self] in self?.receive(metadata, audio: audio) }
                }
                connectivity.onStatusChange = { [weak self] status in
                    Task { @MainActor [weak self] in self?.watchStatus = status }
                }
                connectivity.refreshStatus()
                connectivity.drainInbox()
            }
            for note in notes where note.transcriptionState == .pending || note.transcriptionState == .running {
                Task { await self.transcribe(note.id) }
            }
            for note in notes where note.usesLocalThoughtAI && note.transcriptionState == .ready &&
                (note.summaryState == .pending || note.summaryState == .running) {
                Task { await self.summarize(note.id) }
            }
        } catch {
            errorMessage = "无法打开本地笔记：\(error.localizedDescription)"
        }
    }

    func note(_ id: UUID) -> VoiceNote? { notes.first { $0.id == id } }
    func refreshWatchStatus() { connectivity?.refreshStatus() }
    func audioURL(_ id: UUID) -> URL? {
        guard let repository, let note = note(id) else { return nil }
        return repository.audioURL(for: note)
    }

    func save(id: UUID, title: String, transcript: String) {
        edit(id) { $0.applyEdit(title: title, transcript: transcript) }
    }

    func delete(_ id: UUID) {
        do {
            try repository?.delete(id: id)
            refresh()
        } catch { errorMessage = error.localizedDescription }
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
            await transcribe(note.id)
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            errorMessage = "导入录音失败：\(error.localizedDescription)"
        }
    }

    /// Commits audio before starting ASR so a failed transcription never loses the recording.
    @discardableResult
    func savePhoneRecording(id: UUID, fileURL: URL, capturedAt: Date, duration: TimeInterval) -> Bool {
        guard let repository else { errorMessage = "本地笔记尚未打开，请重启后重试。"; return false }
        do {
            let note = try repository.importRecording(id: id, from: fileURL, kind: .long,
                                                       capturedAt: capturedAt, duration: duration)
            refresh()
            Task { await self.transcribe(note.id) }
            return true
        } catch {
            errorMessage = "录音保存未完成：\(error.localizedDescription)"
            return false
        }
    }

    func transcribe(_ id: UUID) async {
        guard !activeTranscriptions.contains(id), let file = audioURL(id) else { return }
        let transcriptBeforeRun = note(id)?.transcript ?? ""
        let configuration = settings.transcription
        activeTranscriptions.insert(id)
        defer { activeTranscriptions.remove(id) }
        edit(id) { $0.transcriptionState = .running; $0.processingMessage = nil }
        do {
            let text = try await transcribeAudio(file, configuration)
            edit(id) {
                if $0.transcript == transcriptBeforeRun { $0.applyEdit(title: $0.title, transcript: text) }
                $0.transcriptionState = .ready
                $0.processingMessage = nil
            }
            if note(id)?.usesLocalThoughtAI == true, note(id)?.summary.isEmpty == true { await summarize(id) }
        } catch {
            edit(id) {
                $0.transcriptionState = error is TranscriptionFailure ? .unavailable : .failed
                $0.processingMessage = error.localizedDescription
            }
        }
    }

    /// Ring files join the same durable local library and local ASR queue as Watch recordings.
    func saveRingRecording(job: RingTransferJob, fileURL: URL, duration: TimeInterval) throws {
        guard let repository else { throw BRLocalRecordingError.libraryUnavailable }
        let isNew = !repository.notes.contains { $0.id == job.id }
        _ = try repository.importRecording(id: job.id, from: fileURL, kind: job.recordingKind,
            capturedAt: job.capturedAt, duration: duration,
            origin: RecordingOrigin(device: "EurekaRing", deviceID: job.deviceID, fileName: job.file.name,
                recordingTimeIsEstimated: job.file.recordedAt == nil))
        refresh()
        if isNew { Task { await self.transcribe(job.id) } }
    }

    func summarize(_ id: UUID) async {
        guard let note = note(id), summaryModels[id] == nil else { return }
        let text = note.transcript
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let configuration = summaryConfiguration(for: note)
        summaryModels[id] = configuration.label
        defer { summaryModels[id] = nil }
        edit(id) { $0.summaryState = .running; $0.processingMessage = nil }
        do {
            let summary: String
            if configuration.mode == .local {
                summary = try await summarizeOnDevice(text, note.kind)
            } else {
                summary = try await CustomAISummarizer().summarize(text, configuration: configuration, apiKey: settings.apiKey())
            }
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
        guard let repository else { return }
        do {
            let isNewRecording = !repository.notes.contains { $0.id == metadata.id }
            _ = try repository.importRecording(
                id: metadata.id, from: audio, kind: metadata.kind,
                capturedAt: metadata.capturedAt, duration: metadata.duration
            )
            // A duplicate transfer leaves its inbox copy untouched; the durable copy is already indexed.
            if FileManager.default.fileExists(atPath: audio.path) {
                try? FileManager.default.removeItem(at: audio)
            }
            refresh()
            connectivity?.acknowledge(metadata.id)
            if isNewRecording { Task { await self.transcribe(metadata.id) } }
        } catch { errorMessage = "录音接收失败：\(error.localizedDescription)" }
    }

    private func edit(_ id: UUID, _ change: (inout VoiceNote) -> Void) {
        do {
            try repository?.update(id: id, change)
            refresh()
        } catch { errorMessage = error.localizedDescription }
    }

    private func refresh() {
        notes = repository?.notes.sorted { $0.capturedAt > $1.capturedAt } ?? []
    }
}

private enum BRLocalRecordingError: LocalizedError {
    case libraryUnavailable
    var errorDescription: String? { "本地笔记尚未打开，请重启后重试。" }
}
