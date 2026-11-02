import Combine
import Foundation

/// A disposable microphone take, independent of voice notes and conversation storage.
@MainActor protocol AssistantVoiceRecording: AnyObject {
    var duration: TimeInterval { get }
    var level: Float { get }
    var onEnded: (() -> Void)? { get set }
    func start() async throws
    func finish() throws -> URL
    func discard()
}

enum AssistantVoiceInputFailure: LocalizedError {
    case microphoneDenied, interrupted
    case recording(String)
    var errorDescription: String? {
        switch self {
        case .microphoneDenied: "请在系统设置中允许 WiseLife 使用麦克风。"
        case .interrupted: "语音输入被中断，请重新说一次。原有文字已保留。"
        case .recording(let message): message
        }
    }
}

/// Bounded recent microphone energy, with a fast attack and gentler release.
/// Quiet input settles to zero; the view supplies the minimum visible bar height.
struct AssistantVoiceWaveform: Equatable {
    private(set) var samples = [Float](repeating: 0, count: 19)
    private var envelope: Float = 0

    mutating func append(_ input: Float) {
        let target = input.isFinite ? min(1, max(0, input)) : 0
        envelope += (target - envelope) * (target > envelope ? 0.75 : 0.35)
        if envelope < 0.015 { envelope = 0 }
        samples.removeFirst()
        samples.append(envelope)
    }
}

/// Metering must not invalidate the conversation, including its evidence freshness checks.
@MainActor final class AssistantVoiceMeter: ObservableObject {
    @Published var duration: TimeInterval = 0
    @Published var waveform = AssistantVoiceWaveform()
}

@MainActor final class AssistantVoiceInputModel: ObservableObject {
    enum Phase { case idle, preparing, recording, transcribing }
    struct Result: Equatable {
        let id: UUID
        let originalDraft: String
        let draft: String
        let caret: Int
    }
    @Published private(set) var phase: Phase = .idle
    let meter = AssistantVoiceMeter()
    private(set) var duration: TimeInterval {
        get { meter.duration }
        set { meter.duration = newValue }
    }
    private(set) var waveform: AssistantVoiceWaveform {
        get { meter.waveform }
        set { meter.waveform = newValue }
    }
    @Published private(set) var result: Result?
    @Published private(set) var errorMessage: String?
    @Published private(set) var microphoneDenied = false
    var isActive: Bool { phase != .idle }

    private let recorder: any AssistantVoiceRecording
    private let prepare: (TranscriptionConfiguration) async throws -> Void
    private let transcribe: (URL, TranscriptionConfiguration) async throws -> String
    private var operation: UUID?
    private var task: Task<Void, Never>?
    private var ticker: Task<Void, Never>?
    private var deadline: Task<Void, Never>?
    private let transcriptionTimeout: Duration
    private var configuration = TranscriptionConfiguration()
    private var originalDraft = ""
    private var insertionRange = 0..<0

    init(recorder: any AssistantVoiceRecording,
         prepare: @escaping (TranscriptionConfiguration) async throws -> Void,
         transcriptionTimeout: Duration = .seconds(60),
         transcribe: @escaping (URL, TranscriptionConfiguration) async throws -> String) {
        self.recorder = recorder; self.prepare = prepare; self.transcribe = transcribe
        self.transcriptionTimeout = transcriptionTimeout
        recorder.onEnded = { [weak self] in self?.finish() }
    }

    func start(configuration: TranscriptionConfiguration, draft: String, selection: Range<Int>? = nil) {
        guard !isActive else { return }
        let id = UUID(); operation = id
        self.configuration = configuration; originalDraft = draft
        let selection = selection ?? draft.count..<draft.count
        let start = max(0, min(selection.lowerBound, draft.count))
        insertionRange = start..<max(start, min(selection.upperBound, draft.count))
        result = nil; errorMessage = nil; microphoneDenied = false; duration = 0; waveform = .init()
        phase = .preparing
        task = Task { [weak self] in
            guard let self else { return }
            do {
                try await recorder.start()
                try Task.checkCancellation()
                guard operation == id else { return }
                phase = .recording
                task = nil
                ticker = Task { [weak self] in
                    while !Task.isCancelled {
                        try? await Task.sleep(for: .milliseconds(70))
                        guard let self, !Task.isCancelled, self.operation == id, self.phase == .recording else { return }
                        self.duration = self.recorder.duration
                        self.waveform.append(self.recorder.level)
                    }
                }
            } catch { fail(error, operation: id) }
        }
    }

    /// A finger release during resource/permission preparation must not start a late take.
    func release() {
        if phase == .preparing { cancel() }
        else if phase == .recording { finish() }
    }

    func finish() {
        guard phase == .recording, let id = operation else { return }
        ticker?.cancel(); ticker = nil
        // Leave listening before stopping the recorder; duplicate end callbacks are inert.
        phase = .transcribing; waveform = .init()
        do {
            let url = try recorder.finish()
            duration = recorder.duration
            deadline = Task { [weak self, transcriptionTimeout] in
                do { try await Task.sleep(for: transcriptionTimeout) } catch { return }
                self?.fail(AssistantVoiceInputFailure.recording("本机转写等待超时，请重试。原有文字已保留。"), operation: id)
            }
            let configuration = configuration
            task = Task { [weak self] in
                guard let self else { return }
                do {
                    // Inventory/model checks must not consume the user's held speaking time.
                    try await prepare(configuration)
                    try Task.checkCancellation()
                    guard operation == id else { return }
                    let text = try await transcribe(url, configuration).trimmingCharacters(in: .whitespacesAndNewlines)
                    try Task.checkCancellation()
                    guard operation == id else { return }
                    guard !text.isEmpty else { throw TranscriptionResourceError.emptyTranscript }
                    let before = String(originalDraft.prefix(insertionRange.lowerBound))
                    let after = String(originalDraft.dropFirst(insertionRange.upperBound))
                    let prefix = before.isEmpty || before.last!.isWhitespace ? before : before + " "
                    let suffix = after.isEmpty || after.first!.isWhitespace ? after : " " + after
                    let insertion = Result(id: id, originalDraft: originalDraft, draft: prefix + text + suffix, caret: prefix.count + text.count)
                    // Release only this operation's resources; cancelled tasks cannot touch a new take.
                    cleanup(); result = insertion
                } catch { fail(error, operation: id) }
            }
        } catch { fail(error, operation: id) }
    }

    func cancel() { cleanup(); result = nil; errorMessage = nil; microphoneDenied = false }

    private func fail(_ error: Error, operation id: UUID) {
        guard operation == id else { return }
        cleanup()
        guard !(error is CancellationError) else { return }
        errorMessage = error.localizedDescription
        if let failure = error as? AssistantVoiceInputFailure, case .microphoneDenied = failure { microphoneDenied = true }
    }

    private func cleanup() {
        operation = nil
        task?.cancel(); task = nil; ticker?.cancel(); ticker = nil
        deadline?.cancel(); deadline = nil
        recorder.discard(); phase = .idle; waveform = .init()
    }
}
