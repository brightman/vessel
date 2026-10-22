import Combine
import CryptoKit
import Foundation

/// Local review cards point to original records; this store never generates or saves record text.
@MainActor
final class DaybookSuggestionStore: ObservableObject {
    @Published private(set) var activeRecordID: UUID?

    private struct Selection: Codable, Equatable {
        let id: UUID
        let fingerprint: String
    }

    private struct State: Codable, Equatable {
        var day: Date
        var shownIDs: [UUID] = []
        var active: Selection?
        var snoozedUntil: Date?
        var dismissed = false

        var isValid: Bool {
            day.timeIntervalSince1970.isFinite &&
            shownIDs.count <= 5 && Set(shownIDs).count == shownIDs.count &&
            (snoozedUntil?.timeIntervalSince1970.isFinite ?? true) &&
            (active.map { shownIDs.contains($0.id) && $0.fingerprint.count == 64 && $0.fingerprint.allSatisfy(\.isHexDigit) } ?? true)
        }
    }

    private static let storageKey = "daybook.suggestions.state"
    private let defaults: UserDefaults
    private var state: State

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.storageKey), data.count <= 4096,
           let saved = try? JSONDecoder().decode(State.self, from: data), saved.isValid {
            state = saved
        } else {
            state = State(day: Calendar.current.startOfDay(for: .now))
        }
        // Do not expose a persisted selection until its current source and permissions are checked.
        activeRecordID = nil
    }

    /// Pure read: safe during SwiftUI rendering. This cannot consume a suggestion slot.
    func visibleCandidate(records: [DayRecord], preferences: DaybookPreferences, now: Date = .now) -> DayRecord? {
        guard state.day == Calendar.current.startOfDay(for: now),
              canShow(preferences: preferences, now: now) else { return nil }
        return currentRecord(in: records, preferences: preferences, now: now)
    }

    /// Call when records, preferences or the foreground clock changes. Distinct cards consume at
    /// most one slot per local day; resuming the current card never consumes another slot.
    func synchronize(records: [DayRecord], preferences: DaybookPreferences, now: Date = .now) {
        let previous = state
        resetDayIfNeeded(now)
        if state.active != nil && currentRecord(in: records, preferences: preferences, now: now) == nil {
            state.active = nil
        }
        if canShow(preferences: preferences, now: now), state.active == nil,
           state.shownIDs.count < preferences.dailySuggestionLimit {
            let candidate = records.filter {
                isAllowed($0, preferences: preferences, now: now) && !state.shownIDs.contains($0.id)
            }.sorted {
                $0.capturedAt == $1.capturedAt ? $0.id.uuidString < $1.id.uuidString : $0.capturedAt > $1.capturedAt
            }.first
            if let candidate {
                state.active = Selection(id: candidate.id, fingerprint: fingerprint(candidate))
                state.shownIDs.append(candidate.id)
            }
        }
        if state != previous { persist() }
        publish(visibleCandidate(records: records, preferences: preferences, now: now)?.id)
    }

    func advance(records: [DayRecord], preferences: DaybookPreferences, now: Date = .now) {
        resetDayIfNeeded(now)
        state.active = nil
        state.snoozedUntil = nil
        persist()
        synchronize(records: records, preferences: preferences, now: now)
    }

    func snooze(until date: Date) {
        guard state.active != nil, date.timeIntervalSince1970.isFinite else { return }
        state.snoozedUntil = date
        persist()
        publish(nil)
    }

    func dismissToday(now: Date = .now) {
        resetDayIfNeeded(now)
        state.dismissed = true
        state.active = nil
        state.snoozedUntil = nil
        persist()
        publish(nil)
    }

    private func resetDayIfNeeded(_ now: Date) {
        let day = Calendar.current.startOfDay(for: now)
        if state.day != day { state = State(day: day) }
    }

    private func canShow(preferences: DaybookPreferences, now: Date) -> Bool {
        preferences.proactiveEnabled && !preferences.isQuiet(at: now) && !state.dismissed &&
        (state.snoozedUntil.map { now >= $0 } ?? true)
    }

    private func isAllowed(_ record: DayRecord, preferences: DaybookPreferences, now: Date) -> Bool {
        let allowedSource = preferences.allows(record.kind)
        return allowedSource && record.capturedAt <= now &&
            Calendar.current.isDate(record.capturedAt, inSameDayAs: now) &&
            !record.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func currentRecord(in records: [DayRecord], preferences: DaybookPreferences, now: Date) -> DayRecord? {
        guard let selected = state.active,
              let record = records.first(where: { $0.id == selected.id }),
              isAllowed(record, preferences: preferences, now: now),
              fingerprint(record) == selected.fingerprint else { return nil }
        return record
    }

    private func fingerprint(_ record: DayRecord) -> String {
        // Hash only source identity/content, never a generated summary. Incremental hashing avoids
        // an additional large concatenated copy of a long transcript.
        var hash = SHA256()
        for part in [record.kind.rawValue, String(record.capturedAt.timeIntervalSince1970), record.title, record.text] {
            hash.update(data: Data(String(part.utf8.count).utf8))
            hash.update(data: Data([0]))
            hash.update(data: Data(part.utf8))
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(state), data.count <= 4096 else { return }
        defaults.set(data, forKey: Self.storageKey)
    }

    private func publish(_ id: UUID?) {
        if activeRecordID != id { activeRecordID = id }
    }
}
