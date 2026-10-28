import Foundation

/// Pure conversion; lightweight persisted provenance remains independent of processing types.
enum ContentSegmentPresentation {
    struct FieldGenerationCounts: Equatable {
        let eligible: Int
        let complete: Int
    }

    /// Mirrors generateMissingFields: low-information classifications do not get
    /// display fields; unclassified short recordings remain eligible.
    static func fieldGenerationCounts(_ segments: [ContentSegment]) -> FieldGenerationCounts {
        let eligible = segments.filter {
            $0.isFinal && $0.hasText &&
                ($0.editorial == nil || $0.editorial?.classification == ContentSegmentClassification.meaningful.rawValue)
        }
        let complete = eligible.filter {
            !$0.title.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty &&
                !$0.summary.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty
        }.count
        return .init(eligible:eligible.count,complete:complete)
    }

    /// Raw long audio is a library asset, not a timeline event. Empty/no-speech
    /// segments remain in storage for provenance and playback but are not events.
    /// Direct recordings up to 30 minutes need final ASR/VAD and readable text, but
    /// do not need an AI meaningful classification to appear on the timeline.
    static func timelineRecords(_ records: [DayRecord]) -> [DayRecord] {
        records.filter { record in
            guard record.kind == .voice else { return true }
            guard !record.text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty else { return false }
            guard let provenance = record.contentProvenance else { return record.duration <= 30 * 60 }
            guard provenance.isFinal == true else { return false }
            if let duration=provenance.sourceEffectiveDuration,duration <= 30 * 60 { return true }
            return provenance.classification == "meaningful"
        }
    }
    /// Requested-date inputs are assembled before any selected-day parent replacement.
    static func evidenceRecords(legacyParents: [DayRecord], sessionParents: [DayRecord], derived: [DayRecord], scope: DateInterval) -> [DayRecord] {
        DayRecord.evidenceRecords(LegacyAudioDeletionLedger.shared.filter(legacyParents + sessionParents + derived),scope:scope)
    }
    static func record(_ segment: ContentSegment, source: AudioSourceSnapshot, spans: [AudioTranscriptSpan]) -> DayRecord {
        let intervals = segment.ranges.map { DateInterval(start:source.capturedAt.addingTimeInterval($0.sessionStartOffset),duration:$0.duration) }
        var value = DayRecord(id:segment.id,capturedAt:intervals.first?.start ?? source.capturedAt,kind:.voice,
            title:segment.displayTitle,text:AudioTranscriptPresentation.fullText(spans),summary:segment.summary,
            duration:segment.ranges.reduce(0) { $0 + $1.duration },intervals:intervals)
        value.recordingSessionID = source.id.kind == .session ? source.id.id : nil
        value.captureDevice = source.origin?.device
        // Range metadata makes no claim about the location throughout the recording.
        value.contentProvenance = .init(segmentID:segment.id,sourceID:source.id.id,sourceKind:source.id.kind.rawValue,
            sourceRevision:segment.sourceRevision,segmentRevision:segment.revision,configurationKey:segment.provenance.configurationKey,
            contentSignature:segment.provenance.contentSignature,sourceDate:source.capturedAt,
            ranges:segment.ranges.map { .init(chunkID:$0.chunkID,startFrame:$0.startFrame,endFrame:$0.endFrame,sampleRate:$0.sampleRate,sourceOffset:$0.sessionStartOffset) },
            transcript:spans.map { .init(start:$0.start,end:$0.end,text:$0.text) },
            classification:segment.editorial?.classification,isFinal:segment.isFinal,
            sourceEffectiveDuration:source.ranges.reduce(0) { $0 + $1.duration })
        return value
    }
    static func sourceTime(at compact: Double, ranges: [DayRecord.ContentProvenance.AudioRange]) -> Double? {
        guard compact.isFinite, compact >= 0 else { return nil }
        var cursor = 0.0
        for range in ranges {
            if compact < cursor + range.duration { return range.sourceOffset + floor((compact-cursor)*range.sampleRate)/range.sampleRate }
            cursor += range.duration
        }
        return nil
    }
    static func playbackTime(at source: Double, ranges: [DayRecord.ContentProvenance.AudioRange]) -> Double? {
        var cursor = 0.0
        for range in ranges {
            if source >= range.sourceOffset && source < range.sourceOffset + range.duration { return cursor + source-range.sourceOffset }
            cursor += range.duration
        }
        return nil
    }
}

/// Window persistence and successful analysis are separate signals.
struct AudioProcessingPresentation {
    struct Stage {
        var success = 0
        var missingResource = 0
        var failed = 0
        var cancelled = 0
        var notRequested = 0
    }
    let completedWindows: Int
    let totalWindows: Int
    let messages: [String]
    init(states: [AudioJobState:Int], asr: Stage, vad: Stage, speaker: Stage) {
        completedWindows = states[.completed,default:0]
        totalWindows = states.values.reduce(0,+)
        var messages: [String] = []
        if states[.missingResource,default:0] > 0 { messages.append("本机模型资源未就绪，请在语音转写模型设置中检查。") }
        if states[.failed,default:0] > 0 { messages.append("部分处理窗口失败，可重试。") }
        if states[.cancelled,default:0] > 0 { messages.append("部分处理窗口已取消，可重试。") }
        for (label, stage) in [("语音转写",asr),("语音活动检测",vad),("说话人分析",speaker)] {
            if stage.failed > 0 { messages.append("\(label)失败，可重试。") }
            if stage.missingResource > 0 { messages.append("\(label)模型资源未就绪，请在语音转写模型设置中检查。") }
            if stage.cancelled > 0 { messages.append("\(label)已取消，可重试。") }
            if stage.notRequested > 0 {
                if label == "说话人分析" {
                    messages.append("说话人分析尚未执行；可能是录音时长未知，也可能尚未请求此阶段。")
                } else { messages.append("\(label)未请求，不计为分析成功。") }
            }
        }
        self.messages = messages
    }
}
