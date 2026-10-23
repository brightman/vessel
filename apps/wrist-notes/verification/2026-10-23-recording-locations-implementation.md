# Recording locations implementation — 2026-10-23

Scope: Task 1 of `docs/superpowers/plans/2026-10-23-recording-location-content.md`, plus the approved iPhone address-resolution/cache integration. Changes were made in place against the preserved baseline snapshot `/var/folders/89/yl428bks2tz609hjjwc49jg80000gn/T/wiselife-location-content-baseline-fgd17x_3`. Existing recordings/databases were not mutated, and no commit, reset, push, installation or credential work was performed.

## Implemented behavior

- `RecordingLocationSample` lives in existing Shared `CaptureMetadata.swift`: stable UUID, session UUID, audio-boundary offset, requested boundary date, validated original `CaptureLocation` (including actual fix time and accuracy), and source-device identity.
- `sessionOffset` **associates the observation with the requested audio boundary**. It does not claim the location fix occurred at that exact audio sample. `requestedAt` records the requested boundary date; `location.measuredAt` independently preserves the actual device-reported fix time. The shared model documents this distinction.
- Long Watch recordings request location at start, every 600 seconds of effective sampled audio, and stop. The main timer only schedules optional GPS requests; PCM conversion/writing/sealing does not wait for GPS or its journal. A resumed timer skips historical boundaries older than 20 seconds instead of attaching a fresh fix to a long-past boundary.
- The existing location acquisition service remains a bounded one-shot: 20-second timeout, device authorization check, opt-in switch, invalid/stale-fix rejection, and stop-updating after success/cancellation. The sample additionally rejects missing actual fix time, missing accuracy, invalid provenance, and observations outside the existing -10/+30 second boundary freshness tolerance.
- A separate bounded stop acquisition service retains the previous session's stop request when another recording starts immediately. Each completion captures the original session ID, requested boundary, source device and offset. A later stop may replace an earlier still-pending stop request, which is an unavailable observation rather than an invented location.
- Preference changes increment an in-process policy revision. Queued location persistence rechecks both opt-in and that revision, so quick off/on changes invalidate previously queued work. Both location managers observe setting changes and device authorization revocation independently.
- Successful fixes are written atomically and flushed as per-sample sidecars in the Watch session store before they are offered for transfer. Sidecar identities survive relaunch. Audio descriptors and sealed files are not rewritten to attach observations.
- Optional `supportsLocationSamples` in the existing V2 capability reply gates location-only messages. An older peer keeps receiving its existing chunk/end protocol while observations stay local. New `wiseLifeRecordingLocationV2` and `wiseLifeRecordingLocationReceiptV2` messages use the existing pairing/nonce-scoped envelopes.
- The Watch queue persists independent location retry state and ACK receipts, scoped to the stable counterpart identity. Fresh handshake nonces preserve valid receipts; changed counterpart identities get separate ledgers. Audio/end submissions precede optional location work. Damaged optional location ACK ledgers cannot block audio uploads.
- The iPhone receiver durably stages location messages independently, commits their SQLite rows, then writes/replays its receipt outbox. Duplicate/out-of-order arrivals are safe; conflicting identities reject. Deleted session tombstones reject delayed observations and prevent resurrection.
- SQLite migration 11 adds `recording_location_samples(id,session_id,session_offset,requested_at,payload)` with ordered session/time index and cascading session ownership. `RecordingSessionRepository.locationSamples(sessionID:)` returns ordered validated observations.
- SQLite migration 12 adds separate `recording_location_addresses(sample_id,payload)`, cascading from the observation. `applyLocationAddress` compares the original capture identity inside the write transaction; original observation/wire payloads remain immutable for replay. Repository reads overlay valid derived addresses without replacing raw coordinates.
- `RecordingLocationAddressModel` uses the existing Apple Maps resolver, a dedicated SQLite actor, one lookup at a time, one-second spacing, current foreground/location switch/day/locale scope, up to 200 sessions and 128 samples per batch. Failed/offline lookups retain raw observations and retry on foreground/scope changes; completed caches survive restarts. Late results are rejected after cancellation, and deleted samples cannot be recreated by a late result.
- Daybook's existing address synchronization now also schedules recording-session observations. This geocoding queue is independent of ASR and content enrichment; content can use raw observations while addresses are unavailable.

## Lifecycle integration

After a committed observation or address update, `RecordingChunkReceiver.didChange` posts `userInfo: ["sessionID": UUID, "locationUpdated": true]`. Root integration explicitly schedules enrichment for this session even when the audio fingerprint is unchanged. The content worker joins the address cache and includes observed place context in its enrichment/cache identity. Location/address changes must not change ASR configuration or raw-media fingerprints. Session deletion cascades both observation and address-cache rows.

The new `Sources/iPhone/RecordingLocationAddressModel.swift` must be included in the generated iPhone target beside `CaptureAddressModel.swift`; root owns that project-generation change.

## Verification evidence

Observed RED failures before the corresponding implementation included:

- Runtime failure for absent `recording_location_samples` SQLite storage.
- Missing Watch independent-sidecar and optional capability APIs at Swift compilation.
- Real filesystem fault at `capture-context.json`: the prior pipeline raised Cocoa error 512 / POSIX EISDIR and terminated audio on an optional location update. The implementation now keeps that error out of the terminal audio path, and the same test seals all 1,600 effective audio frames.
- Missing explicit idempotent stop-scheduling API.
- Missing settings revision invalidating queued work across off/on.
- Runtime failure for absent independent `recording_location_addresses` storage, followed by missing address-apply API/consumer.

Final executed checks:

| Command | Result / evidence |
| --- | --- |
| `sh apps/wrist-notes/scripts/test_recording_locations.sh` | PASS: start/600-second boundaries/idempotent stop; stale and unknown actual timestamp rejection; Watch persistence/recovery; old/new peer gating; SQLite ordered replay/reopen/conflict; post-COMMIT failure replay; durable ACK across restart/new nonce; deletion/tombstone; exact-coordinate address apply, immutable wire payload/replay, durable overlay and cascade deletion; real optional-location write failure preserves audio. |
| `sh apps/wrist-notes/scripts/test_recording_location_addresses.sh` | PASS: foreground/location gating; cancellation rejects late result; offline retains coordinates without render-loop retries; foreground re-entry retries; durable address cache avoids geocoding after consumer restart. |
| `sh apps/wrist-notes/scripts/test_recording_transfer.sh` | PASS: `RecordingChunkTransferSmoke passed`, including existing audio/end compatibility, durable receipt, replay and counterpart contracts. |
| `sh apps/wrist-notes/scripts/test_streaming_recording.sh` | PASS: first 600-second AAC receipt + stable ASR/VAD before finish/end; replay/coordinator reopen; final-tail coverage, bounded real decoding, cross-file silence split, original bytes; presentation partial/end/history states. An earlier run failed the existing cross-file silence expectation while the content agent was editing derivation; the final integrated rerun passed. |
| `sh apps/wrist-notes/scripts/test_watch_recording_sessions.sh` | PASS: Watch store smoke; synthetic capture 19,200,017 effective frames across three chunks. |
| `sh apps/wrist-notes/scripts/test_watch_sync.sh` | PASS: pairing, sync persistence, failure evidence, retry policy. |
| `sh apps/wrist-notes/scripts/test_places.sh` | PASS: capture validation/transfer/legacy decode/SQLite reopen/delete; opt-in/denial/authorization/stale/one-shot/cancel/pause lifecycle; photo metadata; place provenance. |
| Standalone `swiftc` build/run of `CaptureLocationLifecycleSmoke` after policy-revision test | PASS: includes quick off/on generation invalidation in addition to lifecycle checks. |

Root is responsible for final generated-project native iPhone/Watch builds and complete combined verification. No hardware claim follows from these host-native synthetic tests.

## Hardware checks still required

- Start, every ten-minute boundary, and stop fixes with actual Watch authorization and phone pairing.
- Watch display sleep/background scheduling, location availability, microphone continuity, power consumption and endurance across multi-hour recordings.
- Offline Watch transfer/relaunch, companion updates/older peers, device lock/protected storage and eventual ACK delivery on paired devices.
- Apple Maps address availability, locale quality and network behavior on real devices; denied/offline states must retain coordinates.

## Exact task-owned file list

Production:

- `Sources/Shared/CaptureMetadata.swift`
- `Sources/Shared/CaptureLocationService.swift`
- `Sources/Shared/RecordingChunkTransport.swift`
- `Sources/Watch/WatchRecorder.swift`
- `Sources/Watch/WatchChunkTransferQueue.swift`
- `Sources/Watch/WatchRecordingSessionStore.swift`
- `Sources/Watch/SegmentedAudioCapture.swift`
- `Sources/iPhone/DaybookDatabase.swift`
- `Sources/iPhone/RecordingSessionRepository.swift`
- `Sources/iPhone/RecordingChunkReceiver.swift`
- `Sources/iPhone/PhoneConnectivity.swift`
- `Sources/iPhone/RecordingLocationAddressModel.swift` (new)
- `Sources/iPhone/DaybookView.swift` (recording-address StateObject, sessions-revision address refresh, synchronization call only)

Tests/scripts:

- `Tests/RecordingLocationsSmoke.swift` (new)
- `Tests/RecordingLocationAddressesSmoke.swift` (new)
- `Tests/CaptureLocationLifecycleSmoke.swift`
- `Tests/StreamingRecordingSmoke.swift` (this task only added exhaustive `.location` ACK handling; content agent also adjusted its content expectations)
- `Tests/RecordingChunkTransferSmoke.swift` (exhaustive `.location` ACK handling)
- `scripts/test_recording_locations.sh` (new)
- `scripts/test_recording_location_addresses.sh` (new)
- `scripts/test_watch_recording_sessions.sh` (shared durable transport helper in Swift source lists)
- `verification/2026-10-23-recording-locations-implementation.md` (this report)
