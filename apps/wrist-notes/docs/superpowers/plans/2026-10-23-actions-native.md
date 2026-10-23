# Action Tab Implementation Plan

**Goal:** Implement the approved local-first tasks, reminders and calendar events workspace.
**Architecture:** SQLite ActionItem plus an adapter for existing reminder IDs; EventKit owns only explicitly linked items. Persist desired operations before external calls and reconcile idempotently. Source-based AI produces reviewable drafts, never automatic commitments.
**Tech Stack:** SwiftUI, SQLite, UserNotifications, EventKit, configured Apple/custom/ChatGPT model.

## Constraints
- Preserve current dirty checkout and reminder/system identities; no broad staging or push.
- AI sending consent does not grant permission to activate actions.
- No notifications for undated tasks. Event start/end required. Source quotes stay local.
- Keep source ID, quote and provenance; external tasks receive title/time only.

## Steps
- [x] Test and implement unified action persistence, validation, deduplication and legacy adoption.
- [x] Implement durable external operations and EventKit tasks/events; reuse existing notification reminder coordinator.
- [x] Implement list/filter/detail/editor, manual entry and source conversion.
- [x] Implement consent-aware structured AI draft extraction with source validation and capture-time timezone.
- [x] Integrate routes, project membership and permission copy.
- [x] Run action regression, existing reminders regression and workspace simulator build; record real-device limits.

Evidence: verification/actions-native.md. Live system accounts and AI endpoints remain device acceptance checks.
