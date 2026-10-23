# Content chapters implementation — 2026-10-23

## Delivered behavior

- Derivation identity is `asr-blank-180-chapters-1800-cap-2400-v2`; audio window/ASR identity is unchanged. Existing completed inference is reused when old giant segments are re-derived.
- Successfully processed ASR coverage with at least 180 seconds without a transcript becomes a retained low-information separator. VAD speech does not turn that evidence into acoustic silence. Missing/failed processing is never silence. Existing reliable dual ASR/VAD no-speech intervals of at least 600 seconds retain the hard-boundary behavior and two-second context padding.
- Chapters target 1800 seconds and have a 2400-second automatic cap. Boundaries use actual audio frame ranges, prefer transcript-free gaps and avoid the union of overlapping transcript intervals. Blank edges and chapter cuts use interior frame boundaries so floating-point ASR endpoints cannot duplicate neighboring transcript assignments.
- Raw audio and transcript rows are never edited by derivation. Manual splits, merges, deletions/suppression, revision guards, undo causality, legacy recordings and relocated audio references remain supported.
- AI continuity compares adjacent chapter boundaries, with 64-row pages accumulated to at most 650 characters on each side. It does not call the model for every brief transcript pause. Merge eligibility checks adjacency, both text-bearing chapters, the 40-minute cap, successful coverage, uninterrupted source ranges, configuration, signatures and revisions. Manual, blank, missing and interruption separators cannot be erased. Legacy single-file chapters can merge under the same guards.
- Time/place context is at most 1200 characters. It contains local source timestamps and actual sampled coordinates, fix time, accuracy, source device and available cached addresses. It labels observations as sparse evidence and forbids inferred routes or unsampled venue/home/company/airport labels.
- An evidence digest covers all relevant immutable samples and derived address overlays, including observations omitted from the bounded prompt. Late samples and address resolution invalidate text enrichment checkpoints without re-running ASR. Context is revalidated transactionally after model inference before checkpoint/final-summary writes, and after topic inference before changing ranges.
- Completed-checkpoint reuse remains revision aware; configuration A–B–A and relocation reuse retain useful inference. Automatic merging retains the left segment identity so a restored chapter boundary can reuse prior text checkpoints.
- `confirmationRequired` maps to `awaitingConsent` without setting the unavailable-model latch. Root integration owns selected providers and source-scoped consent.
- `ContentSegment.displayTitle` gives final no-text chapters the factual fallback `未识别到文字`; pending no-text chapters use `等待识别`. Root integration owns presentation wiring and playback explanation.

## Verification

All commands below exited 0 after the final fractional-boundary change:

| Command | Evidence |
| --- | --- |
| `sh apps/wrist-notes/scripts/test_content_segments.sh` | Real SQLite 6h42m speech-heavy source; roughly 30-minute chapters; 40-minute cap; every transcript row retained once; 180-second ASR-empty/VAD-speech separator; old giant-segment re-derivation without new ASR; manual retention; safe nearby row edge; fractional blank endpoint row ownership; overlapping-row closure; failure/retry, suppression, undo causality, persistence and 12,000-interval bounded paging |
| `sh apps/wrist-notes/scripts/test_content_enrichment.sh` | Real SQLite orchestration; 2400 tiny transcript rows produce one boundary request with 650 characters per excerpt; late location and address refresh; stale late-location write rejection; no new ASR; 40-minute merge cap; blank/manual/gap/interruption guards; legacy merge; source/configuration/revision leases; cancellation/restart/checkpoints; empty responses; availability latch |
| `sh apps/wrist-notes/scripts/test_audio_relocation.sh` | Historical job reuse, source/config/hash boundaries, cancellation/retry leases, preserved playback references, topic/enrichment checkpoints and undo |
| `sh apps/wrist-notes/scripts/test_streaming_recording.sh` | Real bounded AAC decoding; stable inference on append/replay/reopen; final tail/end coverage; one actual hard-silence exclusion; all raw transcript rows retained; original audio byte validation |

Red/green evidence: the new long-source test first failed because there were no chapters; the tiny-row test first failed with the previous four-row excerpt; the exact fractional ASR-start test first failed due to duplicate raw-row assignment and passed after interior-frame cuts. Existing regression assertions that assumed every successful ASR-empty region remained inside one giant segment were revised to assert retained media/rows and the same hard-silence exclusion.

## Files owned by this task

- `Sources/iPhone/ContentSegmentation.swift`
- `Sources/iPhone/ContentSegmentRepository.swift`
- `Sources/iPhone/ContentEnrichmentService.swift`
- `Sources/iPhone/AudioProcessing.swift` (derivation algorithm identity only)
- `Tests/ContentSegmentationSmoke.swift`
- `Tests/ContentEnrichmentSmoke.swift`
- `Tests/AudioRelocationSmoke.swift` (dense fixture and locator-era signature identity)
- `Tests/StreamingRecordingSmoke.swift` (content-boundary assertions only; location agent owns its ACK enum addition)

## Limits and integration boundary

These are native software/SQLite tests with injected text models, not paired-device or model-quality validation. Root owns configured provider integration, remote consent UI, Xcode workspace builds, final private-snapshot audit and the main verification report. No commit, push, reset, reinstall, device operation or recording database mutation was performed here.

A pathological transcript whose overlapping rows cover every possible cut for more than 40 minutes must still obey the duration cap; the unavoidable fallback may cross a row. Ordinary overlapping rows are handled by finding a gap outside their union. The copied real-recording audit is re-run by root against a fresh original snapshot to verify its exact row assignments.
