# WiseLife Sliding Group Audio Processing Implementation Plan

> **For agentic workers:** Execute this plan inline in the existing workspace. Preserve all pre-existing uncommitted changes. Do not reset, stage, commit, or run test suites.

**Goal:** Process each recording group incrementally as contiguous files arrive, isolate exhausted inference windows, run topic segmentation over successful regions, and freeze every finalized boundary.

**Architecture:** A recording group remains one logical `AudioSourceSnapshot` whose ranges reference the received files. While the group is open, discovery exposes only the readable ordinal prefix beginning at zero; when the group closes, every readable run is included with missing ordinals represented as discontinuities. The existing five-minute ASR/VAD windows and their two-second context remain the inference units. Failed required-stage windows receive at most three automatic retries, then become explicit coverage gaps so processing and semantic segmentation continue on either side. Only segments with complete ASR/VAD coverage and stable topic boundaries become `isFinal`; new files replan the source and reuse exact unchanged windows while only the open tail is reconciled.

**Tech Stack:** Swift, SQLite migrations, SwiftUI, existing `AudioWindowPlanner`, `AudioProcessingCoordinator`, `ContentSegmentationV2`.

## Global Constraints

- Preserve original group audio files after inference failure; “skip” means stop automatic retries, not delete source audio.
- A missing ordinal or exhausted required-stage window is a hard coverage gap; no semantic segment may cross it.
- `isFinal=true` requires complete ASR/VAD coverage and a completed topic boundary; finalized ranges remain immutable to automatic processing.
- Group receive closure is independent of inference coverage completion.
- Close by explicit contiguous final ordinal, or after 24 hours without a new file when a newer group exists.
- Preserve the existing short-recording rule at 30 minutes and existing ASR core-window sizing/context.
- Do not run tests or edit unrelated worktree changes.

---

### Task 1: Make Group Discovery Incremental and Gap-Aware

**Files:**
- Modify `apps/wrist-notes/Sources/iPhone/AudioSourceDiscovery.swift`
- Preserve the current uncommitted `AudioSourceSnapshot` fields in `apps/wrist-notes/Sources/iPhone/AudioProcessing.swift`

**Interfaces:**
- `AudioSourceDiscovery.sources(explicit:)` continues returning one `AudioSourceSnapshot` per `recordingGroupID`.
- Open groups include only readable ordinal `0...N1`, where every ordinal exists and each file has valid audio metadata.
- Closed groups include all readable files as ordered ranges; offset/ordinal holes remain explicit discontinuities.

- [x] Compute the highest readable contiguous prefix from ordinal zero for open groups.
- [x] Replace the 12-hour idle threshold with 24 hours, retaining the newer-group requirement.
- [x] Keep explicit completion dependent on one final ordinal and all ordinals `0...final` being present.
- [x] On idle closure with ordinal holes, include later readable runs without bridging missing ordinals.
- [x] Keep a missing/invalid local audio asset distinct from a not-yet-arrived ordinal; do not fabricate silence or file content.

### Task 2: Persist Bounded Window Retry State and Continue the Queue

**Files:**
- Modify `apps/wrist-notes/Sources/iPhone/DaybookDatabase.swift`
- Modify `apps/wrist-notes/Sources/iPhone/AudioProcessingRepository.swift`
- Modify `apps/wrist-notes/Sources/iPhone/AudioProcessingCoordinator.swift`

**Interfaces:**
- Add a persisted automatic retry counter to `audio_processing_jobs` in schema version 14.
- `fail(job:state:)` counts inference failures only; resource-unavailable and cancellation outcomes do not consume the retry budget.
- The coordinator retries a failed required-stage window at most three times after its initial attempt. After exhaustion it remains terminally failed and the queue claims the next pending window.

- [x] Add a nonnegative retry counter with default zero for existing jobs.
- [x] Increment it only for `.failed` inference outcomes and retain a safe error state without storing provider-private messages.
- [x] Requeue failed jobs only while automatic retry budget remains; make resource wakeups skip exhausted failures.
- [x] Ensure `.failed` after exhaustion does not prevent `claimNext` from processing later pending windows.
- [x] Preserve successful ASR/VAD sub-results when retrying another incomplete required stage.

### Task 3: Build Topic Inputs from Successful Regions Around Gaps

**Files:**
- Modify `apps/wrist-notes/Sources/iPhone/ContentSegmentRepository.swift`
- Modify `apps/wrist-notes/Sources/iPhone/ContentSegmentationV2.swift`

**Interfaces:**
- `contentV2Input(sourceID:)` returns successful transcript/coverage regions even when another active window is pending or exhausted.
- Unsettled required-stage windows remain uncovered and keep affected output provisional; exhausted failed windows become hard barriers.
- The topic engine analyzes each continuous region independently; it must not merge across a failure or missing-file boundary.

- [x] Replace the all-active-ASR-success guard with per-window result collection.
- [x] Keep transcript spans only when their owning required-stage evidence is usable; retain original ASR data in storage for diagnostics/retry.
- [x] Map exhausted ASR/VAD failures and source-file gaps to hard boundaries; uncovered in-flight/retrying windows cannot produce final output across their gap.
- [x] Ensure a failure in one region does not cancel topic requests for successful regions on either side.
- [x] Keep `isFinal` gated by complete ASR/VAD coverage and a nonprovisional topic boundary.

### Task 4: Advance the Sliding Topic Tail Without Rewriting Final Segments

**Files:**
- Modify `apps/wrist-notes/Sources/iPhone/ContentSegmentRepository.swift`
- Modify `apps/wrist-notes/Sources/iPhone/AudioProcessingRepository.swift`
- Modify `apps/wrist-notes/Sources/iPhone/AudioProcessingModel.swift` only if a new-source revision wake is needed

**Interfaces:**
- Each newly received group file updates the same source identity and triggers window planning/reconciliation.
- Exact unchanged ASR/VAD windows reuse their persisted results; added or content-changed windows are processed.
- New topic work starts from the unresolved tail with existing overlap/context while preserving all finalized ranges.

- [x] Preserve the existing exact-window identity matching and source revision guards.
- [x] Verify the open tail advances when the next contiguous ordinal arrives, without changing prior `isFinal` ranges.
- [x] Allow successfully covered regions on both sides of an exhausted window to finalize independently.
- [x] Keep incomplete tail and exhausted-gap segments off the timeline until their own finalization conditions are met.

### Task 5: Review the Implementation Diff

**Files:**
- Review only the files listed in Tasks 1–4.

- [ ] Inspect the final diff against the pre-existing dirty baseline and confirm no unrelated edits were overwritten.
- [ ] Check database migration ordering, retry-terminal behavior, coverage barriers, and final-range locking by source review.
- [ ] Do not run test commands or modify test files under the current instruction.
