# Lock Screen Quick Recording Implementation Plan

**Goal:** Deliver the approved circular Lock Screen widget: tap to begin one WiseLife recording, then stop/save via the existing Live Activity.

**Architecture:** A static accessoryCircular widget in the existing recording widget extension calls the shared StartWiseLifeRecordingIntent. The intent executes in the app process and uses the existing permission preflight and singleton runtime. Repeated starts are idempotent. The widget contains no personal data and needs no shared data store or periodic refresh.

**Tech stack:** SwiftUI / WidgetKit / AppIntents, iOS 26+, existing ActivityKit recording flow.

## Constraints

- Approved design and implementation request already received; no further approval needed.
- Work in the current feature checkout, preserving all unrelated uncommitted sources, SDK/config and credentials. No commit, push or project regeneration.
- Native Simulator UI automation remains disallowed; use CLI builds, metadata checks, existing focused recording tests and code review. Real Lock Screen authentication/capture requires physical-device acceptance.
- Scope is the circular Lock Screen widget. No Home Screen widgets or Control Center controls in this iteration.
- Preserve existing shortcut type identity, titles and toggle/stop behavior. Locked interactions remain subject to system authentication.

## Implementation and verification

- [x] Add a built-bundle integration check that requires StartWiseLifeRecordingIntent in both the app and embedded widget extension, with matching identifier, AudioRecording and app-process execution metadata. Observe the current extension fail this gate (currently only has Stop).
- [x] Move StartWiseLifeRecordingIntent from Sources/iPhone/RecordingIntents.swift to Sources/RecordingShared/StartWiseLifeRecordingIntent.swift. Add LiveActivityIntent conformance; keep supportedModes [.background, .foreground(.dynamic)] and call runtime.perform(.start). App-only permission/dialog helpers remain in RecordingIntents.swift with internal names. The extension implementation throws an actionable error if misrouted; never returns false success.
- [x] Add Sources/RecordingActivity/QuickRecordingWidget.swift with StaticConfiguration, a static .never timeline, accessoryCircular support, native accessory background and mic.fill button. Register it beside the existing Live Activity in WiseLifeRecordingWidgets.
- [x] Add shared source to both actual app/extension targets and generator; add widget source to extension only. Preserve existing dependencies and signing settings via minimal xcodeproj edits.
- [x] Add Lock Screen setup instructions in QuickRecordingSettingsView, including Face ID/system authorization and the existing Live Activity stop/save path. Localize new app/widget labels in zh-Hans/en/ja.
- [x] Run focused recording state tests (including repeated start), source membership and configuration validation, app+extension build, built-bundle integration check and scoped code review. Save implementation and physical-device acceptance boundaries to verification/lock-screen-recording.md and link from README.

Implementation and CLI verification complete. Build and new bundle gate both exited 0; review found no blockers. Physical Lock Screen/authentication/audio acceptance remains pending, documented in `apps/wrist-notes/verification/lock-screen-recording.md`.

## Commands

```sh
python3 apps/wrist-notes/Tests/test_recording_widget_bundle.py /private/tmp/wiselife-quick-recording-build/Build/Products/Debug-iphonesimulator/WiseNote.app
sh apps/wrist-notes/scripts/test_phone_recording.sh
ruby apps/wrist-notes/Tests/ProjectSourceMembershipSmoke.rb
xcodebuild -workspace apps/wrist-notes/WristNotes.xcworkspace -scheme WristNotes -configuration Debug -destination 'generic/platform=iOS Simulator' -derivedDataPath /private/tmp/wiselife-quick-recording-build CODE_SIGNING_ALLOWED=NO build
```
