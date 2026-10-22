# My Voice Native Implementation Plan

> **For agentic workers:** Use subagent-driven-development for the isolated model component and requesting-code-review for integration. Changes remain uncommitted in this shared, already dirty checkout; preserve other work and the current Ring feature switch.

**Goal:** Implement the approved “我的声音” prototype in the iPhone app, with real 30–60 second enrollment and local identification of the owner's speech after either Apple or Whisper transcription.

**Architecture:** Reuse SpeakerKit turns for clean, non-overlapping speech and a pinned WeSpeaker Core ML model for embeddings. Persist only validated embeddings and metadata in a protected, backup-excluded local profile. Keep manual speaker names separate from automatic owner matches, and reject asynchronous matches if enrollment changes or is deleted.

**Tech Stack:** SwiftUI, AVFAudio, Core ML, existing SpeakerKit/WhisperKit and verified model downloader; no new service or full FluidAudio dependency.

## Global constraints

- Registration is the approved settings entry immediately below transcription settings. It is not a separate model-download entry.
- Download identity weights with existing Apple/Whisper resources. Inference never downloads or uploads audio.
- Real recording lasts 30–60 seconds. Require the user's solo-speech confirmation, sufficient speech, and consistent enrollment embeddings; failed/cancelled replacements preserve the old profile.
- Short, mixed or uncertain voice matches keep generic speaker labels. Multiple diarization clusters may match the owner. No automatic adaptation from inferred matches.
- Manual labels win. Preserve existing notes when profile is deleted. Delete temporary enrollment audio on exit/save/cancellation.
- No native Simulator UI control: prior approval denial persists. Build/XCTest and direct model inference are available; physical microphone and cross-device accuracy require device verification.

## Task 1: Protected profile and embedding component

Create `Sources/iPhone/VoiceIdentity.swift`, `VoiceEmbeddingEngine.swift`, `VoiceIdentityModelStore.swift`, `VoiceIdentityModels.json`, `VoiceIdentityModels-NOTICES.txt`, and focused tests.

Interfaces:
```swift
struct VoiceProfile: Codable, Sendable, Equatable {
    let id: UUID
    let enrolledAt: Date
    let recordingDuration: TimeInterval
    let modelID: String
    let embeddings: [[Float]]
}
struct VoiceProfileStore: Sendable {
    init(root: URL = /* Application Support/WristNotes/PrivateVoiceIdentity */)
    func load() throws -> VoiceProfile?
    func save(_ profile: VoiceProfile) throws
    func delete() throws
}
enum VoiceIdentityPolicy {
    static func makeProfile(embeddings: [[Float]], duration: TimeInterval) throws -> VoiceProfile
    static func matches(embeddings: [[Float]], profile: VoiceProfile) -> Bool
}
actor VoiceEmbeddingEngine {
    init(store: VoiceIdentityModelStore = VoiceIdentityModelStore())
    func extract(samples: [Float]) throws -> [Float] // 16k mono, 2–10 seconds
    func unload()
}
```

- [x] Write and run failing real-storage/policy tests for invalid profiles, replacement, delete, backup exclusion, same/different/uncertain vectors, NaN and wrong dimensions.
- [x] Implement minimum profile validation, conservative matching and atomic persistence. JSON contains no raw audio. iOS uses complete file protection; directory and file excluded from backup.
- [x] Verify current pinned HF model shape and checksum metadata; create complete catalog and licensing notice. Reuse `LocalModelAssetStore` API (`folder`, `downloadBytes`, `validate`, `download`).
- [x] Implement direct Core ML inference with checked shapes, finite samples, model-compatible padding/mask, normalized finite 256-dimensional result and explicit unload.
- [x] Run smoke tests and real downloaded model inference using public or synthetic fixtures. Report calibration limits.

## Task 2: Pipeline integration and stale-result protection

Modify `LocalTranscriptionService`, `NotesModel`, `VoiceNote`, `SpeakerTranscript`, `LiveTranscriptionResources` and resource/build registration.

- [x] Add failing note tests: manual override wins, automatic matching survives coding, edited transcript/deleted or replaced profile rejects stale match results, identity failure preserves diarization and text.
- [x] Reuse serial inference queue. Enrollment segments the recorded audio, rejects substantial overlap, extracts separate clean windows from every substantial cluster and requires sufficient voiced duration plus consistency across all windows. Matching extracts clean windows per original diarization speaker after unloading SpeakerKit.
- [x] Persist automatic owner speaker IDs separately from manual names. Check both transcript revision and current profile UUID immediately before applying automatic IDs.
- [x] Add identity model to shared download readiness/progress without adding a download entry. Upgrade incomplete installed resource sets via the existing action.

## Task 3: Native enrollment flow

Create `MyVoiceProfileModel.swift`, `MyVoiceEnrollmentView.swift`; update `PhoneRecorder`, `DaybookView`, `SettingsViews`, `NotesListView`, localized strings and build registration.

- [x] Add configurable recorder duration limit with default unchanged; enrollment chooses the built-in iPhone microphone, automatic stop at 60 seconds, and cleans drafts on exit. Pending permission callbacks must not start recording after exit.
- [x] Add the settings entry and prepared/recording/review/saving/registered states. Require at least 30 seconds and solo confirmation before saving; show permission/interruption/resource/quality failures with retry.
- [x] Prevent conflict with an existing phone recording/draft; keep prior profile until the replacement is validated and committed. Cancellation or deletion while work is pending must invalidate its generation before persistence.
- [x] Support date/duration, re-enrollment, explicit delete confirmation, privacy copy, theme and localization. No prototype fast-forward controls in native code.

## Task 4: Verify and review

- [x] Register only new task files in the existing project without regenerating unrelated settings.
- [x] Run portable domain tests, focused XCTest integration, full iPhone/Watch simulator build using current Ring configuration, and real offline embedding inference.
- [x] Request scoped independent code review; resolve material findings and rerun relevant tests.
- [x] Save validation evidence, model version/size, matching caveats and remaining physical-device checks in `apps/wrist-notes/verification/my-voice-native.md`.

## Completion record

Implemented and independently reviewed on 2026-10-20. Evidence: `apps/wrist-notes/verification/my-voice-native.md`. Native UI and physical-device accuracy remain explicit acceptance checks. Real synthetic speech revealed sequential diarization over-splitting; fixed by validating all per-cluster windows with unchanged identity thresholds. No commit or push performed.
