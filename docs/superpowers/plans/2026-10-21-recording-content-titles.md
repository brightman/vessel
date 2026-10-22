# Recording Content Titles Implementation Plan

**Goal:** Bring native iPhone lists and detail headings in line with the approved prototype: 长录音·内容标题, with start time only in timeline/metadata and 长录音·待生成标题 before text is available.

**Architecture:** Keep Watch recording and transfer defaults compatible. Add optional title provenance and revision metadata to VoiceNote, derive the iPhone display title centrally, and generate titles from existing transcripts on device. Prefer the available Apple Foundation Model; otherwise extract a short transcript sentence locally. Never send content to a remote provider automatically. Existing custom titles and later manual edits win over inference.

**Constraints:** Existing dirty codex/pages-api-base checkout contains required native changes. Preserve all unrelated work and signed configuration. No native Simulator UI automation, real contact/reminder reads, commit or push. New feature only targets long recordings; thought behavior and Watch protocols stay unchanged. Native model availability and title quality need device acceptance.

## Task 1: Title policy and persistence

- [x] Add portable failing scenarios: legacy timestamp hidden, generated content prefix exactly once, manual title protected, changed/restored transcript revision rejects stale output, optional Codable reload, re-transcription invalidates old auto title.
- [x] Add optional provenance/revision/manual-edit metadata and computed iPhone title in VoiceNote. Retain legacy initializer for Watch. Apply generated titles only to default/previously automatic long recordings with matching opening revision and title. Normalize bounded nonempty content; fallback uses first useful transcript sentence, no artificial recording date.
- [x] Run title policy tests plus existing note editing and contact regressions.

## Task 2: Local generation and iPhone integration

- [x] Add `OnDeviceRecordingTitleGenerator.generate(from:) async -> String?`, availability/locale guarded, bounded transcript sample, task cancellation honored. Return nil on unavailable/refusal/error, never request network fallback.
- [x] Queue eligible durable notes serially in NotesModel on refresh, after successful ASR and foreground recovery. Save generated result/fallback with revision and manual-edit guards. Exit on disk failure; permit later retry. An in-flight generation cannot resurrect a deleted note or overwrite edited content.
- [x] Update the shared daybook projection, voice detail, legacy list and editor initial field to display clean content titles; retain timestamps in metadata. Register new iPhone file in actual project, generator and focused source lists without regenerating project.
- [x] Run portable regression, source membership and full iPhone/Watch/widget Simulator build. Independent review, fixes and a short verification record. Do not equate build with physical local-model validation.
