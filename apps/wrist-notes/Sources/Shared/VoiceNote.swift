import Foundation

enum RecordingKind: String, Codable, CaseIterable {
    case long
    case thought

    var label: String { self == .long ? "长录音" : "语音闪念" }
}

enum RecordingMergeSelection {
    static func canAdd(_ candidate: UUID, to selectedIDs: Set<UUID>, orderedIDs: [UUID], eligibleIDs: Set<UUID>) -> Bool {
        guard orderedIDs.contains(candidate), eligibleIDs.contains(candidate), Set(orderedIDs).count == orderedIDs.count else { return false }
        if selectedIDs.contains(candidate) { return true }
        let next = selectedIDs.union([candidate])
        return next.count == 1 || isContiguous(next, orderedIDs: orderedIDs, eligibleIDs: eligibleIDs)
    }

    static func canMerge(_ selectedIDs: Set<UUID>, orderedIDs: [UUID], eligibleIDs: Set<UUID>) -> Bool {
        selectedIDs.count >= 2 && isContiguous(selectedIDs, orderedIDs: orderedIDs, eligibleIDs: eligibleIDs)
    }

    static func orderedSelection(_ selectedIDs: Set<UUID>, orderedIDs: [UUID], eligibleIDs: Set<UUID>) -> [UUID]? {
        guard canMerge(selectedIDs, orderedIDs: orderedIDs, eligibleIDs: eligibleIDs) else { return nil }
        return orderedIDs.filter(selectedIDs.contains)
    }

    private static func isContiguous(_ selectedIDs: Set<UUID>, orderedIDs: [UUID], eligibleIDs: Set<UUID>) -> Bool {
        guard !selectedIDs.isEmpty, Set(orderedIDs).count == orderedIDs.count,
              selectedIDs.isSubset(of: eligibleIDs) else { return false }
        let indexes = selectedIDs.compactMap { orderedIDs.firstIndex(of: $0) }.sorted()
        guard indexes.count == selectedIDs.count, let first = indexes.first, let last = indexes.last else { return false }
        return indexes.count == last - first + 1
    }
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

struct RecordingOrigin: Codable, Equatable {
    let device: String
    let deviceID: String
    let fileName: String
    let recordingTimeIsEstimated: Bool
}

struct MergedRecordingSource: Codable, Equatable, Identifiable {
    let recordingID: UUID
    let capturedAt: Date
    let duration: TimeInterval
    let origin: RecordingOrigin?

    var id: UUID { recordingID }
    var deviceName: String { origin?.device ?? "设备未知" }
}

/// Text retains its original whitespace so joining timed pieces is lossless.
struct TranscriptSegment: Codable, Equatable, Identifiable, Sendable {
    var id = UUID()
    var start: TimeInterval
    var end: TimeInterval
    var text: String
    var speakerID: String?
}

struct TranscriptionOutput: Equatable, Sendable {
    var text: String
    var segments: [TranscriptSegment] = []
}

/// Frozen when opening the sheet, independently of later observed note updates.
struct SpeakerManagementContext: Identifiable {
    let note: VoiceNote
    let speakerID: String
    var id: String { speakerID }
}

struct SpeakerContactSnapshot: Codable, Equatable, Sendable {
    let identifier: String
    let displayName: String
    let thumbnailData: Data?
}

enum RecordingTitleSource: String, Codable { case model, transcriptExcerpt }

/// Content-only title policy shared by persistence and iPhone presentation.
/// Watch recording metadata keeps its existing default title until iPhone processing.
enum RecordingTitleText {
    static func withoutPrefix(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: #"^长录音\s*·\s*"#, with: "", options: .regularExpression)
    }

    static func isTimestamp(_ value: String) -> Bool {
        value.range(of: #"^\d{1,2}月\d{1,2}日\s+\d{1,2}:\d{2}$"#, options: .regularExpression) != nil
    }

    static func normalized(_ value: String) -> String? {
        var title = value.components(separatedBy: .newlines).first(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) ?? ""
        title = title.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: #"^(?:标题|Title)\s*[:：]\s*"#, with: "", options: [.regularExpression, .caseInsensitive])
        title = withoutPrefix(title.trimmingCharacters(in: CharacterSet(charactersIn: "\"“”‘’「」『』")))
        title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, !isTimestamp(title), title != "待生成标题" else { return nil }
        return String(title.prefix(48))
    }

    static func fallback(from transcript: String) -> String? {
        for part in transcript.components(separatedBy: CharacterSet(charactersIn: "。！？!?；;\n")) {
            if let title = normalized(part) { return title }
        }
        return nil
    }
}

struct VoiceNote: Codable, Identifiable, Equatable {
    let id: UUID
    let kind: RecordingKind
    let capturedAt: Date
    var duration: TimeInterval
    let audioFilename: String
    var title: String
    var transcript: String
    var summary: String
    var transcriptionState: ProcessingState
    var summaryState: ProcessingState
    var processingMessage: String?
    var origin: RecordingOrigin?
    // Optional so records written before audio merging remain decodable.
    var mergedSources: [MergedRecordingSource]? = nil
    var location: CaptureLocation?
    // Optional for JSON written by older iPhone/Watch versions.
    var transcriptSegments: [TranscriptSegment]?
    var speakerNames: [String: String]?
    var speakerContacts: [String: SpeakerContactSnapshot]?
    var ownerSpeakerIDs: Set<String>?
    var voiceIdentityMessage: String?
    var diarizationState: ProcessingState?
    var diarizationMessage: String?
    var transcriptRevision: UUID?
    var titleSource: RecordingTitleSource?
    var titleRevision: UUID?
    var titleManuallyEdited: Bool?

    private var hasDefaultRecordingTitle: Bool {
        let content = RecordingTitleText.withoutPrefix(title)
        return content.isEmpty || content == "待生成标题" || content == "长录音" || RecordingTitleText.isTimestamp(content)
    }
    private var canGenerateRecordingTitle: Bool {
        kind == .long && titleManuallyEdited != true && (titleSource != nil || hasDefaultRecordingTitle)
    }
    var needsRecordingTitle: Bool {
        canGenerateRecordingTitle && transcriptionState == .ready && !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            (titleSource == nil || titleRevision != transcriptRevision)
    }
    var needsModelRecordingTitle: Bool {
        needsRecordingTitle || (canGenerateRecordingTitle && transcriptionState == .ready &&
            !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && titleSource == .transcriptExcerpt)
    }
    var editableRecordingTitle: String {
        guard kind == .long else { return title }
        if canGenerateRecordingTitle && (hasDefaultRecordingTitle || titleRevision != transcriptRevision) { return "" }
        return RecordingTitleText.withoutPrefix(title)
    }
    var displayTitle: String {
        guard kind == .long else { return title }
        let content = editableRecordingTitle
        return "长录音·" + (content.isEmpty ? "待生成标题" : content)
    }
    @discardableResult
    mutating func applyGeneratedRecordingTitle(_ value: String, source: RecordingTitleSource,
                                               expectedRevision: UUID?, expectedTitle: String, replacingExisting: Bool = false) -> Bool {
        let eligible = replacingExisting ? kind == .long && transcriptionState == .ready : needsModelRecordingTitle
        guard eligible, transcriptRevision == expectedRevision, title == expectedTitle,
              let content = RecordingTitleText.normalized(value) else { return false }
        title = content
        titleSource = source
        titleRevision = transcriptRevision
        titleManuallyEdited = false
        return true
    }
    var usesLocalThoughtAI: Bool { kind == .thought && origin?.device == "EurekaRing" }

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
        self.origin = nil
    }

    mutating func applyEdit(title: String, transcript: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let revisedTitle = trimmed.isEmpty ? "未命名录音" : trimmed
        if self.title != revisedTitle {
            titleManuallyEdited = true
            titleSource = nil
            titleRevision = nil
        }
        self.title = revisedTitle
        guard self.transcript != transcript else { return }
        self.transcript = transcript
        transcriptRevision = UUID()
        transcriptSegments = nil
        speakerNames = nil
        speakerContacts = nil
        ownerSpeakerIDs = nil
        voiceIdentityMessage = nil
        diarizationState = nil
        diarizationMessage = nil
        summary = ""
        summaryState = .pending
        processingMessage = nil
        if transcriptionState != .running {
            transcriptionState = transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .pending : .ready
        }
    }

    mutating func applyTranscription(_ output: TranscriptionOutput) {
        applyEdit(title: title, transcript: output.text)
        transcriptRevision = UUID()
        transcriptSegments = output.segments.isEmpty ? nil : output.segments
        speakerNames = nil
        speakerContacts = nil
        ownerSpeakerIDs = nil
        voiceIdentityMessage = nil
        diarizationState = nil
        diarizationMessage = nil
    }

    func speakerName(_ id: String?) -> String {
        guard let id else { return "未区分" }
        if let contact = speakerContacts?[id] { return contact.displayName }
        if let name = speakerNames?[id], !name.isEmpty { return name }
        if speakerNames?[id] == nil, ownerSpeakerIDs?.contains(id) == true { return "我" }
        return "说话人 \(id.replacingOccurrences(of: "speaker-", with: ""))"
    }

    mutating func renameSpeaker(_ id: String, name: String) {
        guard transcriptSegments?.contains(where: { $0.speakerID == id }) == true else { return }
        speakerContacts?[id] = nil
        let trimmed = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(40))
        var names = speakerNames ?? [:]
        // Empty is an explicit manual reset, so automatic identity must not override it.
        names[id] = trimmed
        speakerNames = names
    }

    /// The opening snapshot prevents stale picker confirmations from changing a new transcript.
    func canEditSpeaker(_ id: String, expectedRevision: UUID?, expectedSegments: [TranscriptSegment]) -> Bool {
        transcriptionState != .running && diarizationState != .running &&
        transcriptRevision == expectedRevision && transcriptSegments == expectedSegments &&
        expectedSegments.contains { $0.speakerID == id }
    }

    @discardableResult
    mutating func setSpeakerContact(_ id: String, contact: SpeakerContactSnapshot?, expectedRevision: UUID?, expectedSegments: [TranscriptSegment]) -> Bool {
        guard canEditSpeaker(id, expectedRevision: expectedRevision, expectedSegments: expectedSegments) else { return false }
        var contacts = speakerContacts ?? [:]
        contacts[id] = contact
        speakerContacts = contacts.isEmpty ? nil : contacts
        speakerNames?[id] = nil
        return true
    }

    mutating func editSegment(_ id: UUID, text: String) {
        guard var segments = transcriptSegments, let index = segments.firstIndex(where: { $0.id == id }),
              segments[index].text != text else { return }
        segments[index].text = text
        transcriptSegments = segments
        transcript = segments.map(\.text).joined().trimmingCharacters(in: .whitespacesAndNewlines)
        transcriptRevision = UUID()
        summary = ""
        summaryState = .pending
    }

    /// An edit during inference wins, including edits that restore the original text.
    @discardableResult
    mutating func applyDiarization(_ segments: [TranscriptSegment], expectedRevision: UUID?) -> Bool {
        guard transcriptRevision == expectedRevision else { return false }
        let sameAssignments = (transcriptSegments ?? []).elementsEqual(segments) {
            $0.start == $1.start && $0.end == $1.end && $0.speakerID == $1.speakerID
        }
        if !sameAssignments { speakerNames = nil; speakerContacts = nil }
        ownerSpeakerIDs = nil
        voiceIdentityMessage = nil
        transcriptSegments = segments
        diarizationState = .ready
        diarizationMessage = nil
        return true
    }
}
