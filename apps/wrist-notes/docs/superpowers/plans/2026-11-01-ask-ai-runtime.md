# Ask AI Runtime Implementation Plan

类型：实施计划。状态：首期实现与自动验证完成，真机验证待进行。更新：2026-11-01。适用：WiseLife iOS 26.3 Ask AI。验证：[运行时记录](../../../verification/ask-ai-runtime-2026-11-01.md)。

> **For agentic workers:** Use superpowers:subagent-driven-development or superpowers:executing-plans. Track completion in this plan; no commits or publishing in this task.

**Goal:** Implement the approved iOS 26.3 Ask AI session/context/tool design without replacing existing history or breaking the four provider modes.

**Architecture:** Existing ConversationStore remains authoritative. An application runtime manages bounded context, attempts, evidence and read-only tools; Apple uses native Tool and custom services use protocol adapters. Old text generation remains a compatibility path.

**Tech Stack:** Swift, Foundation Models from installed Xcode SDK, SQLite, HTML/JS prototype, shell smoke tests.

## Global Constraints

- Approved by user on 2026-11-01; source: [technical design](../../ask-ai-session-orchestration.md).
- iOS 26.3 feature availability; do not use iOS 26.4 tokenCount or iOS 27 provider APIs.
- Preserve all current uncommitted changes; work in isolated current-source snapshot, then copy only reviewed task changes back after comparing baseline hashes.
- Keep all four model modes, Siri local-only behavior, existing confirmation and permission rules, 10-turn history pages and original turn IDs.
- User question ≤300 characters; final sources ≤5, snippet ≤200, title ≤48. Apple estimated first input ≤2200 tokens, final output reserve 512; tool calls ≤6 and provider requests ≤8 per run, active deadline 90 seconds excluding consent waits.
- No credentials or personal database reads in tests. No network generation using real accounts. No ASR/recording/topic-splitting changes.
- Tests use synthetic records/temporary SQLite; state unverified simulator/device/provider behavior explicitly.

## Task 1: Bounded context and runtime persistence

Files: add `Sources/iPhone/AskAIContext.swift`, `AskAIRuntimeStore.swift`, `Tests/AskAIRuntimeSmoke.swift`, `scripts/test_ask_ai_runtime.sh`; modify ConversationStore only for narrowly scoped storage access. Integrator owns project membership and other test scripts.

Interfaces:

```swift
enum AskAITokenEstimator { static func estimate(_ text: String) -> Int }
struct AskAIContextBudget {
    var windowTokens: Int = 4096
    var inputLimit: Int = 2200
    var outputReserve: Int = 512
    func fits(instruction: String, content: String, tools: String = "") -> Bool
}
```

Store operates through the existing ConversationStore database, with a serialized background worker, not a separate user database. Provide async APIs to start an attempt, record calls/evidence, complete/interrupt attempts, save/load summary and checkpoint, and clear permission-dependent caches. All five additive tables use `ask-ai-runtime-v1` migration. Turn foreign keys and anchor foreign keys must cascade. Publish final turn and successful run atomically using existing save semantics; preserve original day, position and created_at.

- [x] Write synthetic tests demonstrating bounded mixed Chinese/English input, old history exclusion from factual evidence, migration/reopen, monotonic attempts, stale attempt rejection, restart interruption, reset cascade and redaction cache removal.
- [x] Run the test before implementation and retain the initial failure.
- [x] Implement estimator and bounded context, favor evidence over old assistant prose. Build deterministic structured rolling memory from prior user questions, with coverage cursor and dependency digest; no background remote summarization.
- [x] Implement five tables and minimal APIs needed by integration. Never await in a transaction. Store bounded metadata/excerpts only; no keys or complete transcript duplication.
- [x] Run `sh apps/wrist-notes/scripts/test_ask_ai_runtime.sh`; report exact signatures to integrator.

## Task 2: Query tools and safe index scope

Files: add `AskAIReadTools.swift`; modify `DaybookSemanticIndex.swift` and narrowly scoped reader/retrieval code; add `Tests/AskAIReadToolsSmoke.swift` and script.

- [x] Tests: A→B→A searches preserve A cache; explicit dates and allowed kinds cannot expand; source IDs are stable and final references cap at 5; missing metric differs from zero; unknown tool and invalid parameters fail closed; total tool count is bounded; history returns background only.
- [x] Separate scoped semantic upserts from authoritative deletion maintenance. Keep global resource revisions separate from per-query cancellation. Do not change embeddings or translation semantics.
- [x] Provide `searchRecords`, `readRecord`, `aggregateMetrics`, `searchConversationHistory` using runtime reader closures and existing typed data. Tool results carry status, source identity and bounded text; model never supplies SQL. Speaker queries preserve recording-scoped association and revision checks.
- [x] Run targeted retrieval/semantic/tool tests and record boundaries for unsupported metric domains.

## Task 3: Provider drivers and bounded orchestration

Files: add `AskAIRuntime.swift`, `AskAIAppleDriver.swift`, `AskAICustomDriver.swift`; use shared context/store/tools from prior tasks; tests use scripted drivers and URLProtocol.

- [x] Tests: call/result pairing, cancellation, repeated queries, request/tool/deadline limits, citation repair, one overflow rebuild, invalid capabilities and out-of-scope evidence.
- [x] Apple driver uses native Tool, stable completed Transcript cache and model/locale checks. Restore only matching model/instruction/tool/permission/source fingerprints; malformed caches are discarded.
- [x] Custom driver supports OpenAI Chat Completions and Anthropic Messages tools; preserve ephemeral sessions, no redirects, size/time limits, endpoint validation and credential isolation. Unknown capabilities use the existing text path. Keep ChatGPT/Mac text paths intact.
- [x] New external tool results wait for exact-content supplemental consent when confirmation is enabled; remembered opt-out follows current policy. Check data/config freshness before each network request. Do not use actual credentials in validation.
- [x] Persist run/tool/evidence states; every repair and restart shares the original budgets. Final answer only uses registered citations. Tool errors remain distinguishable from empty records.

## Task 4: Prototype and model integration

Files: `prototype/daybook-ai.js`, `prototype/daybook-ai.css`, `prototype/ai-date-range-design.md`, `DaybookAssistantModel.swift`, `DaybookAssistantView.swift`, relevant localization; adjust generation source membership and affected shell test manifests.

- [x] Update prototype first: progress, cancellation, same-turn retry, supplemental sending preview. Preserve existing layout, composer and source navigation.
- [x] Integrate runtime behind existing Model interface. Recent context comes from SQLite independently of UI pagination. Keep accepted-send immediate composer clearing.
- [x] Retry by turn ID, preserving old successful answer on failed retry and preserving any new composer draft. Only active attempt may publish; reset/revocation cancels pending run and clears caches.
- [x] Replace unrelated-array cancellation with applicable scope fingerprint checks; keep relevant new/deleted data invalidation.
- [x] Update tests, repairing the known stale literal assertion semantically; run full conversation regression and source membership validation.

## Task 5: Review, build and documentation

- [x] Review task diffs against snapshot, not HEAD; no unrelated changes.
- [x] Run focused suites and an iOS simulator build. Test prototype interactions with synthetic data. Do not claim device inference/cloud tools from build results.
- [x] Address review findings; update approved design's implementation/validation status and indexes, prompts and database docs where behavior changed.
- [x] Compare original files with baseline hashes before copy-back. Concurrent changes require a narrow merge, never overwrite.
- [x] Final response links validation, describes working features and explicit limitations; do not commit/push/install unless separately requested.


## 收尾结果与边界

通过存储/上下文、只读工具、完整对话、语义索引和模型协议合成测试；HTML 浏览器交互通过；最终 iOS Simulator 构建通过。未实际调用 Apple/云端模型、未安装真机、未提交或推送。首期采用问题意图记忆、运行快照只读工具、最多 5 样本指标小计和相同输入无工具 Transcript 缓存；全量语义历史摘要、独立 Reader/Speaker SQL 下推、流式输出等仍按主要设计的后续范围处理。复审发现的缓存复活、索引投影竞态、末次发送复核、原生累计预算、排队发布和文本回退输出限额均已修复并加入对应验证。
