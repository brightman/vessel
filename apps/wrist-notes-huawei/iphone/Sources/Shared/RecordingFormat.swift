import Foundation

enum RecordingFormat {
    static func duration(_ seconds: TimeInterval) -> String {
        let total = seconds.isFinite ? max(0, Int(seconds)) : 0
        if total >= 3600 {
            return String(format: "%d:%02d:%02d", total / 3600, total / 60 % 60, total % 60)
        }
        return String(format: "%02d:%02d", total / 60, total % 60)
    }

    static func date(_ date: Date) -> String {
        let time = date.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits))
        if Calendar.current.isDateInToday(date) { return "今天 \(time)" }
        if Calendar.current.isDateInYesterday(date) { return "昨天 \(time)" }
        return date.formatted(.dateTime.month(.defaultDigits).day(.defaultDigits)) + " " + time
    }
}
