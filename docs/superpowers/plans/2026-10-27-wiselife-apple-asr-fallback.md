# WiseLife Apple ASR Engine Fallback Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Prefer Apple `SpeechTranscriber` for configured Apple ASR and use `DictationTranscriber` when Speech is unavailable, does not support the selected locale, lacks its system resource, or fails inference.

**Architecture:** A pure Swift policy chooses the primary and fallback engines. Both engines run through the existing `OnDeviceTranscriber` / `SpeechAnalyzer` boundary. Settings lists the union of supported locales and installs each supported primary/fallback resource; the actual engine name is stored with note/window results and shown in recording details.

**Tech Stack:** Swift 6.2, iOS 26 Speech framework, `SpeechAnalyzer`, `AssetInventory`, Swift smoke tests, Xcode Simulator and generic iOS builds.

## Global Constraints

- Minimum deployment target remains iOS 26 and watchOS 10.
- Apple transcription remains on-device; no server transcription is added.
- Whisper behavior and Watch recording/transfer behavior remain unchanged.
- Keep all pre-existing unrelated worktree changes and credentials untouched.
- Do not stage or commit changes as part of this task.

---

### Task 1: Test and implement the Apple ASR engine policy

**Files:**
- Modify: `apps/wrist-notes/Sources/iPhone/TranscriptionConfiguration.swift`
- Create: `apps/wrist-notes/Tests/AppleASREnginePolicySmoke.swift`
- Create: `apps/wrist-notes/scripts/test_apple_asr_policy.sh`
- Modify: `apps/wrist-notes/scripts/test_local.sh`
- Modify: `docs/superpowers/specs/2026-10-27-wiselife-simulator-apple-asr-design.md`

**Interfaces:**
- `AppleTranscriptionEngine: String, Sendable` has `.speechTranscriber` and `.dictationTranscriber`, plus `displayName`.
- `AppleTranscriptionEnginePolicy.preferred(speechAvailable:speechLocaleSupported:dictationLocaleSupported:) -> AppleTranscriptionEngine?` selects Speech first, then Dictation.
- `AppleTranscriptionEnginePolicy.run<T: Sendable>(preferred:fallback:shouldFallback:operation:) async throws -> (engine: AppleTranscriptionEngine, value: T)` returns the actual successful engine and retries only when `shouldFallback` permits it.

- [ ] **Step 1: Create a failing smoke test and its runner**

The smoke test asserts Speech preference when both engines are available, Dictation selection if Speech or its locale is unavailable, no selection when neither can run, Speech success without retry, Speech failure followed by Dictation success, and cancellation/error propagation without fallback. The runner compiles only Foundation-based configuration and the smoke test:

```sh
swiftc Sources/iPhone/TranscriptionConfiguration.swift Tests/AppleASREnginePolicySmoke.swift -o "$output/policy"
"$output/policy"
```

- [ ] **Step 2: Run the test and confirm the expected missing-policy failure**

Run from `apps/wrist-notes`: `sh scripts/test_apple_asr_policy.sh`.

Expected: compilation fails because `AppleTranscriptionEngine` and `AppleTranscriptionEnginePolicy` do not exist yet.

- [ ] **Step 3: Implement the tested policy and revise the approved design**

Implement the selection and async retry policy in `TranscriptionConfiguration.swift`. Revise the design to remove simulator-only selection, specify Speech-first behavior, resource readiness for both applicable engines, cancellation/invalid-input exclusions, and actual-engine labeling.

- [ ] **Step 4: Re-run the policy test and register it in the local suite**

Run `sh scripts/test_apple_asr_policy.sh`, then run `sh scripts/test_local.sh`.

Expected: `Apple ASR policy: Speech priority, Dictation fallback and cancellation handling passed`; existing local smoke tests also exit 0.

### Task 2: Integrate both engines and language resources

**Files:**
- Modify: `apps/wrist-notes/Sources/iPhone/OnDeviceTranscriber.swift`
- Modify: `apps/wrist-notes/Sources/iPhone/AppleSpeechResources.swift`
- Modify: `apps/wrist-notes/Sources/iPhone/AppleSpeechReservationCoordinator.swift`
- Modify: `apps/wrist-notes/Sources/iPhone/TranscriptionConfiguration.swift`
- Modify: `apps/wrist-notes/Sources/iPhone/TranscriptionSettingsView.swift`

**Interfaces:**
- `OnDeviceTranscriber.transcribeWithSegments(fileURL:locale:) async throws -> TranscriptionOutput` checks the Speech capability first and invokes Dictation when Speech cannot run or a retryable Speech failure occurs.
- `AppleSpeechResources.languages() async -> [SpeechLanguage]` returns the de-duplicated union of Speech and Dictation locales.
- `AppleSpeechResources.status(locale:) async -> SpeechResourceState` reports ready only when every supported primary/fallback module is installed; a module reported unsupported is not required.
- `AppleSpeechResources.download(locale:progress:) async throws` installs supported Speech and Dictation resources sequentially and reports monotonic aggregate progress.

- [ ] **Step 1: Add a failing assertion for the preferred/fallback label**

In `AppleASREnginePolicySmoke.swift`, assert `TranscriptionConfiguration(engine: .apple).label` includes both `SpeechTranscriber` and `DictationTranscriber`, while a Whisper label still contains its configured model size.

- [ ] **Step 2: Run `sh scripts/test_apple_asr_policy.sh` and confirm only the new label assertion fails**

Expected: policy selection and retry assertions pass, but Apple label expectation fails because the current label is generic.

- [ ] **Step 3: Implement the two SpeechAnalyzer runners and resource adapter**

Use `SpeechTranscriber.isAvailable` and `SpeechTranscriber.supportedLocale(equivalentTo:)` to resolve the preferred module. Resolve the fallback with `DictationTranscriber.supportedLocale(equivalentTo:)`; use `.timeIndexedLongDictation` and the existing timed-segment builder. Treat `CancellationError`, active task cancellation, and `BoundedAudioError.invalidWindow` as non-retryable. For a retryable Speech error, run Dictation if its locale is supported. List and install system assets through `AssetInventory`; keep locale reservation serialized through the existing coordinator. Update Settings copy to explain “Speech priority; Dictation fallback” and that both applicable offline resources are managed by iOS.

- [ ] **Step 4: Run the policy and reservation tests, then build the iOS Simulator target**

Run `sh scripts/test_apple_asr_policy.sh`, `sh apps/wrist-notes/scripts/test_local.sh`, and `xcodebuild -project apps/wrist-notes/WristNotes.xcodeproj -scheme WristNotes -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build`.

Expected: smoke tests and simulator build exit 0.

### Task 3: Persist and show the engine that produced each transcript

**Files:**
- Modify: `apps/wrist-notes/Sources/Shared/VoiceNote.swift`
- Modify: `apps/wrist-notes/Sources/iPhone/AudioProcessing.swift`
- Modify: `apps/wrist-notes/Sources/iPhone/AudioProcessingCoordinator.swift`
- Modify: `apps/wrist-notes/Sources/iPhone/LocalTranscriptionService.swift`
- Modify: `apps/wrist-notes/Sources/iPhone/AudioProcessingRepository.swift`
- Modify: `apps/wrist-notes/Sources/iPhone/DaybookVoiceDetailView.swift`
- Modify: `apps/wrist-notes/Tests/AudioProcessingSmoke.swift`
- Modify: `apps/wrist-notes/scripts/test_audio_processing.sh`

**Interfaces:**
- `TranscriptionOutput.engineName: String?` carries the actual engine name.
- `VoiceNote.transcriptionEngineName: String?` is optional so existing saved notes decode without migration.
- `AudioWindowResult.asrEngineName: String?` is optional and stored in the existing JSON result payload.
- `AudioProcessingStatus.asrEngineNames: [String]` contains the stable, de-duplicated names used by successful ASR windows.

- [ ] **Step 1: Add failing round-trip and legacy-decoding assertions**

In `AudioProcessingSmoke.swift`, encode/decode a `VoiceNote` with `transcriptionEngineName`, and encode/decode `AudioWindowResult` with `asrEngineName`. Remove the optional engine key from each encoded JSON object and assert the legacy form still decodes.

- [ ] **Step 2: Run `sh scripts/test_audio_processing.sh` and confirm the new provenance assertions fail**

Expected: compilation fails because the provenance fields are not defined.

- [ ] **Step 3: Propagate provenance through direct and durable processing**

Set the engine name returned by the Apple policy on `TranscriptionOutput`; set a Whisper model name on Whisper output. `VoiceNote.applyTranscription` stores it. The durable worker records the engine per ASR window; repository retries that retain a successful ASR stage also retain its engine. `AudioProcessingCoordinator.status` aggregates successful names and the raw-recording detail view displays them instead of presenting the configured engine as the one that actually ran.

- [ ] **Step 4: Run the focused round-trip test and the full local smoke suite**

Run `sh scripts/test_audio_processing.sh` and `sh apps/wrist-notes/scripts/test_local.sh`.

Expected: the engine provenance and legacy decode tests pass; both commands exit 0.

### Task 4: Verify Simulator and device compilation paths

**Files:**
- Verify: `apps/wrist-notes/WristNotes.xcodeproj` iOS app target
- Reuse only if present: `/private/tmp/wiselife-fleurs-benchmark/samples/zh_full/5836857491995956152.wav`

- [ ] **Step 1: Confirm the isolated iPhone 17 Pro Simulator is available**

Run: `xcrun simctl list devices available`.

Expected: UDID `D9857EEA-8E8C-4788-BBC0-4EB3B10EE506` appears; do not modify the Watch transfer Simulator.

- [ ] **Step 2: Build the app for generic Simulator and device destinations**

Run:

```sh
xcodebuild -project apps/wrist-notes/WristNotes.xcodeproj -scheme WristNotes -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build
xcodebuild -project apps/wrist-notes/WristNotes.xcodeproj -scheme WristNotes -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build
```

Expected: both builds exit 0 with the same Speech-first policy. The earlier direct iOS 26.3.1 Simulator FLEURS probe is baseline evidence for Dictation; do not claim the current app repeated that audio run unless a fresh app execution on the fixture is completed.
