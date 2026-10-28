# Watch M4A Metadata and Recovery Implementation Plan

> **For agentic workers:** Execute inline in the current checkout. Do not reset or commit unrelated worktree changes.

**Goal:** Persist each hourly Watch recording as a deterministically named M4A containing its start time and group identity, then recover and transfer it without JSON sidecars.

**Architecture:** Keep one ordinary M4A per hour. Name each file with group UUID, zero-based ordinal, and UTC start timestamp. Write creation time into the M4A container, derive the same file identity from its name for recovery, and pass the corresponding property-list index fields in the same `transferFile` operation. Keep a bounded binary-plist checkpoint for an active file; do not create JSON sidecars.

**Tech Stack:** Swift, watchOS AVFoundation, AVAssetWriter/AVAsset, WatchConnectivity, iOS AVFoundation.

## Global Constraints

- Preserve independent hourly audio files; never concatenate audio on iPhone.
- Keep Watch-to-iPhone audio transfer on `WCSession.transferFile`.
- Do not add compatibility for old RecordingV2 recordings.
- No JSON sidecars for capture context, per-file metadata, or recovery.
- Keep existing unrelated dirty files untouched; do not stage or commit.
- Do not add or run tests unless the user asks; report whether build/device verification was performed.

---

### Task 1: Define stable file identity and timestamp metadata

**Files:**
- Modify `apps/wrist-notes/Sources/Shared/RecordingChunkProtocol.swift`
- Modify `apps/wrist-notes/Sources/Shared/VoiceNote.swift`

- [x] Define one canonical filename formatter/parser for `<groupUUID>_<ordinal4>_<UTC timestamp>.m4a` and validate parsed UUID, ordinal, and timestamp.
- [x] Define stable per-file UUID derivation from group UUID and ordinal so recovery does not mint duplicate recording IDs.
- [x] Define M4A metadata for recording start time, group UUID, and ordinal. Duration, offset, and source identity ride in the property-list `transferFile` metadata.

### Task 2: Write metadata into hourly M4A files

**Files:**
- Modify `apps/wrist-notes/Sources/Watch/SegmentedAudioCapture.swift`
- Modify `apps/wrist-notes/Sources/Watch/WatchRecorder.swift`

- [x] Replace per-recording JSON sidecars with a binary-plist active-file checkpoint, write creation time into the M4A container, and use canonical partial/final naming.
- [x] At each hourly boundary, finalize one independent M4A and place it under its canonical final name.
- [x] Remove sidecar JSON creation, deletion, and recovery calls from the Watch recording paths.

### Task 3: Recover and transfer ordinary files

**Files:**
- Modify `apps/wrist-notes/Sources/Watch/WatchRecorder.swift`
- Modify `apps/wrist-notes/Sources/iPhone/PhoneConnectivity.swift`
- Modify `apps/wrist-notes/Sources/iPhone/NotesModel.swift`
- Modify `apps/wrist-notes/Sources/iPhone/NoteRepository.swift`

- [x] Scan canonical final M4A files on Watch launch, validate embedded creation time and filename identity, and reconstruct pending items with stable IDs.
- [x] Recover a fully finalized partial M4A from the checkpoint window; incomplete active M4A files are left untouched and never queued.
- [x] Transfer each M4A with a matching property-list metadata dictionary and verify the phone derives the same group, ordinal, start time, and stable ID before importing.
- [x] Preserve the existing durable-import acknowledgement before Watch marks a file uploaded.

### Task 4: Static review and release notes

**Files:**
- Review the modified source files and this plan.

- [x] Run `git diff --check` only; tests and build were not run.
- [x] Confirm the active Watch recording paths no longer write per-recording `.json` sidecars; ordinary Watch file transfer remains the receiver path.
- [x] Report implementation status and device/build verification limits.
