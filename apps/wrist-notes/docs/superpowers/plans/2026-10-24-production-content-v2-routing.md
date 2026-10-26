# Production Content Segmentation V2 Routing Implementation Plan

> **For agentic workers:** Execute task-by-task against the approved specification and verify each task before proceeding.

**Goal:** Route normal iPhone automatic content processing through the approved V2 segmentation engine. Keep audio, ASR, and VAD on-device; send only transcript text through the user's authorized configured model; publish only source-current, fully covered, validated topic results. Titles and summaries may remain pending and do not gate topic finalization.

**Architecture:** Reuse the tested V2 segmentation engine in the normal iPhone enrichment scheduler. A repository adapter owns immutable source snapshots, SQLite checkpoints, revision-guarded publication, and presentation persistence; the engine remains responsible for bounded model requests and semantic validation.

**Tech Stack:** Swift, SQLite, Swift concurrency, existing configured text model, Xcode simulator toolchain.

## Global Constraints

- Audio recording, ASR, and VAD remain local to iPhone.
- Only authorized transcript text and required structured IDs may be sent to the configured provider.
- Never read, copy, or log API keys, audio bytes, signed media URLs, transcript payloads, or raw model replies.
- Preserve unrelated dirty paths and existing simulator source data.
- Timeline publication requires completed coverage and validated topic classification.

---

**Approved source:** `docs/superpowers/specs/2026-10-23-content-segmentation-v2-review.md` (user approved implementation in this conversation).

**Scope:** Normal iOS source scheduling, V2 input/checkpoint persistence, validated transactional publication, progress, recovery, simulator end-to-end acceptance. No Watch transfer/recording, ASR/VAD algorithm, unrelated recap/UI, or credential changes.

## Task 1 — Lock the production boundary with tests

- Add a production-routing smoke test using deterministic model replies.
- Assert the standard enrichment path requests chapter-internal segmentation, makes classification and metadata from each final segment's own full text, and never treats legacy adjacent-boundary-only calls as V2 completion.
- Assert model failure leaves the source unpublished and retry resumes durable validated checkpoints without repeating completed model stages.
- Assert incomplete coverage, stale source revision, manual edits, and transcript ownership mismatch reject publication atomically.
- Run the new test before implementation and confirm the intended routing assertions fail.

## Task 2 — Build a repository snapshot and durable checkpoint boundary

- Extend the existing repository command boundary to produce V2 `Input` from the active source snapshot, successful active ASR/VAD coverage, transcript rows, activity intervals, and protected manual boundaries.
- Use stable transcript row IDs based on job ID and row position; fingerprint algorithm, source revision, configuration/model identity, and every input fact.
- Persist V2 checkpoint envelopes in SQLite and reuse only exact identity/schema-validated results.
- Refuse to run on incomplete ASR coverage; let the V2 planner keep unverified VAD gaps provisional and prevent those segments from becoming final.

## Task 3 — Route normal automatic enrichment through V2

- Adapt `ConfiguredContentTextModel` to the V2 structured request interface without exposing credentials or audio; preserve confirmation/authorization and stale-configuration guards.
- On the standard scheduler path, obtain a stable input snapshot and run chapter analysis, adjacent topic merge, and classification through the V2 engine.
- Publish only after `validateOutput` and source revision/configuration revalidation.
- Preserve explicit manual split/merge/delete history; do not overwrite edited or suppressed segments.
- Treat title/summary fields as optional during V2 classification; when absent, allow the existing later field-generation path to read the final segment's complete owned transcript.

## Task 4 — Safely publish V2 results and expose stage progress

- Convert segment times to original source ranges with frame-safe slicing; persist row ownership, V2 provenance, editorial classification/evidence, presentations, and source signature in one short SQLite transaction.
- Validate full original transcript ownership (including empty rows), non-overlap, audio bounds, legal region/gap boundaries, 40-minute duration, no source conflicts, and exact input freshness before commit.
- Ensure timeline projection includes only `isFinal == true` and meaningful classification; provisional/low-information/pending results remain outside the main timeline.
- Map V2 stages into existing per-source progress UI without leaking transcript/model content into diagnostics.

## Task 5 — Verify, build, and exercise the real simulator path

- Run V2 engine tests and focused repository/enrichment/authorization/presentation tests.
- Build and install the normally signed iOS simulator app without clearing its data container.
- Reprocess the two already captured test recordings through the ordinary app scheduler, verify model calls and durable results in the normal app database, and confirm meaningful completed segments appear in the timeline while low-information/pending results do not.
- Relaunch the app and verify checkpoints prevent duplicate calls and results remain stable. Record exact test/build outcomes and any simulator/network limitations.

## Acceptance

- The regular iPhone scheduler—not a lab command—uses V2.
- Model requests contain ASR text/structured IDs only; no audio bytes, API key, or signed media URL.
- Only validated, fully covered, non-provisional segments can be final and timeline-visible.
- Stale or invalid results leave the prior database state unchanged.
- Completed stages survive retry/relaunch and are reused for identical inputs.
