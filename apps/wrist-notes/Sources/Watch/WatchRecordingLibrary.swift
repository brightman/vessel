import Foundation

struct WatchLibraryEntry: Identifiable, Equatable {
    let recordingID: UUID
    let isSession: Bool
    let kind: RecordingKind
    let startedAt: Date
    let duration: TimeInterval
    let isActive: Bool
    var id: String { (isSession ? "session:" : "recording:") + recordingID.uuidString }
    var title: String { kind == .thought ? "闪念" : "长录音" }
}

enum WatchRecordingLibrary {
    struct Summary: Equatable { let count: Int; let duration: TimeInterval }
    static func durationText(_ seconds: TimeInterval) -> String {
        let total = seconds.isFinite ? Int(min(359_999, max(0, seconds))) : 0
        if total < 3600 { return String(format: "%02d:%02d", total / 60, total % 60) }
        return String(format: "%02d:%02d:%02d", total / 3600, total / 60 % 60, total % 60)
    }
    static func entries(pending: [PendingRecording], chunks: [RecordingChunkDescriptor],
                        ends: [RecordingSessionEnd], activeID: UUID?, activeStartedAt: Date?,
                        elapsed: TimeInterval) -> [WatchLibraryEntry] {
        var result = pending.map {
            WatchLibraryEntry(recordingID: $0.id, isSession: false, kind: $0.kind,
                              startedAt: $0.capturedAt, duration: max(0, $0.duration), isActive: false)
        }
        let grouped = Dictionary(grouping: chunks, by: \.sessionID)
        let endMap = Dictionary(ends.map { ($0.sessionID, $0) }, uniquingKeysWith: { a, b in a.revision > b.revision ? a : b })
        let ids = Set(grouped.keys).union(endMap.keys).union([activeID].compactMap { $0 })
        for id in ids {
            let values = Dictionary((grouped[id] ?? []).map { ($0.ordinal, $0) },
                                    uniquingKeysWith: { a, _ in a }).values
            let start = values.map(\.sessionStartedAt).min() ??
                (id == activeID ? activeStartedAt : nil) ?? endMap[id]?.endedAt
            guard let start else { continue }
            let sealed = values.reduce(0.0) { $0 + $1.duration }
            result.append(.init(recordingID: id, isSession: true, kind: .long, startedAt: start,
                                duration: id == activeID ? max(sealed, elapsed) : sealed, isActive: id == activeID))
        }
        return result.sorted { $0.startedAt == $1.startedAt ? $0.id < $1.id : $0.startedAt > $1.startedAt }
    }
    static func today(_ entries: [WatchLibraryEntry], now: Date, calendar: Calendar = .current) -> Summary {
        let matching = entries.filter { calendar.isDate($0.startedAt, inSameDayAs: now) }
        return .init(count: matching.count, duration: matching.reduce(0) { $0 + $1.duration })
    }
}

struct WatchTransferPresentation: Equatable {
    enum Phase { case recording, saving, waiting, queued, sending, confirming, synced, failed, needsUpdate }
    let phase: Phase
    var fraction: Double? = nil
    var detail: String? = nil
    var title: String {
        switch phase {
        case .recording: return "录音中"
        case .saving: return "正在保存"
        case .waiting: return "等待手机"
        case .queued: return "等待传输"
        case .sending: return "传输中"
        case .confirming: return "等待手机确认"
        case .synced: return "已同步"
        case .failed: return "传输失败，可重试"
        case .needsUpdate: return "需更新手机 App"
        }
    }
    var step: Int {
        switch phase {
        case .recording, .saving, .waiting, .needsUpdate: return 0
        case .queued, .sending, .confirming, .failed: return 1
        case .synced: return 2
        }
    }
}
