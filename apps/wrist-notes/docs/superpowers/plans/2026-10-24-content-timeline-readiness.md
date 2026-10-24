# Final content timeline readiness implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A content segment becomes `isFinal == true` only after complete successful ASR/VAD coverage, a closed boundary, and a completed AI topic-unification pass; finalized ranges stay locked from future automation.

**Architecture:** Persist boundary/coverage readiness separately from `isFinal`. Reconciliation produces provisional candidates, topic AI may split/merge only provisional candidates, and a guarded finalization command runs only after that topic pass has completed. Classification follows finalization and gates timeline visibility; title/summary follow classification and remain independently retryable. Timeline selection routes either content-segment merges or existing raw long-recording merges, never both.

**Tech Stack:** Swift, SwiftUI, SQLite, Foundation-only smoke tests compiled by the repository scripts, Xcode simulator build.

## Global Constraints

- Preserve the existing uncommitted adaptive-summary, location, recap, prototype, and other user changes. Do not reset files, switch branches, or broadly stage changes.
- Finalized boundaries never change through reconciliation, ASR/VAD retry, topic inference, or source append. Only a user-initiated adjacent timeline merge may replace final segments; that explicit choice is a terminal topic decision for its result.
- AI topic decisions `sameTopic`, `newTopic`, and `uncertain` must all reach a persisted terminal outcome. `uncertain` conservatively keeps the current boundary. Failure, cancellation, unavailable model, or unresolved remote consent leaves affected segments nonfinal.
- Classification, title, and summary are later stages; they do not change `isFinal`. Timeline requires final + text + persisted `meaningful` classification.
- Segment title generation must use that segment's own transcript. Preserve manual title edits and adaptive model-window/chunk budgeting.
- Keep old on-device Codable data readable. Any new optional persisted fields must decode when absent.
- Keep long-recording file concatenation behavior separate from content-segment metadata merging.
- No commits, pushes, deployment, account operations, or device-data clearing are part of this plan.

## File Map

- `Sources/iPhone/ContentSegmentation.swift`: represent closed, fully ASR/VAD-covered draft ranges without prematurely making them final; persist backward-compatible readiness metadata.
- `Sources/iPhone/ContentSegmentRepository.swift`: lock final ranges during reconciliation; support provisional topic split/merge; finalize only after completed topic pass; reject final splits and nonfinal timeline merges; keep optimistic revision checks.
- `Sources/iPhone/ContentEnrichmentService.swift`: topic-decision completion and ordering, production classification, then title/summary; retain per-segment transcript and model-budget behavior.
- `Sources/iPhone/ContentSegmentModel.swift`: repository commands, classification/manual field actions, and segment operation lifecycle exposed to UI.
- `Sources/iPhone/ContentSegmentPresentation.swift`, `Sources/iPhone/DayRecord.swift`: strict final/classification presentation provenance while decoding older data.
- `Sources/iPhone/DaybookView.swift`, `Sources/Shared/VoiceNote.swift`: content-segment selection and typed merge routing beside unchanged long-recording merge.
- `Sources/iPhone/ContentSegmentDetailView.swift`: show real processing stage; remove neighbor merge; gate split; add separate per-segment title/summary generation controls.
- `Tests/ContentSegmentationSmoke.swift`, `Tests/ContentEnrichmentSmoke.swift`, `Tests/ContentSegmentPresentationSmoke.swift`, `Tests/RecordMergeSelectionSmoke.swift`: lifecycle, final-lock, model-failure, visibility, and typed-selection regressions.
- `scripts/test_content_segments.sh`, `scripts/test_content_enrichment.sh`, `scripts/test_content_segment_presentation.sh`, `scripts/test_local.sh`: required focused verification.

## Tasks

### 1. Separate boundary readiness from finality

- [x] Add failing repository/segmentation tests: full ASR+VAD coverage and a closed deterministic boundary produce a boundary-ready but nonfinal segment before topic inference; incomplete coverage is not boundary-ready; legacy stored segments still decode.
- [x] Run `./scripts/test_content_segments.sh` and confirm the new assertions fail for the current premature-final behavior.
- [x] Add optional persisted readiness state to drafts/segments and make `ContentSegmentation.build` report readiness while emitting all automatic drafts with `isFinal == false`.
- [x] Reconcile without allowing a new derivation to expand, shrink, split, merge, or reuse-and-rewrite an already-final segment. Preserve final ranges and process appended material as provisional new ranges.
- [x] Re-run `./scripts/test_content_segments.sh`; verify existing manual edits, tombstones, source relocation, and final-range invariants remain green.

### 2. Make AI topic unification the finalization gate

- [x] Add failing enrichment tests proving topic splits/merges remain provisional during the topic stage; successful completion of every eligible boundary decision finalizes only ready ranges; topic failure/cancellation/consent wait leaves them nonfinal; `uncertain` is persisted as a conservative keep-boundary result.
- [x] Run `./scripts/test_content_enrichment.sh` and confirm expected failures before changing implementation.
- [x] Add a guarded repository finalization command. Run it only after the topic pass returns successfully; split/merge products stay provisional until this command. Store topic terminal outcomes so retries and restarts do not re-run completed decisions unnecessarily.
- [x] Ensure automatic topic candidates and mutations only touch nonfinal segments. Final inputs are excluded from future topic comparisons and cannot be changed by later transcript append/reprocessing.
- [x] Add a regression for paged topic-boundary traversal so every boundary is visited once; fix offset progression if needed.
- [x] Re-run `./scripts/test_content_enrichment.sh` and `./scripts/test_content_segments.sh`.

### 3. Persist production classification before publishing timeline records

- [x] Add failing presentation tests that reject nonfinal voice records and require a persisted `meaningful` classification; verify existing legacy records without final provenance remain readable but hidden.
- [x] Run `./scripts/test_content_segment_presentation.sh` and confirm the current permissive filter fails.
- [x] Add optional `isFinal` to `DayRecord.ContentProvenance`; populate it from segments and filter timeline records by `isFinal == true`, nonempty transcript, and `classification == "meaningful"`.
- [x] Add the production classification request/result path after finalization, using only that segment's transcript and guarded persistence against segment revision/content signature. Persist model/version/evidence metadata. Classification failure must not undo finality or fabricate a classification.
- [x] Verify title/summary work starts after classification and title input remains the segment's own full transcript, including adaptive chunking paths.
- [x] Re-run presentation and enrichment scripts.

### 4. Expose truthful per-segment processing and field actions

- [x] Add failing tests for independent manual title and summary actions, manual-title preservation, and stale-write rejection without changing finality/classification.
- [x] Add enumerable stage state for topic, classification, title, and summary sufficient for the detail screen to distinguish waiting, processing, completed, retryable failure, unavailable model, and consent required. Do not show an estimated percentage without measured progress.
- [x] Add per-segment “生成/重新生成标题” and “生成/重新生成总结” operations using that segment's transcript, current model/privacy confirmation, and existing adaptive context budget. Keep field writes independent.
- [x] Remove neighbor merge from the detail menu and reject splitting final segments in the repository as well as the UI. Keep delete and undo behavior.
- [x] Re-run the enrichment and segment scripts; add UI-level smoke assertions where the current test harness permits.

### 5. Add timeline segment multi-selection with safe typed routing

- [x] Add failing selection tests for same-source consecutive content segments, hidden intermediate segments, mixed sources, mixed content/raw recordings, nonadjacent selections, and final-only eligibility.
- [x] Add a distinct content-segment selection mode/action in `DaybookView`, preserving the independent long-recording merge path. Do not concatenate audio for content-segment merges.
- [x] Make repository merge require final inputs for the timeline path and preserve source/range provenance; the output remains final by explicit user decision, while classification/title/summary are recomputed from merged transcript.
- [x] Ensure failed merge preserves selection and source items; success clears selection and refreshes/repositions to the result.
- [x] Run `./scripts/test_local.sh` and focused segmentation/presentation scripts.

### 6. Verify complete implementation

- [x] Run `./scripts/test_content_segments.sh`.
- [x] Run `./scripts/test_content_enrichment.sh`.
- [x] Run `./scripts/test_content_segment_presentation.sh`.
- [x] Run `./scripts/test_local.sh`.
- [ ] Build the `WristNotes` scheme for an available iOS simulator. If CoreSimulator or Xcode caches remain unavailable in the sandbox, report the exact environment limitation and still run every focused script that is available.
- [x] Inspect the final diff against the starting dirty state, confirm only intended hunks/files changed, and report simulator/visual acceptance separately from automated checks.

**Verification notes (2026-10-24):** Focused segmentation, enrichment, authorization, configured-model, presentation, and record-merge-selection smoke tests passed. The selection regression also confirms that a hidden intermediate segment and adjacent segments from different recordings cannot be merged. `test_local.sh` reached `test_audio_duration.sh` and stopped because this macOS runtime has no AAC encoder; AudioToolbox then raised CoreAudio error `1718449215`. The simulator build compiled Swift sources but stopped at link with `ld: framework 'Pods_WristNotes' not found`. No simulator launch or visual acceptance was completed.

## Plan Self-Review

- The finalization gate explicitly combines successful ASR/VAD range coverage, closed boundaries, and terminal AI topic unification; title, summary, and classification do not delay it.
- Both success and interruption paths are specified, including cancellation, remote consent, model unavailability, stale revisions, retry, and persisted uncertain decisions.
- Automatic final-boundary locking is tested independently from permitted user timeline merges.
- Timeline visibility, detail actions, long-recording merge routing, compatibility with saved data, and the adaptive-summary edits are covered without expanding into Watch/audio capture or server work.
- Tests are written before implementation in each behavior group, with the exact scripts needed to observe red and green.
