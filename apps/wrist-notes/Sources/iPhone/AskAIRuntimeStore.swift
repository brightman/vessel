import Foundation

/// A lock-backed publication lease: invalidation and the synchronous SQL commit are ordered.
final class AskAIPublicationFence: @unchecked Sendable {
    enum Failure: Error { case validationPending }
    private let lock = NSRecursiveLock()
    private var valid = true
    private var pending: UUID?
    private var waiters: [CheckedContinuation<Void, Error>] = []
    func invalidate() {
        lock.lock(); valid = false; pending = nil
        let waiting = waiters; waiters = []; lock.unlock()
        waiting.forEach { $0.resume(throwing: CancellationError()) }
    }
    func check() -> Bool { lock.lock(); defer { lock.unlock() }; return valid }
    func suspend(validation: UUID) { lock.lock(); defer { lock.unlock() }; if valid { pending = validation } }
    func resume(validation: UUID) {
        lock.lock()
        guard valid, pending == validation else { lock.unlock(); return }
        pending = nil; let waiting = waiters; waiters = []; lock.unlock()
        waiting.forEach { $0.resume() }
    }
    func waitUntilReady() async throws {
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                lock.lock()
                if !valid { lock.unlock(); continuation.resume(throwing: CancellationError()) }
                else if pending == nil { lock.unlock(); continuation.resume() }
                else { waiters.append(continuation); lock.unlock() }
            }
        }, onCancel: { self.invalidate() })
    }
    func withLease<T>(_ body: () throws -> T) throws -> T {
        lock.lock(); defer { lock.unlock() }
        guard valid else { throw CancellationError() }
        guard pending == nil else { throw Failure.validationPending }
        return try body()
    }
}


/// All new runtime SQL runs on one background queue, through ConversationStore's authoritative DB.
/// Closures passed to DaybookDatabase.transaction are synchronous and never suspend.
final class AskAIRuntimeStore: @unchecked Sendable {
    enum Failure: Error { case missingTurn, staleAttempt, invalidMetadata, incompatibleCheckpoint }
    enum State: String, Codable, Sendable {
        case preparing, awaitingConsent, generating, toolRunning, validating, completed, failed, cancelled, interrupted
        var terminal: Bool { [.completed, .failed, .cancelled, .interrupted].contains(self) }
    }
    struct Run: Equatable, Sendable {
        let id: UUID
        let turnID: UUID
        let attempt: Int
        let state: State
        let providerRequests: Int
        let toolCalls: Int
        let errorCode: String?
    }
    struct StoredTurn: Sendable { let turn: DaybookConversationTurn; let day: Date }
    struct Checkpoint: Codable, Equatable, Sendable {
        let anchorTurnID: UUID
        let providerConfigDigest: String
        let formatVersion: String
        let toolVersion: String
        let promptVersion: String
        let inputDigest: String
        let permissionDigest: String
        let sourceDigest: String
        let payload: Data
    }
    private let conversationStore: DaybookConversationStore
    private let queue = DispatchQueue(label: "WiseLife.AskAIRuntimeStore", qos: .utility)
    init(conversationStore: DaybookConversationStore) { self.conversationStore = conversationStore }

    private func perform<T>(_ body: @escaping (DaybookDatabase) throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    let db = try self.conversationStore.runtimeDatabase()
                    try Self.prepare(db)
                    continuation.resume(returning: try body(db))
                } catch { continuation.resume(throwing: error) }
            }
        }
    }
    private static func prepare(_ db: DaybookDatabase) throws {
        try db.migrate("ask-ai-runtime-v1") {
            let statements = [
                """
                CREATE TABLE ask_ai_runs (
                  id TEXT PRIMARY KEY, turn_id TEXT NOT NULL REFERENCES conversation_turns(id) ON DELETE CASCADE,
                  attempt INTEGER NOT NULL CHECK(attempt > 0), session_key TEXT NOT NULL,
                  provider TEXT NOT NULL, model TEXT NOT NULL, config_revision TEXT NOT NULL, state TEXT NOT NULL,
                  started_at REAL NOT NULL, ended_at REAL, error_code TEXT,
                  provider_requests INTEGER NOT NULL DEFAULT 0, tool_calls INTEGER NOT NULL DEFAULT 0,
                  result_payload BLOB, UNIQUE(turn_id,attempt))
                """,
                "CREATE INDEX ask_ai_runs_turn ON ask_ai_runs(turn_id,attempt DESC)",
                """
                CREATE TABLE ask_ai_tool_calls (
                  run_id TEXT NOT NULL REFERENCES ask_ai_runs(id) ON DELETE CASCADE,
                  call_id TEXT NOT NULL, tool_name TEXT NOT NULL, args_digest TEXT NOT NULL,
                  arguments TEXT NOT NULL, state TEXT NOT NULL, result_refs BLOB NOT NULL,
                  elapsed_ms INTEGER NOT NULL, PRIMARY KEY(run_id,call_id))
                """,
                """
                CREATE TABLE ask_ai_evidence (
                  id TEXT NOT NULL, run_id TEXT NOT NULL REFERENCES ask_ai_runs(id) ON DELETE CASCADE,
                  source_identity TEXT NOT NULL, source_version TEXT NOT NULL, query_scope TEXT NOT NULL,
                  excerpt TEXT NOT NULL, permission_digest TEXT NOT NULL, excerpt_range TEXT NOT NULL,
                  PRIMARY KEY(run_id,id))
                """,
                """
                CREATE TABLE ask_ai_memory (
                  session_key TEXT PRIMARY KEY, anchor_turn_id TEXT NOT NULL REFERENCES conversation_turns(id) ON DELETE CASCADE,
                  covered_cursor TEXT, summary_json BLOB NOT NULL, dependency_digest TEXT NOT NULL, prompt_version TEXT NOT NULL)
                """,
                """
                CREATE TABLE ask_ai_checkpoints (
                  session_key TEXT PRIMARY KEY, anchor_turn_id TEXT NOT NULL REFERENCES conversation_turns(id) ON DELETE CASCADE,
                  provider_config_digest TEXT NOT NULL, format_version TEXT NOT NULL, tool_version TEXT NOT NULL,
                  prompt_version TEXT NOT NULL, input_digest TEXT NOT NULL, permission_digest TEXT NOT NULL,
                  source_digest TEXT NOT NULL, payload BLOB NOT NULL)
                """
            ]
            for sql in statements { try db.execute(sql) }
        }
    }
    private static func bounded(_ values: [String], limit: Int = 300) throws {
        guard values.allSatisfy({ $0.utf8.count <= limit && !$0.contains("\0") }) else { throw Failure.invalidMetadata }
    }
    private static func active(_ runID: UUID, db: DaybookDatabase) throws -> DaybookDatabase.Row {
        guard let row = try db.query("SELECT * FROM ask_ai_runs WHERE id = ?", [.text(runID.uuidString)]).first,
              let raw = row["state"]?.string, let state = State(rawValue: raw), !state.terminal,
              let turnID = row["turn_id"],
              let latest = try db.query("SELECT id FROM ask_ai_runs WHERE turn_id = ? ORDER BY attempt DESC LIMIT 1", [turnID]).first,
              latest["id"] == .text(runID.uuidString) else { throw Failure.staleAttempt }
        return row
    }
    private static func run(_ row: DaybookDatabase.Row) throws -> Run {
        guard let id = UUID(uuidString: try row.requiredString("id")),
              let turnID = UUID(uuidString: try row.requiredString("turn_id")),
              let state = State(rawValue: try row.requiredString("state")) else { throw Failure.invalidMetadata }
        return Run(id: id, turnID: turnID, attempt: Int(try row.requiredDouble("attempt")), state: state,
                   providerRequests: Int(try row.requiredDouble("provider_requests")), toolCalls: Int(try row.requiredDouble("tool_calls")), errorCode: row["error_code"]?.string)
    }
    func startAttempt(turnID: UUID, provider: String, model: String, configRevision: String, sessionKey: String = "assistant-default") async throws -> Run {
        try Self.bounded([provider, model, configRevision, sessionKey])
        return try await perform { db in
            try db.transaction {
                guard let turn = try db.query("SELECT state FROM conversation_turns WHERE id = ?", [.text(turnID.uuidString)]).first,
                      turn["state"] != .text("redacted") else { throw Failure.missingTurn }
                let attempt = Int(try db.query("SELECT COALESCE(MAX(attempt),0)+1 AS next FROM ask_ai_runs WHERE turn_id = ?", [.text(turnID.uuidString)])[0].requiredDouble("next"))
                try db.execute("UPDATE ask_ai_runs SET state = 'interrupted', ended_at = ?, error_code = 'superseded' WHERE turn_id = ? AND state NOT IN ('completed','failed','cancelled','interrupted')", [.real(Date.now.timeIntervalSinceReferenceDate), .text(turnID.uuidString)])
                let id = UUID()
                try db.execute("INSERT INTO ask_ai_runs(id,turn_id,attempt,session_key,provider,model,config_revision,state,started_at) VALUES (?,?,?,?,?,?,?,'preparing',?)", [.text(id.uuidString), .text(turnID.uuidString), .integer(Int64(attempt)), .text(sessionKey), .text(provider), .text(model), .text(configRevision), .real(Date.now.timeIntervalSinceReferenceDate)])
                return Run(id: id, turnID: turnID, attempt: attempt, state: .preparing, providerRequests: 0, toolCalls: 0, errorCode: nil)
            }
        }
    }
    func loadRun(id: UUID) async throws -> Run? {
        try await perform { db in try db.query("SELECT * FROM ask_ai_runs WHERE id = ?", [.text(id.uuidString)]).first.map(Self.run) }
    }
    func updateAttempt(runID: UUID, state: State, providerRequests: Int, toolCalls: Int) async throws {
        guard !state.terminal, (0...8).contains(providerRequests), (0...6).contains(toolCalls) else { throw Failure.invalidMetadata }
        try await perform { db in
            try db.transaction {
                let row = try Self.active(runID, db: db)
                guard providerRequests >= Int(try row.requiredDouble("provider_requests")), toolCalls >= Int(try row.requiredDouble("tool_calls")) else { throw Failure.invalidMetadata }
                try db.execute("UPDATE ask_ai_runs SET state = ?,provider_requests = ?,tool_calls = ? WHERE id = ?", [.text(state.rawValue), .integer(Int64(providerRequests)), .integer(Int64(toolCalls)), .text(runID.uuidString)])
            }
        }
    }
    func recordToolCall(runID: UUID, callID: String, toolName: String, argsDigest: String, arguments: String, state: String, resultReferences: [String], elapsedMilliseconds: Int) async throws {
        try Self.bounded([callID, toolName, argsDigest, state] + resultReferences)
        guard arguments.utf8.count <= 2048, resultReferences.count <= 32, (0...90000).contains(elapsedMilliseconds) else { throw Failure.invalidMetadata }
        try await perform { db in
            try db.transaction {
                _ = try Self.active(runID, db: db)
                let prior = try db.query("SELECT tool_name,args_digest,arguments FROM ask_ai_tool_calls WHERE run_id = ? AND call_id = ?", [.text(runID.uuidString), .text(callID)]).first
                if let prior {
                    guard prior["tool_name"] == .text(toolName), prior["args_digest"] == .text(argsDigest), prior["arguments"] == .text(arguments) else { throw Failure.invalidMetadata }
                } else {
                    let count = try db.query("SELECT COUNT(*) AS n FROM ask_ai_tool_calls WHERE run_id = ?", [.text(runID.uuidString)])[0].requiredDouble("n")
                    guard count < 6 else { throw Failure.invalidMetadata }
                }
                try db.execute("INSERT INTO ask_ai_tool_calls(run_id,call_id,tool_name,args_digest,arguments,state,result_refs,elapsed_ms) VALUES (?,?,?,?,?,?,?,?) ON CONFLICT(run_id,call_id) DO UPDATE SET state=excluded.state,result_refs=excluded.result_refs,elapsed_ms=excluded.elapsed_ms", [.text(runID.uuidString), .text(callID), .text(toolName), .text(argsDigest), .text(arguments), .text(state), try DaybookDatabase.json(resultReferences), .integer(Int64(elapsedMilliseconds))])
            }
        }
    }
    func recordEvidence(runID: UUID, id: String, sourceIdentity: String, sourceVersion: String, queryScope: String, excerpt: String, permissionDigest: String, excerptRange: String = "") async throws {
        try Self.bounded([id, sourceIdentity, sourceVersion, queryScope, permissionDigest, excerptRange])
        guard excerpt.count <= 200 else { throw Failure.invalidMetadata }
        try await perform { db in
            try db.transaction {
                _ = try Self.active(runID, db: db)
                let count = try db.query("SELECT COUNT(*) AS n FROM ask_ai_evidence WHERE run_id = ?", [.text(runID.uuidString)])[0].requiredDouble("n")
                let existing = try db.query("SELECT id FROM ask_ai_evidence WHERE run_id = ? AND id = ?", [.text(runID.uuidString), .text(id)]).first
                guard existing != nil || count < 64 else { throw Failure.invalidMetadata }
                try db.execute("INSERT INTO ask_ai_evidence(id,run_id,source_identity,source_version,query_scope,excerpt,permission_digest,excerpt_range) VALUES (?,?,?,?,?,?,?,?) ON CONFLICT(run_id,id) DO UPDATE SET source_identity=excluded.source_identity,source_version=excluded.source_version,query_scope=excluded.query_scope,excerpt=excluded.excerpt,permission_digest=excluded.permission_digest,excerpt_range=excluded.excerpt_range", [.text(id), .text(runID.uuidString), .text(sourceIdentity), .text(sourceVersion), .text(queryScope), .text(excerpt), .text(permissionDigest), .text(excerptRange)])
            }
        }
    }
    /// Publishes using the existing per-turn save, within the same transaction as run success.
    /// saveTurn preserves original day/position/created_at in its ON CONFLICT branch.
    func completeAttempt(runID: UUID, turn: DaybookConversationTurn, publicationFence: AskAIPublicationFence? = nil, beforePublicationLease: (@Sendable () -> Void)? = nil) async throws {
        guard turn.completionState == .completed else { throw Failure.invalidMetadata }
        try await perform { db in
            beforePublicationLease?()
            try (publicationFence ?? AskAIPublicationFence()).withLease { try db.transaction {
                if let row = try db.query("SELECT state,turn_id FROM ask_ai_runs WHERE id = ?", [.text(runID.uuidString)]).first,
                   row["state"] == .text("completed") {
                    guard row["turn_id"] == .text(turn.id.uuidString), let stored = try self.conversationStore.runtimeTurn(id: turn.id) else { throw Failure.staleAttempt }
                    var normalized = turn; normalized.createdAt = stored.createdAt
                    guard stored == normalized else { throw Failure.staleAttempt }
                    return
                }
                let run = try Self.active(runID, db: db)
                guard run["turn_id"] == .text(turn.id.uuidString),
                      let row = try db.query("SELECT day,state,question FROM conversation_turns WHERE id = ?", [.text(turn.id.uuidString)]).first,
                      row["state"] != .text("redacted"), row["question"] == .text(turn.question) else { throw Failure.staleAttempt }
                try self.conversationStore.saveTurn(turn, day: Date(timeIntervalSinceReferenceDate: try row.requiredDouble("day")))
                // Only source identities are retained; the answer itself remains in the authoritative turn.
                try db.execute("UPDATE ask_ai_runs SET state = 'completed',ended_at = ?,result_payload = ? WHERE id = ?", [.real(Date.now.timeIntervalSinceReferenceDate), try DaybookDatabase.json(turn.sources.map(\.id)), .text(runID.uuidString)])
            } }
        }
    }
    func interruptAttempt(runID: UUID, state: State = .cancelled, errorCode: String? = nil) async throws {
        guard state.terminal && state != .completed else { throw Failure.invalidMetadata }
        try Self.bounded(errorCode.map { [$0] } ?? [])
        try await perform { db in
            try db.transaction {
                let run = try Self.active(runID, db: db)
                try db.execute("UPDATE ask_ai_runs SET state = ?,ended_at = ?,error_code = ? WHERE id = ?", [.text(state.rawValue), .real(Date.now.timeIntervalSinceReferenceDate), errorCode.map(DaybookDatabase.Value.text) ?? .null, .text(runID.uuidString)])
                // A failed retry cannot replace a previous successful answer.
                try db.execute("UPDATE conversation_turns SET state = ?,text = ?,generated = 0,provider = '',sources = ?,scope = '',question_references = NULL WHERE id = ? AND state = 'pending'", [.text(state == .failed ? "failed" : "cancelled"), .text(state == .failed ? "回答未完成，可重试。" : "上次回答已中断，可重试。"), try DaybookDatabase.json([DaybookRetrieval.Source]()), run["turn_id"]!])
            }
        }
    }
    func interruptUnfinishedAttempts() async throws {
        try await perform { db in
            try db.transaction {
                try db.execute("UPDATE conversation_turns SET state = 'cancelled',text = ?,sources = ?,question_references = NULL WHERE state = 'pending' AND id IN (SELECT turn_id FROM ask_ai_runs WHERE state NOT IN ('completed','failed','cancelled','interrupted'))", [.text("上次回答已中断，可重试。"), try DaybookDatabase.json([DaybookRetrieval.Source]())])
                try db.execute("UPDATE ask_ai_runs SET state = 'interrupted',ended_at = ?,error_code = 'restart' WHERE state NOT IN ('completed','failed','cancelled','interrupted')", [.real(Date.now.timeIntervalSinceReferenceDate)])
            }
        }
    }
    func runtimeHistory(limit: Int = 40) async throws -> [DaybookConversationTurn] {
        try await perform { db in
            // Page remains capped at 100; this count is independent of UI pagination.
            let ids = try db.query("SELECT id FROM conversation_turns WHERE COALESCE(state,'completed') = 'completed' ORDER BY created_at DESC,id DESC LIMIT ?", [.integer(Int64(max(1, min(limit, 100))))])
            return try ids.reversed().compactMap { row in
                guard let id = UUID(uuidString: try row.requiredString("id")) else { throw Failure.invalidMetadata }
                return try self.conversationStore.runtimeTurn(id: id)
            }
        }
    }
    func runtimeTurn(id: UUID) async throws -> StoredTurn? {
        try await perform { db in
            guard let row = try db.query("SELECT day FROM conversation_turns WHERE id = ?", [.text(id.uuidString)]).first,
                  let turn = try self.conversationStore.runtimeTurn(id: id) else { return nil }
            return StoredTurn(turn: turn, day: Date(timeIntervalSinceReferenceDate: try row.requiredDouble("day")))
        }
    }
    func cacheGeneration() async throws -> Int64 {
        try await perform { db in try Self.generation(db) }
    }
    private static func generation(_ db: DaybookDatabase) throws -> Int64 {
        Int64(try db.query("SELECT imported_at FROM storage_migrations WHERE domain='ask-ai-runtime-cache-generation'").first?["imported_at"]?.double ?? 0)
    }
    private static func validateCacheWrite(_ db: DaybookDatabase, anchor: UUID, expectedGeneration: Int64) throws {
        guard try generation(db) == expectedGeneration,
              let row = try db.query("SELECT state FROM conversation_turns WHERE id=?", [.text(anchor.uuidString)]).first,
              row["state"] == .text("completed") || row["state"] == .null else { throw Failure.staleAttempt }
    }
    func saveMemory(_ memory: AskAIRollingMemory, anchorTurnID: UUID, expectedGeneration: Int64, publicationFence: AskAIPublicationFence? = nil, sessionKey: String = "assistant-default") async throws {
        try Self.bounded([sessionKey, memory.dependencyDigest, memory.promptVersion, memory.inputDigest])
        guard memory.questions.count <= 12, memory.questions.allSatisfy({ $0.count <= 120 }), (memory.coveredCursor?.utf8.count ?? 0) <= 128 else { throw Failure.invalidMetadata }
        try await perform { db in
            try (publicationFence ?? AskAIPublicationFence()).withLease { try db.transaction {
                try Self.validateCacheWrite(db, anchor: anchorTurnID, expectedGeneration: expectedGeneration)
                try db.execute("INSERT INTO ask_ai_memory(session_key,anchor_turn_id,covered_cursor,summary_json,dependency_digest,prompt_version) VALUES (?,?,?,?,?,?) ON CONFLICT(session_key) DO UPDATE SET anchor_turn_id=excluded.anchor_turn_id,covered_cursor=excluded.covered_cursor,summary_json=excluded.summary_json,dependency_digest=excluded.dependency_digest,prompt_version=excluded.prompt_version", [.text(sessionKey), .text(anchorTurnID.uuidString), memory.coveredCursor.map(DaybookDatabase.Value.text) ?? .null, try DaybookDatabase.json(memory), .text(memory.dependencyDigest), .text(memory.promptVersion)])
            } }
        }
    }
    func loadMemory(dependencyDigest: String, sessionKey: String = "assistant-default") async throws -> AskAIRollingMemory? {
        try await perform { db in
            guard let row = try db.query("SELECT * FROM ask_ai_memory WHERE session_key = ?", [.text(sessionKey)]).first else { return nil }
            guard row["dependency_digest"] == .text(dependencyDigest), row["prompt_version"] == .text("ask-ai-memory-v1"),
                  let memory = try? DaybookDatabase.decode(AskAIRollingMemory.self, row["summary_json"]) else {
                try db.execute("DELETE FROM ask_ai_memory WHERE session_key = ?", [.text(sessionKey)]); return nil
            }
            return memory
        }
    }
    func saveCheckpoint(_ checkpoint: Checkpoint, expectedGeneration: Int64, publicationFence: AskAIPublicationFence? = nil, sessionKey: String = "assistant-default") async throws {
        try Self.bounded([sessionKey, checkpoint.providerConfigDigest, checkpoint.formatVersion, checkpoint.toolVersion, checkpoint.promptVersion, checkpoint.inputDigest, checkpoint.permissionDigest, checkpoint.sourceDigest])
        guard checkpoint.payload.count <= 65536 else { throw Failure.invalidMetadata }
        try await perform { db in
            try (publicationFence ?? AskAIPublicationFence()).withLease { try db.transaction {
                try Self.validateCacheWrite(db, anchor: checkpoint.anchorTurnID, expectedGeneration: expectedGeneration)
                try db.execute("INSERT INTO ask_ai_checkpoints(session_key,anchor_turn_id,provider_config_digest,format_version,tool_version,prompt_version,input_digest,permission_digest,source_digest,payload) VALUES (?,?,?,?,?,?,?,?,?,?) ON CONFLICT(session_key) DO UPDATE SET anchor_turn_id=excluded.anchor_turn_id,provider_config_digest=excluded.provider_config_digest,format_version=excluded.format_version,tool_version=excluded.tool_version,prompt_version=excluded.prompt_version,input_digest=excluded.input_digest,permission_digest=excluded.permission_digest,source_digest=excluded.source_digest,payload=excluded.payload", [.text(sessionKey), .text(checkpoint.anchorTurnID.uuidString), .text(checkpoint.providerConfigDigest), .text(checkpoint.formatVersion), .text(checkpoint.toolVersion), .text(checkpoint.promptVersion), .text(checkpoint.inputDigest), .text(checkpoint.permissionDigest), .text(checkpoint.sourceDigest), .blob(checkpoint.payload)])
            } }
        }
    }
    func loadCheckpoint(providerConfigDigest: String, permissionDigest: String, sourceDigest: String, formatVersion: String = "1", toolVersion: String = "1", promptVersion: String = "1", inputDigest: String? = nil, sessionKey: String = "assistant-default") async throws -> Checkpoint? {
        try await perform { db in
            guard let row = try db.query("SELECT * FROM ask_ai_checkpoints WHERE session_key = ?", [.text(sessionKey)]).first else { return nil }
            guard row["provider_config_digest"] == .text(providerConfigDigest), row["permission_digest"] == .text(permissionDigest), row["source_digest"] == .text(sourceDigest), row["format_version"] == .text(formatVersion), row["tool_version"] == .text(toolVersion), row["prompt_version"] == .text(promptVersion), inputDigest == nil || row["input_digest"] == .text(inputDigest!),
                  let anchor = UUID(uuidString: try row.requiredString("anchor_turn_id")), let payload = row["payload"]?.data, payload.count <= 65536 else {
                try db.execute("DELETE FROM ask_ai_checkpoints WHERE session_key = ?", [.text(sessionKey)]); return nil
            }
            return Checkpoint(anchorTurnID: anchor, providerConfigDigest: providerConfigDigest, formatVersion: formatVersion, toolVersion: toolVersion, promptVersion: promptVersion, inputDigest: try row.requiredString("input_digest"), permissionDigest: permissionDigest, sourceDigest: sourceDigest, payload: payload)
        }
    }
    func clearPermissionDependentCaches() async throws {
        try await perform { db in
            try db.transaction { try DaybookConversationStore.invalidateRuntimeCaches(db) }
        }
    }
}
