# WiseLife Full Text and Complete Chunk Indexing Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox syntax for tracking.

**Goal:** Deliver the approved second phase: real SQLite keyword retrieval and resumable full-original-text vector coverage.

**Architecture:** A full-text cache and chunk-progress cache share DaybookDatabase but remain independent of primary stores. Existing asynchronous semantic service becomes the combined local retrieval entry point, with SQL keyword payloads consumed by library/Ask retrieval and bounded vector work resumed by the foreground library model.

**Tech Stack:** Swift, system SQLite FTS5 trigram with scoped substring fallback, existing static SQLite Vector, Apple local embeddings, macOS smoke tests, iOS simulator build.

## Global Constraints

- Work only in `/private/tmp/wiselife-sqlite-metadata-20261020`, branch `codex/wiselife-search-20261020`; main workspace contains concurrent unrelated edits. Parent integrates task-only files after hash checks. Never merge snapshot commits.
- Keep primary metadata/media/UUIDs, complete file protection, AI providers, ASR, Ring disabled and single-day UX unchanged. No real user databases, media, secrets, containers or production services.
- Bind user text as SQL parameters; quote FTS literal syntax. All cache mutations are transactional and subject to existing generation invalidation/cancellation. Corrupt/unavailable cache falls back to live in-memory keyword retrieval, never silent empty data.
- Library keyword search includes all local records/title/text/summary. AI keyword and vectors use allowed title/original text only. Date/kind/AI permissions must constrain SQL before vector scan. Returned snippets are rechecked against live originals.
- Full original text, deterministic sentence-preferred chunks at most 600 Swift Characters, at most 80 overlap, persisted offsets/order/progress; at most 64 new embeddings per search pass. Do not permanently omit tail text or starve other records.
- Exact vector scan batches at most 4,095 candidates and merges by actual distances across all batches; no old 1,365-record eviction or 4,095-total truncation. Report remaining/unavailable/model-window coverage honestly.
- No App Xcode project regeneration. New production source membership may be added precisely, with all CLI compile inputs maintained. No new dependencies.

### Task 1: Deliver the combined full-text and complete-chunk retrieval path

**Files:**
- Modify `apps/wrist-notes/Sources/iPhone/DaybookSemanticIndex.swift`, `DaybookRetrieval.swift`, `DaybookSemanticSearchModel.swift`.
- Create focused helpers under `Sources/iPhone/` if needed: prefer `DaybookFullTextIndex.swift` for SQL keyword cache and `DaybookTextChunks.swift` for segmentation; keep the main worker readable.
- Modify `DaybookView.swift`, `DaybookAssistantModel.swift`, `AppleDaybookEmbedding.swift` only where needed for current result/progress/resource behavior. Do not add unrelated UI/provider changes.
- Extend `Tests/DaybookSemanticSmoke.swift`, `Tests/DaybookRetrievalSmoke.swift` and new focused smoke tests as appropriate.
- Update `scripts/test_semantic.sh`, `scripts/test_local.sh` and exact Xcode source references if new production files are added.

**Interfaces:**
- Preserve `DaybookSemanticSearching.search(query:records:dayStart:dayEnd:allowedKinds:limit:) async -> DaybookSemanticMatches` and existing callers/test fakes.
- Extend `DaybookSemanticMatches` with defaulted optional SQL keyword-result data and coverage progress; current constructions with only hits/status/evidence/generation must remain valid.
- `DaybookRetrieval.prepare` and `libraryRecords` consume fresh SQL keyword payloads when available, otherwise existing in-memory behavior remains valid. Keep original live-record validation and context limits. A query mismatch must not use an old SQL payload.
- The worker owns SQL caches and embedding operations. Expose pure shared keyword extraction instead of duplicating the current parsing rules. New helper APIs are internal to this task and must be documented in its report.
- `DaybookSemanticSearchModel` publishes partial results and continues bounded passes only while foreground/current and actual pending work can progress; cancellation and resource-reset semantics remain intact. Do not make Ask wait for the whole corpus.

- [x] **Step 1: Establish a RED using real full-tail behavior.**

Add a deterministic fixture embedding whose distinct vector appears only when it receives text beyond the old prefix, then drive existing public search and inspect durable chunks. Example shape:

```swift
let body = String(repeating: "普通记录。", count: 600) + "周五需要核对合同预算"
let record = DayRecord(id: UUID(), capturedAt: day, kind: .voice, title: "会议", text: body)
_ = await index.search(query: "合同预算", records: [record], dayStart: day,
    dayEnd: day.addingTimeInterval(86400), allowedKinds: [.voice], limit: 20)
let chunks = try db.query("SELECT snippet FROM semantic_chunks ORDER BY ordinal")
precondition(chunks.contains { $0["snippet"]?.string?.contains("合同预算") == true },
    "tail beyond 1800 characters must be indexed")
```

Use the existing real C extension script (`sh apps/wrist-notes/scripts/test_semantic.sh`). Record RED exit/error before implementation, adapt fixture text so it fits one 64-chunk batch.

- [x] **Step 2: Implement SQL full-text cache and integrate keyword consumption.**

Use `db.migrate` for a new derived domain. Add complete text projection table with date/kind indexes, stable IDs and complete-content fingerprints; synchronize changed/deleted records atomically with FTS. Probe `CREATE VIRTUAL TABLE ... USING fts5(..., tokenize='trigram')`; unsupported-tokenizer path uses scoped SQL substring queries. Use a fixed case-folding/Unicode normalization version consistently. For >=3 scalar literal terms use quoted MATCH plus literal validation; shorter terms use `instr`. SQL candidate scope must include date and required kinds. Generated summaries must be excluded from AI queries even if included in library queries. Do not interpolate literal text into SQL.

Add public-path assertions for Chinese short/long phrases, punctuation, quotes/operator text, case/Unicode, full tail, denied-library-visible vs AI-absent, summary-only content, date/type constraints and stale-query rejection. Force SQL write failure via real trigger and assert rollback plus current-memory fallback. Inspect EXPLAIN QUERY PLAN for date/kind index scope and FTS virtual-table access.

- [x] **Step 3: Implement persisted complete chunk planning and bounded progress.**

Segment complete original text by sentence-preferred Character boundaries with stable offsets and overlap. Preserve coverage for empty/whitespace, long sentence, emoji, repeated text and phrase at a boundary. Cache fingerprint includes original text, relevant metadata and segmentation version. Store total/finished/unavailable chunk state with vectors; incremental writes only add unfinished work. Schedule across records fairly. Nil/unsupported content must remain explicitly incomplete without blocking other records or retry-spinning; resource changes/rebuild allow retry. Upgrade existing v1 cache transactionally without touching business tables.

Keep cancellation checks before inference, after inference, and at atomic durable mutations. Model-space changes cannot mix vectors. Stream SQL-filtered vectors in bounded batches into real extension scans, combine record minima globally by numeric distance and stable tie breaks. Do not truncate total candidates or evict completed records due to previous small-cache limits.

Regression cases: a >64-chunk record progresses across requests and DB reopen; completed chunks are not rewritten (SQL trigger can enforce); tail edits invalidate correct cache; failure/unsupported content before a valid record does not starve it; >4,095 eligible candidates include a final best hit; old model and revoked/out-of-day data never enter candidate scan; clear/cancel during held inference cannot repopulate data.

- [x] **Step 4: Connect foreground continuation and preserve retrieval behavior.**

Use structured coverage in results, not parsing a status string. Publish each partial pass, yield between passes, stop on no-progress/resource-unavailable and when inactive/cancelled. Test with controllable service continuations, no timer stress loops. Query/day/source changes and explicit clear must invalidate the old generation; same-query resume can continue. Existing Ask/remote-confirmation and citation re-grounding tests must remain valid. Updated status text reports full-text availability and exact vector progress without a fabricated confidence score.

- [x] **Step 5: Run focused tests, self-review and commit task-only changes.**

Run `sh apps/wrist-notes/scripts/test_semantic.sh` plus affected retrieval/assistant/conversation scripts from `test_local.sh`; execute the full local runner if source lists changed. Record exact RED/GREEN commands/results, touched files, new internal interfaces, FTS behavior and physical-test limitations in the assigned report. `git diff --check` must pass. Use per-command identity `git -c user.name=Codex -c user.email=codex@openai.com commit ...`; no global git configuration. Stage only this task's files, never snapshot/docs owned by controller.

### Task 2: Integrate, verify native builds, document and review

**Files:** Task-one files, `apps/wrist-notes/docs/local-storage-and-retrieval.md`, dated second-phase report, this plan and prior architecture review update note.

**Interfaces:** Consume reviewed Task 1 commit diff; integrate content only after comparison with `/private/tmp/wiselife-search-20261020-baseline.json`. If a file changed concurrently, merge only task hunks; never overwrite or regenerate the project.

- [x] Complete Task 1 spec/quality review, fix important findings, obtain scoped rereview.
- [x] Compare baseline hashes, integrate task files, run full local regression in main plus iPhone/Watch simulator build.
- [x] If needed, run isolated synthetic iOS SQLite FTS probe to establish runtime support without user containers.
- [x] Update actual storage/query/progress documentation and dated test results. Clearly retain model-window/device-quality/performance limitations and third-phase scope.
- [x] Broad final review of this phase; resolve findings with one bundled fix and scoped rereview, verify final integrated sources and close the phase.
