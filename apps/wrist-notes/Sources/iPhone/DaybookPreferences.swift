import Combine
import Foundation

@MainActor
final class DaybookPreferences: ObservableObject {
    @Published var proactiveEnabled: Bool {
        didSet { defaults.set(proactiveEnabled, forKey: key("proactiveEnabled")) }
    }
    @Published var allowAudio: Bool {
        didSet { defaults.set(allowAudio, forKey: key("allowAudio")) }
    }
    @Published var allowPhotos: Bool {
        didSet { defaults.set(allowPhotos, forKey: key("allowPhotos")) }
    }
    @Published var allowHealth: Bool { didSet { defaults.set(allowHealth, forKey: key("allowHealth")) } }
    @Published var allowCalendar: Bool { didSet { defaults.set(allowCalendar, forKey: key("allowCalendar")) } }
    @Published var allowLocation: Bool { didSet { defaults.set(allowLocation, forKey: key("allowLocation")) } }
    func allows(_ kind: DayRecord.Kind) -> Bool {
        switch kind { case .voice, .thought: allowAudio; case .image: allowPhotos; case .activity, .sleep: allowHealth; case .calendar: allowCalendar; case .location: allowLocation }
    }
    var allowedKinds: Set<DayRecord.Kind> { Set([DayRecord.Kind.voice, .thought, .image, .activity, .sleep, .calendar, .location].filter(allows)) }
    @Published var quietEnabled: Bool {
        didSet { defaults.set(quietEnabled, forKey: key("quietEnabled")) }
    }
    @Published var quietStartMinutes: Int {
        didSet {
            let normalized = min(1439, max(0, quietStartMinutes))
            if quietStartMinutes != normalized { quietStartMinutes = normalized }
            defaults.set(quietStartMinutes, forKey: key("quietStartMinutes"))
        }
    }
    @Published var quietEndMinutes: Int {
        didSet {
            let normalized = min(1439, max(0, quietEndMinutes))
            if quietEndMinutes != normalized { quietEndMinutes = normalized }
            defaults.set(quietEndMinutes, forKey: key("quietEndMinutes"))
        }
    }
    @Published var dailySuggestionLimit: Int {
        didSet {
            let normalized = min(5, max(1, dailySuggestionLimit))
            if dailySuggestionLimit != normalized { dailySuggestionLimit = normalized }
            defaults.set(dailySuggestionLimit, forKey: key("dailySuggestionLimit"))
        }
    }

    private let defaults: UserDefaults
    private static let prefix = "daybook.preferences."

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        func bool(_ name: String, fallback: Bool) -> Bool {
            (defaults.object(forKey: Self.prefix + name) as? Bool) ?? fallback
        }
        func integer(_ name: String, fallback: Int, range: ClosedRange<Int>) -> Int {
            let value = (defaults.object(forKey: Self.prefix + name) as? Int) ?? fallback
            return min(range.upperBound, max(range.lowerBound, value))
        }
        proactiveEnabled = bool("proactiveEnabled", fallback: true)
        allowAudio = bool("allowAudio", fallback: true)
        allowPhotos = bool("allowPhotos", fallback: true)
        allowHealth = bool("allowHealth", fallback: false)
        allowCalendar = bool("allowCalendar", fallback: false)
        allowLocation = bool("allowLocation", fallback: false)
        quietEnabled = bool("quietEnabled", fallback: true)
        quietStartMinutes = integer("quietStartMinutes", fallback: 22 * 60, range: 0...1439)
        quietEndMinutes = integer("quietEndMinutes", fallback: 8 * 60, range: 0...1439)
        dailySuggestionLimit = integer("dailySuggestionLimit", fallback: 3, range: 1...5)
    }

    /// Quiet hours apply to in-app suggestions. Confirmed reminders keep the time the user chose.
    /// Equal start and end times mean a full day of quiet hours.
    func isQuiet(at date: Date) -> Bool {
        guard quietEnabled else { return false }
        let components = Calendar.current.dateComponents([.hour, .minute], from: date)
        let minute = (components.hour ?? 0) * 60 + (components.minute ?? 0)
        if quietStartMinutes == quietEndMinutes { return true }
        if quietStartMinutes < quietEndMinutes {
            return minute >= quietStartMinutes && minute < quietEndMinutes
        }
        return minute >= quietStartMinutes || minute < quietEndMinutes
    }

    private func key(_ name: String) -> String { Self.prefix + name }
}
