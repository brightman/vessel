# Local Speaker Diarization Implementation Plan

> Execution: inline, preserving the existing dirty workspace; approved by the user's “同意，请修改”.

**Goal:** Add offline speaker labels and editable per-note names to WiseLife transcripts.
**Architecture:** Timestamped ASR persists before a separate local diarization pass. Both use one serial model queue. Portable value types own alignment and mutation invariants; SDK adapters only translate external results.
**Tech Stack:** SwiftUI, SpeechAnalyzer, WhisperKit/SpeakerKit 0.18.0, Core ML, JSON local repository.

## Constraints

- iOS 26; watchOS 10 remains supported; dependencies only link into iPhone.
- No audio uploads. Explicit model download in settings, checksummed manifest, inference download disabled.
- Existing notes decode without new fields. ASR success survives diarization failure.
- Speaker IDs/names apply to one recording. No claims of identifying real people.

## Tasks

- [x] 1. Add failing portable tests in Tests/SpeakerDiarizationSmoke.swift for legacy JSON, speaker turn alignment, unmatched intervals, rename persistence, clearing stale segments and edit protection. Run with `swiftc Sources/Shared/VoiceNote.swift Sources/iPhone/NoteRepository.swift Sources/iPhone/SpeakerTranscript.swift Tests/SpeakerDiarizationSmoke.swift`.
- [x] 2. Implement TranscriptSegment, TranscriptionOutput, SpeakerTurn, SpeakerAlignment and VoiceNote applyTranscription / applyDiarization / renameSpeaker / editSegment methods. Preserve transcript text and invalidate summaries on text changes.
- [x] 3. Generalize verified local model download behind WhisperModelStore; add SpeakerModelStore and pinned SpeakerModels.json, bundled into existing ASR downloads without a separate entry. Keep existing Whisper download tests green.
- [x] 4. Update LocalTranscriptionService / OnDeviceTranscriber to return TranscriptionOutput; add SpeakerKit offline inference, serial model release, and NotesModel persistence/status/retry. Keep existing injected transcription test compatibility.
- [x] 5. Add reusable SpeakerTranscriptView to both detail pages, name and segment editing, timestamp display and independent diarization status. Update generator and Xcode project without overwriting unrelated settings.
- [x] 6. Portable suite, 7 focused iOS tests, independent iOS UI/source compilation, watchOS shared typecheck, real local model inference and code review completed. Evidence: `apps/wrist-notes/verification/speaker-diarization.md`.
- [ ] Deferred verification: full workspace build waits for the other agent's Ring SDK. Native UI interaction was denied by tool permission. Physical iPhone Apple ASR/diarization and long-recording performance remain unverified.
