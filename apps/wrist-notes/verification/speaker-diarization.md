# Local speaker diarization verification

Date: 2026-10-20 (implementation started 2026-10-19).

## Delivered behavior

- Apple SpeechAnalyzer and Whisper Tiny/Base/Small retain timed transcript pieces.
- After ASR is durably saved, SpeakerKit analyzes the original audio locally; timestamp overlap assigns speaker labels. Ambiguous/unmatched pieces remain unassigned. Labels are numbered by first appearance within each recording.
- Both detail views show speaker, time range and text. Names apply to all corresponding segments in that note. The editor supports segment text corrections and whole-text replacement. Whole-text changes clear stale timing/labels; unchanged text retains them.
- ASR and diarization failures are independent. Audio and successful ASR survive unavailable speaker resources or failed diarization. Retry reuses the persisted timed transcript. Saved edits, including edit-and-restore changes, win over in-flight inference.
- Settings have one download action. Apple/Whisper resources include the shared speaker model. Existing models are reused; incomplete bundles remain unavailable for saving configuration; retries download only missing assets.
- Model inference uses explicit local paths with `download: false`. SDK versions are pinned: WhisperKit/SpeakerKit 0.18.0, swift-transformers 1.1.6. No audio is uploaded by this feature.
- Speaker models: 20 files, 11,242,906 bytes, revision `556fc52a13327837688f02289457cded017802e9`, checksummed and installed atomically under Application Support/WristNotes/SpeakerModels. Downloadable models are excluded from backup. Model license CC BY 4.0, SDK MIT; attribution is bundled and linked from the existing settings footer.

## Verification performed

| Check | Result | Boundary |
| --- | --- | --- |
| Portable speaker tests | Passed | Legacy decode, JSON/repository restart, renaming, source-order preservation including untimed punctuation, overlap/tie/gap alignment, text editing, revision protection |
| Existing `scripts/test_local.sh` suite | Passed | Repository, Watch interaction/status, settings, model download recovery, daybook/SQLite regressions |
| Focused iOS build and 7 XCTest cases | Passed, 0 failures | Real production NotesModel/repository/UI/resources compiled for iOS Simulator; slow inference replaced only at its dependency boundary in lifecycle tests |
| Shared source typecheck for watchOS 10 simulator | Passed | VoiceNote and RecordingFormat; not a Watch app runtime test |
| Actual Whisper Tiny + SpeakerKit Core ML inference on Mac | Passed | Official public 26.909s VADAudio fixture produced 24 timed pieces, one assigned speaker, three display segments; music remained unassigned |
| Actual alternating two synthetic English voices on Mac | Ran successfully | 33.86s, 82 timed pieces, four turns. Auto clustering returned **three** labels for two source voices; this demonstrates over-splitting, not validated diarization accuracy |
| Independent code review | No remaining high/medium findings | Review does not replace physical-device or UI testing |

Disk-failure tests were first observed failing, then passed after commit-gating and retryable failure-state fixes. The portable persistence test first failed because old serialization discarded speaker metadata.

### XCTest coverage

1. Persist ASR before diarization; diarization failure preserves successful ASR and can retry.
2. Editing during diarization prevents stale result overwrite.
3. Editing and restoring original text during ASR still prevents overwrite.
4. Deleting a note during processing does not resurrect it.
5. Failed ASR persistence does not advance to diarization.
6. Failed diarization persistence leaves a retryable state.
7. Bundled downloads remain incomplete until both models validate; retry reuses completed Whisper assets.

## Reproduce

From repository root:

```sh
sh apps/wrist-notes/scripts/test_local.sh
ruby apps/wrist-notes/scripts/test_speakers_ios.rb /private/tmp/wiselife-speaker-ios
xcodebuild -project /private/tmp/wiselife-speaker-ios/SpeakerVerification.xcodeproj \
  -scheme SpeakerVerification \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -derivedDataPath /private/tmp/wiselife-speaker-ios-derived test
```

The focused target references production Swift files directly. `Tests/SpeakerVerification/BoundaryTypes.swift` substitutes only Ring metadata and unrelated settings/navigation types, allowing these checks while the separate Ring SDK is absent. It does **not** verify EurekaRing integration or the full application.

`Tests/SpeakerIntegrationSmoke.swift` is the actual-model executable entry point. It uses production transcription/model-store classes and accepts:

```
smoke whisper-manifest speaker-manifest whisper-root speaker-root audio-file
```

This session's build and real-inference logs are under `/private/tmp/wiselife-speaker-*.log`; the two-voice output is `/private/tmp/wiselife-two-speakers.log`. They contain only public/synthetic fixture text. Models and generated audio remain outside the repository.

## Remaining verification

- Full `WristNotes.xcworkspace` build is pending: existing external BRRecorderCore and Pods were absent. The user assigned rebuilding this SDK to a different agent and asked this task to continue independently.
- Native clicks, alerts and visual inspection are not verified. Computer Use returned `Computer Use was not approved to use Simulator`; no alternate UI-control route was used.
- Apple ASR execution, speed/memory/heat, long recordings and real conversational diarization on iPhone 16 Pro are not verified. The simulator previously reported Apple SpeechTranscriber unavailable. Compiling that adapter does not establish runtime availability.
- Speaker labels are estimates. The two-voice fixture over-split one source voice; no thresholds were tuned to this single example. Overlap, noise, short speech and similar voices need representative physical-device testing.
- Names are local to one recording. No enrolled voiceprints or automatic identity recognition across recordings are implemented.

## iPhone 16 Pro acceptance steps

1. Open Settings → 语音转写模型; choose Apple or Whisper; use the single “下载或补全离线资源” action, then save.
2. Record two people alternating turns for 1–2 minutes. Finish recording; verify text appears before speaker analysis finishes.
3. Open 全文; compare time ranges and speaker labels with playback. Rename a speaker; reopen the note and verify all corresponding labels persist.
4. Correct a segment; verify timing and name remain, and the old summary is invalidated. Replace whole text; verify stale labels disappear.
5. Repeat after disabling networking. Compare short and long recordings for timing, accuracy and peak memory; do not infer iPhone performance from Mac results.
