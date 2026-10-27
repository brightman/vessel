# Persisted content timeline

**Goal:** Fix October 22's 6h42m recording presentation using durable processed segments.

**User requirements:** Timeline shows meaningful content segments only. Raw long recordings and empty segments are hidden there; recordings remain available for playback. Finished segment data is stored in SQLite and read by the app.

**Architecture:** Keep `content_segments` as the authoritative metadata, title, summary and range store. Add a rebuildable SQLite presentation table with the segment's exact timed transcript, keyed by semantic content signature. Processing prepares this artifact outside the writer transaction, then validates and commits it in a short transaction. Date reads use persisted artifacts, with no raw ASR scan or inference. Full evidence retains timed spans and strict date containment.

**Constraints:** Preserve audio and original ASR; no reset/uninstall. Preserve remote AI consent and daily recap budget. Keep 2-second ASR boundary context, manual edits, tombstones and cross-midnight rules. Existing unrelated working changes stay untouched.

## Work

- [x] Add regression proving date presentation does not query raw transcript rows after processing; include restart, stale artifact, blank segment and parent filtering checks.
- [x] Add schema v13 and processing-time materialization in `DaybookDatabase.swift` / `ContentSegmentRepository.swift`. Bound source transcript queries by real segment ranges and model context.
- [x] Read persisted artifacts in `ContentSegmentModel.swift`; cancel superseded refresh tasks, publish the requested date before library/calendar completion.
- [x] Filter timeline in `ContentSegmentPresentation.swift` / `DaybookView.swift`; retain raw recording access in the library and segment detail.
- [x] Run presentation, contention, segmentation, enrichment and relocation regressions; verify the real phone database copy and exact preservation of the target recording and its ASR/VAD rows. Two other notes have separate deletion tombstones; do not assert all-library equality.
- [x] Build signed workspace and install in place. Final build installed at 20:42; launched at 20:46. Home screenshots and SQLite audit recorded in `verification/2026-10-23-persisted-timeline-recap-refresh.md`.
- [ ] Recheck October 22's list on the final build. The 20:30 screenshot proved multiple segments on the preceding build; final empty-segment filtering has code/SQLite coverage but no final list screenshot yet. iPhone Mirroring is not configured, so the user must navigate on the phone for this specific visual check.

## Daily recap follow-up

- [x] Preserve the durable per-date automatic-attempt limit for today, yesterday and historical dates. Related/unrelated data updates, settings changes and restarts cannot renew it; later generation is manual.
- [x] Remove foreground loading resets on processing progress, scope visible fingerprints by date, preserve compatible historical citation hashes, and fence late validation against newly generated results.
- [x] Pass the complete recap regression suite, including 20 progress notifications, deletion/privacy, cancellation, asynchronous overwrite and two-connection automatic-claim tests. Independent review found no blockers.

No commit or push is part of this follow-up.
