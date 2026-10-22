import Foundation

@main struct VoiceSpeechWindowsSmoke {
    static func main() throws {
        let turns = [SpeakerTurn(start:0,end:8,speaker:0), SpeakerTurn(start:3,end:5,speaker:1),
                     SpeakerTurn(start:8,end:10,speaker:0), SpeakerTurn(start:.nan,end:100,speaker:2)]
        let ranges = VoiceSpeechSelection.ranges(turns:turns, speaker:0, sampleCount:160_000)
        precondition(ranges.map(\.lowerBound) == [0,80_000])
        precondition(ranges.map(\.upperBound) == [48_000,160_000], "Overlap must not enter identity samples")
        let samples = (0..<160_000).map(Float.init)
        let windows = VoiceSpeechSelection.windows(samples:samples, ranges:ranges, limit:6)
        precondition(windows.count == 2 && windows[0].count == 80_000 && windows[1].count == 48_000)
        precondition(windows[0][48_000] == 80_000, "Gap must not enter concatenated clean speech")
        precondition(VoiceSpeechSelection.windows(samples:[Float](repeating:0,count:20_000),ranges:[0..<20_000],limit:6).isEmpty)
        let clipped = VoiceSpeechSelection.ranges(turns:[.init(start:0,end:1e100,speaker:0)],speaker:0,sampleCount:32_000)
        precondition(clipped == [0..<32_000], "Huge finite ranges must be clamped before integer conversion")
        do {
            _ = try VoiceSpeechSelection.enrollmentRanges(turns: [
                .init(start: 0, end: 30, speaker: 0), .init(start: 10, end: 20, speaker: 1)
            ], sampleCount: 30 * 16_000)
            preconditionFailure("A fully overlapping second voice must reject solo enrollment")
        } catch VoiceEnrollmentError.multipleVoices { }
        let solo = try VoiceSpeechSelection.enrollmentRanges(turns: [
            .init(start: 0, end: 30, speaker: 0), .init(start: 10, end: 20, speaker: 0)
        ], sampleCount: 30 * 16_000)
        precondition(solo == [[0..<(30 * 16_000)]], "Repeated turns of the same speaker must be merged")
        let fragments = try VoiceSpeechSelection.enrollmentRanges(turns: [
            .init(start: 0, end: 20, speaker: 0), .init(start: 20, end: 35, speaker: 1)
        ], sampleCount: 35 * 16_000)
        precondition(fragments == [[0..<(20 * 16_000)], [(20 * 16_000)..<(35 * 16_000)]],
                     "Sequential clusters must retain separate windows for voice consistency validation")
        do {
            _ = try VoiceSpeechSelection.enrollmentRanges(turns: [
                .init(start: 0, end: 30, speaker: 0), .init(start: 28.5, end: 31.5, speaker: 1)
            ], sampleCount: 35 * 16_000)
            preconditionFailure("A substantial speaker with too little clean speech must not be omitted")
        } catch VoiceEnrollmentError.insufficientSpeech { }
        print("Clean speech overlap, enrollment validation, clipping, windowing and short-input rejection passed")
    }
}
