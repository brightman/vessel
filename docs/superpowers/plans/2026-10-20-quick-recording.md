# WiseLife Action button recording

## Approved scope

User approved: Action button start, recording Live Activity, automatic saving. A long press invokes a recording toggle; the next invocation stops and saves. Also expose explicit start and stop App Shortcuts. Lock Screen and Dynamic Island show recording duration and a stop action. Recording, storage, and transcription remain local. No separate Control Center control in this iteration.

## Architecture and boundaries

- An app-process singleton owns one NotesModel, one normal PhoneRecorder, and a recording session coordinator; the visible UI and App Intents use the same objects. Voice enrollment keeps its own recorder, with microphone ownership enforced to prevent overlap.
- Move auto-save out of SwiftUI onChange into the session coordinator. Save audio durably before requesting ASR. Failed saves retain retryable drafts, including restart recovery; never acknowledge saving before persistence succeeds.
- AudioRecordingIntent runs in the app process. Start/stop/toggle actions are exposed by AppShortcutsProvider. First-use permissions or disabled Live Activities produce actionable errors; no success haptic before recording starts.
- ActivityKit controller plus WidgetKit Live Activity extension use shared attributes containing only session ID, start time and status. A stop intent includes the session ID so a stale card cannot stop a newer recording. Start a Live Activity for shortcut recording and keep it active during capture, as Apple requires.
- Keep pending starts/stops serialized and protect recordings from duplicate requests and stale callbacks. Interrupted recordings save their captured portion. A terminated process cannot resume an audio recorder; recover finalized staged audio and end obsolete activities.

## Workspace constraints

Work in the existing feature checkout with extensive uncommitted changes. Required dependencies are already in this checkout; a new checkout would omit them. No commit, push, branch switch, broad staging or unrelated cleanup. Preserve Ring SDK work and Config/BuildFeatures.json (currently eurekaRing false). Native Simulator UI automation was previously denied; use build and CLI tests only. Real-device Action button, cold/locked startup and ActivityKit behavior remain explicitly unverified until device testing.

## Tasks

- [x] Recording engine/session: test-first lifecycle, automatic durable save/retry, duplicate invocation, interruption and draft recovery; preserve voice enrollment behavior.
- [x] Live Activity: shared attributes, ActivityKit controller, lock-screen/Dynamic Island widget, stale-session stop button; project/generator integration and compilation.
- [x] App wiring: singleton runtime, App Intents/Shortcuts, existing recording UI integration and setup guidance; localizable copy.
- [x] Verification: focused deterministic tests, existing local regression, iPhone and extension simulator build, independent scoped review, saved verification report with physical-device checklist.

## Shared interfaces

`RecordingActivityManaging` is MainActor with `start(sessionID: UUID, startedAt: Date) async throws`, `finish(sessionID: UUID, saved: Bool) async`, and `onDismiss: ((UUID) -> Void)?`.

`PhoneRecordingSession` receives an engine, activity manager and synchronous throwing save closure (persistence completes before return). It exposes async throwing `start(requireLiveActivity: Bool)`, `toggle()`, `stopAndSave(expectedSessionID: UUID?)`, `retrySave()`; async `discard()`; observable phase and lastSaved draft. Parent runtime owns the actual PhoneRecorder separately for existing UI bindings.

`RecordingActivityAttributes` has `sessionID: UUID`, `startedAt: Date`, and Codable/Hashable ContentState with phase (`recording`, `saved`, `failed`). `StopWiseLifeRecordingIntent` takes a sessionID string; widget and app compile the same intent with app-process execution via AudioRecordingIntent.

## Official sources checked

- https://developer.apple.com/documentation/appintents/audiorecordingintent — Live Activity must remain active while intent recording runs; available iOS 18+ in installed SDK.
- https://developer.apple.com/documentation/widgetkit/creating-controls-to-perform-actions-across-the-system — WidgetKit / App Intents system actions.
- https://support.apple.com/guide/iphone/iphe89d61d66/26/ios/26 — Action button uses press-and-hold; user assigns shortcut in Settings.

## Verification plan

Cover initial microphone denial, activity unavailable, successful begin, repeated begin, concurrent toggles, cancellation during start, stop before begin completes, automatic save after interruption, save failure/retry without duplicate notes, stale activity stop, activity dismissal, and staged draft restart recovery. Compile real AppIntents and ActivityKit symbols with installed iOS SDK. Preserve existing recording enrollment tests. Build unsigned app + embedded extension; do not claim physical recording or lock-screen acceptance from simulator build.
