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

        let sourceKeys = [first: "session:one", gap: "session:one", second: "session:one", third: "session:two"]
        precondition(RecordingMergeSelection.canAddSameSource(second, to: [first], orderedIDs: [first, second], eligibleIDs: [first, second], sourceKeys: sourceKeys),
                     "adjacent meaningful final segments from one recording can be selected")
        precondition(!RecordingMergeSelection.canAddSameSource(third, to: [second], orderedIDs: [second, third], eligibleIDs: [second, third], sourceKeys: sourceKeys),
                     "adjacent segments from different recordings cannot be selected")
        precondition(!RecordingMergeSelection.canAddSameSource(second, to: [first], orderedIDs: [first, gap, second], eligibleIDs: [first, second], sourceKeys: sourceKeys),
                     "a hidden final segment remains an adjacency blocker")
        precondition(!RecordingMergeSelection.canAddSameSource(gap, to: [first], orderedIDs: [first, gap], eligibleIDs: [first, gap], sourceKeys: [:]),
                     "a raw-recording item cannot enter content-segment selection")
        precondition(RecordingMergeSelection.canMergeSameSource([first, second], orderedIDs: [first, second], eligibleIDs: [first, second], sourceKeys: sourceKeys),
                     "same-source adjacent final segments can be merged")
        precondition(!RecordingMergeSelection.canMergeSameSource([second, third], orderedIDs: [second, third], eligibleIDs: [second, third], sourceKeys: sourceKeys),
                     "different-source segments cannot reach merge confirmation")
        precondition(!RecordingMergeSelection.canMergeSameSource([first, second], orderedIDs: [first, gap, second], eligibleIDs: [first, second], sourceKeys: sourceKeys),
                     "hidden intermediate segments prevent a nonadjacent merge")

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
