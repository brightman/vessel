# Contacts and Apple Reminders Prototype Plan

**Goal:** Extend the current iphone-day HTML prototype with the two user-approved flows, without changing native code or invoking system data APIs.

**Architecture:** Existing single-sheet UI and deterministic page-memory state. Speaker bindings are scoped by recording ID and speaker ID. Apple reminder state augments the existing AI reminder drafts/list. Keep the existing graphite/blue palette, phone proportions, dark mode and three interface languages.

**Constraints:** Preserve all current dirty edits. No commit/push or project generation. Contacts are fictional; no system contacts, notifications, reminders, network or persistent feature data. Existing appearance/language preferences may continue using their current storage. Prototype-only notices are visible. Native Simulator automation is not used; browser verification is allowed. Work in the user's existing feature checkout so current uncommitted prototype changes remain the baseline.

## Task 1: Optional Apple Reminders flow

Files owned: `apps/wrist-notes/prototype/daybook-ai.js`, new `daybook-apple-reminders.js`, new `daybook-apple-reminders.css`. Do not edit HTML, daybook.js, global locales or the speaker files; parent owns those.

- [x] Extend the existing reminder form with a default-off switch named `同时添加到 Apple 提醒事项`. Preserve title/date/time/evidence across all nested UI and permission flows, and save nothing until explicit final confirmation.
- [x] Show target list selection from fictional writable iCloud lists (`WiseLife`, `个人`, `工作`). Do not invent an always-available local-only list. Clearly say iCloud lists sync via Apple; only the task title/time are shared by default, no transcript/audio. Source stays in WiseLife.
- [x] Simulate first-use full access explanation with allow/decline; denial offers keep only in WiseLife or retry via a clearly marked system-settings preview. Never claim actual OS permission. Support a collapsed demo-results control for success/write failure/permission revoked/no writable lists. Preserve a local reminder on write failure and expose retry without duplicates.
- [x] List rows distinguish WiseLife-only, added-to-Apple, pending/failed. Successful add suppresses duplicate WiseLife alerts conceptually. Linked edit/completion/delete semantics must be explicit and consistent; a simple mirrored demo store is acceptable, with read-only Apple Reminders preview to show the item. No fabricated real app launch. Keep unrelated AI features intact.
- [x] Expose existing AI API as `{render, openReminders, createDraft}` so parent can add prototype entry buttons. New helper if used: `window.createDaybookAppleReminders(app)`. New locale rows: `window.daybookAppleRemindersCopy = [[zh,en,ja], ...]`. Parent loads helper before daybook-ai.js and includes copy in locale aggregation.
- [x] Run node syntax checks and self-review of permission cancellation/draft retention/retry. Save report to `.superpowers/sdd/2026-10-21-people-reminders-prototype/task-1-report.md`. No browser automation (parent owns browser). No tests that merely mirror source; parent will exercise flows in browser.

## Task 2: Speaker-contact flow and integration (parent)

- [x] Add `daybook-speaker-contacts.js` and CSS, plus limited hooks in daybook.js. Two example recordings contain diarized segments; clicking a speaker opens a sheet with contact linking, manual name, replace, unlink, and back-to-transcript. Preserve the original transcript text; apply label to all matching segments in the same recording only.
- [x] Fictional contact selector supports search, no results, selection confirmation and cancel. Show identity initials/avatar and matching context; clear that choosing someone does not enable future automatic voice identification. Do not request broad contacts permission.
- [x] Add preview entries outside the phone and optional `?preview=contacts|reminders#product` entry routing. Integrate helper scripts/styles/copy without replacing existing website content.
- [x] Verify browser flows: link/replace/unlink/manual name; cancel/search-empty; reminder default-off/permission rejection/success/failure/retry; edits and language/theme state. Save screenshots and a verification note. Check JS syntax and scoped whitespace. Mark plan complete with actual evidence.
