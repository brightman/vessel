# Daily recaps implementation

> Follow the approved HTML prototype in the existing dirty checkout; preserve concurrent content/audio changes. No commit or push in this task.

1. **Core and persistence** — add `DaybookRecap.swift`, `DaybookRecapStore.swift`, `Tests/DaybookRecapSmoke.swift`, `scripts/test_daily_recaps.sh`.
   - `DaybookRecapInput.prepare(records:day:allowedKinds:calendar:)` produces a complete day manifest and bounded source batches.
   - `DaybookRecapStore.load()/save(_:)` uses an additive SQLite migration and atomic per-date writes.
   - Test before implementation: yesterday across DST, >5 source coverage, permission filtering, blank ASR, archive reload >30 days, edit/deletion/addition comparison, transaction failure.
   - Run `sh apps/wrist-notes/scripts/test_daily_recaps.sh`; verify failing assertions/missing production types, then implement and make it pass.
2. **Generation and coordination** — add `DaybookRecapService.swift`, `DaybookRecapModel.swift`; add one dedicated factual-recap completion method to `CustomAISummarizer.swift`.
   - Protocol `DaybookRecapGenerating.generate(_:configuration:apiKey:language:isCurrent:) async throws -> String` supports injected generation in tests.
   - Snapshot the exact prepared content and config for confirmation. Validate durable attempt identity, asynchronous scope freshness, citations, saved state, error and retry.
   - Test the actual coordinator with suspended provider completions and complete asynchronous scope loaders: consent, stale callbacks, permissions, failed attempts, foreground and capture cancellation.
3. **Native presentation** — add `DaybookRecapViews.swift`; incrementally modify `DaybookView.swift`.
   - Home recap card, archive filter and search, detail sheet, all current source navigation, refresh and consent preview.
   - Load full dated content/session scope through existing model APIs. Wire data/config/permissions/lifecycle refresh, while preserving existing daily insight page.
   - Add files to generator and existing project using targeted xcodeproj edits; include test script in `test_local.sh`.
4. **Verify and review** — run targeted recap tests, source membership, existing related checks, and CLI iOS Simulator workspace build with signing disabled. Request independent read-only code review, fix concrete findings, save `verification/daily-recaps-native.md` with tested and untested boundaries.

Implementation is authorized by the request to implement the existing prototype. Proceed inline; no additional design approval is needed.

## Completion

All four tasks completed. Added three executable Swift smoke suites and integrated them into `test_local.sh`. Independent read-only review and follow-up review completed; identified issues were fixed and regression-tested. The final complete local suite and iOS Simulator workspace build passed. Evidence and remaining device/UI validation boundaries are in `apps/wrist-notes/verification/daily-recaps-native.md`. No commit or push was made for this implementation task.
