# WiseLife 自动 ASR、内容分段与检索 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 将已经接收的录音和旧长文件以有界窗口自动转写、可靠分段，持久保存进度，并在时间轴、回听、检索和 AI 中使用片段。

**Architecture:** 原始录音与派生内容分离。SQLite 保存逐窗口任务、带时间戳文字、VAD 覆盖、片段范围和可撤销编辑；应用生命周期内一个调度器使用与旧转写/声纹登记共享的串行推理服务。复用现有 Pyannote 本地模型的逐帧人声检测结果，成功的空 ASR 不自动等于无人声。

**Tech Stack:** Swift/SwiftUI, SQLite/FTS5/现有 SQLite Vector, AVAudioFile, SpeechAnalyzer/SpeechTranscriber, Core ML Pyannote VAD, WhisperKit/SpeakerKit, Apple Foundation Models.

## Global Constraints

- 当前工程最低版本保持 iOS 26.0、watchOS 10.0；真机验收使用用户的 iPhone 16 Pro 和 Apple Watch SE。
- 默认使用本地存储和端上模型；模型不可用时给出状态，不自动启用云端服务。既有用户配置的云模型仍遵循原有明确选择和发送确认机制。
- 用户已有录音、文字、手动标题、说话人标注和数据保护策略保留；原音频不因自动分段而重写或删除。
- 5 分钟物理文件、模型输入窗口、时间轴内容片段分别定义。一个内容片段可跨文件，一份文件可被多个内容片段引用。
- 输入窗口上限初始为 300 秒，边缘额外读取最多两秒上下文；遇到资源不足缩小窗口并降低并发。ASR/说话人模型重任务同一时刻仅一个，采样缓冲用完释放。
- 旧的多小时文件通过 AVAudioFile 按范围读取，也进入同一流水线。禁止先把原文件完整解码，再切数组。
- 跨窗口文本以源时间戳和范围归属去重；重复口头表达不能仅凭相同文字被删除。所有时间戳映射回原音频范围。
- 任务完成和结果在同一 SQLite 事务中保存。退出后重跑未提交窗口，保留已提交窗口；模型/语言变更产生新版本，不覆盖人工修改。
- 必须拥有连续、成功分析的音频覆盖，且 VAD 确认无人声；区间可以有环境音或音乐。ASR 空结果本身不证明无人声。有 ASR 文本但 VAD 判无人声时标记冲突并复核，不能直接作为高置信边界。
- 按会话时间轴跨文件累计，连续无人声达到 600 秒形成边界；前后语音各保留最多两秒前导/尾音，并裁到合法可用范围。缺失文件、中断和处理失败不计入无人声。
- 自动合并限定同一次录音会话。用户确认过的内容边界保留。
- 说话人编号仅在单窗口内有意义；通过会话级声纹/特征匹配建立跨窗口映射，不直接把不同窗口的 speaker-1 当作同一个人。合并证据不足时保留未知。
- 一个文件可以被多个内容片段引用。删除内容片段仅改变派生记录；删除整次原始录音是独立显式动作，采用 tombstone + 文件清理重试，并清除关联全文、向量与 AI 缓存。
- 内容片段跨午夜时按每个本地日期的交叠区间投影到各日，保持同一 segmentID，日期内显示该日范围及续段标记；完整详情仍可回听全部片段。
- FTS 用于准确文本检索，SQLite Vector 用于语义候选召回；向量相似度不是确定内容合并的唯一依据。
- 保留 Watch 连续采集验证开关和旧长文件超过 30 分钟的说话人保护。只有真实设备的有界说话人内存验证通过后才开放长录音说话人识别。本轮不安装/重启 Watch，不启动麦克风，不下载模型，不读取私人录音全文到报告。
- 仅修改本计划拥有的文件；在已存在的隔离工作树开发。起点 9b7c522 为本地工作快照，不能推送其祖先或整体合并；最后以本起点后的任务差异安全同步回原目录。

## File structure and decisions

- `AudioProcessing.swift`: Foundation-only source/window/job/span/activity/progress values, validation and stable IDs.
- `AudioWindowPlanner.swift`: frame-exact bounded plans and timestamp ownership, no media decoding.
- `AudioProcessingRepository.swift`: SQLite source versions, job leases/results, cancellation/retry and tombstones. Schema added transactionally via `DaybookDatabase`.
- `BoundedAudioReader.swift`: streaming source ranges to a protected temporary PCM file (4096-frame reads) and optional bounded Float samples; no original mutations.
- `OnDeviceSpeechActivity.swift`: direct Core ML adapter for the existing installed Pyannote segmenter; validate every output and coverage. Holes/errors remain uncertain. SpeechDetector is not standalone and its documented public results currently support error handling only.
- `LocalTranscriptionService.swift`: same process-wide gate for legacy ASR, bounded ASR/VAD, speaker models and voice enrollment; offline adapters.
- `AudioProcessingCoordinator.swift`: durable serial pump with source discovery, foreground/unlock/resource/config wakeups, cancellation and stale guards.
- `AudioProcessingModel.swift`: observable UI state, worker-confined repositories, source adapters and processing actions.
- `ContentSegmentation.swift`: deterministic 600-second and hard-gap policy, timestamp clipping, conservative semantic decisions and manual boundary rules.
- `ContentSegmentRepository.swift`: ordered ranges, revisions, tombstones and edit history with split/merge/undo transactions.
- `ContentEnrichmentService.swift`: bounded local topic proposals and hierarchical summaries, revision-scoped commits.
- `ContentSegmentModel.swift` and `ContentSegmentDetailView.swift`: paged content/transcript, summary/text tabs, frame-range playback and manual actions.
- Existing runtime, NotesModel, session detail, DayRecord/Daybook and retrieval/index entry points receive narrow integration changes. Do not build a second vector index or duplicate retrieval service.
- `Tests/Audio*Smoke.swift`, `Tests/Content*Smoke.swift`, and focused scripts hold executable fixtures; generated synthetic audio goes only under temporary directories.

## Shared interfaces

Values are `Sendable`, and persisted values `Codable` where appropriate. Task 1 defines exact memberwise initializers in its report for subsequent tasks; these named operations are the cross-task contract:

```swift
enum AudioSourceKind: String, Codable, Sendable { case session, legacyNote }
struct AudioSourceID: Hashable, Codable, Sendable { let kind: AudioSourceKind; let id: UUID }
// AudioSourceSnapshot: source ID, capturedAt, title, origin/location, complete,
// immutable source ranges and source fingerprint. A range wraps RecordingSourceRange
// plus its content hash; legacy uses the original note ID and original file URL.
// AudioProcessingWindow: stable ID, source ID, configuration version, core start/end,
// available <=2s context and ordered range slices. Input <=304s, core <=300s.
// AudioWindowResult: source-time transcript spans, explicit activity intervals,
// separate ASR/VAD/speaker outcomes, optional evidence-backed speaker features.
enum AudioJobState: String, Codable, Sendable {
    case pending, running, completed, missingResource, cancelled, failed
}
enum AudioActivityKind: String, Codable, Sendable { case speech, noSpeech, uncertain }

enum AudioWindowPlanner {
    static func plan(source: AudioSourceSnapshot, configurationKey: String) throws -> [AudioProcessingWindow]
}
// Repository synchronous, serial worker/actor owned; never await in a SQL transaction.
// register(source:configurationKey:windows:), claimNext(), commit(job:result:),
// fail(job:state:message:), retry(sourceID:), cancel(sourceID:), delete(sourceID:),
// recoverInterrupted(), progress(sourceID:), spans(sourceID:limit:offset:),
// activities(sourceID:), currentSource(_:) are implemented in Task 1.
```

## Verification strategy

Use focused scripts after each change. Task 2 verifies real SDK compilation, Task 3 verifies runtime integration, and Task 6 runs the full local suite and a generic iOS workspace build once. Reviewers use the recorded outputs and only run a test to resolve a concrete unanswered doubt. Synthetic 6.5-hour audio validates the range-reader memory contract; it does not prove model quality or actual-device ASR memory. Record these separately in the verification report.

### Task 1: Durable window processing storage and planning

**Files:** Create `Sources/iPhone/AudioProcessing.swift`, `AudioWindowPlanner.swift`, `AudioProcessingRepository.swift`, `Tests/AudioProcessingSmoke.swift`, `scripts/test_audio_processing.sh`. Modify `DaybookDatabase.swift`, `scripts/test_local.sh`, `scripts/generate_project.rb`, `WristNotes.xcodeproj/project.pbxproj`, schema-version expectations in existing SQLite tests if needed.

**Interfaces:** Produces the Shared interfaces above. Consume `DaybookDatabase`, `RecordingSourceRange`/effective half-open frames. Store source descriptors separately from result rows; job keys include source identity, input hashes/ranges, config/algorithm version. Configuration changes keep old results separate; new append-only chunks reuse unchanged committed jobs. A stale job lease or removed source cannot commit. UI source revision advances on material result changes.

- [ ] **Step 1: RED: write a real SQLite/reopen fixture and pure planner tests.** Required assertions:

```swift
// Each fixture is generated in a temporary root; no model mocks are called here.
precondition(windows.allSatisfy { $0.coreEnd - $0.coreStart <= 300 })
precondition(windows.allSatisfy { $0.inputDuration <= 304 })
// Core timestamps own each word exactly once; equal words at different times survive.
// First committed window survives database reopen; running lease recovers pending.
// Interrupted commit rolls back BOTH span insertion and the completed status.
// Replaying completion is idempotent; stale lease/config/tombstone rejects late result.
// ASR empty success, VAD missing resource, failed and cancelled are distinct.
```

Run `sh apps/wrist-notes/scripts/test_audio_processing.sh`; record expected missing-type failure.

- [ ] **Step 2: implement additive schema and validated value types.** Add `audio_processing_sources`, `audio_processing_jobs`, `audio_transcript_spans`, `audio_activity_intervals`, source tombstones and speaker mappings if needed. Store individual spans, not a single ever-growing JSON payload. Index source/version/time and queue state. Foreign keys or delete guards must prevent parent/session/legacy deletion resurrection. Include explicit ASR/VAD successful coverage and input hashes; do not store private transcript in error messages.
- [ ] **Step 3: implement plans and ownership.** Frames define exact input. Discontinuities break windows; file boundaries alone do not. For a receiving session hold an unstable final core until enough following context or an end marker is available. Use the word/span midpoint in the half-open core to assign ownership; clip to available source ranges. Never deduplicate by text alone. Repeated raw ranges or invalid/nonfinite frames/time fail before enqueue.
- [ ] **Step 4: GREEN: verify SQLite rollback/reopen, append reuse, 6.5-hour plan, gaps, cancellation and change-version tests.** Run focused script, affected existing schema smoke and source membership; inspect actual exit codes.
- [ ] **Step 5: commit only task files and report public initializers/method signatures.** `git diff --check` must pass. Use per-process git author/committer copied from HEAD, never global config.

### Task 2: Bounded local inference, real VAD and speaker mapping

**Files:** Create `BoundedAudioReader.swift`, `OnDeviceSpeechActivity.swift`, `AudioSpeakerMapping.swift`, `Tests/BoundedAudioReaderSmoke.swift`, `Tests/AudioActivitySmoke.swift`, `scripts/test_bounded_audio.sh`. Modify `LocalTranscriptionService.swift`, `OnDeviceTranscriber.swift`, `NotesModel.swift` and `MyVoiceProfileModel.swift` (shared service injection only), project membership.

**Interfaces:** Consumes Task 1 windows/results. Produces `LocalTranscriptionService.shared` and `process(window:configuration:) async throws -> AudioWindowResult`. Existing service APIs remain usable. Bounded reader `materialize(_ window: AudioProcessingWindow) throws` returns a temporary-file owner with source-time mapping and deterministic cleanup. Native calls must occur inside the same FIFO/gate as enrollment/legacy jobs.

- [ ] **Step 1: RED: create synthetic files and test bounded reading and activity reconciliation.** 6.5-hour source header, read first/middle/last windows, max 4096 source-frame buffer, <=304s materialized input, sample markers on cross-file boundaries. Explicit detector coverage only, failed/missing interval breaks noSpeech; overlapping transcript forces uncertain. Verify equal words at different source timestamps remain.
- [ ] **Step 2: stream requested ranges through AVAudioFile/AVAudioConverter into protected temporary PCM.** Seek to effective frames, enforce exact end and progress, cancel between buffers, cleanup success/error/cancel. Reject short reads/missing source instead of synthesizing silence. Whisper may load the bounded temporary file or bounded samples only. Never pass an original long audio path into `engine.transcribe(audioPath:)`.
- [ ] **Step 3: add real local frame VAD using the installed Pyannote segmenter.** Load `SpeakerModelStore.modelPaths[0]` through Core ML, validate input/output schema, predict sequential <=30-second PCM blocks, and map `speaker_ids` masks from overlapping sliding windows to source frames. Any speech mask wins; noSpeech requires all covering successful masks to be inactive; invalid/missing/nonfinite/ambiguous outputs are uncertain or a failed VAD stage. Derive timing from validated `sliding_window_waveform`/`speaker_ids` shapes and 16 kHz, not guessed fixed frame rates. Do not use a successful empty SpeakerKit diarization as proof: its upstream segmentation/embedding code catches model failures internally. No energy-only or ASR-only silence heuristic. Use existing settings downloads, never download during inference. ASR and VAD failures are independent. Refer to the native-vad-evidence.md in the task ledger for primary API/source findings.
- [ ] **Step 4: share the memory gate and bound legacy calls.** Route production NotesModel and new worker through one service. Legacy long ASR must loop bounded windows if invoked through existing APIs, while Task 3 adds durable app routing. Preserve short-note behavior. Ensure cancellation while waiting and after model calls releases gate; unload all local models. Do not nest gate acquisitions.
- [ ] **Step 5: implement feature-backed speaker mapping without opening the long-speaker gate.** Reuse installed speaker and voice embedding models; clean windows yield normalized features. Compare compatible feature dimensions/model versions with conservative threshold and runner-up margin; uncertain becomes unknown, local speaker IDs alone never merge. Persist mapping evidence through Task 1 contract. The >30-minute source guard remains unless separate physical evidence approves it. Missing models do not block ASR or trigger download.
- [ ] **Step 6: GREEN and commit.** Run focused reader/activity/mapping tests and generic iOS workspace compile (log under `/private/tmp/wiselife-asr-development`). Record synthetic memory high-water independently from real model/device memory. No physical mic, model download or Watch installation.

### Task 3: Automatic resumable processing lifecycle

**Files:** Create `AudioProcessingCoordinator.swift`, `AudioProcessingModel.swift`, `Tests/AudioProcessingCoordinatorSmoke.swift`, `scripts/test_audio_processing_coordinator.sh`. Modify `NotesModel.swift`, `WiseLifeRuntime.swift`, `RecordingSessionModel.swift`, `NoteRepository.swift`, `RecordingSessionRepository.swift`, `TranscriptionSettingsModel.swift`/`AppSettings.swift` only for change notifications and deletion integration, project membership.

**Interfaces:** Consumes Task 1 repository and Task 2 shared service. Produces app-lifetime `AudioProcessingModel`, observable progress/revision, `refresh()`, `retry(_ sourceID:)`, `cancel(_ sourceID:)`, `delete(_ sourceID:)`, and a revisioned completion notification for derived-content work. `WiseLifeRuntime` owns it. Source discovery runs on worker, not UI/main or WCSession callbacks.

- [ ] **Step 1: RED: drive coordinator with real temporary SQLite and an injected bounded inference closure.** First window commits, second is interrupted, reconstruct coordinator, verify only second runs. Simultaneous receive/foreground/resource wakeups run one pump. Verify explicit cancel persists across wakeups, missing resource is retried on explicit retry/resource availability, config change rejects old result, source delete during inference does not recreate data.
- [ ] **Step 2: adapt saved V2 sessions and legacy recordings.** Use session repository source ranges; legacy preserves file URL, note ID, manual title/transcript/speaker metadata. For new/pending long notes route to durable window jobs; previously completed legacy transcripts are not overwritten or automatically reprocessed. Explicit reprocessing derives a new version; preserve manual original. File hash computed streaming and cached against validated immutable source metadata on worker.
- [ ] **Step 3: implement serial pump and lifecycle.** Register jobs before inference, claim one, process, transactional commit then notify. Handle shutdown/lock/resource failures with stable UI state; do not busy-loop failed jobs. Wake on startup, receive commit, foreground, protected-data availability and resource/config changes. Pause/cancel appropriately while foreground audio capture is active, release resources on cancellation. Provide explicit reprocess and retry actions.
- [ ] **Step 4: preserve old note UX and deletion safety.** New source status participates in note detail, source transcript/summary stays compatible where safe; manual legacy content wins. Parent deletion atomically tombstones derived source before late work can commit and removes derived indexes through current invalidation path. No queue callback should open missing root and resurrect deleted audio.
- [ ] **Step 5: GREEN and commit.** Run focused coordinator and affected existing NotesModel/recovery tests, compile generic iOS workspace for runtime lifecycle. Report which paths are native compile verified versus synthetic scheduler verified.

### Task 4: Reliable content segments and reversible edits

**Files:** Create `ContentSegmentation.swift`, `ContentSegmentRepository.swift`, `Tests/ContentSegmentationSmoke.swift`, `scripts/test_content_segments.sh`. Modify `DaybookDatabase.swift`, `AudioProcessingModel.swift` completion hook, project membership.

**Interfaces:** Consumes current-source windows/spans/activity/success coverage from Task 1. Produces `ContentSegment` (stable UUID, AudioSourceID, source revision, ordered ranges, title, summary, revision, manual/final flags, derived provenance), `ContentSegmentRepository` and `ContentSegmentation.build(...)`. Repository operations: `reconcile`, `segments(sourceID:limit:offset:)`, `segment(id:)`, `spans(segmentID:limit:offset:)`, `split(id:at:expectedRevision:)`, `merge(ids:expectedRevisions:)`, `delete(id:expectedRevision:)`, `undo(sourceID:)`, `applyEnrichment(id:expectedRevision:sourceRevision:title:summary:)`.

- [ ] **Step 1: RED: real persistent fixtures plus pure interval rules.** Check 599/600/601 seconds, across physical files, speech crossing 300s, ambient-only detector noSpeech, ASR/VAD disagreement, failed middle window, missing chunk, interruption, midnight and same text repeated. For confirmed 600s gap, speech clips keep <=2s valid padding and no fabricated ranges.
- [ ] **Step 2: create schema with segment-range relations and edit history.** Add `content_segments`, `content_segment_ranges`, `content_segment_edits`, derived suppression/tombstones and revision guards. SQL transactions apply split/merge/delete/undo as one mutation. Keep original audio untouched. All deleted derived IDs remain tombstoned to reject late summaries.
- [ ] **Step 3: reconcile deterministic content.** Merge continuous speech across file boundaries; split on confirmed noSpeech>=600 or actual audio gap. Unanalysed/failed coverage stays pending/uncertain, not silence. Do not finalize beyond current successful coverage; append processing updates automatic draft tail, preserving manual boundaries/edits and stable IDs for unchanged ranges. A source all-noSpeech has an explicit processed/no-speech state and retains complete-recording access.
- [ ] **Step 4: implement manual split/merge/undo.** Split at legal source position with nonempty ranges each side; adjacent same-source merge requires explicit user action and retains visible gaps. Automatic flow never crosses hard gaps; manual flow cannot merge different sources. Undo refuses to overwrite intervening revisions. Reprocess creates an auditable derived version and never silently unfreezes manual boundaries.
- [ ] **Step 5: GREEN and commit.** Exercise persistence reopen, stale summary/result after deletion, undo conflicts, partial processing and reconciliation after append. Run focused script and affected SQLite smoke, record stable-ID evidence.

### Task 5: Bounded local content summaries and topic continuity

**Files:** Create `ContentEnrichmentService.swift`, `Tests/ContentEnrichmentSmoke.swift`, `scripts/test_content_enrichment.sh`. Modify `ContentSegmentation.swift`, `ContentSegmentRepository.swift`, `AudioProcessingModel.swift`, `OnDeviceSummarizer.swift` if reusable bounded helpers are needed, project membership.

**Interfaces:** Consumes versioned content segments and paged transcript. Produces enrichment with expected segment/source revisions and local topic suggestions. Inputs at a candidate boundary include <=650 chars on each side and <=220 chars prior summary. Same-topic decision can merge eligible automatic adjacent drafts only; clear change can split at a transcript timestamp. Missing model or uncertain decision leaves deterministic result intact.

- [ ] **Step 1: RED: exercise the real orchestration with injected local text model.** Assert bounded prompts, hard-gap/session/manual exclusions, same-topic crossing file boundary, clear topic change after short pause, 600-second gap with same-topic text remains split, stale replies after manual edit/config/source change are discarded.
- [ ] **Step 2: add local Foundation Models adapter.** Check availability and locale, bounded typed/validated decision (`sameTopic`, `newTopic`, `uncertain`) and only known candidate timestamps. Treat text as content, not instructions. Never invent source ranges from model output. Use a fresh session/limited response tokens. Model unavailable is visible, no remote fallback.
- [ ] **Step 3: implement paged hierarchical summary.** Read bounded transcript pages, summarize <=650-character chunks into <=220-character partials, recursively reduce with explicit progress/bounds to guarantee termination. Persist checkpoints/version to avoid redoing completed summaries after restart, and reject stale results transactionally. Title is bounded and does not replace manual titles. Existing user-selected remote AI remains behind its existing explicit confirmation; automatic new enrichment is local-only.
- [ ] **Step 4: GREEN and commit.** Run focused orchestration tests including source text containing fake instructions, empty model reply, unavailable model, revision conflict and restart; compile native adapter if not covered by later build. Report actual local-model execution separately.

### Task 6: Segment UI, timeline, search and AI provenance

**Files:** Create `ContentSegmentModel.swift`, `ContentSegmentDetailView.swift`, `Tests/ContentSegmentPresentationSmoke.swift`, `scripts/test_content_segment_presentation.sh`. Modify `WiseLifeRuntime.swift`, `WristNotesApp.swift`, `DayRecord.swift`, `DaybookView.swift`, `DaybookCalendarView.swift`, `RecordingSessionDetailView.swift`, `DaybookVoiceDetailView.swift`/`NoteDetailView.swift`, `DaybookRetrieval.swift`, `DaybookConversationStore.swift`, existing semantic/FTS entry points, `Localizable.xcstrings`, project membership and `verification/segmented-asr-content.md`.

**Interfaces:** Runtime owns content model. Content projection uses segment ID, source ID, exact available DateIntervals and source audio ranges; `DayRecord` gains optional derived fields preserving old Codable archives. `recordingProjection` preserves fields. UI route resolves segment before full session/legacy note. FTS/vector consume the existing DayRecord path; AI citations retain optional segment/range provenance.

- [ ] **Step 1: RED: pure presentation and retrieval fixtures.** Midnight segment projects to two dates with same ID and correct daily audio totals. Parent+children input counts only child evidence. Deleted/stale segment invalidates stored evidence. Search hits and conversation citations route to the segment with correct audio ranges, not a fabricated URL.
- [ ] **Step 2: add observable paged list/detail.** Summary/全文 tabs below audio, paged transcript, processing progress/missing resources/failure/retry/cancel and manual split/merge/undo. Source lists use stable IDs. Provide “查看完整录音”; clearly separate “删除片段” and “删除完整录音”. Use `RecordingRangePlayback` with segment ranges, and stop playback when recording begins. Never join missing audio with synthetic silence.
- [ ] **Step 3: project segments into home/calendar/library.** Replace processed parent rows with derived segments while retaining parent fallback when not processed/none are available. Do not count parent twice. Preserve complete recording access for all-noSpeech or manually hidden segments. Existing settings/download flow remains the entry for missing ASR resources.
- [ ] **Step 4: wire exact/semantic retrieval and provenance.** Reuse SQLite FTS and Vector indexes with source/segment revisions; avoid simultaneous parent+child AI evidence. Update invalidation for resegment/edit/delete/undo. Keep AI privacy preferences, source freshness and remote consent checks unchanged. Range metadata is evidence provenance, not a claim of person/location.
- [ ] **Step 5: GREEN final software validation.** Run all new scripts, full `test_local.sh`, project source-membership and one generic iOS workspace build. Confirm no whole-long-file ASR decode call is reachable, no model auto-download, no Watch switch alteration. Record remaining physical 6.5h/model memory/VAD accuracy gates distinctly. Safely three-way sync only changes since 9b7c522 into original; build/test handed-off code and preserve concurrent edits/index.
- [ ] **Step 6: commit code and verification report; request whole-change review through SDD.** After scoped fix wave, hand off source with exact tested revision and clear limitations. Do not push local snapshot lineage or install Watch as part of this plan.
