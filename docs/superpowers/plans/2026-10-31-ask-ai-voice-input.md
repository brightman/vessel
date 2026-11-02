# Ask AI voice input implementation plan

**Goal:** Implement the approved microphone composer in the native iPhone app.

**Architecture:** A cancellable main-actor model owns a disposable, at-most-60-second take. A dedicated `PhoneRecorder` uses its existing microphone ownership guard; `LocalTranscriptionService.shared` performs only local ASR through the existing inference gate. Completed text is inserted into the original draft at the selection and requires manual sending.

**Scope:** iPhone composer, disposable capture adapter, localization, project membership and focused tests. Existing recording files, timeline processing, Watch transport, AI sending confirmation and SQLite conversation persistence keep their existing contracts. The current native 300-character question limit remains; long transcripts stay editable rather than being silently truncated.

## Implementation

- [x] Add `AssistantVoiceInputModel.swift`, `AssistantVoiceInputLive.swift` and `AssistantVoiceInputSmoke.swift`. Verify missing resources, cancellation while preparing/transcribing, late results, empty speech, microphone interruption, repeated taps, selection insertion and cleanup of temporary audio.
- [x] Reuse `PhoneRecorder.start(maximumDuration: 60, builtInMicrophoneOnly: true)` for protected disposable audio without location collection. Expose actual input metering for the waveform. Never save the take as a voice note or conversation.
- [x] Check the selected Apple/Whisper resources before recording; expose the existing transcription settings on failure. Do not download resources or use a remote ASR implicitly.
- [x] Add microphone, listening/transcribing panel and error state to `DaybookAssistantView`. Disable sending during capture/transcription; apply successful text to the matching draft only. Cancel on leaving the view, opening another sheet, or backgrounding; microphone permission prompts must not be mistaken for backgrounding. The draft now belongs to `DaybookView` so tab changes retain it.
- [x] Wire new files in the existing Xcode project and generator without regenerating unrelated project state. Add Chinese/English/Japanese strings.
- [x] Run focused model tests, existing recording tests, source-membership checks, simulator build and native UI verification. Record the boundaries of simulated versus actual microphone/ASR evidence in `apps/wrist-notes/verification/ask-ai-voice-input-2026-10-31.md`.

## Acceptance

1. Hold the microphone, speak, release to transcribe, edit the resulting text and manually send.
2. Cancel or interrupt an operation without changing the existing draft or sending a question.
3. Permission denial, occupied microphone, unavailable model and empty speech are visible and recoverable.
4. No recording appears in the timeline, no audio is sent to a server, and disposable audio is deleted when the operation finishes or is cancelled.
5. A stale completion cannot replace the draft or affect a newer recording.

Execution is inline in the current session. No Git publish is requested.

## Approved interaction refinement — October 31

- [x] Replace the single scaled, repeating waveform with a bounded history of actual microphone energy, sampled every 70 ms, with quick attack and smooth decay. Reset between takes and respect Reduce Motion.
- [x] Use a 0.2-second hold to start and finger release to finish. A brief tap does nothing. Release while preparing cancels rather than starting a late take; a cancelled gesture preserves the draft. Keep accessible VoiceOver activation.
- [x] Remove cancel/finish controls and supplementary copy from the listening card; it displays status, waveform and elapsed time. Keep the 60-second limit in the composer hint.
- [x] Align the HTML demo with pointer/keyboard hold, release, cancellation and the display-only card. It remains explicitly marked as a simulation without microphone access.
- [x] Verify state tests, actual simulator hold/release UI, HTML browser interaction, simulator/device builds and installation on the connected iPhone. Hardware launch remains blocked by its lock screen.
