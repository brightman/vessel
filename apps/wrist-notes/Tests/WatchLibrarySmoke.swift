import Foundation
@main struct WatchLibrarySmoke {
    static func main() {
        precondition(WatchRecordingLibrary.durationText(596) == "09:56")
        precondition(WatchRecordingLibrary.durationText(3661) == "01:01:01")
        precondition(WatchRecordingLibrary.durationText(.nan) == "00:00")
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        let now = Date(timeIntervalSince1970: 1_793_059_200)
        let today = calendar.startOfDay(for: now)
        let id = UUID()
        let start = today.addingTimeInterval(3600)
        let origin = RecordingOrigin(device: "Watch", deviceID: "fixture", fileName: "fixture", recordingTimeIsEstimated: false)
        let chunk = RecordingChunkDescriptor(id: UUID(), sessionID: id, ordinal: 0,
            sessionStartedAt: start, capturedAt: start, timeZoneIdentifier: calendar.timeZone.identifier,
            sessionStartOffset: 0, frameCount: 16000 * 120, sampleRate: 16000, byteCount: 100,
            sha256: String(repeating: "a", count: 64), origin: origin, location: nil)
        let pending = [PendingRecording(id: UUID(), kind: .thought, capturedAt: today.addingTimeInterval(60), duration: 17),
            PendingRecording(id: UUID(), kind: .long, capturedAt: today.addingTimeInterval(-60), duration: 90)]
        let end = RecordingSessionEnd(sessionID: id, finalOrdinal: 0, endedAt: start.addingTimeInterval(120), interrupted: false, revision: 0)
        let entries = WatchRecordingLibrary.entries(pending: pending, chunks: [chunk,chunk], ends: [end], activeID: nil, activeStartedAt: nil, elapsed: 0)
        precondition(entries.count == 3, "one recording per session, including legacy recordings")
        let summary = WatchRecordingLibrary.today(entries, now: now, calendar: calendar)
        precondition(summary.count == 2 && summary.duration == 137, "today statistics duplicated chunks or included yesterday")
        let active = WatchRecordingLibrary.entries(pending: [], chunks: [chunk], ends: [], activeID: id, activeStartedAt: start, elapsed: 150)
        precondition(active.count == 1 && active[0].duration == 150 && active[0].isActive, "active time added sealed duration twice")
        let unsealed = WatchRecordingLibrary.entries(pending: [], chunks: [], ends: [], activeID: id, activeStartedAt: start, elapsed: 4)
        precondition(unsealed.count == 1 && unsealed[0].duration == 4, "new recording hidden before first sealed chunk")
        print("Watch library: daily boundaries, legacy/session counting, deduplication and active duration passed")
    }
}
