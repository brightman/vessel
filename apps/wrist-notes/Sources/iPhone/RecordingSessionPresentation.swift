import Foundation

enum RecordingSessionPresentation {
    static func status(_ session: RecordingSessionSummary) -> String {
        if session.endRevision == nil { return "录音结束状态待同步" }
        if !session.syncComplete { return "部分录音尚未同步" }
        if session.interrupted { return "录音已中断" }
        return "完整录音"
    }

    static func records(_ sessions: [RecordingSessionSummary], legacyIDs: Set<UUID>) -> [DayRecord] {
        var seen = Set<UUID>()
        return sessions.compactMap { session in
            guard seen.insert(session.id).inserted,
                  session.legacyNoteID.map({ !legacyIDs.contains($0) }) ?? true,
                  let date = session.startedAt else { return nil }
            var record = DayRecord(id: session.id, capturedAt: date, kind: .voice, title: "完整录音", text: "",
                duration: session.recordedDuration,
                intervals: session.recordedIntervals.map { DateInterval(start: $0.start, end: $0.end) })
            record.recordingSessionID = session.id
            record.captureDevice = session.origin?.device
            record.location = session.location
            return record
        }
    }

    static func occupiedDates(_ sessions: [RecordingSessionSummary], within window: DateInterval,
                              calendar: Calendar = .current) -> [Date] {
        var dates = Set<Date>()
        for interval in sessions.flatMap(\.recordedIntervals) {
            let start = max(interval.start, window.start), end = min(interval.end, window.end)
            guard start < end else { continue }
            var day = calendar.startOfDay(for: start)
            while day < end {
                dates.insert(day)
                guard let next = calendar.date(byAdding: .day, value: 1, to: day), next > day else { break }
                day = next
            }
        }
        return dates.sorted()
    }
}
