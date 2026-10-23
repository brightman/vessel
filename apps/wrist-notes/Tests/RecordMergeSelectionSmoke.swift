import Foundation

@main
struct RecordMergeSelectionSmoke {
    static func main() {
        let first = UUID()
        let gap = UUID()
        let second = UUID()
        let third = UUID()
        let order = [first, gap, second, third]
        let eligible: Set<UUID> = [first, second, third]

        precondition(!RecordingMergeSelection.canMerge([first, second], orderedIDs: order, eligibleIDs: eligible),
                     "a non-recording row between two long recordings breaks adjacency")
        precondition(!RecordingMergeSelection.canAdd(second, to: [first], orderedIDs: order, eligibleIDs: eligible),
                     "selection cannot skip a row")
        precondition(RecordingMergeSelection.canMerge([second, third], orderedIDs: order, eligibleIDs: eligible),
                     "adjacent long recordings can merge")
        precondition(!RecordingMergeSelection.canMerge([second], orderedIDs: order, eligibleIDs: eligible),
                     "at least two recordings are required")
        precondition(!RecordingMergeSelection.canAdd(gap, to: [], orderedIDs: order, eligibleIDs: eligible),
                     "non-long recordings cannot be selected")
        precondition(RecordingMergeSelection.canAdd(first, to: [first], orderedIDs: order, eligibleIDs: eligible),
                     "a selected recording can always be deselected")
        precondition(RecordingMergeSelection.orderedSelection([third, second], orderedIDs: order, eligibleIDs: eligible) == [second, third],
                     "selected items keep their timeline order")
        precondition(!RecordingMergeSelection.canMerge([second, third], orderedIDs: [second, second, third], eligibleIDs: eligible),
                     "ambiguous duplicate rows cannot be merged")

        let sourceOrigin = RecordingOrigin(device: "Apple Watch", deviceID: "watch-se", fileName: "watch-part.m4a", recordingTimeIsEstimated: false)
        var mergedNote = VoiceNote(id: UUID(), kind: .long, capturedAt: .now, duration: 12)
        mergedNote.mergedSources = [MergedRecordingSource(recordingID: first, capturedAt: .now, duration: 12, origin: sourceOrigin)]
        let encoded = try! JSONEncoder().encode(mergedNote)
        let decoded = try! JSONDecoder().decode(VoiceNote.self, from: encoded)
        precondition(decoded.mergedSources?.first?.origin?.device == "Apple Watch",
                     "merged notes retain the original audio source metadata")
        var legacyPayload = try! JSONSerialization.jsonObject(with: encoded) as! [String: Any]
        legacyPayload.removeValue(forKey: "mergedSources")
        let legacyNote = try! JSONDecoder().decode(VoiceNote.self, from: JSONSerialization.data(withJSONObject: legacyPayload))
        precondition(legacyNote.mergedSources == nil, "older note payloads remain readable without merged source metadata")

        print("RecordMergeSelectionSmoke passed")
    }
}
