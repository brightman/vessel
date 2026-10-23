import Combine
import AVFAudio
import Foundation

@MainActor
final class NotesModel: ObservableObject {
    @Published private(set) var notes: [VoiceNote] = []
    @Published var errorMessage: String?
    @Published var localeIdentifier = UserDefaults.standard.string(forKey: "transcriptionLocale") ?? "zh-CN" {
        didSet { UserDefaults.standard.set(localeIdentifier, forKey: "transcriptionLocale") }
    }

    private var repository: NoteRepository?
    private var huaweiReceiver: HuaweiRecordingReceiver?
    private var activeTranscriptions: Set<UUID> = []

    init() {
        do {
            let root = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("VoiceNotes", isDirectory: true)
            let repository = try NoteRepository(root: root)
            self.repository = repository
            self.huaweiReceiver = try HuaweiRecordingReceiver(repository: repository, staging: root.appendingPathComponent("Incoming"))
            self.notes = repository.notes.sorted { $0.capturedAt > $1.capturedAt }
            for note in notes where note.transcriptionState == .pending || note.transcriptionState == .running {
                Task { await self.transcribe(note.id) }
            }
        } catch {
            errorMessage = "无法打开本地笔记：\(error.localizedDescription)"
        }
    }

    func note(_ id: UUID) -> VoiceNote? { notes.first { $0.id == id } }
    func audioURL(_ id: UUID) -> URL? {
        guard let repository, let note = note(id) else { return nil }
        return repository.audioURL(for: note)
    }

    func save(id: UUID, title: String, transcript: String) {
        edit(id) { $0.applyEdit(title: title, transcript: transcript) }
    }

    /// Future Wear Engine adapter calls this only after authenticating the peer and
    /// assembling the complete file. Return this ack over the same authenticated channel.
    func receiveHuaweiRecording(_ metadata: HuaweiRecordingMetadata, source: URL) throws -> HuaweiStoredAcknowledgement {
        guard let huaweiReceiver else { throw HuaweiReceiveFailure.unavailable }
        let needsTranscription = note(metadata.id)?.transcriptionState != .ready
        let ack = try huaweiReceiver.receive(metadata: metadata, source: source)
        refresh()
        if needsTranscription { Task { await transcribe(metadata.id) } }
        return ack
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

    func transcribe(_ id: UUID) async {
        guard !activeTranscriptions.contains(id), let file = audioURL(id) else { return }
        let transcriptBeforeRun = note(id)?.transcript ?? ""
        activeTranscriptions.insert(id)
        defer { activeTranscriptions.remove(id) }
        edit(id) { $0.transcriptionState = .running; $0.processingMessage = nil }
        do {
            let text = try await OnDeviceTranscriber().transcribe(fileURL: file, locale: Locale(identifier: localeIdentifier))
            edit(id) {
                if $0.transcript == transcriptBeforeRun { $0.applyEdit(title: $0.title, transcript: text) }
                $0.transcriptionState = .ready
                $0.processingMessage = nil
            }
        } catch {
            edit(id) {
                $0.transcriptionState = error is TranscriptionFailure ? .unavailable : .failed
                $0.processingMessage = error.localizedDescription
            }
        }
    }

    func summarize(_ id: UUID) async {
        guard let note = note(id), note.summaryState != .running else { return }
        let text = note.transcript
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        edit(id) { $0.summaryState = .running; $0.processingMessage = nil }
        do {
            let summary = try await OnDeviceSummarizer().summarize(text)
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
