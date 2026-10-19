# WristNotes Implementation Plan

**Goal:** Build a local-only iPhone and Apple Watch app that captures long recordings and press-to-talk thoughts, transfers audio to iPhone, creates editable voice notes with on-device transcription, and summarizes text on-device.

**Architecture:** The watch persists each recording and queues it with Watch Connectivity. The iPhone moves received files into its own durable store, acknowledges them only after metadata is saved, and runs SpeechAnalyzer and Foundation Models locally. No Vessel HTTP API or account is used.

**Tech stack:** SwiftUI, AVFAudio, WatchConnectivity, SpeechAnalyzer, FoundationModels, JSON index in the app container, Xcode 26.3.

## Constraints

- iPhone test device: iPhone 16 Pro on iOS 26.5.2.
- Watch test device: Apple Watch SE, generation not yet confirmed, currently watchOS 10.6.2. Do not require a watchOS upgrade.
- iPhone deployment target: iOS 26. Watch deployment target: watchOS 10, so the current watch can run the first build.
- Audio, transcripts, and summaries stay on-device. Apple language model assets may need a one-time system download.
- Never discard the watch recording until the iPhone has durably stored and acknowledged it.
- A queued background transfer or processing job must be visible as pending; completion time is not guaranteed.

## Tasks

### 1. Native project and local note store

- Create two SwiftUI application targets in `WristNotes.xcodeproj` with companion bundle identifiers and an embedded watch product.
- Define `VoiceNote` and a JSON-backed `NoteStore`. Store audio under `Documents/Audio` and the index under Application Support. Write the index atomically.
- Add focused tests for idempotent imports and persistence recovery.
- Build both generic simulator targets with code signing disabled.

### 2. Watch capture and transfer

- Add long recording start/stop and a press-to-talk gesture, microphone permission handling, elapsed-time UI, and interruptions.
- Persist completed recording metadata next to the audio file. Queue files through `WCSession.transferFile(_:metadata:)` and retry pending files when connectivity becomes available.
- Receive an acknowledgement carrying the recording ID and mark the local recording uploaded. Preserve the local entry and audio until the user deletes it, per the approved Watch prototype.
- Check a short recording and a background/long recording on the physical Watch.

### 3. iPhone receive and manage

- Move each incoming Watch Connectivity file to `Documents/Audio` synchronously in the delegate callback. Reject invalid metadata and preserve the temporary file on failure.
- Save or deduplicate the note by recording ID. Return acknowledgement with a background-safe transfer method after durable save.
- Add list, detail, playback, title and transcript editing, delete, and clear pending/error states.
- Verify offline handoff, duplicate transfer, and app relaunch on the paired devices.

### 4. On-device ASR

- Check `SpeechTranscriber.isAvailable`, supported locale, and installed model assets. Use `AssetInventory` for an explicit one-time language asset download.
- Analyze the received audio file using `SpeechAnalyzer` and `.offlineTranscription`; save finalized text and a retryable error state.
- Test Mandarin audio, airplane-mode transcription after asset installation, and a long recording on the iPhone 16 Pro.

### 5. On-device summary and review

- Check `SystemLanguageModel.default.availability` and locale support. Summarize transcript chunks, then combine chunk summaries, keeping the original transcript editable.
- Build both targets again, run focused store tests, review the two UIs, and document all physical-device checks still outstanding.

## Acceptance

- The watch can save both recording modes without network access.
- A recording survives disconnection until the phone acknowledges durable receipt.
- The iPhone can play and manage the original audio even if ASR or summarization is unavailable.
- No audio or note content is sent to an app server.

## Prototype alignment, 2026-10-18

- [x] Single red Watch control and a fixed recording list below it.
- [x] Tap / hold / slide-to-cancel rules, short-thought suppression and haptics.
- [x] Uploaded-state persistence, legacy index decoding and swipe deletion.
- [x] iPhone list, search, import, language picker and swipe deletion.
- [x] Audio player, editable title and Summary / Transcript tabs below the player.
- [x] Edited transcript invalidates the previous summary; unchanged saves preserve processing state.
- [x] Simulator and unsigned device builds, local checks, native screenshot review.
- [ ] Manual simulator or physical-device gesture and playback validation.
- [ ] Complete Watch-to-iPhone receipt / import / acknowledgement verification. Deferred while prioritizing prototype alignment.
