# WiseLife HealthKit Refresh Implementation Plan

> Execute inline in the existing shared checkout; preserve unrelated work and use the task baseline. User approved notifications plus foreground refresh.

**Goal:** Update local steps/sleep snapshots when HealthKit changes, with foreground catch-up.

**Architecture:** One app-lifetime LifeSourceModel owns one reader. The reader installs step/sleep HKObserverQuery instances at app launch for an enabled source. A serial, generation-guarded refresh queue merges notification bursts and writes through LifeSourceStore to the existing SQLite database. Each observer completion is acknowledged after processing or cancellation/error/timeout.

**Tech Stack:** Swift, HealthKit, UIKit launch delegate, SwiftUI, SQLite.

## Constraints

- No new network services, permission prompts on launch, or raw step summing.
- Preserve SQLite complete file protection and existing backup exclusion. Locked-data failures keep old snapshots; unlock/foreground retries.
- Notifications and foreground catch-up refresh today, yesterday, and the selected day; other historical edits are reconciled when that day is selected/refreshed.
- Request hourly step delivery and immediate sleep delivery; actual delivery is scheduled by iOS, not a fixed interval.
- Existing health snapshots and separate AI permission remain unchanged when pausing the source.
- Baseline: `/var/folders/89/yl428bks2tz609hjjwc49jg80000gn/T/wiselife-health-baseline-yarkjpjp`.

## Tasks

- [x] Add `Tests/HealthRefreshSmoke.swift` and `scripts/test_health.sh`: verify launch consent, merged notifications, background SQLite persistence, foreground catch-up, today/yesterday/selected-day coverage, pause and stale callbacks, failures, timeout, and relaunch without authorization prompts. Run before implementation and confirm expected failure.
- [x] Extend `LifeSourceReading` with observer start/stop defaults. In `LifeSourceModel.swift`, add one serial health queue and completion drain, 20-second watchdog, observer lifecycle and unlock recovery; keep non-health foreground rules.
- [x] In `LifeSourceReader.swift`, install HKObserverQuery for steps/sleep, serialize background enable/disable calls, and stop/resume active read continuations exactly once on cancellation. Retain HKStatisticsQuery and sleep interval merging.
- [x] In `WiseLifeRuntime.swift`, `WristNotesApp.swift`, and `DaybookView.swift`, share a single model and initialize at didFinishLaunching; retry after unlock. Add HealthKit background-delivery entitlement and truthful settings copy.
- [x] Run focused tests and existing local regression suite, plus iOS Simulator and generic iOS builds. Review the diff against the fresh baseline. Document real-device checks and scheduling/lock/history limits in `apps/wrist-notes/docs/2026-10-20-health-background.md`.
