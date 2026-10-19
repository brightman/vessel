import Foundation
import WristNotesDiarization

enum SpeakerDiarizationFailure: LocalizedError {
    case noSpeech
    var errorDescription: String? { "没有得到可用的发言人区间。录音过短、声音太轻或多人重叠时可能无法区分。" }
}

struct LocalSpeakerDiarizer {
    static var modelNotices: String { LocalDiarization.notices }
    func identify(file: URL, note: VoiceNote, words: [TranscriptSegment],
        progress: @escaping @Sendable (String) -> Void) async throws -> SpeakerDiarization {
        var directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("WristNotes/SpeakerModels", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try directory.setResourceValues(values)
        let spans = try await LocalDiarization.identify(audio: file, modelsDirectory: directory, progress: progress)
        try Task.checkCancellation()
        let turns = spans.map { SpeakerTurn(start: $0.start, end: $0.end, speakerID: $0.speakerID) }
        let result = SpeakerDiarization.aligned(turns: turns, words: words, note: note, model: LocalDiarization.modelLabel)
        guard !result.turns.isEmpty else { throw SpeakerDiarizationFailure.noSpeech }
        return result
    }
}
