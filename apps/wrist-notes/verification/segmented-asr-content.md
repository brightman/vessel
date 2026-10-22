# Segmented recording content — software verification

2026-10-22. Phase B/C software delivery and verification; physical acceptance is listed separately below. Development task provenance starts at `9b7c522`; publication uses the clean `codex/vessel` ancestry.

## Delivered software

- Durable SQLite audio-window jobs/results, lease/configuration/deletion guards, bounded original-file reads and a shared serial on-device inference gate. Successful stages survive partial retry, interruption and restart.
- Content segmentation from continuous confirmed VAD noSpeech coverage, preserving physical audio boundaries/gaps and manual split/merge/delete/undo decisions. Empty ASR alone cannot create a silence boundary.
- Local Foundation Models topic/title/summary enrichment with bounded prompts/reduction, durable checkpoints and stale-result guards; unavailable models remain explicit and no cloud fallback is automatic.
- Runtime-owned observable content model, bounded SQL list pages, complete explicit DateInterval evidence snapshots, source lists and paged transcript detail.
- Stable segment IDs across midnight; each date receives actual overlapping intervals, frame ranges and timestamp-backed transcript. A span crossing a date boundary is excluded from each narrower date because word timing is unavailable; the complete original/combined scope retains it. Span audio coverage uses the continuous union of adjacent clipped physical ranges, so speech across file boundaries survives while genuine audio gaps remain excluded. A narrower scope excludes whole-segment generated titles/summaries to avoid out-of-date facts. Source gaps remain gaps.
- Home/library/calendar use derived content instead of simultaneous parent evidence. Complete recordings remain reachable for pending, all-noSpeech or manually hidden content. Explicit AI dates load complete parent-session fallback independently of selection and UI paging. Parent suppression is computed after projection, so a selected-date child cannot erase the same source’s queried-date fallback.
- Segment detail has audio, summary/full text, processing/resource/failure/retry/cancel status, revision-guarded split/merge/delete/undo, and complete-recording access. Split converts compact playback position through RecordingRangePlan.locate; transcript/citation seeks perform the reverse range mapping. Segment playback stops when capture disallows playback.
- Existing SQLite FTS/Vector indexes consume one combined clipped DayRecord per segment per explicit DateInterval. Scope/source/segment identity enters cache fingerprints and async generations. Local citations persist URL-free chunk/frame provenance and route to the segment; removed/stale records invalidate current evidence. Existing privacy and remote-send confirmation remain active. Durable legacy deletion now immediately invalidates the production presentation cache, outstanding scope work, loaded assistant evidence/remote confirmation and vector/FTS generations. Old captured source arrays cannot resurrect deleted evidence. The complete legacy view exposes a confirmed original-audio-plus-derived-content delete action through existing tombstones.

## Enablement and user entry points

Startup/foreground and committed recording/chunk notifications refresh durable discovery. New session audio and eligible unfinished legacy long recordings enter the bounded processing queue; accepted ASR/VAD work derives content, then the serial local enrichment queue creates topic/title/summary outputs. Content notifications refresh presentation.

Previously completed legacy transcriptions and existing manual transcript bodies are not automatically enrolled solely by this UI change. Existing known durable sources resume; the full recording's explicit processing retry or existing explicit reprocess action can enroll/reprocess legacy audio. Original notes, manual titles/text and original audio remain stored separately from derived records.

Independent ASR/VAD/speaker failures, cancellation, missing resources and skipped stages remain visible even when all window jobs are completed. Speaker skips explain the >30-minute/unknown-duration protection without implying success. Missing resources show a state and a **语音转写模型设置** button using the existing settings/download flow. Retry does not download models. Local enrichment checks Foundation Models availability and zh-CN support; unavailable is visible and can be retried. No cloud fallback was added. Existing explicitly selected remote short-note/answer flows retain consent checks. **取消转写处理** cancels durable transcription processing; local enrichment has its existing capture/protected-data/memory cancellation lifecycle.

## Verified

- `sh apps/wrist-notes/scripts/test_content_segment_presentation.sh`, exit 0; `/private/tmp/task-6-presentation-final.log`. Real Foundation/SQLite fixtures cover midnight distinct words and exact frames, daily totals, parent/child deduplication, stale/deleted evidence, old Codable archives, URL-free citations, combined intervals, source-gap time mapping, and 121 rows beyond SQL/UI pages. Existing assistant regression suite also runs: requested old-date loading/failure/late cancellation, question-first persistence, remote consent, source/config races and conversation lifecycle.
- `sh apps/wrist-notes/scripts/test_semantic.sh`, exit 0; `/private/tmp/task-6-semantic.log`. Same-ID midnight FTS/vector replacement and combined scope/generation invalidation plus existing tokenizer, resumable chunks, 4097 candidates, cancellation, permissions and resource lifecycle fixtures.
- `sh apps/wrist-notes/scripts/test_recording_presentation.sh`, exit 0; `/private/tmp/task-6-recording-presentation.log`. Exact range seeks, sparse gaps, midnight/DST and session-model old-day/month/paging behavior.
- `sh apps/wrist-notes/scripts/test_apple_reminders.sh`, exit 0; `/private/tmp/task-6-reminders.log`. Current schema 9 migration and reminder recovery/persistence.
- `sh apps/wrist-notes/scripts/test_recording_repository.sh`, exit 0; `/private/tmp/task-6-recording-repository.log`. Current schema migration, recovery, receipts, deletion and media ranges.
- `ruby apps/wrist-notes/Tests/ProjectSourceMembershipSmoke.rb`, exit 0; `/private/tmp/task-6-membership.log`.
- `xcodebuild -workspace apps/wrist-notes/WristNotes.xcworkspace -scheme WristNotes -configuration Debug -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build`, exit 0, `BUILD SUCCEEDED`; `/private/tmp/task-6-native-final.log`. Includes Task 4/5 production sources and Foundation Models typed adapter; final incremental run covers the final model/view/assistant changes. No reported compiler warnings/errors in this log.
- `git diff --check`, exit 0.

Focused simulator test-host generators were updated and generated successfully at `/private/tmp/task-6-storage-host` and `/private/tmp/task-6-speaker-host`. Their simulator/device tests were not run.

## Review fix covering checks (I1–I5)

- `sh apps/wrist-notes/scripts/test_content_segment_presentation.sh`, exit 0; `/private/tmp/task-6-fix-presentation-final.log`. Real SQLite crossing-midnight span exclusion and combined-scope retention, same-source date fallback, durable repository cascade and production cache invalidation; actual assistant pending-loader/late-result/remote-preview cancellation; pure independent-stage failed/missing/cancelled/skipped presentation. The existing assistant/conversation regression suite also passes.
- `sh apps/wrist-notes/scripts/test_semantic.sh`, exit 0; `/private/tmp/task-6-fix-semantic-final.log`. Actual durable repository deletion synchronously revokes index generation, clears vector/FTS rows and rejects pre-delete arrays; existing semantic/keyword/chunk/race fixtures pass.
- One final incremental generic iOS workspace build, exit 0, `BUILD SUCCEEDED`; `/private/tmp/task-6-fix-native-final.log`. The actual cache inheritance, stage bridge, full-delete UI and catalog compile. Existing Watch AccentColor/OSAtomic and ChatGPT UIWindow warnings plus AppIntents extraction warning remain; no new fix-source warning/error was reported. `git diff --check`, exit 0.
- Exact RED assertion evidence and temporary `da37933` source-overlay commands are in `/private/tmp/wiselife-asr-development/review-evidence/task-6-report.md`, fix round 1. No full local or unaffected model suite was repeated in this fix wave.

## Review fix round 2 — continuous range coverage

- `sh apps/wrist-notes/scripts/test_content_segment_presentation.sh`, exit 0; `/private/tmp/task-6-fix2-presentation-final.log`. Added `[0,300]` + `[300,600]` / span `[299,301]` same-day and combined-scope retention with reversed range order; real-gap exclusion; contiguous chunk boundary at midnight still enforces strict date containment. Existing SQLite, deletion, stage-state and assistant/conversation checks pass. The new contiguous-span assertion first failed with exit 133 in `/private/tmp/task-6-fix2-red-contiguous.log`.
- One final incremental generic iOS workspace build, exit 0, `BUILD SUCCEEDED`; `/private/tmp/task-6-fix2-native-final.log`. No warnings/errors in this incremental log. `git diff --check`, exit 0. Semantic sources were untouched and their suite was not repeated.

## Consolidated Phase B/C verification

The publication tree is based on `origin/codex/vessel` at `13563425cc9052969098db956f97ee39364fe10e`, with task-owned changes applied by three-way merge. The development snapshot ancestry is not part of the published history. Existing LifeMoment fields/UI/navigation, project membership and localization were preserved.

### Full software gate and final covering checks

| Command | Task revision applied to publication tree | Result |
| --- | --- | --- |
| `sh apps/wrist-notes/scripts/test_local.sh` | `da37933` | exit 0, 1024.7 s |
| `sh apps/wrist-notes/scripts/test_bounded_audio.sh` | `da37933` | exit 0, 47.5 s |
| `sh apps/wrist-notes/scripts/test_audio_processing_coordinator.sh` | `da37933` | exit 0, 27.9 s |
| `sh apps/wrist-notes/scripts/test_content_segments.sh` | `da37933` | exit 0, 68.8 s |
| `sh apps/wrist-notes/scripts/test_content_enrichment.sh` | `da37933` | exit 0, 110.3 s |
| `sh apps/wrist-notes/scripts/test_content_segment_presentation.sh` | `da37933` | exit 0, 41.7 s |
| `sh apps/wrist-notes/scripts/test_content_segment_presentation.sh` | `ce3bb20` | exit 0, 89.4 s |
| `sh apps/wrist-notes/scripts/test_semantic.sh` | `ce3bb20` | exit 0, 79.1 s |
| unsigned generic iOS workspace build | `ce3bb20` | exit 0 / BUILD SUCCEEDED, 61.3 s |
| final requested-date assembly presentation/assistant checks (development source) | `a00aba2` | exit 0 |
| final unsigned generic iOS workspace build (publication target) | `a00aba2` | exit 0 / BUILD SUCCEEDED, 16.9 s |

Structured results and matching logs are retained under `/private/tmp/wiselife-asr-development/publication/`. The full suite ran once against the merged publication content. Later fixes use covering checks; unchanged suites are not represented as rerun after each fix.

The synthetic sparse 6.5-hour file exercises <=4096-frame original reads and <=304-second inference inputs. Its reader process used approximately 16 MB peak RSS. This is bounded-reader evidence, not iPhone memory or model endurance evidence. Persistence fixtures cover leases/restart/stale configuration/deletion rejection, retained successful stages, speaker mapping provenance, 599/600/601-second noSpeech boundaries, 12,000 activity intervals with maximum SQL page 256, causal manual undo and A-to-B-to-A enrichment cache restoration.

Earlier Task 2 executed installed cached Whisper/Pyannote/SpeakerKit/identity adapters on this Mac with network denied, using synthetic fixtures. Actual service ASR/VAD/speaker stage integration and VAD-only retry passed. Observed Mac model-process peak RSS was 580943872 bytes; this is not physical iPhone memory, accuracy or availability evidence. No model was downloaded for those checks. Actual Foundation Models generation was not exercised.

### Historical diagnostics retained

The first Task 3 focused native lifecycle run finished with 11 tests and one existing Watch-import retry timeout (xcodebuild exit 65). The unchanged Watch test subsequently passed in isolation (1/0); the affected projection/routing checks passed (3/0). No Watch receiver implementation was changed. These later passes do not erase the original timing observation or prove it impossible.

Unsigned `--strip-bitcode`, existing Watch AccentColor/OSAtomic deprecations, ChatGPT UIWindow deprecation and AppIntents extraction warnings are recorded nonblocking diagnostics. Generic unsigned compilation does not verify device signing, installation or execution.

## Physical acceptance and known limits

No physical-device installation/restart, microphone capture, GUI/screenshot or private recording access was performed in this Phase B/C round. Physical >15-minute/three-boundary validation, 6.5-hour capture endurance, actual device peak memory/thermal/battery behavior, ASR/VAD quality, Foundation Models availability/quality, resource downloads and interactive audio/UI lifecycle remain open.

The Watch DEBUG continuous-capture opt-in and Release guard remain unchanged. Unknown-duration and >30-minute speaker analysis remains blocked. Empty ASR is never treated as silence: automatic separation requires continuous successful VAD noSpeech coverage. Environmental sound classification was discussed but is outside this implementation.

The prior SQLite page-in SIGBUS and the unexplained discrepancy between 6.5-hour capture and 5.5-hour received audio are not claimed fixed by these checks. Original audio, IDs, file paths, manual data and tombstone/protection behavior are retained. The existing SQLite FTS/Vector index is reused; no parallel index or automatic cloud fallback was introduced.

## Final scope fix and original-checkout handoff

The final whole-change review found one remaining requested-date legacy-parent assembly omission. Commit `a00aba2` adds current original legacy notes to the scope-authoritative input before date projection and child suppression. The focused fixture uses an actual imported legacy note and persisted B-day child: A retains its fallback when no A child exists, B contains only its child, and actual deletion fences captured stale inputs for both dates. The presentation/assistant script passed with exit 0 (`/private/tmp/task-6-final-fix-presentation-final.log`); its preceding named assertion failed with exit 133. Final scoped code review approved the fix with no open Critical/Important findings.

The original checkout also contains independently developed bulk audio merging/deletion code. A narrowly pinned handoff adapter preserves that code and emits one deletion notification per actually deleted source only after the transaction commits. Exact-byte/idempotence/unknown-input rejection and full-repository Swift compilation plus bulk/single/duplicate/absent-ID/rollback/tombstone fixtures passed (exit 0). The malformed automatic merge first reproduced the out-of-scope `id` compile error (exit 1). This original-only integration does not import the independent merger feature into the publication commit.

The final reviewed task revision was applied to both actual targets. Publication generic iOS compilation passed in 16.9 seconds; original-checkout generic iOS compilation passed in 52.8 seconds, both exit 0 / BUILD SUCCEEDED. Commands use `WristNotes.xcworkspace`, `WristNotes`, Debug, `generic/platform=iOS` and `CODE_SIGNING_ALLOWED=NO`. Results/logs are in `publication/final-fix-native*` and `handoff/final-original-native*` under the temporary evidence directory.

A fresh 1,044-file fingerprint preceded the original handoff. The immediate before/after check confirmed exactly 76 task paths changed, no unrelated changes, and unchanged original branch, HEAD and index entries. After this handoff, independent recording-merge work continued in VoiceNote, its tests, the detail/list views, NotesModel, NoteRepository and localization. These later edits were preserved; the named production diffs retain this task’s processing/evidence/deletion changes. The later original-checkout revisions are outside the reported handoff-version build evidence. The reviewed publication tree remains unchanged by that concurrent work. Concurrent LifeMoment, recording-merge UI and localization work were retained. The explicit publication manifest contains 77 paths: the task paths plus the approved design prerequisite. Pods, private data, unrelated work and the development snapshot ancestry are excluded. Review reports and scoped packages are archived at `/private/tmp/wiselife-asr-development/review-evidence/`; the portable outcomes and limits are recorded in this document.
