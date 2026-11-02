# Speaker Ask and Contact Records Implementation Plan

## Goal

Implement the approved local Speaker Ask design in WiseLife: persist reusable local contact profiles, associate a recording's speaker with a contact, and retrieve only that contact's transcript evidence. Flash thoughts (`.thought`) are attributed to the owner (`self`) without diarization or a contact row.

## Constraints

- Keep associations scoped to `(source_key, speaker_id)` and keep system Contacts read-only.
- Store iOS contact snapshots and manually created contacts in the local database; never send email, phone, avatar, or system contact identifiers to an AI provider.
- Filter speaker evidence before full-text or semantic ranking; cite recording and time ranges.
- Preserve all unrelated existing working-tree changes. Do not add or run tests unless the user asks.

## Steps

1. [x] Add an additive SQLite migration for `contacts` and `recording_speaker_contacts`, indexes, and an atomic migration from legacy contact snapshots.
2. [x] Add typed contact records/repositories for iOS snapshot refresh, manual local contacts, source-scoped link/rebind/unlink, and speaker revision checks.
3. [x] Update the speaker picker/management UI to show contact details and support manual contact creation while retaining the existing iOS contact picker.
4. [x] Add speaker evidence retrieval over active transcript spans, preserving source/date/time and filtering by recording-scoped speaker relation. Treat thoughts as the virtual `self` source only.
5. [x] Route supported contact/speaker questions through the existing Daybook answer flow; retain existing privacy confirmation and citation behavior.
6. [x] Update storage/retrieval documentation to reflect implemented schema and query limits; run `git diff --check` and an Xcode build only.

## Completion checks

- [x] Schema migration preserves old contact mappings and can be rerun safely.
- [x] Manual contacts and iOS snapshots can be linked, rebound, refreshed, and unlinked locally.
- [x] Speaker Ask only receives spans belonging to the resolved contact/speaker; `.thought` remains the owner's speech.
- [x] Xcode workspace build succeeds and `git diff --check` is clean for the scoped changes. No test suite is run.
