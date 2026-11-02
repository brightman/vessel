import Foundation

@main
struct AskAIRuntimeSmoke {
    static func check(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        if try !condition() { throw TestFailure(message: message) }
    }
    struct TestFailure: Error { let message: String }
    static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ask-ai-runtime-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let legacy = root.appendingPathComponent("history.json")
        let db = try DaybookDatabase(url: root.appendingPathComponent("fixture.sqlite3"))
        let store = DaybookConversationStore(url: legacy, database: db)
        let day = Date(timeIntervalSinceReferenceDate: 800000000)
        let evidence = DaybookEvidenceSnapshot(records: [], dayStart: day, dayEnd: day.addingTimeInterval(86400), allowedKinds: [.voice])
        let turn = DaybookConversationTurn(id: UUID(), question: "上周项目怎样？", text: "OLD_ASSISTANT_FACT_MUST_NOT_BECOME_EVIDENCE", generated: true, provider: "fixture", evidence: evidence, sources: [], scopeDescription: "fixture", state: .completed, createdAt: day)
        try store.saveTurn(turn, day: day)
        let source = DaybookRetrieval.Source(id: UUID(), number: 1, title: "当前证据", capturedAt: day, kind: .voice, snippet: "项目已交付 CURRENT_EVIDENCE", truncated: false)
        let context = try AskAIContextBuilder.build(question: String(repeating: "中英文mix ", count: 35), history: [turn], evidence: [source], instruction: "Use current evidence only", tools: String(repeating: "schema ", count: 100))
        try check(context.estimatedInputTokens <= 2200, "mixed Chinese/English must fit total budget")
        try check(context.content.contains("CURRENT_EVIDENCE"), "current evidence must survive history trimming")
        try check(!context.content.contains("OLD_ASSISTANT_FACT"), "assistant prose must not be recycled as factual evidence")
        let memory = AskAIRollingMemory.build(turns: [turn], dependencyDigest: "permissions-v1")
        try check(memory.questions == [turn.question] && memory.coveredCursor != nil, "memory includes user intent and coverage cursor")
        try check(memory == AskAIRollingMemory.build(turns: [turn], dependencyDigest: "permissions-v1"), "memory is deterministic")
        try check(context.content.contains("capturedAt=") && context.content.contains("kind=voice"), "evidence retains temporal and kind identity")
        let numbered = DaybookRetrieval.Source(id: source.id, number: 4, title: source.title, capturedAt: day, kind: .voice, snippet: source.snippet, truncated: false)
        let numberedContext = try AskAIContextBuilder.build(question: "项目？", history: [], evidence: [numbered], instruction: "ground facts")
        try check(numberedContext.sources.first?.number == 4 && numberedContext.content.contains("[4]"), "existing source numbers remain stable")
        do {
            _ = try AskAIContextBuilder.build(question: "项目？", history: [], evidence: [source], instruction: "", budget: .init(windowTokens: 160, inputLimit: 140, outputReserve: 0))
            throw TestFailure(message: "nonempty evidence failed to fit but builder accepted")
        } catch AskAIContextBuilder.Failure.noEvidence { }
        let runtime = AskAIRuntimeStore(conversationStore: store)
        let generation = try await runtime.cacheGeneration()
        let first = try await runtime.startAttempt(turnID: turn.id, provider: "local", model: "fixture", configRevision: "1")
        let second = try await runtime.startAttempt(turnID: turn.id, provider: "local", model: "fixture", configRevision: "1")
        try check(first.attempt == 1 && second.attempt == 2, "attempt numbers are monotonic")
        do { try await runtime.completeAttempt(runID: first.id, turn: turn); throw TestFailure(message: "stale attempt published") }
        catch AskAIRuntimeStore.Failure.staleAttempt { }
        let completed = DaybookConversationTurn(id: turn.id, question: turn.question, text: "new answer", generated: true, provider: "local", evidence: evidence, sources: [], scopeDescription: "fixture", state: .completed, createdAt: day.addingTimeInterval(400))
        let before = try db.query("SELECT day,position,created_at FROM conversation_turns WHERE id = ?", [.text(turn.id.uuidString)])
        try await runtime.completeAttempt(runID: second.id, turn: completed)
        let after = try db.query("SELECT day,position,created_at FROM conversation_turns WHERE id = ?", [.text(turn.id.uuidString)])
        try check(before == after, "retry must preserve original day position and created_at")
        try check(try store.load().first?.turns.first?.text == "new answer", "successful attempt publishes answer")
        let savedRun = try await runtime.loadRun(id: second.id)
        try check(savedRun?.state == .completed, "successful run and answer agree")
        let failedRetry = try await runtime.startAttempt(turnID: turn.id, provider: "local", model: "fixture", configRevision: "1")
        let invalid = DaybookConversationTurn(id: turn.id, question: turn.question, text: String(repeating: "X", count: 8001), generated: true, provider: "fixture", evidence: evidence, sources: [], scopeDescription: "fixture", state: .completed)
        do { try await runtime.completeAttempt(runID: failedRetry.id, turn: invalid); throw TestFailure(message: "invalid answer published") }
        catch DaybookConversationFailure.save { }
        try check(try store.runtimeTurn(id: turn.id)?.text == "new answer", "failed publication rolls back answer")
        try await runtime.interruptAttempt(runID: failedRetry.id, state: .failed, errorCode: "fixture_failure")
        try check(try store.runtimeTurn(id: turn.id)?.text == "new answer", "failed retry preserves prior success")
        for offset in 1...12 {
            let item = DaybookConversationTurn(id: UUID(), question: "question \(offset)", text: "answer", generated: false, provider: "", evidence: evidence, sources: [], scopeDescription: "", state: .completed, createdAt: day.addingTimeInterval(Double(offset)))
            try store.saveTurn(item, day: day)
        }
        let runtimeHistory = try await runtime.runtimeHistory(limit: 12)
        try check(runtimeHistory.count == 12 && runtimeHistory.first?.question == "question 1", "worker history ignores ten-turn UI page and returns chronological turns")
        try await runtime.saveMemory(memory, anchorTurnID: turn.id, expectedGeneration: generation)
        let checkpoint = AskAIRuntimeStore.Checkpoint(anchorTurnID: turn.id, providerConfigDigest: "config", formatVersion: "1", toolVersion: "1", promptVersion: "1", inputDigest: "input", permissionDigest: "permissions-v1", sourceDigest: "sources", payload: Data("stable snapshot".utf8))
        try await runtime.saveCheckpoint(checkpoint, expectedGeneration: generation)
        let reopened = AskAIRuntimeStore(conversationStore: DaybookConversationStore(url: legacy, database: try DaybookDatabase(url: db.url)))
        let loadedMemory = try await reopened.loadMemory(dependencyDigest: "permissions-v1")
        try check(loadedMemory == memory, "memory survives reopen")
        let loadedCheckpoint = try await reopened.loadCheckpoint(providerConfigDigest: "config", permissionDigest: "permissions-v1", sourceDigest: "sources")
        try check(loadedCheckpoint == checkpoint, "checkpoint survives reopen")
        let mismatch = try await reopened.loadCheckpoint(providerConfigDigest: "changed", permissionDigest: "permissions-v1", sourceDigest: "sources")
        try check(mismatch == nil, "configuration mismatch discards snapshot")
        let third = try await reopened.startAttempt(turnID: turn.id, provider: "local", model: "fixture", configRevision: "1")
        try await reopened.recordToolCall(runID: third.id, callID: "call-1", toolName: "searchRecords", argsDigest: "digest", arguments: "{}", state: "completed", resultReferences: ["source-1"], elapsedMilliseconds: 4)
        try await reopened.recordEvidence(runID: third.id, id: "e1", sourceIdentity: "source-1", sourceVersion: "1", queryScope: "today/voice", excerpt: "bounded excerpt", permissionDigest: "permissions-v1")
        try await reopened.saveCheckpoint(checkpoint, expectedGeneration: generation)
        try await reopened.updateAttempt(runID: third.id, state: .toolRunning, providerRequests: 2, toolCalls: 1)
        do { try await reopened.updateAttempt(runID: third.id, state: .generating, providerRequests: 1, toolCalls: 1); throw TestFailure(message: "counters regressed") }
        catch AskAIRuntimeStore.Failure.invalidMetadata { }
        do { try await reopened.recordEvidence(runID: first.id, id: "stale", sourceIdentity: "source", sourceVersion: "1", queryScope: "today", excerpt: "stale", permissionDigest: "permissions-v1"); throw TestFailure(message: "stale evidence accepted") }
        catch AskAIRuntimeStore.Failure.staleAttempt { }
        try await reopened.interruptUnfinishedAttempts()
        let interrupted = try await reopened.loadRun(id: third.id)
        try check(interrupted?.state == .interrupted, "restart interrupts unfinished runs")
        let privacyStore = DaybookConversationStore(url: legacy, database: try DaybookDatabase(url: db.url))
        try privacyStore.redactDisallowed([.voice])
        try check(try db.query("SELECT * FROM ask_ai_memory").count == 1, "unchanged allowed permissions must retain caches")
        try privacyStore.redactDisallowed([])
        for table in ["ask_ai_evidence", "ask_ai_tool_calls", "ask_ai_memory", "ask_ai_checkpoints"] {
            try check(try db.query("SELECT * FROM " + table).isEmpty, "redaction removes permission-dependent caches: " + table)
        }
        do { try await reopened.saveCheckpoint(checkpoint, expectedGeneration: generation); throw TestFailure(message: "late revoked checkpoint restored") }
        catch AskAIRuntimeStore.Failure.staleAttempt { }
        do { try await reopened.saveMemory(memory, anchorTurnID: turn.id, expectedGeneration: generation); throw TestFailure(message: "late revoked memory restored") }
        catch AskAIRuntimeStore.Failure.staleAttempt { }
        // A fresh valid anchor proves FK cleanup without restoring redacted data.
        let fresh = DaybookConversationTurn(id: UUID(), question: "fresh", text: "fresh", generated: false, provider: "", evidence: evidence, sources: [], scopeDescription: "", state: .completed, createdAt: day)
        try store.saveTurn(fresh, day: day)
        let currentGeneration = try await reopened.cacheGeneration()
        try await reopened.saveMemory(memory, anchorTurnID: fresh.id, expectedGeneration: currentGeneration)
        let pending = DaybookConversationTurn(id: UUID(), question: "pending", text: "", generated: false, provider: "", evidence: evidence, sources: [], scopeDescription: "", state: .pending, createdAt: day)
        try store.saveTurn(pending, day: day)
        let pendingRun = try await reopened.startAttempt(turnID: pending.id, provider: "local", model: "fixture", configRevision: "1")
        try await reopened.clearPermissionDependentCaches()
        try check(try store.runtimeTurn(id: pending.id)?.completionState == .cancelled, "cache invalidation settles pending conversation row")
        let cancelledRun = try await reopened.loadRun(id: pendingRun.id)
        try check(cancelledRun?.state == .interrupted, "cache invalidation settles run")
        try await reopened.saveMemory(memory, anchorTurnID: fresh.id, expectedGeneration: try await reopened.cacheGeneration())
        try store.reset()
        try check(try db.query("SELECT * FROM ask_ai_runs").isEmpty, "reset cascades runs")
        try check(try db.query("SELECT * FROM ask_ai_memory").isEmpty, "reset cascades anchors")
        print("Ask AI runtime: bounded context, deterministic memory, migration/reopen, stale attempts, atomic retry, interruption, redaction and reset passed")
    }
}
