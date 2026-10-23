# Streaming long recording verification

Implementation evidence for the [streaming design](../docs/superpowers/specs/2026-10-22-streaming-recording-design.md), 2026-10-22. This is software verification; physical Watch capture, WCSession scheduling, background model execution and endurance remain unverified.

Source revision: `96514e4b1b35b6d4c53a5ddac89fb91391b74b7f`, following Task 1 `852ad6e4f60b86a42e3ba93164badd19f030f7b3`. Commands below run from `apps/wrist-notes` in `/Users/karama/.codex/worktrees/887a/Vessel`. Logs are under `/private/tmp/wiselife-streaming-development/`.

## Synthetic integration

`sh scripts/test_streaming_recording.sh` uses production `RecordingChunkWriter`, `WatchRecordingSessionStore`, `WatchChunkTransferQueue`, `RecordingChunkReceiver`, SQLite session/processing/content repositories, coordinator, segmentation and `BoundedAudioReader`. It generates 1,210 seconds of synthetic AAC from a reusable 4,096-frame PCM buffer; it never opens a microphone or downloads a model. OS delivery and native inference are injected.

The fixture observes `RecordingChunkReceiver.didChange`, the same notification used by `AudioProcessingModel`, and refreshes the production coordinator. Discovery reads the real session repository and validates the real files. The UIKit/Combine `AudioProcessingModel` facade and native inference implementation do not execute in this macOS fixture; their integration is native-build evidence only.

Assertions establish:

- At 600 seconds, before `writer.finish()` and with no session end, the first original AAC file is retained, the phone receipt exists, the session is incomplete, and the stable ASR/VAD window `[0,300]` is committed. The next window waits for two seconds of right context; early receipt does not imply all 600 seconds have already been analyzed.
- Appending the second 600-second file commits `[300,600]` and `[600,900]`. Duplicate delivery leaves one chunk row and receipt and does not rerun unchanged committed inference. Reopening SQLite and the coordinator preserves those results.
- Delivering the end before the final ten-second tail cannot complete the phone session or Watch sync state. Once the tail arrives, remaining `[900,1200]` and `[1200,1210]` windows commit and all chunks plus end ACK complete the session.
- Every model core is at most 300 seconds; every materialized model input is at most 304 seconds. Real AAC decoding uses buffers of at most 4,096 source frames.
- Injected successful ASR/VAD coverage with noSpeech `[480,1080]` crosses the file boundary at 600 seconds and yields exactly two content segments, retaining two seconds of context at each silence edge. Reconciliation retains the same segment identities. A failed/missing middle coverage interval cannot produce that silence split.
- Content ranges reference original chunk IDs, URLs, hashes and valid frames. Revalidating Watch and phone originals against sealed descriptors confirms byte preservation; no concatenated audio file is created.
- Pure presentation derivation distinguishes local active recording, unknown/pending end, pending sync and fully ACKed history. Active recording cannot be wholly synced even when every currently sealed chunk has been saved.

The integration checks characterized an existing working processing path; no processing coordinator, receiver, model facade, native inference, SQL schema, content derivation or long-speaker gate change was needed.

## Commands and results

| Command | Result | Log |
| --- | --- | --- |
| `sh scripts/test_streaming_recording.sh` | Exit 0 | `task-2-green.log` |
| `sh scripts/test_audio_processing_coordinator.sh` | Exit 0 | `task-2-focused-coordinator.log` |
| `sh scripts/test_content_segments.sh` | Exit 0 | `task-2-focused-content.log` |
| `sh scripts/test_recording_transfer.sh` | Exit 0 | `task-2-focused-transfer.log` |
| `ruby Tests/ProjectSourceMembershipSmoke.rb` | Exit 0 | Console; also included in full suite |
| `sh scripts/test_local.sh` (one full run, includes streaming) | Exit 1 at baseline Daybook retrieval compile source-list omission | `task-2-full-local.log` / `.exit` |
| `sh /private/tmp/wiselife-streaming-development/task-2-suite-resume.sh` (failed command through remaining suite after runner fix) | Exit 0; all remaining commands passed | `task-2-suite-resume.log` / `.exit` |
| Generic iOS workspace build below (includes Watch) | Exit 0, `BUILD SUCCEEDED` | `task-2-native-build.log` / `.exit` |
| Release parser invocation below (no `-D DEBUG`) | Exit 0 | `task-2-release-parse.log` / `.exit` |
| `git diff --check` | Exit 0 | Console |

```sh
xcodebuild -workspace WristNotes.xcworkspace -scheme WristNotes -configuration Debug \
  -destination 'generic/platform=iOS' \
  -derivedDataPath /private/tmp/wiselife-streaming-development/native-derived \
  -clonedSourcePackagesDirPath /Users/karama/Library/Developer/Xcode/DerivedData/WristNotes-afdgjwgqwjnxdqbmksfbzlpgxkau/SourcePackages \
  -disableAutomaticPackageResolution -onlyUsePackageVersionsFromResolvedFile -skipPackageUpdates \
  CODE_SIGNING_ALLOWED=NO build

swiftc -frontend -dump-parse -target arm64-apple-watchos10.0 \
  -sdk /Applications/Xcode.app/Contents/Developer/Platforms/WatchOS.platform/Developer/SDKs/WatchOS26.2.sdk \
  Sources/Watch/WatchRecorder.swift Sources/Watch/SegmentedAudioCapture.swift
```

The full run exposed a preexisting runner gap: `DaybookRetrievalSmoke.swift` calls `NoteRepository`, but its compile command omitted both `NoteRepository.swift` and its `VoiceNote.swift` dependency. Both the reference and omission are present in Task 1 revision `852ad6e4f60b86a42e3ba93164badd19f030f7b3`. The runner now lists those sources. The saved resume script defines the same original runner variables/temp-directory cleanup, then runs the corrected failed compile command and every remaining command verbatim. The completed prefix was not repeated. This records actual full coverage without claiming that the original full command exited successfully.

Release preprocessing/syntax evidence: the no-DEBUG parse retains `beginContinuousCapture(sessionID:)` and its call. Source review confirms the `.long` branch and recovery guard are outside all conditional compilation blocks, with no DEBUG flag or opt-in key in either file. This is not a full Release build.

Native build warnings (29 repeated diagnostics, four distinct types; existing code/resources):

- Watch `Assets.xcassets`: missing `AccentColor`.
- `SegmentedAudioCapture.swift:156,164,169,175,179`: `OSAtomicCompareAndSwap32Barrier` deprecated since watchOS 3.0.
- AppIntents metadata extraction skipped for a target without an `AppIntents.framework` dependency.
- `ChatGPTBrowserAuthorization.swift:51`: `ASPresentationAnchor()` initialization deprecated in iOS 26.0.

The build completed `WristNotesWatch` and `WiseLifeWatchRecordingWidget` and embedded their products into the iPhone app. Existing cached packages were used; the build log contains no `Fetching` or `Downloading` messages. No new source membership was needed.

## Physical acceptance still required

Both devices were reported unavailable to `devicectl` by the controller during this task. No install, restart, uninstall, download, microphone operation, private-audio access or backup attempt was made. The preexisting untracked Pods symlink and cached packages were preserved.

Before any separately authorized device change, back up the prior unsynced Watch recording. The user then starts a recording of at least 21 minutes: verify early iPhone receipts before stopping, reconnect/replay behavior, final chunk count and total effective duration, retained originals, interruption recovery and user-visible partial sync. Also exercise native model availability/unlock/background execution and actual Watch text/layout on paired devices. Synthetic success and a native build do not establish those device outcomes.

## Reviewed delivery to the active checkout

Both task reviews and the final whole-task review of `f354f5e..57fb371` approved the implementation with no new Critical or Important findings. Existing native diagnostics remain documented above.

The controller delivered only the 21 task-owned paths to `/Users/karama/Documents/Vessel`. Three-way integration retained the concurrent activation guards in `WatchRecorder` and `PhoneWatchStatus` and the existing local test runner changes. The string catalog retained every original entry and received the three non-overlapping task additions. Original source snapshots, candidate hashes and the applied manifest are under `/private/tmp/wiselife-streaming-development/handoff-reviewed-eo5z9tav/`. The original Git index was unchanged; no unrelated files were staged or replaced.

Verification on the actual merged original checkout, from `apps/wrist-notes`:

| Command | Result | Evidence under `/private/tmp/wiselife-streaming-development/` |
| --- | --- | --- |
| `sh scripts/test_streaming_recording.sh` | Exit 0; all streaming and presentation assertions passed | `original-streaming.log` / `.exit` |
| `sh scripts/test_watch_sync.sh` | Exit 0; pairing, persistence, failure evidence and retry policy passed | `original-watch-sync.log` / `.exit` |
| `ruby Tests/ProjectSourceMembershipSmoke.rb` | Exit 0; Watch/iPhone/shared/widget membership and localized resources passed | Controller console |
| `sh -n scripts/test_local.sh scripts/test_streaming_recording.sh` | Exit 0 | Controller console |
| `git diff --check` limited to modified tracked delivery files | Exit 0 | Controller console |
| Generic iOS workspace build below, including Watch app and widget | Exit 0, `BUILD SUCCEEDED` | `original-native-build.log` / `.exit` |

```sh
xcodebuild -workspace WristNotes.xcworkspace -scheme WristNotes -configuration Debug \
  -destination 'generic/platform=iOS' \
  -derivedDataPath /private/tmp/wiselife-streaming-development/original-native-derived \
  -clonedSourcePackagesDirPath /Users/karama/Library/Developer/Xcode/DerivedData/WristNotes-afdgjwgqwjnxdqbmksfbzlpgxkau/SourcePackages \
  -disableAutomaticPackageResolution -onlyUsePackageVersionsFromResolvedFile -skipPackageUpdates \
  CODE_SIGNING_ALLOWED=NO build
```

This merged build emitted 30 repeated diagnostics from the same four existing warning types, with no package fetching/downloading entries. Hash checks confirmed all 21 delivered files still matched their reviewed/merged candidates after verification. Subsequent changes only update this verification report and plan checkboxes. The branch/worktree is retained locally; this task was not pushed. No device install or microphone operation was performed, and the earlier unsynced Watch recording remains a separate unresolved device incident.
