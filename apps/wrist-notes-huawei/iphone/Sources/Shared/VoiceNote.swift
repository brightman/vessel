import Foundation

enum RecordingKind: String, Codable, CaseIterable {
    case long
    case thought

    var label: String { self == .long ? "长录音" : "语音闪念" }
}

enum ProcessingState: String, Codable {
    case pending
    case running
    case ready
    case unavailable
    case failed
}

struct VoiceNote: Codable, Identifiable, Equatable {
    let id: UUID
    let kind: RecordingKind
    let capturedAt: Date
    let duration: TimeInterval
    let audioFilename: String
    var title: String
    var transcript: String
    var summary: String
    var transcriptionState: ProcessingState
    var summaryState: ProcessingState
    var processingMessage: String?

    init(id: UUID, kind: RecordingKind, capturedAt: Date, duration: TimeInterval) {
        self.id = id
        self.kind = kind
        self.capturedAt = capturedAt
        self.duration = duration
        self.audioFilename = "\(id.uuidString).m4a"
        self.title = "\(kind.label) · \(capturedAt.formatted(date: .abbreviated, time: .shortened))"
        self.transcript = ""
        self.summary = ""
        self.transcriptionState = .pending
        self.summaryState = .pending
        self.processingMessage = nil
    }

    mutating func applyEdit(title: String, transcript: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        self.title = trimmed.isEmpty ? "未命名录音" : trimmed
        guard self.transcript != transcript else { return }
        self.transcript = transcript
        summary = ""
        summaryState = .pending
        processingMessage = nil
        if transcriptionState != .running {
            transcriptionState = transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .pending : .ready
        }
    }
}
