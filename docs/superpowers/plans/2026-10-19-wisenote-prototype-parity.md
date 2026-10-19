# WiseNote prototype parity correction

**Goal:** Match the approved `iphone-day.html` screen structure, exact CSS typography, colors, vector icons, spacing, navigation and sheet flows in native SwiftUI.

**Architecture:** Keep all live recording, storage, ASR, model, retrieval, permission and notification services. Replace the custom interpretations of the UI with source-mapped native views. Use actual data and empty/disconnected states in the prototype's original slots. No fabricated health/activity/insight facts.

## Source of truth and mapping

- `daybook.css`: paper #fafbfc, ink #20272e, secondary #65717c, accent #335f83, 23pt page inset, 34pt day heading, 58×65 date tile; divider metrics; 3 rhythm tracks; continuous timestamp/line/dot rows; ungrouped bottom navigation.
- `iphone-day.html`: today, AI, insights, library, data screen structure; same top toolbar/bottom nav; capture and detail sheets.
- `daybook-ai.css` / `daybook-ai.js`: 40pt identity, 18pt title, lined context row, 29pt welcome, bordered prompt buttons, user bubble/plain answer/source chips, pinned bottom input; flat preference/reminder forms.
- `daybook-capture-settings.css` / photos/model settings scripts: stacked capture rows, photo grids and preview, radio model choices, labeled full-width fields, blue resource box, bottom cancel/save.

## Tasks

- [x] Parent: DaybookStyle + source SVG assets, home/calendar/toolbar/navigation/library/settings data page, audio banner/capture menu, original voice detail sheet, insight/evidence flow.
- [x] AI agent: match AI layout and pinned composer; preserve live confirmation and stale-evidence guards.
- [x] Photo agent: match capture/detail/original viewer sheets and image grids; preserve import/OCR state handling.
- [x] Settings agent: match model, preferences and reminder sheets; preserve actual downloads, protocols and scheduling.
- [x] Parent: register sources, integrated builds and existing behavior smoke; focused review.
- [ ] Visual comparison: user explicitly reauthorized browser/Simulator viewing/screenshots/clicking for this correction. Use equal-size screenshots to compare real renders. Report any remaining differences instead of claiming 1:1 from build success.

## Boundaries

- Current dirty checkout snapshot: `/private/tmp/wisenote-prototype-alignment-baseline` (87 files). No broad reset/stage/commit. Preserve unrelated work and secrets.
- Latest user override: without health authorization, replace steps/sleep metrics with thought count and actual image attachment count. Prototype source toggle demonstrates this fallback; native uses these real local counts until HealthKit is integrated. Other prototype structure remains the reference.
- Native system status bar/home indicator/pickers/keyboard remain OS-owned. Do not draw fake device chrome or present simulated success.
- Do not send records or credentials to external models for visual verification.

## Review and verification progress

- Shared style, 45 Lucide assets and license, date/calendar, root pages, flat navigation, AI composer, model forms, photo sheets, audio details and persistent recording banner are integrated.
- Root sheet routes carry their associated IDs/draft data. Historical image questions select the image date. Tomorrow plans and reminder creation both use the actual next day.
- Review fixes: recording blocks playback/session deactivation and the old editor; both audio summary entry points confirm custom AI text requests; reminder cancel errors are surfaced; abnormal-recording warnings survive autosave.
- Exact default follow-up prompt first failed its regression assertion, then passed after query scaffolding was fixed. Full existing offline suite passes.
- Native simulator and unsigned generic iOS builds pass. Final UI source edits were rebuilt for both destinations; both exited 0. Evidence is saved in apps/wrist-notes/verification/prototype-parity/.
- Browser prototype was viewed earlier. Current Chrome native target fails `cgWindowNotFound`; no browser provider is available. Simulator access was automatically denied with `Computer Use was not approved to use Simulator` despite the user's authorization. No alternate screenshot/input method was used.
- Equal-size final screenshot comparison and native touch/keyboard/gesture/real recording verification remain open. Build success does not establish visual 1:1 acceptance.
