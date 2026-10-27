import Foundation

/// Local labels are only evidence keys. Matching uses compatible, normalized features.
enum AudioSpeakerMapping {
    /// Apply only labels to exact retained source rows, avoiding timestamp round-trip drift.
    static func annotating(_ spans: [AudioTranscriptSpan], speakerIDs: [String?]) throws -> [AudioTranscriptSpan] {
        guard spans.count == speakerIDs.count else { throw AudioProcessingError.invalidInput }
        return zip(spans,speakerIDs).map { original, speakerID in
            var annotated = original
            annotated.speakerID = speakerID
            return annotated
        }
    }

    // Conservative uncalibrated policy; ambiguous evidence stays unknown.
    static let minimumSimilarity: Double = 0.90
    static let minimumMargin: Double = 0.10
    /// Long recordings are diarized in bounded windows; total source duration is not a cap.
    static func permitsAnalysis(sourceDuration: Double?) -> Bool {
        guard let sourceDuration, sourceDuration.isFinite, sourceDuration > 0 else { return false }
        return true
    }
    static func normalized(_ values: [Float]) -> [Float]? {
        guard !values.isEmpty, values.count <= 4096, values.allSatisfy(\.isFinite) else { return nil }
        let norm = sqrt(values.reduce(0.0) { $0 + Double($1)*Double($1) })
        guard norm.isFinite, norm > 1e-8 else { return nil }
        return values.map { Float(Double($0)/norm) }
    }
    /// Candidate keys are established session speaker IDs, never window-local speaker numbers.
    static func match(_ feature: AudioSpeakerFeature, candidates: [String:AudioSpeakerFeature]) -> String? {
        guard !feature.modelVersion.isEmpty, let vector = normalized(feature.vector) else { return nil }
        let ranked: [(String,Double)] = candidates.compactMap { key, candidate in
            guard candidate.modelVersion == feature.modelVersion, candidate.vector.count == vector.count,
                  let other = normalized(candidate.vector) else { return nil }
            return (key,zip(vector,other).reduce(0.0) { $0 + Double($1.0)*Double($1.1) })
        }.sorted { $0.1 > $1.1 }
        guard let best = ranked.first, best.1 >= minimumSimilarity,
              ranked.count == 1 || best.1-ranked[1].1 >= minimumMargin else { return nil }
        return best.0
    }
}
