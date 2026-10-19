import Foundation

private func expect(_ condition: Bool, _ message: String) {
    if !condition { fatalError(message) }
}

@main
struct DaybookSuggestionSmoke {
    @MainActor
    static func main() {
        let suite = "daybook-suggestions-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = DaybookPreferences(defaults: defaults)
        preferences.quietEnabled = false
        preferences.dailySuggestionLimit = 2
        let calendar = Calendar.current
        let now = calendar.date(from: DateComponents(year: 2026, month: 10, day: 19, hour: 12))!
        let today = calendar.startOfDay(for: now)
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: now)!
        func record(_ title: String, minutes: Int, kind: DayRecord.Kind = .voice, id: UUID = UUID(), date: Date? = nil, text: String? = nil) -> DayRecord {
            DayRecord(id: id, capturedAt: date ?? today.addingTimeInterval(Double(minutes) * 60), kind: kind,
                      title: title, text: text ?? "原始文字：\(title)", summary: "不应使用这段总结")
        }
        let oldest = record("晨间想法", minutes: 480, kind: .thought)
        let middle = record("照片说明", minutes: 540, kind: .image)
        let newest = record("工作记录", minutes: 600)
        let records = [oldest, newest, middle]
        let store = DaybookSuggestionStore(defaults: defaults)
        expect(store.visibleCandidate(records: records, preferences: preferences, now: now) == nil, "pure read must not choose or consume a card")
        store.synchronize(records: records, preferences: preferences, now: now)
        expect(store.activeRecordID == newest.id, "latest original record is selected regardless of input order")
        store.synchronize(records: records, preferences: preferences, now: now)
        expect(store.visibleCandidate(records: records, preferences: preferences, now: now)?.id == newest.id, "repeated synchronization preserves current")

        store.advance(records: records, preferences: preferences, now: now)
        expect(store.activeRecordID == middle.id, "advance chooses next distinct record")
        let reopened = DaybookSuggestionStore(defaults: defaults)
        reopened.synchronize(records: records, preferences: preferences, now: now)
        expect(reopened.activeRecordID == middle.id, "active card survives relaunch at daily cap")
        reopened.advance(records: records, preferences: preferences, now: now)
        expect(reopened.activeRecordID == nil && reopened.visibleCandidate(records: records, preferences: preferences, now: now) == nil, "daily distinct-card limit survives relaunch")
        let afterLimit = DaybookSuggestionStore(defaults: defaults)
        afterLimit.synchronize(records: records, preferences: preferences, now: now)
        expect(afterLimit.activeRecordID == nil, "reopen cannot reset daily budget")

        // New day starts a new budget; yesterday's records are never carried into it.
        let nextDayRecord = record("次日记录", minutes: 0, date: tomorrow.addingTimeInterval(-60))
        afterLimit.synchronize(records: records + [nextDayRecord], preferences: preferences, now: tomorrow)
        expect(afterLimit.activeRecordID == nextDayRecord.id, "day rollover selects only today's records with a fresh budget")

        // Snooze retains the selected record and its already-consumed slot.
        let snoozedUntil = tomorrow.addingTimeInterval(3600)
        afterLimit.snooze(until: snoozedUntil)
        expect(afterLimit.activeRecordID == nil, "snooze immediately hides current card")
        let afterSnooze = DaybookSuggestionStore(defaults: defaults)
        afterSnooze.synchronize(records: [nextDayRecord], preferences: preferences, now: tomorrow.addingTimeInterval(1800))
        expect(afterSnooze.activeRecordID == nil, "snooze survives relaunch")
        afterSnooze.synchronize(records: [nextDayRecord], preferences: preferences, now: snoozedUntil)
        expect(afterSnooze.activeRecordID == nextDayRecord.id, "snooze expiry resumes same card without consuming another slot")
        let secondNextDay = record("次日第二条", minutes: 0, date: tomorrow.addingTimeInterval(-120))
        afterSnooze.advance(records: [nextDayRecord, secondNextDay], preferences: preferences, now: snoozedUntil)
        expect(afterSnooze.activeRecordID == secondNextDay.id, "resuming did not double count daily budget")

        preferences.dailySuggestionLimit = 1
        afterSnooze.synchronize(records: [nextDayRecord, secondNextDay], preferences: preferences, now: snoozedUntil)
        expect(afterSnooze.activeRecordID == secondNextDay.id, "lowering limit preserves the existing card")
        afterSnooze.advance(records: [nextDayRecord, secondNextDay, oldest], preferences: preferences, now: snoozedUntil)
        expect(afterSnooze.activeRecordID == nil, "lowering limit cannot permit another candidate")

        defaults.removeObject(forKey: "daybook.suggestions.state")
        preferences.dailySuggestionLimit = 5
        let privacy = DaybookSuggestionStore(defaults: defaults)
        preferences.proactiveEnabled = false
        privacy.synchronize(records: records, preferences: preferences, now: now)
        expect(privacy.activeRecordID == nil, "disabled proactive mode consumes no card")
        preferences.proactiveEnabled = true
        preferences.quietEnabled = true
        preferences.quietStartMinutes = 12 * 60
        preferences.quietEndMinutes = 13 * 60
        privacy.synchronize(records: records, preferences: preferences, now: now)
        expect(privacy.activeRecordID == nil, "quiet hours never create a new card")
        privacy.synchronize(records: records, preferences: preferences, now: now.addingTimeInterval(3600))
        expect(privacy.activeRecordID == newest.id, "quiet end permits selection")
        preferences.proactiveEnabled = false
        expect(privacy.visibleCandidate(records: records, preferences: preferences, now: now.addingTimeInterval(3600)) == nil, "pure read immediately hides a disabled card")
        privacy.synchronize(records: records, preferences: preferences, now: now.addingTimeInterval(3600))
        expect(privacy.activeRecordID == nil, "published active ID hides when disabled")
        preferences.proactiveEnabled = true
        privacy.synchronize(records: records, preferences: preferences, now: now.addingTimeInterval(3600))
        expect(privacy.activeRecordID == newest.id, "re-enabled suggestions resume the existing card")
        privacy.synchronize(records: records, preferences: preferences, now: now)
        expect(privacy.activeRecordID == nil, "quiet hours hide even an existing card")
        preferences.quietEnabled = false
        privacy.synchronize(records: records, preferences: preferences, now: now)
        expect(privacy.activeRecordID == newest.id, "leaving quiet hours restores current card")

        preferences.allowAudio = false
        expect(privacy.visibleCandidate(records: records, preferences: preferences, now: now) == nil, "source revocation immediately prevents use")
        privacy.synchronize(records: records, preferences: preferences, now: now)
        expect(privacy.activeRecordID == middle.id, "revoked audio is replaced only by an allowed photo")
        preferences.allowPhotos = false
        privacy.synchronize(records: records, preferences: preferences, now: now)
        expect(privacy.activeRecordID == nil, "revoking all sources hides all cards")

        defaults.removeObject(forKey: "daybook.suggestions.state")
        preferences.allowAudio = true
        preferences.allowPhotos = true
        let mutations = DaybookSuggestionStore(defaults: defaults)
        mutations.synchronize(records: records, preferences: preferences, now: now)
        let edited = record(newest.title, minutes: 600, id: newest.id, text: "已经修改的正文")
        expect(mutations.visibleCandidate(records: [edited], preferences: preferences, now: now) == nil, "changed original text invalidates visible content immediately")
        let afterEdit = DaybookSuggestionStore(defaults: defaults)
        afterEdit.synchronize(records: [edited, middle, oldest], preferences: preferences, now: now)
        expect(afterEdit.activeRecordID == middle.id, "text signature survives restart and changed record is not shown twice")
        expect(afterEdit.visibleCandidate(records: [oldest], preferences: preferences, now: now) == nil, "deleted record cannot remain visible")
        afterEdit.synchronize(records: [oldest], preferences: preferences, now: now)
        expect(afterEdit.activeRecordID == oldest.id, "deletion permits another unseen allowed record")
        afterEdit.dismissToday(now: now)
        let afterDismiss = DaybookSuggestionStore(defaults: defaults)
        afterDismiss.synchronize(records: records, preferences: preferences, now: now)
        expect(afterDismiss.activeRecordID == nil, "dismiss-today persists across relaunch")
        afterDismiss.synchronize(records: [nextDayRecord], preferences: preferences, now: tomorrow)
        expect(afterDismiss.activeRecordID == nextDayRecord.id, "dismiss-today expires at day rollover")
        afterDismiss.snooze(until: tomorrow.addingTimeInterval(172800))
        let thirdDay = calendar.date(byAdding: .day, value: 1, to: tomorrow)!
        let thirdDayRecord = record("第三天", minutes: 0, date: thirdDay.addingTimeInterval(-60))
        afterDismiss.synchronize(records: [thirdDayRecord], preferences: preferences, now: thirdDay)
        expect(afterDismiss.activeRecordID == thirdDayRecord.id, "day rollover clears even a long snooze")

        defaults.removeObject(forKey: "daybook.suggestions.state")
        let invalid = DaybookSuggestionStore(defaults: defaults)
        let empty = record("仅有总结", minutes: 660, text: " \n")
        let future = record("未来记录", minutes: 780)
        let yesterday = record("昨天", minutes: 0, date: today.addingTimeInterval(-60))
        invalid.synchronize(records: [empty, future, yesterday], preferences: preferences, now: now)
        expect(invalid.activeRecordID == nil, "empty original text, future dates and other-day records are excluded")
        invalid.synchronize(records: records, preferences: preferences, now: now)
        let stored = defaults.data(forKey: "daybook.suggestions.state")!
        let storedText = String(data: stored, encoding: .utf8)!
        expect(stored.count < 4096 && !storedText.contains(newest.text) && !storedText.contains(newest.title) && !storedText.contains(newest.summary), "bounded persistence contains no raw record content")
        print("Daybook suggestions: daily caps, quiet/off gating, source revocation, edits/deletions, rollover, snooze, dismissal, relaunch and bounded content-free state passed")
    }
}
