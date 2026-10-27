# 6h42m recording: simulator content v2 pilot

Date: 2026-10-23. Scope: isolated simulator experiment, shared Swift engine, persisted native content projection. **Production automatic scheduling and physical-device deployment are not complete.**

## Input and environment

- Original simulator: `D9857EEA-8E8C-4788-BBC0-4EB3B10EE506`; cloned lab: **WiseLife Content Lab**, `012F6CC3-6B1C-4D05-A9FC-2E729A8E30E5`, iOS 26.3.
- App: `cloud.karama.wisenote`, built through `WristNotes.xcworkspace` / `WristNotes`, with `WISELIFE_CONTENT_LAB`. The flag disables legacy automatic enrichment and automatic daily recaps in this simulator build.
- Source: `legacyNote:25658F81-25F2-498C-B100-DF989AC7D67E`, 2026-10-22 12:45:04 UTC+8; duration **24,129.276 seconds (6:42:09.276)**.
- Audio SHA256: `05b4100fc316365e1127403b972b49671274f1db90c376c64e3abada6c830537`.
- ASR: 81 successful original phone windows, 69,706 rows, 74,513 text characters. VAD: 81 successful windows from the earlier corrected Mac inference. **Neither was freshly inferred in the simulator.**
- Imported fixture: `/private/tmp/wiselife-recording-audit-20261023-6bktew7e/native-fixed.sqlite3`. Source revision 530; this fixture's cancellation state is 0. The phone's separate source/cancellation state was not modified.
- Private audio, source text, prompts, responses, SQLite backups and comparison artifacts remain outside Git at `/Users/karama/Documents/WiseLife-Reports/2026-10-23-simulator-content-v2/`.

## Real model result and changes

The development runner compiles the **same `ContentSegmentationV2.swift`** added to the iPhone target. It executes on the simulator using the previously authorized configured `Doubao-Seed-2.0-mini`; credentials stay in simulator keychain and are not printed/exported.

Deterministic preparation matches the earlier preview's 254 complete text blocks and 16 candidate chapters, including each block's text/start/end. Eight ASR blank candidates yield five verified separators after full VAD coverage/ratio checks.

| Run | Total text segments | Meaningful | Low information | Observed change |
| --- | ---: | ---: | ---: | --- |
| First complete Swift/model pass | 32 | 26 | 6 | Navigation split at road phase; disconnected fragments and a turn-taking phrase were overclassified |
| Second pass | 31 | 20 | 11 | Continuous navigation merged; disconnected fragment lists filtered |
| Final pass | **31** | **19** | **12** | Waiting/turn-taking without an actual question/topic classified as low information |

The final navigation segment is 00:00–17:39.40. A short, substantive question about watch recording remains meaningful; the isolated waiting-for-a-question phrase does not. Rules use content evidence, without source IDs, sample-specific overrides or duration-only rejection. No airport/company/taxi interpretation from the old manual preview was imported.

- Complete ownership: **69,706/69,706** original rows, no duplicates or omissions.
- No overlapping segments or merges across the five verified blank separators.
- Longest segment: **2,247.9 seconds (37:27.9)**, within the 40-minute cap.
- Final pass: **31 model requests, 54 validated checkpoint hits, 0 repair requests**. This is the last pass, not the entire experiment's usage.
- Across all resumes and quality rounds: 157 unique saved successful HTTP responses; their reported usage sums to 678,576 tokens. Failed/unrecorded transport attempts are not represented by that count.
- The previous liked preview had 15 meaningful + 5 low-information segments and included a manual sample override; its counts are not an acceptance target for an independent model run.

## SQLite and native read validation

Publication uses normal `content_segments`, `content_segment_ranges`, `content_segment_presentations`, and `content_segment_sources` tables. All 31 results remain stored; classification filters the main timeline to 19. It references the original audio frames and does not concatenate or re-encode the recording.

Before publication, the tool validates the exact source revision, ASR/VAD coverage and rows, unique segment IDs, full ownership, audio hashes and frame bounds. Manual edits/suppression/tombstones and IDs owned by another source reject publication. State is checked again inside a short transaction. The database is backed up before publication and container relocation.

Live SQLite → `ContentSegmentSnapshot.read` → `ContentSegmentPresentation.timelineRecords` exposed two existing projection errors:

1. Reconstructing fractional-duration `DateInterval`s from absolute endpoints changed their floating-point values. A whole segment was mistaken for a clipped segment and its generated title/summary cleared. In-scope intervals now keep their original value.
2. A few floating-point bits at an audio range endpoint excluded an exactly aligned transcript row. Coverage checks now tolerate four endpoint ULPs; requested day bounds remain strict and genuine missing-audio gaps remain separate.

Both were reproduced with failing tests before fixes. The final native read preserves **all 19 titles, summaries and complete text exactly**, with **69,706 cached transcript rows** across all segments.

After final installation and media-path relocation, the app was launched, terminated and relaunched. Before/after timeline JSON is byte-identical. Hashes of all source/job/transcript/activity/content/recap table contents are unchanged. Counts include 81 jobs, 31 presentations, 31 segments, zero manual edits, **zero daily recaps and zero recap attempts**. Original media SHA256 remains unchanged.

Native AVFoundation in the simulator reads the original duration and decodes bounded windows at start/middle/end successfully. This verifies media readability, **not visual playback controls or listening quality**.

## Verification evidence

- Shared engine: `scripts/test_content_v2.sh` — **55 checks passed**.
- Real publisher on disposable lab database copies: **8 checks passed**. Seven invalid cases reject without changing logical database contents; valid publication and repeat remain consistent. RED run confirmed the seven missing guards accepted unsafe inputs before fixes.
- Presentation executable: passed fractional interval/endpoint regressions, original cross-midnight/gap rules, cached SQLite reads, classifications and deletion behavior.
- The same script's separate AI assistant/retrieval suite did **not** stay green during parallel workspace changes: observed failures at `DaybookRetrievalSmoke.swift:752` and `:891`. These are recorded rather than counted as a passing full script; no changes were made here to that suite or its assistant implementation.
- Workspace build initially encountered a transient `DaybookView.swift:315` syntax error in another changing file. The final fresh build succeeded: `/private/tmp/wiselife-v2-native-latest-build.log`; this is the installed binary.
- Final native snapshot and restart verification: `verification.json`, `timeline-before-launch.json`, `timeline-after-restart.json`, `before-launch-state.json` in the private report directory.
- Media verification: `audio-validation.json`; exact input/model output: `input.json`, `run-1/output.json`; previous rounds: `baseline-output.json`, `quality-round-2-output.json`.

## What remains unverified or unfinished

- Native UI control repeatedly failed with `Sky Computer Use native pipe startup failed`. No successful screenshot, date selection, detail-tab click, scrolling or playback-control test was obtained. Alternative screenshot permission was requested and was not received during this run.
- The generated local HTML listening report was checked structurally; browser rendering and listening were not verified.
- The simulator app **reads persisted pilot output**. Further strategy experiments run through the explicit development runner. Native manual reprocessing still routes to the existing scheduler; production streaming/partial publication, recovery orchestration, on-device summarizer adaptation and physical-device acceptance remain follow-up integration work.
- No phone installation, source deletion, Git commit or push was performed in this task.

## Reviewing the result

Use simulator **WiseLife Content Lab**, open WiseLife, and select **October 22**. The main timeline projection contains the 19 meaningful pieces. Full per-segment start time, duration, topic and summary are also saved in `模拟器分段结果.md`; `模拟器分段试听.html` provides bounded playback buttons against the original local audio.

See [lab tools](../Tools/ContentV2Simulator/README.md) for repeatable execution and [strategy review](../docs/superpowers/specs/2026-10-23-content-segmentation-v2-review.md) for the full production design and remaining acceptance items.
