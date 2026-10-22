import Foundation

enum RecordingFormat {
    static func duration(_ seconds: TimeInterval, language: String? = nil) -> String {
        let total = wholeSeconds(seconds)
        let hour = total / 3600, minute = total / 60 % 60, second = total % 60
        switch language ?? UserDefaults.standard.string(forKey: "interfaceLanguage") ?? "zh-Hans" {
        case "en": return "\(hour)h \(minute)m \(second)s"
        case "ja": return "\(hour)時間\(minute)分\(second)秒"
        default: return "\(hour)小时\(minute)分\(second)秒"
        }
    }

    /// Transcript offsets are navigation timestamps, separate from recording durations.
    static func timecode(_ seconds: TimeInterval) -> String {
        let total = wholeSeconds(seconds)
        if total >= 3600 {
            return String(format: "%d:%02d:%02d", total / 3600, total / 60 % 60, total % 60)
        }
        return String(format: "%02d:%02d", total / 60, total % 60)
    }

    private static func wholeSeconds(_ seconds: TimeInterval) -> Int {
        guard seconds.isFinite, seconds > 0 else { return 0 }
        return seconds >= Double(Int.max) ? Int.max : Int(seconds)
    }

    static func date(_ date: Date) -> String {
        let time = date.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits))
        if Calendar.current.isDateInToday(date) { return "今天 \(time)" }
        if Calendar.current.isDateInYesterday(date) { return "昨天 \(time)" }
        return date.formatted(.dateTime.month(.defaultDigits).day(.defaultDigits)) + " " + time
    }
}

/// SwiftUI's TimeDataSource uses these boundaries to update without per-second ActivityKit pushes.
@available(iOS 18.0, macOS 15.0, watchOS 11.0, *)
struct RecordingElapsedFormatStyle: DiscreteFormatStyle {
    let startedAt: Date
    var language = "zh-Hans"

    func format(_ value: Date) -> String {
        RecordingFormat.duration(value.timeIntervalSince(startedAt), language: language)
    }

    func discreteInput(after input: Date) -> Date? {
        let elapsed = input.timeIntervalSince(startedAt)
        guard elapsed.isFinite else { return nil }
        return startedAt.addingTimeInterval(max(0, floor(elapsed)) + 1)
    }

    func discreteInput(before input: Date) -> Date? {
        let elapsed = input.timeIntervalSince(startedAt)
        guard elapsed.isFinite, elapsed >= 1 else { return nil }
        let boundary = startedAt.addingTimeInterval(floor(elapsed)).timeIntervalSinceReferenceDate
        return Date(timeIntervalSinceReferenceDate: boundary.nextDown)
    }
}
