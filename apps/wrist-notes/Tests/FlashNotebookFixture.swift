import Foundation

/// Synthetic UI fixture. Run only against a dedicated Simulator app container.
@main struct FlashNotebookFixture {
    static func main() throws {
        guard CommandLine.arguments.count == 2 else { fatalError("Supply a dedicated Simulator data container") }
        let container = URL(fileURLWithPath: CommandLine.arguments[1])
        guard container.path.contains("CoreSimulator/Devices/") else { fatalError("Fixture is Simulator-only") }
        let db = try DaybookDatabase(url: container.appendingPathComponent("Library/Application Support/WristNotes/Database/daybook.sqlite3"))
        let repo = try FlashCaptureRepository(database: db)
        let source = ActionSource(id: UUID(uuidString: "5D82B520-9A64-4C03-985D-C54EC31B7111")!, title: "闪念 · 测试想法与账目",
            quote: "记个想法，做一个按人回顾的入口，把过去与同一个人讨论过的片段放在一起。今天午餐花了35元人民币。", capturedAt: .now,
            timeZoneID: "Asia/Shanghai", recordingKind: "thought", timeZoneKnown: true, device: "Apple Watch")
        let json = #"{"items":[{"kind":"idea","title":"按人回顾","text":"做一个按人回顾的入口，把过去与同一个人讨论过的片段放在一起。","quote":"记个想法，做一个按人回顾的入口，把过去与同一个人讨论过的片段放在一起。"},{"kind":"expense","title":"午餐","quote":"今天午餐花了35元人民币。","direction":"expense","amount":"35","currency":"CNY","category":"餐饮","date":"2026-10-31"}]}"#
        try repo.commit(FlashCaptureParser.parse(json, source: source), source: source)
        var second = source; second.id = UUID(uuidString: "5D82B520-9A64-4C03-985D-C54EC31B7112")!; second.capturedAt = source.capturedAt.addingTimeInterval(-3600)
        second.quote = "访谈时先听用户讲经历，再问观点。"
        try repo.commit(.init(assets: [FlashAsset(kind: .idea, title: "访谈顺序", text: second.quote, source: second)]), source: second)
        var missing = source; missing.id = UUID(uuidString: "5D82B520-9A64-4C03-985D-C54EC31B7113")!; missing.quote = "记一下买了咖啡。"
        try repo.commit(.init(assets: [FlashAsset(kind: .expense, title: "咖啡", text: missing.quote, source: missing, direction: .expense, currency: "CNY", category: "餐饮", date: "2026-10-31")]), source: missing)
        let actionRepo = try ActionRepository(database: db)
        let existing = try actionRepo.load()
        let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: source.capturedAt)!
        for (suffix, kind, title) in [("21", ActionItem.Kind.todo, "画出按人回顾的草图"), ("22", .reminder, "给林茜打电话"), ("23", .event, "和林茜讨论按人回顾")] {
            let id = UUID(uuidString: "5D82B520-9A64-4C03-985D-C54EC31B71" + suffix)!
            var action = ActionItem(id: id, kind: kind, title: title, source: source)
            action.dedupKey = "flash|synthetic|" + suffix; action.sync = .local
            action.timeZoneID = "Asia/Shanghai"; action.flashCalendarDestinationChosen = true
            if kind != .todo { action.start = tomorrow }
            if kind == .event { action.end = tomorrow.addingTimeInterval(1800) }
            action.source?.quote = "用于界面验证的虚构指令：" + title
            action.revision = existing.first { $0.id == id }?.revision ?? 0
            _ = try actionRepo.save(action)
        }
        var incomplete = ActionItem(id: UUID(uuidString: "5D82B520-9A64-4C03-985D-C54EC31B7124")!, kind: .reminder, title: "给林茜发草图", source: missing)
        incomplete.dedupKey = "flash|synthetic|24"; incomplete.sync = .failed; incomplete.syncError = "尚未指定提醒时间，补充后安排。"
        incomplete.revision = existing.first { $0.id == incomplete.id }?.revision ?? 0
        _ = try actionRepo.save(incomplete)
        for origin in [source, missing] {
        var note = VoiceNote(id: origin.id, kind: .thought, capturedAt: origin.capturedAt, duration: 78)
        note.title = origin.title; note.transcript = origin.quote; note.transcriptionState = .ready; note.summaryState = .ready
        note.origin = RecordingOrigin(device: "Apple Watch", deviceID: "synthetic", fileName: note.audioFilename, recordingTimeIsEstimated: false, timeZoneIdentifier: "Asia/Shanghai")
        try db.execute("INSERT OR REPLACE INTO voice_notes(id,captured_at,kind,title,transcript,summary,duration,audio_filename,payload) VALUES(?,?,?,?,?,?,?,?,?)", [.text(note.id.uuidString), .real(note.capturedAt.timeIntervalSinceReferenceDate), .text(note.kind.rawValue), .text(note.title), .text(note.transcript), .text(""), .real(78), .text(note.audioFilename), try DaybookDatabase.json(note)])
        }
        try repo.seedHistory([source.id, second.id, missing.id])
        print("Synthetic notebook fixture installed. Fictional result states only; no audio or real system actions created.")
    }
}
