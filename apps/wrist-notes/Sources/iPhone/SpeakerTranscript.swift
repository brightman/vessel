import AVFAudio
import Foundation

/// The current diarizer retains the entire decoded array. Bound that input before allocation.
/// Use the audio header, never Watch metadata (recovered recordings may report zero seconds).
enum SpeakerAudioInput {
    static func load(from url: URL, using loader: (String) throws -> [Float]) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let rate = file.processingFormat.sampleRate
        guard file.length > 0, rate.isFinite, rate > 0 else { throw SpeakerDiarizationError.invalidAudio }
        let duration = Double(file.length) / rate
        guard duration.isFinite, duration > 0 else { throw SpeakerDiarizationError.invalidAudio }
        // At 16 kHz mono Float32, 30 minutes is 115 MB before decoder/model working copies.
        // Longer input needs a separately bounded pipeline rather than an automatic whole-file retry.
        guard duration <= 30 * 60 else { throw SpeakerDiarizationError.recordingTooLong }
        return try loader(url.path)
    }
}

enum TimedTranscriptBuilder {
    struct Piece {
        let text: String
        let start: TimeInterval?
        let end: TimeInterval?
    }

    /// Apple can omit timing on punctuation/whitespace. Attach it in text order,
    /// instead of assigning the entire sentence's time range to each separator.
    static func segments(_ pieces: [Piece], fallbackStart: Double, fallbackEnd: Double) -> [TranscriptSegment] {
        var output: [TranscriptSegment] = []
        var prefix = ""
        for piece in pieces {
            if let start = piece.start, let end = piece.end, start.isFinite, end.isFinite, start >= 0, end >= start {
                output.append(.init(start: start, end: end, text: prefix + piece.text))
                prefix = ""
            } else if !output.isEmpty {
                output[output.count - 1].text += piece.text
            } else { prefix += piece.text }
        }
        if output.isEmpty, !prefix.isEmpty, fallbackStart.isFinite, fallbackEnd.isFinite,
           fallbackStart >= 0, fallbackEnd >= fallbackStart {
            output.append(.init(start: fallbackStart, end: fallbackEnd, text: prefix))
        }
        return output
    }
}

struct SpeakerTurn: Sendable {
    let start: TimeInterval
    let end: TimeInterval
    let speaker: Int
}

enum SpeakerAlignment {
    static func identifiers(for turns: [SpeakerTurn]) -> [Int: String] {
        let sorted = turns.filter { $0.start.isFinite && $0.end.isFinite && $0.start >= 0 && $0.end > $0.start }
            .sorted { $0.start == $1.start ? $0.speaker < $1.speaker : $0.start < $1.start }
        var names: [Int: String] = [:]
        for turn in sorted where names[turn.speaker] == nil { names[turn.speaker] = "speaker-\(names.count + 1)" }
        return names
    }
    /// Assign labels one row at a time, retaining exact identity, text and timestamps.
    /// Greatest overlap at word granularity. Ties and gaps stay unknown, never guessed.
    static func annotate(_ pieces: [TranscriptSegment], turns: [SpeakerTurn]) -> [TranscriptSegment] {
        let turns = turns.filter { $0.start.isFinite && $0.end.isFinite && $0.start >= 0 && $0.end > $0.start }
            .sorted { $0.start == $1.start ? $0.speaker < $1.speaker : $0.start < $1.start }
        let names = identifiers(for: turns)
        var output: [TranscriptSegment] = []
        var firstCandidate = 0
        var previousStart = -Double.infinity
        for var piece in pieces {
            piece.speakerID = nil
            if piece.start.isFinite && piece.end.isFinite && piece.end > piece.start {
                if piece.start < previousStart { firstCandidate = 0 }
                previousStart = piece.start
                while firstCandidate < turns.count && turns[firstCandidate].end <= piece.start { firstCandidate += 1 }
                var overlaps: [Int: Double] = [:]
                for turn in turns.dropFirst(firstCandidate) {
                    if turn.start >= piece.end { break }
                    let overlap = max(0, min(piece.end, turn.end) - max(piece.start, turn.start))
                    if overlap > 0 { overlaps[turn.speaker, default: 0] += overlap }
                }
                let ranked = overlaps.sorted { $0.value > $1.value }
                if let best = ranked.first, ranked.count == 1 || best.value - ranked[1].value > 0.01 {
                    piece.speakerID = names[best.key]
                }
            }
            output.append(piece)
        }
        return output
    }

    /// Presentation grouping is separate from annotation of durable transcript rows.
    static func align(_ pieces: [TranscriptSegment], turns: [SpeakerTurn]) -> [TranscriptSegment] {
        var output: [TranscriptSegment] = []
        for piece in annotate(pieces,turns:turns) {
            if let last = output.last, last.speakerID == piece.speakerID,
               piece.start - last.end <= 1, piece.end - last.start <= 30,
               last.text.count + piece.text.count <= 400 {
                output[output.count - 1].end = max(last.end, piece.end)
                output[output.count - 1].text += piece.text
            } else { output.append(piece) }
        }
        return output
    }
}

enum SpeakerDiarizationError: LocalizedError {
    case missingModels, missingTimestamps, noSpeakers, recordingTooLong, invalidAudio
    var errorDescription: String? {
        switch self {
        case .missingModels: "请到设置 → 语音转写模型补全离线资源，说话人模型会一并下载。全文已保留。"
        case .missingTimestamps: "这条全文没有时间信息，请重新转写后再区分说话人。"
        case .noSpeakers: "未能区分说话人。可先查看全文，稍后重试。"
        case .recordingTooLong: String(localized: "这段录音超过 30 分钟，暂不区分说话人，以避免内存不足。音频和全文已保留，可正常查看。")
        case .invalidAudio: String(localized: "暂时无法读取音频信息。原文件和全文已保留，请稍后重试。")
        }
    }
}
