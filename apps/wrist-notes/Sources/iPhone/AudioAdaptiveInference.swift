import Foundation

/// Reduces only uncommitted native input, preserving the durable outer window and its core.
/// Called inside the shared permit; the operation must invoke installed adapters directly.
enum AudioAdaptiveInference {
    static func windows(_ outer: AudioProcessingWindow, maximumCoreDuration: Double) throws -> [AudioProcessingWindow] {
        guard maximumCoreDuration.isFinite, maximumCoreDuration >= 30, maximumCoreDuration <= 300 else { throw AudioProcessingError.invalidInput }
        if outer.coreEnd - outer.coreStart <= maximumCoreDuration { return [outer] }
        let core = try AudioWindowPlanner.slices(outer.ranges,start:outer.coreStart,end:outer.coreEnd)
        let source = try AudioSourceSnapshot(id:outer.sourceID,capturedAt:Date(timeIntervalSinceReferenceDate:0),title:"",ranges:core,complete:true)
        return try AudioWindowPlanner.plan(source:source,configurationKey:outer.configurationKey,maximumCoreDuration:maximumCoreDuration).enumerated().map { index, part in
            AudioProcessingWindow(id:outer.id + ":inner:" + String(index),sourceID:outer.sourceID,configurationKey:outer.configurationKey,
                coreStart:part.coreStart,coreEnd:part.coreEnd,
                ranges:try AudioWindowPlanner.slices(outer.ranges,start:max(outer.inputStart,part.coreStart-2),end:min(outer.inputEnd,part.coreEnd+2)))
        }
    }
    static func process(window: AudioProcessingWindow, maximumCoreDuration: Double,
                        priorSpans: [AudioTranscriptSpan],
                        operation: (AudioProcessingWindow,[AudioTranscriptSpan]) async throws -> AudioInferenceDelta) async throws -> AudioInferenceDelta {
        let parts = try windows(window,maximumCoreDuration:maximumCoreDuration)
        if parts.count == 1 { return try await operation(parts[0],priorSpans) }
        var outcomes: [AudioWindowResult] = [], spans: [AudioTranscriptSpan] = [], activities: [AudioActivityInterval] = []
        var updates: [AudioTranscriptSpan] = [], evidence: [String:AudioSpeakerFeature] = [:]
        for (index, part) in parts.enumerated() {
            try Task.checkCancellation()
            let prior = priorSpans.filter { $0.start < part.inputEnd && $0.end > part.inputStart }
            let delta = try await operation(part,prior)
            let result = delta.result
            var labels: [String:String] = [:]
            let firstEvidence = evidence.isEmpty
            for feature in result.speakerFeatures {
                guard let vector = AudioSpeakerMapping.normalized(feature.vector) else { continue }
                let canonical = AudioSpeakerMapping.match(feature,candidates:evidence) ?? (firstEvidence ? "inner:\(index):\(feature.localSpeakerID)" : nil)
                if let canonical {
                    labels[feature.localSpeakerID] = canonical
                    if evidence[canonical] == nil { evidence[canonical] = .init(localSpeakerID:canonical,modelVersion:feature.modelVersion,vector:vector) }
                }
            }
            func mapped(_ values: [AudioTranscriptSpan]) -> [AudioTranscriptSpan] {
                values.map { span in var value = span; value.speakerID = span.speakerID.flatMap { labels[$0] }; return value }
            }
            outcomes.append(result); spans += mapped(result.spans); updates += mapped(delta.speakerSpanUpdates); activities += result.activities
        }
        func combined(_ key: KeyPath<AudioWindowResult,AudioAnalysisOutcome>) -> AudioAnalysisOutcome {
            let values = outcomes.map { $0[keyPath:key] }
            if values.allSatisfy({ $0 == .notRequested }) { return .notRequested }
            if values.allSatisfy({ $0 == .success }) { return .success }
            if values.contains(.missingResource) { return .missingResource }
            if values.contains(.cancelled) { return .cancelled }
            return .failed
        }
        let asr = combined(\.asr), vad = combined(\.vad), speaker = combined(\.speaker)
        // A failed inner analysis cannot claim full outer-stage success or coverage.
        if speaker != .success { spans = spans.map { var copy = $0; copy.speakerID = nil; return copy }; updates = [] }
        return .init(result:.init(spans:asr == .success ? spans : [],
            activities:vad == .success ? activities : (vad == .notRequested ? [] : [.init(start:window.coreStart,end:window.coreEnd,kind:.uncertain)]),
            asr:asr,vad:vad,speaker:speaker,
            asrCoverage:asr == .success ? outcomes.flatMap(\.asrCoverage) : [],
            vadCoverage:vad == .success ? outcomes.flatMap(\.vadCoverage) : [],
            speakerFeatures:speaker == .success ? evidence.keys.sorted().compactMap { evidence[$0] } : []),
            speakerSpanUpdates:speaker == .success ? updates : [])
    }
}
