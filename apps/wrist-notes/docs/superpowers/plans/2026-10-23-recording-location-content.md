# Long recording locations and content chapters

> **For agentic workers:** Use subagent-driven-development for the two independent capture/derivation tasks; integrate provider routing and verify the complete native flow in this session.

**Goal:** Sample location during long recordings and ship the approved three-minute blank candidates, roughly thirty-minute chapters, and bounded AI topic continuity strategy.

**Architecture:** Audio remains immutable ten-minute files. Location observations have durable independent identities and transfer receipts. SQLite stores time-indexed observations and derived content ranges; ASR/VAD results are reused. Deterministic segmentation provides a useful offline result; AI may refine adjacent topic boundaries subject to coverage and duration guards.

**Tech Stack:** Swift, Core Location, WatchConnectivity, SQLite, Apple Foundation Models and the app's configured AI providers.

## Global Constraints

- Preserve all existing recordings, transcripts, manual edits, unrelated working-tree changes and credentials. No reinstall, commit or push is part of this task.
- Audio chunks stay 600 seconds; inference core windows stay at most 300 seconds. Location never blocks recording, sealing, uploading or ASR.
- Sample at start, each ten-minute boundary and stop. Persist actual fix time, requested boundary, session offset, accuracy and source device. Stale/failed fixes must not become fresh locations.
- Respect the location switch and device authorization. Use bounded one-shot acquisition; verify background behavior on hardware separately.
- Persist location before sending; receiver saves transactionally before ACK. Duplicate, out-of-order, offline/relaunch and deleted-session behavior must be safe. Do not mutate sealed chunk descriptors.
- Three minutes without ASR in successfully processed coverage is a low-information boundary candidate, not a claim of acoustic silence. Failed/missing processing is never silence.
- Ten-minute verified no-speech gaps remain hard boundaries. Add chapters near thirty minutes with a forty-minute automatic segment cap. Never split through a transcript row if a nearby safe boundary exists; preserve every ASR row.
- AI may join adjacent same-topic chapters within the cap; never join across interruptions, blank separators, deleted/manual ranges or missing coverage. Nonadjacent similar topics must not become a single continuous audio range.
- Summaries use time and sampled-place evidence with uncertainty. Do not invent airport/home/company labels or assume a sparse route proves a full journey.
- Remote enrichment must use the selected provider and existing remote confirmation policy. No silent cloud fallback or credential export. Deterministic chapters work without an AI model.
- Existing data is re-derived by a strategy-version change without new ASR or modifying raw media.

## Task 1: Watch location sampling and durable synchronization

**Files:** Shared capture metadata/location service and recording wire contracts; Watch recorder/store/queue; iPhone receiver/session repository/DaybookDatabase; focused location/transfer tests.

**Interface:** Define `RecordingLocationSample: Codable, Equatable, Sendable` with stable `id`, `sessionID`, `sessionOffset`, `requestedAt`, `location: CaptureLocation`, and source-device provenance. `RecordingSessionRepository.locationSamples(sessionID:)` returns ordered samples. SQLite table `recording_location_samples` indexes session and time; its payload contains the shared sample. Optional location-only transport capability preserves old peers.

- [x] Add failing tests for boundary scheduling, stale fixes, persistence/reopen, replay/out-of-order receipt, deletion, and location failure independent of audio.
- [x] Implement sampling and independent durable outbox/ACK transport; start and stop capture without waiting for GPS.
- [x] Add SQLite migration/read path and source-lifecycle cleanup. Keep audio metadata stable.
- [x] Run recording location, streaming recording and transfer tests; record exact evidence and remaining hardware checks.

## Task 2: Deterministic content chapters and AI continuity

**Files:** ContentSegmentation.swift, ContentSegmentRepository.swift, ContentEnrichmentService.swift, AudioProcessing.swift identity version, focused segmentation/enrichment tests.

**Interfaces:** Keep existing repository/service public entry points. Extend `ContentLocalRequest` with bounded `context: String = ""` used by all providers. Source context must participate in enrichment cache/lease checks without invalidating ASR. Consume task 1's samples using SQLite on the existing processing worker. Root owns configured provider routing, AudioProcessingModel, and CustomAISummarizer.

- [x] Add failing real SQLite tests for a 6h42m speech-heavy source, three-minute ASR blanks with VAD speech, unknown/failed coverage, thirty-minute chapter boundaries, forty-minute merge cap, raw row preservation and manual-edit retention.
- [x] Build bounded chapters, retaining raw reference ranges and distinguishing ASR blank from verified silence. Bump only derivation algorithm identity.
- [x] Evaluate topic continuity at bounded chapter boundaries rather than every one-second ASR gap. Apply checked merges and stable cached decisions for session and legacy sources.
- [x] Include observed time/location evidence in summary requests and cache identity; handle late samples. No unsupported place inference.
- [x] Run content segmentation/enrichment/relocation tests and report behavior and model limits.

## Task 3: Configured AI integration and end-to-end verification

**Files:** AudioProcessingModel.swift, new configured content-model adapter, CustomAISummarizer.swift, existing content detail UI if confirmation is needed, scripts/project source membership.

- [x] Add failing provider tests for selected local/OpenAI/Anthropic routes, topic reply validation, consent gating and stale configuration cancellation.
- [x] Route content enrichment through settings. Read credentials only after authorization; background work with confirmation enabled remains local/deterministic until a concrete payload is approved.
- [x] Integrate location changes with enrichment refresh, preserving ASR caches; ensure UI receives updated derived segments.
- [x] Build iPhone and Watch via WristNotes.xcworkspace; run targeted regression scripts and inspect generated source membership.
- [x] If the private real-recording SQLite audit snapshot still exists, copy it and run the native derivation strategy against that copy, reporting segment count/ranges and transcript coverage. No phone database mutation.
- [x] Record verification in apps/wrist-notes/verification/2026-10-23-recording-location-content.md and report software versus hardware validation separately.

## Task 4: Physical delivery and acceptance — still open

Software completion above does not close the feature. The user authorized in-place installation and testing after the original implementation plan; preserve live recordings and databases throughout.

- [x] Install the iPhone build in place and verify its automatic re-derivation of the real 6h42m source: 26 deterministic segments, with every active transcript row assigned exactly once.
- [ ] Confirm the updated Watch build is actually installed; first confirm it is not recording and protect its existing files. CoreDevice currently lists pairing but cannot establish the debug tunnel.
- [ ] Record across at least one actual 600-second boundary and verify start/boundary/stop location observations, actual fix timestamps and accuracy in Watch storage and iPhone SQLite.
- [ ] Verify screen-off boundary sampling, optional GPS failure, offline queue/reconnect, durable receipts and audio preservation on paired hardware.
- [ ] Run the selected real AI provider through the application's consent flow; verify permitted adjacent-topic merges and saved titles/summaries. The 26 deterministic segments alone do not prove this step.
- [ ] Complete dated timeline/detail/playback acceptance and resolve the observed slow complete-date load. A database with segments is not sufficient proof of a usable timeline.

Delivery status: **partial; hardware GPS, real-model enrichment and complete UI acceptance remain open**. Latest evidence is in `verification/2026-10-23-recording-location-content-device.md` and the subsequent SQLite/recap reports.
