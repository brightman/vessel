import Foundation

enum RecordingKind: String, Codable, CaseIterable {
    case long
    case thought

    var label: String { self == .long ? "长录音" : "语音闪念" }
}

enum SimulatorAudioChunks {
    static let maximumChunkSize = 48 * 1024

    static func split(_ data: Data) -> [Data] {
        guard !data.isEmpty else { return [] }
        return stride(from: 0, to: data.count, by: maximumChunkSize).map { start in
            let end = min(start + maximumChunkSize, data.count)
            return Data(data[start..<end])
        }
    }
}

struct SimulatorAudioChunkAssembler {
    private var totalChunks: Int?
    private var chunks: [Int: Data] = [:]

    mutating func append(_ chunk: Data, at index: Int, total: Int) throws -> Data? {
        guard total > 0, total <= 4_096, index >= 0, index < total,
              chunk.count <= SimulatorAudioChunks.maximumChunkSize else {
            throw ChunkAssemblyError.invalidChunk
        }
        if let totalChunks, totalChunks != total { throw ChunkAssemblyError.inconsistentChunkCount }
        if let existing = chunks[index] {
            guard existing == chunk else { throw ChunkAssemblyError.conflictingDuplicate }
            return nil
        }

        totalChunks = total
        chunks[index] = chunk
        guard chunks.count == total else { return nil }
        var assembled = Data()
        for chunkIndex in 0..<total {
            guard let part = chunks[chunkIndex] else { return nil }
            assembled.append(part)
        }
        return assembled
    }

    enum ChunkAssemblyError: Error {
        case invalidChunk
        case inconsistentChunkCount
        case conflictingDuplicate
    }
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
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M月d日 HH:mm"
        self.title = "\(kind.label) · \(formatter.string(from: capturedAt))"
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
