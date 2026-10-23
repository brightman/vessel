# Ten-minute streaming recording Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [x]`) syntax for tracking.

**Goal:** Default new Watch long recordings to durable ten-minute files and deliver/handle sealed files before the recording ends, with backward compatibility and inspectable progress.

**Architecture:** Keep the existing continuous PCM writer, V2 durable transfer, receiver, SQLite processing queue and content derivation. Widen physical chunks with explicit receiver capability; keep bounded inference independent. Add a real-component streaming integration fixture and show partial sync honestly.

**Tech Stack:** Swift, AVFAudio, WatchConnectivity, SQLite, SwiftUI; iOS 26 and watchOS 10.

## Global Constraints

- Work only in `/Users/karama/.codex/worktrees/887a/Vessel` on `codex/wiselife-streaming-10m`, baseline `f354f5ebacd2f9f355134b843550efdcbb4cb586`. Do not touch original checkout, devices, private audio, other branches or unrelated work. Controller delivers reviewed diffs to original with conflict checks.
- New long capture seals at exactly 600 effective seconds, 16 kHz mono AAC, 32 kbps. Short thought recording stays unchanged. Default capture must work without DEBUG opt-in. No microphone activation by tools.
- Model core windows remain <=300 seconds, input <=304 seconds. The VAD noSpeech threshold remains 600 seconds across files and successful coverage; missing/failed audio is never silence.
- Old 300-second chunks and legacy single files remain valid and retain original bytes. Keep wire version 2 and existing keys; negotiate receiving maximum duration through an optional field with conservative 300-second legacy fallback.
- File delivery is system scheduled. Only durable phone save permits ACK. Keep <=4 total in-flight files, retries, pairing isolation, stale receipt guards and completion requiring all chunks plus end ACK.
- SQLite stores metadata/jobs/results/indexes; original audio remains files. Preserve protection, tombstones, manual edits, local-first models and no implicit downloads/cloud calls.
- No physical install/restart/uninstall or mic actions. Unsynced Watch audio has not yet been backed up. Software tests/builds do not prove device transmission or capture endurance.
- Use focused tests per task; final integration runs full local suite and generic iOS workspace build once. Existing baseline deprecations must be reported accurately. Do not change long-speaker resource gate.
- New flow and physical acceptance limitations are documented in `docs/superpowers/specs/2026-10-22-streaming-recording-design.md`.

### Task 1: Ten-minute capture and compatible early upload

**Files:** Modify `Sources/Shared/RecordingChunkProtocol.swift`, `Sources/Shared/RecordingChunkTransport.swift`, `Sources/Watch/SegmentedAudioCapture.swift`, `Sources/Watch/WatchRecordingSessionStore.swift`, `Sources/Watch/WatchChunkTransferQueue.swift`, `Sources/Watch/WatchRecorder.swift`, `Sources/iPhone/RecordingChunkReceiver.swift`, `Tests/SegmentedAudioCaptureSmoke.swift`, `Tests/WatchRecordingSessionStoreSmoke.swift`, `Tests/RecordingSessionSmoke.swift`, `Tests/RecordingChunkTransferSmoke.swift` as needed.

**Interfaces:** Retain existing public types and wire keys. Add `RecordingCapabilityReply.maximumChunkDuration: TimeInterval?` with default nil and compatible decoding. New receiver explicitly advertises 600. Queue tracks negotiated maximum and exposes a read-only `requiresCompanionUpdate` derived from unsaved unsupported chunks. Keep old init call sites source-compatible. Shared frame/duration limits must be consumed by writer and recovery; do not leave the 4,800,000-frame recovery ceiling.

- [x] RED: modify the real AAC writer boundary fixture to 1,200 seconds + 17 frames. Expected sealed frame counts `[9_600_000, 9_600_000, 17]`, offsets `[0,600,1200]`; verify first file seals before finish and tones adjacent to 600-second boundary stay on their own side. Exercise stop concurrent with sealing at 9,600,000 + 128 frames and exact once tail. Run `sh scripts/test_watch_recording_sessions.sh` and record intended failure before code.
- [x] RED: add real recovery coverage for >300 and <=600 second partial metadata, retaining original partial bytes. Keep old 300-second descriptor decode/receipt cases; reject >600 second descriptors. Add queue/receiver integration cases: no end marker sends a 600-second file to a modern receiver; missing capability field decodes as legacy 300 and does not enqueue 600-second files or finalize that session; old short files still send; modern re-handshake releases blocked files with durable ACKs. Exercise malformed duration rejection. Run `sh scripts/test_recording_sessions.sh` and `sh scripts/test_recording_transfer.sh` with expected failures.
- [x] GREEN: centralize physical frame bounds, change capture/validation/recovery to 600, remove DEBUG-only long-capture branch, keep thought AVAudioRecorder route. Do not silently fall back if continuous capture fails. Retain seal->store->refresh upload ordering while recording continues. In `pump`, skip unsupported chunk/end work without consuming retry budget; show update-needed message on Watch and keep all original files.

```swift
// Wire decoding of old replies must remain supported.
var maximumChunkDuration: TimeInterval? = nil
// Receiver reply explicitly sets RecordingChunkProtocol.chunkDuration.
// Queue accepts a positive finite limit, legacy nil means 300; never trust NaN/zero.
// Newly recorded long audio enters beginContinuousCapture without developerEnabled.
```

- [x] GREEN: run the three focused scripts plus `sh scripts/test_recording_repository.sh`; inspect exits and preserve old receipt/restore coverage. No full suite or native build yet. Write a report with files, API decisions, RED/GREEN evidence, and limitations; commit only task-owned files.

### Task 2: Streaming pipeline integration and progress presentation

**Files:** Create `Tests/StreamingRecordingSmoke.swift`, `scripts/test_streaming_recording.sh`, `verification/streaming-recording.md`. Modify `Sources/Watch/WatchRecorder.swift`, `Sources/Watch/WatchContentView.swift`, `Sources/iPhone/PhoneWatchStatus.swift`, `Sources/iPhone/Localizable.xcstrings`, `scripts/test_local.sh`; change `AudioProcessingModel.swift`, `AudioProcessingCoordinator.swift`, `RecordingChunkReceiver.swift`, or content derivation only for concrete gaps exposed by integration. Avoid new Xcode source membership by keeping new executable fixture outside app targets.

**Interfaces:** Consume Task 1's duration capability and existing real `RecordingChunkWriter`, `WatchRecordingSessionStore`, `WatchChunkTransferQueue`, `RecordingChunkReceiver`, `RecordingSessionRepository`, `AudioProcessingRepository`, `AudioProcessingCoordinator`, `ContentSegmentRepository` and `ContentSegmentation`. The actual Watch adapter must surface active session identity for honest status. iPhone can show receiving/incomplete audio without claiming the Watch is currently recording when that fact is unknown.

- [x] Build a synthetic streaming fixture, no microphone or model downloads. Generate AAC with bounded buffers using production writer; stage queue sends through real receiver and SQLite, injecting only OS delivery and native inference. A receive notification must trigger the production coordinator with real persistent repositories. If native AudioProcessingModel cannot be compiled in the macOS script, use the same documented receive notification boundary and record that native facade runtime remains build-verified only.

```swift
// Stream first 600-second chunk; no RecordingSessionEnd exists.
// Assert receiver session is incomplete, receipt exists, and at least one stable
// ASR/VAD window has committed before writer.finish(). Original Watch file exists.
// Append second full chunk; replay its delivery; verify one chunk row/receipt and
// no re-inference of unchanged committed windows. Reopen SQLite/coordinator and
// preserve progress. Finish tail and send end; all chunks+end required for complete.
// Check every model input <=304 sec and core <=300 sec.
// Confirm 600 sec successful noSpeech from [480,1080] crosses file boundary 600
// and splits content only once; a failed/missing middle range must not do so.
// All content references valid original ranges; files are not concatenated or rewritten.
```

- [x] If the fixture exposes a production gap, capture expected failure, make the narrow fix, then rerun. Existing working pipeline tests can be characterization coverage; do not manufacture failures. Test user-visible active recording/partial sync derivation with a pure helper in an existing Foundation-only file if needed; exact wording assertions are unnecessary.
- [x] Show Watch recording session's partial sync directly (recording in progress and saved count/total sealed count); do not label a still-recording session wholly synced. Retain existing disclosure and no false error when end is pending. Phone explanatory text must describe automatic sealed-chunk sync, not say all recordings wait until end. Add zh/en/ja strings, preserving unrelated catalog entries.
- [x] Wire `test_streaming_recording.sh` into `test_local.sh`. Run streaming + affected focused tests and then full `sh scripts/test_local.sh` once with log under `/private/tmp/wiselife-streaming-development/`. Build workspace Debug generic iOS using existing Pods/cache, signing disabled if needed; build must include Watch. Do not install. Verify release preprocessing does not reintroduce DEBUG-only capture.
- [x] Update verification report with actual tests/build commands, outcomes, known baseline warnings and device tests remaining. Mark spec as implementation-vs-device evidence. Commit task files and report exact commit(s), tests and concerns.

## Delivery

Controller performs task reviews and final whole-diff review, then merges only this baseline-relative task diff into `/Users/karama/Documents/Vessel`, preserving current concurrent Watch activation/status fixes and unrelated edits. Verify conflict-free file deltas, focused regressions and original workspace compile as needed for actual integration. Never stage the original checkout broadly or push a local snapshot ancestor. Physical acceptance is user-started >=21-minute recording with early phone receipts before stop, reconnect/replay, final counts/duration and source preservation; prior unsynced recording must be backed up first.
