# Simulator Content V2 Implementation Plan

> **For agentic workers:** Use subagent-driven-development for the shared engine and independent review. The controller owns simulator preparation, integration, and UI verification. No commits are requested.

**Goal:** Import the real 6h42m recording into an isolated simulator, execute the v2 content strategy there, and inspect durable results in the native app.

**Architecture:** A Foundation-only Swift engine owns evidence validation, blocks, chapters, model-output validation, merging, and final classification. A development runner compiles that same source for the simulator and uses the already configured Doubao service. A guarded test publisher saves validated results into the simulator's SQLite database; the native app reads the normal content tables. The physical phone and original simulator remain unchanged.

**Tech Stack:** Swift, CoreSimulator, SQLite, existing WiseLife workspace and model configuration.

## Global Constraints

- Review specification: `../specs/2026-10-23-content-segmentation-v2-review.md`.
- Keep the original audio intact; verify SHA256 and 24129.276 seconds. Reuse successful ASR/VAD fixtures with provenance; do not claim new simulator ASR inference.
- 180-second blank candidates require full ASR/VAD coverage, noSpeech >=90%, speech <=5%, uncertain <=10%. Missing coverage is not silence.
- Full transcript blocks; about 1800-second candidate chapters; final automatic segments <=2400 seconds; at most 5 splits per model chapter reply.
- JSON plans must completely cover ordered blocks. No invented IDs, overlap, omitted text, or cross-gap merges.
- No source-ID hardcodes or manual preview overrides in the algorithm. Navigation is not proof of a taxi trip or a company destination.
- Clone the simulator. Keep source recordings, existing settings and keychain credentials intact; never print credentials.
- Existing dirty checkout contains the app baseline. Work on narrowly owned paths in place; do not reset, broadly stage, or create an incomplete worktree from HEAD.
- This is a simulator pilot of the new engine. Production scheduling, partial streaming publication and physical deployment remain a subsequent integration step. Do not mark those spec requirements complete.
- Daily recap generation must remain disabled in this test copy, and generated historical recaps must not be invalidated.

## Task 1: Shared deterministic engine and structured model pipeline

**Files:** Create `Sources/iPhone/ContentSegmentationV2.swift`, `Tests/ContentSegmentationV2Smoke.swift`, `scripts/test_content_v2.sh`.

**Interface:** A Codable input carries source identity/duration, sorted transcript rows with stable IDs, successful ASR/VAD coverage, activity intervals, and explicit discontinuity/manual boundaries. A Codable plan contains evidence blocks, verified gap intervals, and candidate chapters. An async engine receives an injected JSON model closure and checkpoint storage closure. Output contains final nonoverlapping block ranges, title, summary, classification, evidence IDs, and original transcript ownership. Exact Swift interfaces are to be recorded in the task report before simulator integration.

- [x] Write behavior tests and observe failure for speech-filled ASR blanks, missing VAD coverage, full text preservation, chapter-internal split, invalid/omitted IDs, cross-gap/overlong merge refusal, and low-information classification.
- [x] Implement deterministic preparation and strict validation, including bounded one-repair model policy and no silent text truncation.
- [x] Implement chapter analysis, adjacent merge proposals, and final full-text title/summary/classification requests. Persist per-unit validated checkpoints using input/prompt/model identity. Surface stage-specific errors.
- [x] Run `sh apps/wrist-notes/scripts/test_content_v2.sh`; review source and test outcomes. Do not modify current production routing in this task.

## Task 2: Isolated simulator input, runner, SQLite publication

**Files:** Create development tools under `Tools/ContentV2Simulator/`; use reports under `/Users/karama/Documents/WiseLife-Reports/2026-10-23-simulator-content-v2/`. Modify normal content presentation only where required for persisted classification.

- [x] Clone the existing simulator and boot the clone. Record both UDIDs; copy original audio and successful ASR/VAD input only into the clone.
- [x] Build a simulator runner using Task 1's exact shared source. Reuse configured model transport with redacted errors and keychain lookup inside simulator.
- [x] Replay available frozen responses where schema/input match; run a genuine configured-model pass for the optimized schema. Save request/result evidence locally outside git.
- [x] Validate complete original row ownership, gaps, segment duration caps, classification, and all final evidence IDs before publishing.
- [x] Publish atomically into the clone's SQLite content tables and cached presentations; retain low-information output for inspection while filtering it from the main timeline. Preserve prior test state with a backup and refuse publication to an unexpected container/source.
- [x] Build and install the native workspace app in the clone. Verify final output survives launch/restart without old enrichment overwriting the pilot result.

## Task 3: Native UI, independent review, comparison report

**Files:** Create `verification/2026-10-23-simulator-content-v2.md`; update the review document's implementation status accurately.

- [x] Review the shared engine and importer for coverage loss, stale publication, unsafe overwrite and sample-specific rules; resolve material findings.
- [ ] Through Simulator UI, inspect the recording duration/date, meaningful-only timeline, title/summary/full text, segment playback, and restart persistence.
- [x] Save a comparison with the prior preview, per-segment start/duration/topic/summary, model request count, and clearly separated untested production/device behavior.

## Progress

- Initial evidence: original audio and full successful ASR/VAD fixture exist. Existing configured simulator contains `Doubao-Seed-2.0-mini` under `com.vessel.wristnotes`; credentials stay in its keychain.

## Final status

- Shared engine and simulator execution/publication completed:19meaningful+12lowInformation;31normal SQLite segments;69706rows preserved.
- Native workspace build/install and source-table/timeline stability across restart verified.
- UI click/playback acceptance remains open:CUA native pipe startup failure; screenshot fallback permission not received.
- Presentation regressions pass; the bundled assistant suite had separate failures during concurrent workspace changes, recorded in verification.
- Production automatic routing and phone rollout remain outside this pilot. See `../../../verification/2026-10-23-simulator-content-v2.md`.
