# WiseNote native daily companion implementation plan

**Goal:** Upgrade the existing iPhone app to the approved daily timeline, voice/photo capture, unified settings and cited local-record AI conversation; preserve Watch transfer, ASR and all existing recordings.

**Architecture:** Keep the VoiceNotes repository and Watch protocol unchanged. Persist images in an adjacent repository; project both stores into a common `DayRecord` value for timeline and retrieval. Use exact date filtering plus bounded lexical retrieval before Apple Foundation Models or the user's explicitly selected custom AI. Reminder scheduling is a separate local module.

**Tech stack:** SwiftUI, PhotosUI/UIKit camera, Vision OCR, AVFAudio, Foundation Models, UserNotifications, Codable atomic file stores. iOS 26 / watchOS 10. No new external service or package.

## Constraints and boundaries

- Existing approval: user accepted `prototype/iphone-day.html`, voice/photo-only capture, existing model configuration, and upgrading this app in phases.
- Preserve app bundle identifiers, signing, VoiceNote IDs, documents and current dirty changes. No git staging or commits of prior work.
- Normal startup has no fabricated health, calendar, location or personal records. Health/calendar integration and vector embeddings remain the later phases already discussed; current retrieval must clearly say keyword/date scope.
- Use real native capture, persistence and cancellation/error flows. Camera/microphone access occurs only after a user action. Photos are selected with the system picker.
- Custom AI receives only allowed text selected for the question, after an explicit per-request confirmation. Raw photos/audio stay local. No automatic remote fallback.
- Reminder proposals do not schedule until user confirmation. Local notification permission failure must remain visible.
- Prior browser preview denial must not be bypassed. Native build/simulator tools are independent authorized development tools.

## Interfaces

`DayRecord`: Foundation-only Codable/Equatable/Identifiable; UUID `id`, Date `capturedAt`, Kind `kind` (.voice/.thought/.image), String `title`, `text`, `summary`, TimeInterval `duration`. Immutable snapshot of searchable app records; no binary data. Use named initializer with defaults on summary/duration.

`PhotoMoment`: UUID id, Date capturedAt, String caption, String recognizedText, [PhotoAttachment] photos; computed title/searchableText. `PhotoAttachment`: UUID id, String filename, String recognizedText. Foundation model and repository independently testable.

`PhotoLibraryModel`: main-actor ObservableObject with published moments and errorMessage, imageURL(for attachment: PhotoAttachment) -> URL?, delete(_ id: UUID), reload(). `PhotoCaptureView(library:onSaved:)`; `PhotoDetailView(momentID:library:)` use these only and existing NotesStyle.

`DaybookAssistantModel`: main-actor ObservableObject; asks using DayRecord array/date plus AppSettings, persists no secrets or raw attachments; includes citations, scope/coverage, pending/cancel/error. Its service must be separately testable for no-data/date/lexical ranking/bounded context and deletions. UI integration owned by parent after service contracts are reported.

## Task 1: Photo capture and repository (isolated files)

- [x] Create PhotoMoment.swift, PhotoRepository.swift, PhotoLibraryModel.swift, PhotoCaptureView.swift, PhotoDetailView.swift and PhotoRepositorySmoke.swift.
- [x] Test persistence/reopen/deletion, file-path validation, partial import rollback, invalid inputs before implementation; run standalone swiftc smoke.
- [x] Implement up to 6 selected photos, preview/removal/cancel/caption, real camera and PhotosPicker, local JPEG storage and Vision OCR with cancellation. No album-wide access; never claim OCR success if recognition failed.
- [x] Provide parent an exact integration report and iOS typecheck evidence. Parent handles plist/project membership.

## Task 2: Retrieval and AI conversation (independent files)

- [x] Create DaybookRetrieval.swift, DaybookAssistantModel.swift, DaybookAssistantView.swift and DaybookRetrievalSmoke.swift. Own only these and an optional narrowly named AI generation service.
- [x] Test date boundaries, no-data, Chinese lexical matching, bounded snippet selection, original record references, aggregation and removal/update behavior.
- [x] Implement real Apple generation with availability/language checks; reuse secure CustomAISummarizer transport through a new public answer method (parent adds it). Preserve local-only operation by default and no remote fallback.
- [x] Use a single-request task with cancellation/version guard; reject stale/deleted/disallowed evidence before displaying a result. No-data response is deterministic and requests no model.

## Task 3: Native daily UI and recording (parent)

- [x] Create DayRecord.swift, DaybookView.swift, DaybookComponents.swift, PhoneRecorder.swift and capture sheet. Project existing notes/images without changing legacy storage.
- [x] Today/date picker, real counts/audio duration, 24-hour recording marks, searchable/filterable records, detail links, Watch status, bottom Today/AI/Insights navigation and Capture button.
- [x] Real iPhone microphone recording, start/stop/cancel/interruption, temporary file cleanup, save into existing audio repository and ASR pipeline.
- [x] Integrate existing transcription/AI settings, appearance and import. Add AI preference/reminder settings.

## Task 4: Local reminders and insights (parent)

- [x] Persist preferences and reminder items, explicit title/date confirmation, local notification scheduling/cancel/completion/edit, visible denied-permission handling.
- [x] Display grounded daily recap/actions from actual selected records. Link source IDs, allow dismissal/snooze. Avoid invented behavioral/health claims or continuous-background guarantees.
- [x] Source permissions apply to retrieval and outstanding generation. Core counts use code; summaries use bounded original text.

## Task 5: Integration and evidence

- [x] Register sources without regenerating unrelated project settings; update generator's file list, plist purpose strings, targeted test script and README.
- [x] Run baseline and new Foundation smoke tests; run iOS simulator build and generic iOS build with signing disabled. Fix compile/concurrency issues.
- [ ] Native UI / device acceptance: initial integrated build installed and launched without uninstall/data reset. Simulator computer-use access was denied; no UI interaction or screenshots were attempted through alternatives. Later refinements are built but not installed again. Actual device ASR/camera/LLM checks remain unverified this turn.
- [x] Review task-owned changes, record outstanding real-device gates in verification/daybook-native.md, report what actually works and what remains a later phase.

## Progress

- Initial scoped baseline saved at `/private/tmp/wisenote-native-upgrade-baseline`; original working tree contained prior model/Watch changes.

- Native implementation complete for daily UI, phone voice/photo capture, bounded single-day AI questions, linked reminders and local review cards. No new service dependency.
- Added suggestion store: persisted per-day distinct-card budget, quiet hours, source revocation/edit validation, snooze and dismissal. These are local review cues; model analysis remains an explicit AI question.
- New offline tests and existing suite passed together; final iOS simulator/generic iOS builds and embedded Watch check passed. Exact evidence: `apps/wrist-notes/verification/daybook-native.md`.
- Focused review fixes verified: source IDs reach reminder persistence/navigation; suggestion limit is consumed; local thumbnail ImageIO decoding; cross-midnight recording preserves start-date navigation; failed audio index writes preserve the retry draft.
- Watch/shared/PhoneConnectivity bytes and all pre-existing target build/signing settings match the task-start snapshot. No Git commit or push.
- User discussed WiseLife branding during implementation; parent recommended the name, but did not change identifiers/display names based only on that question.
