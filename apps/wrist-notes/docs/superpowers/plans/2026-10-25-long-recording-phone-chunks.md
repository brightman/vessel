# Feature Implementation Plan

**Goal:** Store new iPhone long recordings as durable ordered audio chunks, process sealed chunks with the shared Watch/iPhone ASR/VAD pipeline, and enforce the agreed four-chunk topic-segmentation gate.

**Architecture:** Reuse `recording_sessions` / `recording_chunks` as the cross-device source model while keeping Watch transport receipts Watch-only. Phone capture seals 10-minute AAC chunks into a recoverable local manifest. Each sealed chunk is idempotently committed to the session repository; session end closes the manifest. A pure policy gates V2 topic requests and selects a single-recording final path for closed sources with at most three chunks and at most 30 minutes. Timeline finality continues to require complete ASR/VAD coverage for the range and a terminal editorial decision.

**Tech Stack:** Swift, AVAudioRecorder, SQLite, AVAudioFile, SwiftUI, Xcode iOS simulator.

## Global Constraints

- Preserve the current shared checkout and all existing user edits; do not reset, stash, broadly stage, commit, or push.
- Keep Watch recording/transfer behavior unchanged. Keep short flash recordings on their current single-file path.
- A chunk is immutable after sealing. Recovery/import is idempotent and never deletes the only valid audio copy before database commit.
- ASR/VAD can process complete sealed chunks before the session ends. Topic requests wait until four sealed chunks; the closed <=3-chunk, <=30-minute path skips AI topic/merge requests.
- A growing source must not expose provisional timeline items. Manual merges and title/summary generation remain final-content operations.
- Simulator build and UI acceptance are separate from Watch hardware validation.

---

## Task 1: Policy and V2 single-recording path

**Files:** `ContentSegmentationV2.swift`, `ContentSegmentationV2ProductionSmoke.swift`.

- [x] Add tests for open-source 4-chunk eligibility and closed-source <=3/<=30-minute bypass.
- [x] Add a topic-disabled V2 execution path that skips AI topic/continuity-merge calls but retains deterministic hard boundaries, final classification, and validation.
- [x] Run the focused V2 script.

## Task 2: Source gating and finality

**Files:** `AudioProcessingModel.swift`, `ContentSegmentRepository.swift`, focused content tests.

- [x] Gate enrichment using current source chunk count, duration, and end state.
- [x] Preserve range-level `isFinal` semantics: require full ASR/VAD coverage and a terminal editorial decision for that range; the whole source need not close after the four-chunk gate is reached.
- [x] Add policy coverage for incomplete/open sources below and at the threshold; existing timeline tests cover final-item visibility.

## Task 3: Durable iPhone long-recording chunks

**Files:** `PhoneRecordingDraftStore.swift`, `PhoneRecorder.swift`, `PhoneRecordingSession.swift`, `WiseLifeRuntime.swift`, session repository and phone recording tests.

- [x] Add manifest-backed chunk metadata and migration/recovery for existing single-file drafts.
- [x] Rotate iPhone long capture into 10-minute 16 kHz mono AAC files and preserve interruption/stop behavior.
- [x] Idempotently import sealed chunks into the shared session repository; close the session only after final chunk persistence.
- [x] Verify legacy drafts, crash recovery, and discard through phone-session tests. Repository retry/duplicate integration tests are present but blocked locally because CoreAudio AAC fixture creation fails before those tests start.

## Task 4: Simulator verification and documentation

**Files:** schema/recording lifecycle documentation and focused verification report.

- [x] Run phone-recording, V2, recording-session, audio-processing, and timeline tests. Phone draft, V2, content-segment, recording-session, and audio-processing suites pass; repository/streaming smoke suites cannot start because local CoreAudio AAC fixture creation fails before test logic.
- [x] Build, install, and launch the iPhone app in the existing iOS 26.3 simulator; the home screen and recording entry sheet render. A real microphone capture/10-minute rotation was not exercised in this turn.
- [x] Record the local CoreAudio fixture limitation; Watch hardware checks remain separate.
