# Native transcription models and downloads

> Use subagent-driven-development for the independent AI protocol task and review; implement the connected resource/UI pipeline together.

**Goal:** Implement the approved HTML settings prototype and real local speech resources on iPhone.

**Architecture:** Persist a transcription configuration separately from resource availability. A MainActor settings editor owns a cancellable operation and generation token. Apple resources use SpeechTranscriber/AssetInventory; Whisper uses pinned WhisperKit and locally installed Core ML models/tokenizer. Route actual note transcription through the saved configuration. Audio never goes to a transcription server.

## Constraints

- Scope `apps/wrist-notes`; preserve Watch transfer/recording implementations and signing settings.
- iOS 26+, watchOS 10+. Keep dependencies on the iPhone target only.
- Exact title: `iPhone端上转写`; description: `iPhone系统语音模型，无需API Key，支持单语言转写，按需下载系统语言包`.
- Both models use language picker → resource status → explicit download/retry → save. Apple languages are queried on device; unsupported devices show a real unavailable state. Whisper supports Tiny/Base/Small multilingual models and auto language detection; no per-language downloads.
- Downloads must use real byte/progress information, support cancellation, preserve completed files, reject stale callbacks, never mark incomplete models ready, and persist across relaunch. No fake success, network fallback or secrets in files.
- Save only a supported configuration with installed resources. Model/language changes cannot alter an in-flight transcription. Returning discards drafts.
- Latest AI prototype includes `API 接口兼容`: OpenAI Chat Completions and Anthropic Messages. Preserve existing OpenAI settings, Keychain and test-before-save behavior.
- Verify with local smoke tests, generic iOS/watchOS build, isolated simulator UI where available, and a real Whisper Tiny download/load/transcription test. Report physical-device Apple asset limitations explicitly.

## Tasks

- [x] 1. AI protocol adapter: extend AIConfiguration with backwards-compatible `apiProtocol`, protocol-specific endpoint, label, headers/request/response; add real request-contract tests using URLProtocol, no real credentials. Files: AIConfiguration.swift, CustomAISummarizer.swift, Tests/AISettingsSmoke.swift. Parent owns SettingsViews.swift and AppSettings.swift. Test older JSON decoding, protocol invalidation, Anthropic text blocks and incomplete/error responses, OpenAI regression.
- [x] 2. Transcription configuration and resource coordinator: new TranscriptionConfiguration.swift, TranscriptionSettingsModel.swift, AppleSpeechResources.swift, WhisperModelStore.swift. Save drafts atomically in AppSettings; migrate old transcriptionLocale. Inject backend closures for deterministic tests of readiness, save gates, cancellation, stale completion and language/model changes. Download model/tokenizer files into staging with manifests and size checks, promote only after completion, exclude models from backup.
- [x] 3. Native settings and transcription routing: TranscriptionSettingsView with identical picker/resource flow, real progress/cancel/retry and scene refresh; add AI protocol picker. Connect NotesModel to a reusable serialized LocalTranscriptionService so concurrent imports do not load multiple Whisper engines. Keep successful prior transcripts on failure.
- [x] 4. Dependency/project integration and real verification: pin WhisperKit version, update generator incrementally without rewriting existing signing settings, test source membership and scripts, generic build/Watch embedding. Download and run Tiny on a generated sample, reload offline from installed assets; record exact limits and evidence in verification/model-downloads.md. Sync completed scoped changes back to the original workspace after review.

## Progress

- Approved design is the existing prototype and the user's implementation request; no additional product decisions are pending.
- Baseline local suite passed before this iteration; work isolated from unrelated dirty Vessel files.

- 2026-10-19: native settings, Apple reservations/downloads, Whisper cache/downloads/local inference, protocol adapters and project integration complete.
- Verification passed: local suite; generic simulator and unsigned device builds (including Watch); embedded Watch check; real Tiny download/hash/load; explicit/auto inference in a network-denied fresh process; native screenshots. See verification/model-downloads.md.
- Review: initial Apple reservation ownership/capacity and Whisper retry-cache findings fixed and re-reviewed; final review has no Critical/Important finding.
- Physical iPhone Apple asset installation and iPhone Whisper performance remain device acceptance checks; no simulated success is claimed.
