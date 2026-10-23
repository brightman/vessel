# WiseLife Watch Background Transfer Status Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use `executing-plans` to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Show reliable long-recording background transfer state, iPhone-persisted chunk counts, a fresh status timestamp, and current-file progress when WatchConnectivity exposes it.

**Architecture:** Extend the V2 Watch session snapshot with backwards-compatible optional transport details. The Watch publishes a coalesced snapshot from its outstanding WatchConnectivity transfers; the iPhone combines it with durable per-chunk receipts in `WatchSyncStore`, then renders the result in the existing Watch status popover. Completion means the iPhone has persisted all chunks and end metadata; status timestamps remain visible so delayed snapshots are not presented as live.

**Tech Stack:** Swift, SwiftUI, WatchConnectivity, Foundation `Progress`, SQLite-backed `WatchSyncStore`, shell-driven Swift smoke tests, Xcode workspace build.

## Global Constraints

- Keep existing V1 recording sync readable and preserve older V2 snapshots by decoding new fields as optional.
- Count a chunk as received only after iPhone file and metadata persistence; continue sending acknowledgements after persistence.
- Use `WCSession.updateApplicationContext` for the latest coalesced status; do not promise continuous background refresh.
- Show a whole-recording fraction only as received chunks / total chunks; never convert chunk count into a byte or time percentage.
- Show current-file progress only while WatchConnectivity reports an active transfer and a finite progress fraction.
- Keep all data local; do not add a server or new package dependency.

---

## File map

- `apps/wrist-notes/Sources/Shared/WatchSyncSnapshot.swift`: Codable phase and optional per-session transport fields shared by Watch and iPhone.
- `apps/wrist-notes/Sources/Watch/WatchRecorder.swift`: inspect V2 `outstandingFileTransfers`, publish state changes and safe current-file progress in the existing application context.
- `apps/wrist-notes/Sources/iPhone/WatchSyncStore.swift`: expose per-session durable receipt counts and completeness alongside the existing aggregate.
- `apps/wrist-notes/Sources/iPhone/PhoneConnectivity.swift`: pass the scoped V2 transfer summary into `PhoneWatchStatus`.
- `apps/wrist-notes/Sources/iPhone/PhoneWatchStatus.swift`: map snapshot and receipt evidence into user-facing stage, segment count, current-file progress, and report time.
- `apps/wrist-notes/Sources/iPhone/NotesListView.swift`: show transfer rows in the existing Watch connection popover.
- `apps/wrist-notes/Sources/iPhone/Localizable.xcstrings`: add the new Chinese source strings and English/Japanese translations.
- `apps/wrist-notes/Tests/WatchSyncSmoke.swift`: test snapshot compatibility and durable per-session progress; the existing `test_watch_sync.sh` already compiles this harness and its dependencies.

## Task 1: Model and persist per-session phone receipt progress

**Files:**
- Modify: `apps/wrist-notes/Sources/Shared/WatchSyncSnapshot.swift`
- Modify: `apps/wrist-notes/Sources/iPhone/WatchSyncStore.swift`
- Modify: `apps/wrist-notes/Tests/WatchSyncSmoke.swift`

**Interfaces:**
- Add `enum WatchTransferPhase: String, Codable { case waiting, queued, transferring }`.
- Add `WatchSessionSyncSnapshot.validProgressFraction(_:) -> Double?`, returning a value only when it is finite and within `0...1`.
- Validate optional incoming totals/ordinals/fractions in `WatchSessionSyncSnapshot.decode`; totals are `0...maximumOrdinal + 1`, ordinals are valid protocol ordinals, and fractions are finite within `0...1`.
- Extend `WatchSessionSyncSnapshot.Pending` with optional `totalChunkCount`, `phase`, `transferringChunkOrdinal`, and `currentChunkFraction` fields so older encoded V2 snapshots still decode.
- Add `WatchSyncStore.SessionTransfer` with `sessionID`, `receivedChunkCount`, `totalChunkCount`, `phase`, `transferringChunkOrdinal`, `currentChunkFraction`, `reportedAt`, and `isComplete`; return these rows from `WatchSyncStore.Summary.sessionTransfers`.
- `receivedChunkCount` comes from `watch_session_sync_chunk`; `isComplete` is true only when all ordinals are durably stored and matching end metadata is present.

- [x] **Step 1: Write failing compatibility and receipt-count tests**

Add to `WatchSyncSmoke.main()` a snapshot round-trip using the new optional fields, an old V2 JSON payload with only `sessionID`, `lastOrdinal`, and `end`, and an incomplete-session assertion after persisting fewer than the reported total chunks. Assert that phone receipt count comes from SQLite rather than from the Watch's submitted/queued counts.

```swift
let sessionID = UUID()
let time = Date(timeIntervalSinceReferenceDate: 1_000)
let progress = WatchSessionSyncSnapshot.Pending(
    sessionID: sessionID, lastOrdinal: 2, end: nil,
    totalChunkCount: 6, phase: .transferring,
    transferringChunkOrdinal: 2, currentChunkFraction: 0.4
)
let snapshot = WatchSessionSyncSnapshot(updatedAt: time, pending: [progress])
let roundTrip = try JSONDecoder().decode(WatchSessionSyncSnapshot.self, from: JSONEncoder().encode(snapshot))
expect(roundTrip.pending[0].currentChunkFraction == 0.4, "current file fraction round-trips")
let oldV2JSON = Data("""
{"updatedAt":1000,"pending":[{"sessionID":"\(sessionID.uuidString)","lastOrdinal":2,"end":null}]}
""".utf8)
let decodedOldV2 = try JSONDecoder().decode(WatchSessionSyncSnapshot.self, from: oldV2JSON)
expect(decodedOldV2.pending[0].currentChunkFraction == nil, "old V2 snapshots remain readable")
let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
let store = try WatchSyncStore(database: DaybookDatabase(url: root.appendingPathComponent("sync.sqlite3")))
try store.recordSaved(.init(receipt: .init(sessionID: sessionID, chunkID: UUID(), ordinal: 0, sha256: String(repeating: "a", count: 64)), savedAt: time), counterpartID: "progress-test")
try store.recordSaved(.init(receipt: .init(sessionID: sessionID, chunkID: UUID(), ordinal: 1, sha256: String(repeating: "b", count: 64)), savedAt: time), counterpartID: "progress-test")
try store.apply(snapshot, counterpartID: "progress-test")
let summary = try store.readSessions(counterpartID: "progress-test")
expect(summary.sessionTransfers[0].receivedChunkCount == 2, "only durable phone receipts count as received")
```

- [x] **Step 2: Run the focused smoke test and confirm it fails for missing fields**

Run from repository root: `sh apps/wrist-notes/scripts/test_watch_sync.sh`.
Expected: Swift compilation fails because `WatchTransferPhase`, the new `Pending` fields, and `Summary.sessionTransfers` do not exist yet.

- [x] **Step 3: Add backwards-compatible snapshot fields and SQLite-derived transfer rows**

Add the optional Codable fields to the shared `Pending` value. In `readSessions(counterpartID:)`, query receipt count, matching end metadata and complete ordinal coverage for each pending session; create `SessionTransfer` values using `snapshot.updatedAt` as `reportedAt`. Preserve the existing `pendingCount` and `lastSyncedAt` calculations.

- [x] **Step 4: Run the focused smoke test and confirm it passes**

Run: `sh apps/wrist-notes/scripts/test_watch_sync.sh`.
Expected: the old V2 payload decodes, new transfer fields round-trip, and the reported received count matches only persisted phone receipts.

- [x] **Step 5: Review the task diff without staging overlapping pre-existing changes**

Run: `git diff -- apps/wrist-notes/Sources/Shared/WatchSyncSnapshot.swift apps/wrist-notes/Sources/iPhone/WatchSyncStore.swift apps/wrist-notes/Tests/WatchSyncSmoke.swift apps/wrist-notes/scripts/test_watch_sync.sh`.
Keep the existing workspace edits intact; do not stage these files because they already contain unrelated uncommitted work.

## Task 2: Publish Watch queue phase and current-file progress

**Files:**
- Modify: `apps/wrist-notes/Sources/Watch/WatchRecorder.swift`
- Modify: `apps/wrist-notes/Sources/Shared/WatchSyncSnapshot.swift`
- Modify: `apps/wrist-notes/Tests/WatchSyncSmoke.swift`

**Interfaces:**
- `WatchRecorder.publishSessionSnapshot()` reports each incomplete V2 session's sealed chunk count, transfer phase, active chunk ordinal, and optional active-file fraction.
- Add `WatchSessionSyncSnapshot.phase(outstandingCount:transferringCount:) -> WatchTransferPhase`; active transfers take precedence, then queued transfers, then waiting.
- `WatchSessionSyncSnapshot.validProgressFraction(_:) -> Double?` accepts only finite fractions in `0...1` and is used before serialization.
- Resolve active V2 transfer metadata through `RecordingChunkWire.decode`; ignore malformed or unrelated V1 metadata.
- A finite fraction is clamped to `0...1`; omit it when the file is queued, not transferring, or reports an indeterminate fraction.

- [x] **Step 1: Add failing pure-model tests for transfer phase selection**

Assert that no outstanding files maps to `waiting`, outstanding files with no active sender map to `queued`, and any active transfer maps to `transferring`. Assert fractions outside `0...1` and non-finite fractions are rejected by `validProgressFraction`.

```swift
expect(WatchTransferPhase.queued.rawValue == "queued", "queued status has stable wire value")
expect(WatchSessionSyncSnapshot.phase(outstandingCount: 0, transferringCount: 0) == .waiting, "no system job waits on Watch")
expect(WatchSessionSyncSnapshot.phase(outstandingCount: 2, transferringCount: 0) == .queued, "queued jobs are not reported active")
expect(WatchSessionSyncSnapshot.phase(outstandingCount: 2, transferringCount: 1) == .transferring, "active job takes precedence")
expect(WatchSessionSyncSnapshot.validProgressFraction(0.4) == 0.4, "finite progress is retained")
expect(WatchSessionSyncSnapshot.validProgressFraction(.nan) == nil, "indeterminate progress is omitted")
expect(WatchSessionSyncSnapshot.validProgressFraction(1.1) == nil, "out-of-range progress is omitted")
```

- [x] **Step 2: Run the focused smoke test and confirm it fails**

Run: `sh apps/wrist-notes/scripts/test_watch_sync.sh`.
Expected: compilation fails because the phase/fraction behavior has not been implemented.

- [x] **Step 3: Implement coalesced Watch status publication**

In `publishSessionSnapshot()`, inspect only WatchConnectivity transfers whose metadata belongs to the current V2 binding. Group active/queued transfers by `sessionID`; mark a session `transferring` if any matching `WCSessionFileTransfer.isTransferring` is true, otherwise `queued` if matching outstanding work exists, otherwise `waiting`. Choose one active chunk ordinal for the optional current-file progress and publish the latest snapshot through the existing `updateApplicationContext` path when the resulting pending payload changes. Keep progress sample updates bounded to changes in the reported fraction and never change recording or retry behavior.

- [x] **Step 4: Run the focused smoke test and the Watch/iPhone workspace build**

Run `sh apps/wrist-notes/scripts/test_watch_sync.sh`, then run:

```sh
xcodebuild -workspace apps/wrist-notes/WristNotes.xcworkspace \
  -scheme WristNotes -configuration Debug \
  -destination 'generic/platform=iOS Simulator' \
  -disableAutomaticPackageResolution -onlyUsePackageVersionsFromResolvedFile \
  -skipPackageUpdates CODE_SIGNING_ALLOWED=NO -quiet build
```

Expected: smoke test passes and the WatchConnectivity progress adapter compiles for its Watch target.

- [x] **Step 5: Inspect only the Watch snapshot publication diff**

Run: `git diff -- apps/wrist-notes/Sources/Watch/WatchRecorder.swift apps/wrist-notes/Sources/Shared/WatchSyncSnapshot.swift` and verify V1 transfer handling is untouched.

## Task 3: Render honest status in the iPhone connection popover

**Files:**
- Modify: `apps/wrist-notes/Sources/iPhone/PhoneConnectivity.swift`
- Modify: `apps/wrist-notes/Sources/iPhone/PhoneWatchStatus.swift`
- Modify: `apps/wrist-notes/Sources/iPhone/NotesListView.swift`
- Modify: `apps/wrist-notes/Sources/iPhone/Localizable.xcstrings`
- Modify: `apps/wrist-notes/Tests/WatchSyncSmoke.swift`

**Interfaces:**
- `PhoneWatchStatus.recordingTransfers: [WatchSyncStore.SessionTransfer]` stores the current paired Watch's per-session status.
- `WatchSyncStore.SessionTransfer` contains `sessionID`, `receivedChunkCount`, optional `totalChunkCount`, optional `phase`, optional `transferringChunkOrdinal`, optional `currentChunkFraction`, `reportedAt`, and `isComplete`.
- `PhoneWatchStatus` derives localized stage/segment/current-file strings and a report-time string from each transfer row.
- `NotesListView` renders these fields below the existing Watch status message without changing retry controls.

- [x] **Step 1: Add failing presentation tests for all status transitions**

Extend `WatchSyncSmoke` to assert transfer-row values for queued, actively transferring, partial durable receipt, complete durable receipt, absent total count, and optional current-file fraction. Assert that a complete status requires all chunks plus matching persisted end metadata.

```swift
expect(queuedTransfer.phase == .queued && queuedTransfer.receivedChunkCount == 0, "queued is distinct from received")
expect(activeTransfer.receivedChunkCount == 2 && activeTransfer.totalChunkCount == 6, "only phone receipts advance the count")
expect(activeTransfer.transferringChunkOrdinal == 2 && activeTransfer.currentChunkFraction == 0.4, "current file progress names the active ordinal")
```

- [x] **Step 2: Run the focused smoke test and confirm presentation assertions fail**

Run: `sh apps/wrist-notes/scripts/test_watch_sync.sh`.
Expected: compilation fails because `PhoneWatchStatus` does not yet expose transfer rows or labels.

- [x] **Step 3: Connect the stored transfer summary to `PhoneWatchStatus`**

In `PhoneConnectivity.refreshStatus()`, assign the current pairing's V2 session rows after applying the incoming application-context snapshot. In `PhoneWatchStatus`, derive display strings only from durable phone receipt counts, Watch phase, optional current-file progress and `reportedAt`; do not label an old report as live. Keep generic V1 pending count and recent-sync labels as fallbacks.

- [x] **Step 4: Add the three language strings and render the transfer rows**

Add Chinese source strings and English/Japanese translations to `Localizable.xcstrings`. In the existing popover in `NotesListView`, render each V2 session's stage, received/total count, current-file progress when present, and “status updated” time. Keep the existing retry button and failure messages.

- [x] **Step 5: Run focused and full local validation**

Run `sh apps/wrist-notes/scripts/test_watch_sync.sh`, `sh apps/wrist-notes/scripts/test_local.sh`, and the iOS Simulator workspace build from Task 2. Expected: all commands exit successfully; note any pre-existing unrelated failure separately.

- [x] **Step 6: Review the final scoped diff and report device-verification limits**

Run `git diff --check` and `git diff --` for the seven files in the File map. Do not stage or commit because each native source/test file already has pre-existing user changes. Report that paired-device background scheduling and update latency still need real Watch/iPhone validation.

---

## Self-review

- Snapshot compatibility, sender-side queue/progress, durable iPhone receipts, UI states, time freshness and multilingual copy each have a task.
- “Complete” is based on iPhone persistence of all chunks and matching end metadata, not on Watch having received the returned ACK.
- No global byte/time percentage is inferred from chunk count; current-file progress is shown only when WatchConnectivity reports it.
- Existing V1 support, retry controls, audio files and other user changes remain outside this implementation.

## Validation outcome

- `sh apps/wrist-notes/scripts/test_watch_sync.sh`: passed, including visibility of the latest completed session after Watch receives its ACK.
- Generic iOS Simulator workspace build: passed.
- `sh apps/wrist-notes/scripts/test_local.sh`: stopped in the unrelated audio-duration fixture because this macOS runtime has no AAC encoder (`AVFAudio` error 1718449215); earlier checks in that script passed.
- Paired-device transfer timing and progress refresh still require real Watch/iPhone validation.
