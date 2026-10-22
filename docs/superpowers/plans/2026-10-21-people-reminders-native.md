# Native Contacts and Apple Reminders Implementation Plan

**Goal:** Implement the two approved prototype flows in the existing WiseLife iPhone app: manually link a recording speaker to a chosen contact, and optionally create/manage a linked Apple reminder.

**Architecture:** Contact snapshots are optional fields within the existing VoiceNote payload. Reminders retain the current SQLite repository and local notification scheduler, adding durable Apple-link metadata and an injectable EventKit bridge. All operations are user initiated; no server.

**Tech stack:** SwiftUI, ContactsUI, EventKit, existing SQLite and portable Swift smoke tests, Xcode workspace build.

## Constraints

- Work on current codex/pages-api-base checkout because current native dependencies and prototype changes are uncommitted. Preserve unrelated edits; take scoped baseline snapshots. No commit, push, project regeneration, credentials or real personal-data inspection.
- Keep eurekaRing false and ChatGPT public-client eligibility false. Do not change Watch protocols or recording logic.
- No native Simulator UI automation. CLI compile/tests are allowed. Physical contact picker/EventKit authorization and actual Apple account synchronization remain device acceptance.
- Scope begins with the two approved prototype flows. Person profile and person-scoped Ask AI require the pending optional scope answer; do not assume approved yet.
- Public copy reflects actual persistence and failure state. An Apple failure keeps local task data; never claim a notification was scheduled if it was not. Suppress duplicate local notifications for tasks that may already exist in Apple.

## Task 1: Speaker contact vertical slice

Owner files: Sources/Shared/VoiceNote.swift, Sources/iPhone/NotesModel.swift (speaker methods only), Sources/iPhone/SpeakerTranscriptView.swift, new Sources/iPhone/SpeakerContactViews.swift, new Tests/SpeakerContactsSmoke.swift, new scripts/test_speaker_contacts.sh. Parent owns project/generator, localizations, README and all reminder files.

- [x] First add a portable failing test for binding/unbinding, replacement, per-note scope, Codable legacy compatibility/reload, and clearing associations on new transcription/changed diarization while retaining them for same assignments and segment text edits.
- [x] Store minimal chosen contact snapshot (identifier, display name, optional bounded thumbnail Data) per speaker in optional VoiceNote field. Use existing payload persistence; no new table. Names from people are verbatim text, not localization keys. Manual rename explicitly clears contact association. Unlink restores existing default speaker naming behavior; never modify system contacts.
- [x] Use CNContactPickerViewController (ContactsUI) as the actual system picker, retrieving only selected contact. No full contact permission or CNContactStore fetch. Snapshot normalizes name (fallback to organization or 未命名联系人) and downsizes/caps thumbnail. Do not persist phone/email or whole CNContact.
- [x] Speaker management sheet includes current name/avatar/state, source excerpt, link/change contact, manual rename for unlinked, and confirmed unlink. Chosen contact confirmation precedes persistence. Cancel retains old binding. Follow original typography/colors; integrate both transcript hosts via shared SpeakerTranscriptView.
- [x] Guard saves against stale transcript revision or changed assignments while picker open, active processing and deleted note. Surface errors without closing successful-looking UI. Existing segment editor remains functional.
- [x] Run red/green focused smoke and existing speaker/owner regressions. Report new source names and translation rows (zh/en/ja) in .superpowers/sdd/2026-10-21-people-reminders-native/task-1-report.md. Do not edit central localization/project files or run full build (parent owns).

## Task 2: Optional Apple reminder vertical slice (parent)

- [x] Add meaningful portable red tests with a fake Apple bridge covering permission refusal, preserved local data, idempotent retry after a post-write interruption, update/completion/delete failure, external edit/completion/deletion, local notification suppression, and old SQLite metadata migration.
- [x] Add a v4 SQLite table keyed to daybook_reminders storing optional Codable Apple link payload; unchanged rows remain compatible. Persist desired external operation before calling EventKit; cache returned identifier and last synced content only after success. A stable opaque URL marker recovers the same task after a crash; missing previously linked task is never silently recreated.
- [x] EventKit adapter requests full reminder access only on explicit opt-in, enumerates writable lists and account labels, creates EKReminder title/start/due/alarm with opaque app-link marker (no transcript/audio/notes), updates/completes/removes only owned linked tasks, and exposes typed errors. Fetch is limited to ownership checks; no private-data logging.
- [x] Extend coordinator/store with Apple opt-in, retry, unlink, complete/delete and foreground reconciliation. Preserve local-only behavior/tests. Failed first adds retain task data with attention state; existing Apple tasks suppress local alerts even when a change is pending. Read external changes only for linked tasks; preserve pending local edits. Permission loss does not trigger duplicates or recreate deleted external tasks.
- [x] Editor default-off toggle, explicit access request, writable-list picker and iCloud/account explanation. Preserve draft across authorization. List shows local/linked/pending/error, retry, and confirmed paired delete. Local-only fallback is an explicit choice.
- [x] Parent registers new files minimally in actual Xcode project and generator (do not run generator), adds NSRemindersFullAccessUsageDescription and Chinese/English/Japanese strings. Run focused tests, affected persistence regressions, source membership and full app/Watch/widget build.
- [x] Independent review, fixes, verification report and README update. Report actual device limits; do not claim system integration E2E from mocks/build.
