import Foundation

@main struct NotebookLedgerSmoke {
    static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("notebook.sqlite3")
        let db = try DaybookDatabase(url: url)
        let source = ActionSource(id: UUID(), title: "闪念", quote: "午餐", capturedAt: ISO8601DateFormatter().date(from:"2026-10-31T18:00:00Z")!, timeZoneID:"Asia/Shanghai", recordingKind:"thought", timeZoneKnown:true)
        // Existing installations have v1 payloads and no month column.
        try db.migrate("flash-notebook-v1") {
            try db.execute("CREATE TABLE flash_batches(source_id TEXT PRIMARY KEY,payload BLOB NOT NULL)")
            try db.execute("CREATE TABLE flash_assets(id TEXT PRIMARY KEY,source_id TEXT NOT NULL,kind TEXT NOT NULL,captured_at REAL NOT NULL,revision INTEGER NOT NULL,revoked INTEGER NOT NULL,ready INTEGER NOT NULL,currency TEXT,direction TEXT,amount_minor INTEGER,payload BLOB NOT NULL)")
        }
        let legacy = FlashAsset(kind:.expense,title:"午餐",text:"午餐",source:source,direction:.expense,amountMinor:3500,currency:"CNY",date:"2026-10-31")
        try db.execute("INSERT INTO flash_assets VALUES(?,?,?,?,?,?,?,?,?,?,?)",[.text(legacy.id.uuidString),.text(source.id.uuidString),.text("expense"),.real(source.capturedAt.timeIntervalSinceReferenceDate),.integer(0),.integer(0),.integer(1),.text("CNY"),.text("expense"),.integer(3500),try DaybookDatabase.json(legacy)])
        let repo = try FlashCaptureRepository(database:db)
        try check(repo.totals(month:"2026-10") == [.init(currency:"CNY",income:0,expense:3500)],"legacy migration by expense date")
        var edited=try repo.assets(kind:.expense,month:"2026-10").first!
        edited.date="2026-11-01"; edited=try repo.save(edited)
        try check(repo.totals(month:"2026-10").isEmpty,"moving month removes old totals")
        let pending=FlashAsset(kind:.expense,title:"待补充",text:"待补充",source:source)
        _=try repo.save(pending)
        let income=FlashAsset(kind:.expense,title:"收入",text:"收入",source:source,direction:.income,amountMinor:1200,currency:"USD",date:"2026-11-02")
        _=try repo.save(income)
        try check(repo.assets(kind:.expense,month:"2026-11",pendingOnly:true).count == 1,"missing date uses capture local month")
        try check(repo.totals(month:"2026-11").count == 2,"currency isolation")
        edited.revoked=true; _=try repo.save(edited)
        try check(repo.totals(month:"2026-11") == [.init(currency:"USD",income:1200,expense:0)],"revoked and incomplete excluded")
        try check(repo.assets(kind:.expense,month:"2026-11",currency:"USD",direction:.income).count == 1,"ledger filters")
        let reopened=try FlashCaptureRepository(database:DaybookDatabase(url:url))
        try check(reopened.assets(kind:.expense,month:"2026-11",limit:1,offset:1).count == 1,"pagination after reopen")
        try check(reopened.months().contains("2026-11"),"persisted months")
        let idea=FlashAsset(kind:.idea,title:"灵感",text:"一个想法",source:source)
        _=try repo.save(idea)
        let second=FlashAsset(kind:.idea,title:"灵感2",text:"另一个想法",source:source)
        _=try repo.save(second)
        let seeds=try repo.assets(kind:.idea)
        let context=try NotebookIdeaGeneration.context(seeds,direction:"组合出新的方向")
        try check(context.contains("一个想法"),"selected text is included")
        do { _=try NotebookIdeaGeneration.context([seeds[0]],direction:""); throw TestFailure.failed("one seed accepted") } catch is ActionFailure {}
        let candidates=try NotebookIdeaGeneration.parse("{\"ideas\":[{\"title\":\"新方向\",\"text\":\"合成内容\"}]}")
        do { _=try NotebookIdeaGeneration.parse("{\"ideas\":[{\"title\":\"\",\"text\":\"\"}]}"); throw TestFailure.failed("empty AI output accepted") } catch is ActionFailure {}
        let drafts=try NotebookIdeaRepository(database:db)
        var draft=NotebookIdeaDraft(seeds:seeds,direction:"组合",candidates:candidates)
        try drafts.save(draft)
        let accepted=try drafts.accept(draftID:draft.id,candidateIDs:Set(candidates.map(\.id)))
        try check(accepted.count == 1 && accepted[0].parentIdeas?.count == 2,"new idea keeps seed snapshots")
        try check(accepted[0].text == "合成内容","generated content saved")
        try check(drafts.accept(draftID:draft.id,candidateIDs:Set(candidates.map(\.id))).count == 0,"repeat accept is idempotent")
        draft=try drafts.drafts().first!
        try check(draft.savedCandidateIDs.count == 1,"accept state survives reload")
        try check(repo.assets(kind:.idea).filter { seeds.map(\.id).contains($0.id) }.count == 2,"original ideas retained")
        let expired=NotebookIdeaDraft(seeds:seeds,direction:"旧来源",candidates:candidates)
        var changed=seeds[0]; changed.text="用户更新后的灵感"; changed.requiresLocalAI=true; changed=try repo.save(changed)
        do { try drafts.save(expired); throw TestFailure.failed("stale source was accepted") } catch is ActionFailure {}
        let localDraft=NotebookIdeaDraft(seeds:[changed,seeds[1]],direction:"组合",candidates:try NotebookIdeaGeneration.parse("{\"ideas\":[{\"title\":\"本地灵感\",\"text\":\"保留来源限制\"}]}"))
        try drafts.save(localDraft)
        let localResult=try drafts.accept(draftID:localDraft.id,candidateIDs:Set(localDraft.candidates.map(\.id)))
        try check(localResult.first?.requiresLocalAI == true,"local-only source constraint propagates to generated ideas")
        let nextDraft=NotebookIdeaDraft(seeds:[localResult[0],seeds[1]],direction:"继续组合",candidates:try NotebookIdeaGeneration.parse("{\"ideas\":[{\"title\":\"第二代\",\"text\":\"限制持续保留\"}]}"))
        try drafts.save(nextDraft)
        try check(drafts.accept(draftID:nextDraft.id,candidateIDs:Set(nextDraft.candidates.map(\.id))).first?.requiresLocalAI == true,"local-only is transitive")
        try drafts.discard(localDraft.id)
        try check(repo.asset(localResult[0].id) != nil,"discard draft retains accepted content")
        let cancelledDraft=NotebookIdeaDraft(seeds:[changed,seeds[1]],direction:"取消",candidates:candidates)
        let beforeCancel=try drafts.drafts().count
        let cancelled=Task {
            while !Task.isCancelled { await Task.yield() }
            try drafts.save(cancelledDraft)
        }
        cancelled.cancel()
        do { try await cancelled.value; throw TestFailure.failed("cancelled draft persisted") } catch is CancellationError {}
        try check(drafts.drafts().count == beforeCancel,"cancelled queued save leaves no draft")
        print("Notebook ledger, migration, JSON, stale sources, local-only provenance, cancellation and durable generation smoke passed")
    }
    enum TestFailure:Error { case failed(String) }
    static func check(_ value: @autoclosure () throws -> Bool,_ message:String) throws { if try !value() { throw TestFailure.failed(message) } }
}
