import Foundation
@main struct ActionSmoke {
    static func main() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:url) }
        let repo = try ActionRepository(database:DaybookDatabase(url:url.appendingPathComponent("actions.sqlite")))
        var task = ActionItem(kind:.todo,title:"写方案")
        try task.validate()
        task = try repo.save(task)
        let saved = try repo.load(); precondition(saved.count == 1)
        task.status = .completed; task = try repo.save(task)
        let completed = try repo.load(); precondition(completed.first?.status == .completed)
        var event = ActionItem(kind:.event,title:"讨论")
        event.start = Date.now
        do { try event.validate(); preconditionFailure("End is required") } catch is ActionFailure {}
        event.end = event.start!.addingTimeInterval(-60)
        do { try event.validate(); preconditionFailure("End before start") } catch is ActionFailure {}
        var reminder = ActionItem(kind:.reminder,title:"提醒")
        do { try reminder.validate(); preconditionFailure("Time required") } catch is ActionFailure {}
        reminder.start = Date.now.addingTimeInterval(3600); try reminder.validate()
        let source = ActionSource(id:UUID(),title:"闪念",quote:"明天写方案",capturedAt:.now,timeZoneID:"Asia/Shanghai")
        var draft = ActionItem(kind:.todo,title:"写方案",source:source); draft.status = .suggested
        let first = try repo.addSuggestion(draft)
        draft.id = UUID()
        let second = try repo.addSuggestion(draft)
        precondition(first.id == second.id)
        var edited = first; edited.title = "用户修改"; edited.status = .active; try repo.save(edited)
        let retained = try repo.addSuggestion(draft); precondition(retained.title == "用户修改")
        let reopened = try ActionRepository(database:DaybookDatabase(url:url.appendingPathComponent("actions.sqlite")))
        let restored = try reopened.load(); precondition(restored.count == 2)
        let stale = task
        task.title = "改名"; task = try repo.save(task)
        do { _ = try repo.save(stale); preconditionFailure("stale update") } catch ActionFailure.changed {}
        let json = "[{\"kind\":\"event\",\"title\":\"讨论\",\"sourceID\":\"\(source.id.uuidString)\",\"quote\":\"明天写方案\",\"start\":\"2026-10-24T14:00:00+08:00\",\"end\":null}]"
        let unknownZone = try ActionProposalParser.parse(json,sources:[source])
        precondition(unknownZone.first?.status == .suggested && unknownZone.first?.start == nil && unknownZone.first?.end == nil)
        var known = source; known.timeZoneKnown = true
        let parsed = try ActionProposalParser.parse(json,sources:[known])
        precondition(parsed.first?.start != nil && parsed.first?.end == nil)
        do { _ = try ActionProposalParser.parse(json.replacingOccurrences(of:"明天写方案",with:"捏造原话"),sources:[source]); preconditionFailure("ungrounded quote") } catch is ActionFailure {}
        print("Action persistence: undated tasks, validation, durable state, deduplication passed")
    }
}
