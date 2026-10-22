# WiseLife 长录音阶段 A Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking. 在当前会话逐项执行；需要并行时再根据适用授权决定，不默认启动子代理。

**Goal:** 在 Apple Watch 持续采集中每 5 分钟封口一个文件，可靠恢复并逐片同步到 iPhone，以一次录音展示和回听。

**Architecture:** 新增共享会话/分片契约，Watch 使用持续采集和串行分片写入，清单可从独立 sidecar 恢复。iPhone 延续持久 inbox → 文件校验 → SQLite 提交 → ACK，新增会话投影和范围播放，保留旧单文件录音。

**Tech Stack:** Swift、AVFAudio、WatchConnectivity、SQLite、SwiftUI；现有 Xcode workspace 与测试脚本。

## Global Constraints

- 原始文件每 300 秒一个；最后一个文件允许不足 300 秒。
- 当前工程最低版本保持 iOS 26.0、watchOS 10.0；真机验收使用用户的 iPhone 16 Pro 和 Apple Watch SE。
- 音频以单声道、16 kHz、约 32 kbps AAC 保存；采集设备原生采样率在后台写入队列中转换。
- 默认使用本地存储和端上模型；模型不可用时给出状态，不自动启用云端服务。
- 用户已有录音、文字、手动标题、说话人标注和数据保护策略保留；原音频不因自动分段而重写或删除。
- 本计划仅实现设计 A。B/C 的 ASR、VAD、说话人和语义内容整理分别在 A 的数据契约验证后编制执行计划。
- 工作树有大量在途修改。执行前保存任务路径基线；不切换/还原共享工作树，不广泛暂存，不提交用户的设备数据、凭据或诊断音频。
- 设计依据：[长录音设计](../specs/2026-10-22-long-recording-design.md)。方框按已执行证据更新；真机门槛独立保留未完成状态。

---

## 文件职责与接口

所有以下路径均相对 `apps/wrist-notes/`。

| 新增文件 | 职责 |
| --- | --- |
| Sources/Shared/RecordingSession.swift | 会话与分片值类型、状态和帧范围 |
| Sources/Shared/RecordingChunkProtocol.swift | V2 descriptor/ACK/结束 manifest 的 Codable 校验与能力键 |
| Sources/Shared/RecordingFramePartition.swift | 单缓冲跨 300 秒边界的纯帧分配 |
| Sources/Watch/SegmentedAudioCapture.swift | 持续 AVAudioEngine 输入、有界缓冲和串行写入 |
| Sources/Watch/WatchRecordingSessionStore.swift | 清单、sidecar、封口和恢复状态 |
| Sources/Watch/WatchChunkTransferQueue.swift | V2 能力、逐片发送、重复/收据和会话结束消息 |
| Sources/iPhone/RecordingSessionRepository.swift | 会话/分片 SQLite、导入事务、tombstone |
| Sources/iPhone/RecordingChunkReceiver.swift | 持久 inbox 的 V2 验证、流式 hash 和导入重放 |
| Sources/iPhone/RecordingSessionModel.swift | 会话投影及 UI 状态，不执行模型推理 |
| Sources/iPhone/RecordingSessionDetailView.swift | 完整录音、分片状态与缺口详情 |
| Sources/iPhone/RecordingRangePlayback.swift | 有序源范围、跨文件播放、seek 和受限波形 |

最小接口约定（在任务 1 实现值类型与验证；其余方法在对应任务实现）：

```swift
struct RecordingFrameSlice: Equatable {
    let ordinal: Int
    let inputOffset: Int64
    let frameCount: Int64
    let chunkOffset: Int64
}
enum RecordingFramePartition {
    static func split(inputStartFrame: Int64, frameCount: Int64,
                      framesPerChunk: Int64) throws -> [RecordingFrameSlice]
}
struct RecordingChunkDescriptor: Codable, Equatable, Identifiable {
    let id: UUID
    let sessionID: UUID
    let ordinal: Int
    let sessionStartedAt: Date
    let capturedAt: Date
    let timeZoneIdentifier: String
    let sessionStartOffset: Double
    let frameCount: Int64
    let sampleRate: Double
    let byteCount: Int64
    let sha256: String
    let origin: RecordingOrigin
    let location: CaptureLocation?
    func validate() throws
}
struct RecordingChunkReceipt: Codable, Equatable {
    let sessionID: UUID
    let chunkID: UUID
    let ordinal: Int
    let sha256: String
}
struct RecordingSessionEnd: Codable, Equatable {
    let sessionID: UUID
    let finalOrdinal: Int?
    let endedAt: Date
    let interrupted: Bool
    let revision: Int
}
struct RecordingSourceRange: Equatable {
    let chunkID: UUID
    let url: URL
    let startFrame: Int64
    let endFrame: Int64
    let sampleRate: Double
}
```

sessionStartedAt 是会话归属时间，capturedAt 是该文件首个有效帧的现实时间；sessionStartOffset 包含真实中断，不根据 ordinal 推算。所有数值必须有限、有效，帧范围使用半开区间。V2 固定键为 `wiseLifeRecordingChunkV2`、`wiseLifeRecordingReceiptV2`、`wiseLifeRecordingEndV2`，值为 Codable Data；能力键为 `wiseLifeRecordingProtocolVersions`，值含整数 2，绑定当前配对关系。

## Task 1：共享契约与帧边界

**Files:** 新增上述三个 Shared 文件；新增 `Tests/RecordingSessionSmoke.swift` 与 `scripts/test_recording_sessions.sh`；修改 `scripts/generate_project.rb`、`WristNotes.xcodeproj/project.pbxproj` 的精确源文件成员。保留全部既有目标及构建开关。

**Interfaces:** 输入原生转换后帧位置；输出 RecordingFrameSlice。descriptor/receipt/结束消息作为后续存储与传输的唯一值类型契约。

- [x] 创建最小可执行回归脚本，先编译并运行下列边界测试；首次运行必须失败，失败点为缺失分配器或错误帧范围。

```swift
let pieces = try RecordingFramePartition.split(
    inputStartFrame: 4_799_999, frameCount: 3, framesPerChunk: 4_800_000)
precondition(pieces == [
    .init(ordinal: 0, inputOffset: 0, frameCount: 1, chunkOffset: 4_799_999),
    .init(ordinal: 1, inputOffset: 1, frameCount: 2, chunkOffset: 0)
])
let empty = try RecordingFramePartition.split(
    inputStartFrame: 0, frameCount: 0, framesPerChunk: 4_800_000)
precondition(empty.isEmpty)
```

- [x] 用除法/余数分配半开帧范围，校验负数、零容量和加法溢出；不得逐帧遍历。

```text
while remaining > 0:
  ordinal = cursor / framesPerChunk
  room = framesPerChunk - cursor % framesPerChunk
  take = min(room, remaining)
  emit(ordinal, inputOffset, take, cursor % framesPerChunk)
  cursor += take; inputOffset += take; remaining -= take
```

- [x] descriptor 验证 UUID/ordinal、有限时间、正采样率/有效帧/字节数、64 位十六进制 SHA-256；接收路径由内部 ID 构造，不接受发送端路径。
- [x] 加入随机大小缓冲的属性回归：累计输入帧等于输出帧、无重叠/缺口、整 300 秒不创建空尾片、溢出被拒绝。V1 fixture 解码不受影响。
- [x] 运行 `sh apps/wrist-notes/scripts/test_recording_sessions.sh`、`ruby apps/wrist-notes/Tests/ProjectSourceMembershipSmoke.rb`；记录结果并审查任务路径差异。

## Task 2：先验证连续采集，再接入持久分片

**Files:** 新增 `SegmentedAudioCapture.swift`、`WatchRecordingSessionStore.swift`；新增 `Tests/SegmentedAudioCaptureSmoke.swift`、`Tests/WatchRecordingSessionStoreSmoke.swift`；扩展任务 1 脚本。接入修改 `WatchRecorder.swift`、`WatchConnectivityStatus.swift`、`WatchContentView.swift`，同时更新源成员。

**Interfaces:** `SegmentedAudioCapture.start(sessionID: UUID) throws`、`stop() async throws`，封口回调产生 `(RecordingChunkDescriptor, URL)`；`WatchRecordingSessionStore(root: URL)`，`seal(_:file:) throws`、`recover() throws`、`acknowledge(_:) throws`。捕获层与 WCSession 无直接依赖。

- [x] 先写封口恢复回归：合成 AAC 关闭后调用 seal；重复 seal 幂等；破坏总清单后 recover 仍找回已封口文件。每个测试目录用 defer 清理，只用合成音频。

```text
given valid final file + descriptor sidecar, missing session manifest
when recover runs twice
then one chunk exists with unchanged hash and frames
given one invalid manifest among two sessions
then the valid session is still recovered and invalid bytes are retained
```

- [x] 实现串行封口和原子清单写入，恢复独立于 pending.json 成功解码；pending.json 留作 V1 兼容，不能覆盖旧内容。
- [x] 创建开发验证入口，持续 AVAudioEngine tap 使用预分配有界缓冲；单个写入工作队列转换到 16 kHz，调用任务 1 分配器轮换 AAC writer。将 hash/清单写入移出采集回调。
- [x] 用合成编号帧验证输入与所有文件有效帧对应；对 AAC 有损编码采用有效帧数量、时间定位和边界标记验证，不比较 PCM 数值逐字节相同。编码器填充不累计为会话时间。
- [ ] 在 SE 上先运行超过 15 分钟的跨三个边界实验，包含后台和锁屏；记录实际边界缺口、峰值内存、耗电和音频格式。不通过时保留现有录音路径，修复采集实现后重测，不降级为未说明的 stop/start 切片。
- [x] 接入长录音开始/停止，保持闪念原行为。录音 UI 显示实际已采样时长；轮换不得触发一次新的“开始/结束”触感。
- [x] 强制写入失败、缓冲满、停止/轮换竞争、路由变化、partial 损坏测试通过；不可恢复文件保留，异常状态可见。

## Task 3：iPhone 会话数据库与文件导入

**Files:** 新增 `RecordingSessionRepository.swift`；修改 `DaybookDatabase.swift`；新增 `Tests/RecordingSessionRepositorySmoke.swift`；扩展同一测试脚本。

**Interfaces:** `RecordingSessionRepository(root: URL, database: DaybookDatabase)`；`importChunk(_:from:pairingID:) throws -> RecordingChunkReceipt`；`applyEnd(_:) throws`；`sourceRanges(sessionID:) throws -> [RecordingSourceRange]`；`deleteSession(_:) throws`。V1 NoteRepository 保持原接口。

- [x] 写失败测试：分片 2、0、1 乱序导入只生成一个会话；结束消息先到；最后一个缺失时同步状态不能 ready；重复完全相同来件只有一个分片和收据。

```text
import ordinal 2; applyEnd(finalOrdinal: 2)
assert savedCount == 1 and syncComplete == false
import ordinal 0; import ordinal 1; import ordinal 1 again
assert savedCount == 3 and syncComplete == true
```

- [x] 在最新 schema 版本上增量增加 sessions/chunks/gaps/receipts 及必要 tombstone；使用事务维护 UNIQUE(session_id, ordinal)、chunkID、配对收据和结束修订号。
- [x] 实现文件校验后的持久导入；文件和 SQL 之间每个失败点保留可重试数据；同一身份不同 hash 返回冲突，保留原件，不能覆写后返回成功。
- [x] 失败注入在 SQL commit、文件发布、回收 inbox 三处；重开后记录可读且无重复。测试删除后重传不能复活、同 ID 不同 hash、同 ordinal 不同 ID、越界帧、未知未来协议、结束消息修订倒退。
- [x] 旧笔记采用只读适配或幂等元数据关联，原 ID/路径/全文/人工标记不变；已有多小时原文件无需物理重切。
- [x] 运行新脚本及 `sh apps/wrist-notes/scripts/test_metadata_sqlite.sh`，完成数据库 quick_check 和旧数据迁移测试。

## Task 4：V2 传输与耐久 ACK

**Files:** 新增 `WatchChunkTransferQueue.swift`、`RecordingChunkReceiver.swift`；修改 `WatchRecorder.swift`、`PhoneConnectivity.swift`、`WatchSyncSnapshot.swift`、`WatchSyncStore.swift`；新增 `Tests/RecordingChunkTransferSmoke.swift` 并扩展脚本。

**Interfaces:** Watch queue 消费已封口 descriptor/file 和 receipt；iPhone receiver 用任务 3 导入方法。所有网络行为通过可注入发送/回调接口测试；V1 acknowledge 原函数保留。

- [x] 写事件顺序回归和重启回归。以下伪代码中的事件由注入的文件系统/事务/发送器记录，不从源代码字符串推断：

```text
receive closed chunk -> persist inbox -> validate -> publish file
-> commit rows + receipt -> send ACK
assert ACK is absent when any preceding durable operation fails
restart after commit, before ACK -> replay -> same receipt, one chunk
```

- [x] 实现 V2 能力协商和配对隔离。旧手机不支持时继续在 Watch 保存并显示待升级；不得把 V2 伪装成 V1 发给旧接收器。
- [x] 接收回调返回前移走临时音频，随后后台流式 hash/头校验；锁屏存储不可用则保留待处理文件或依靠 Watch 原件重传，解锁恢复。
- [x] ACK 携带完整身份和 hash，Watch 只确认匹配副本；完成消息采用独立持久重试队列，防止最后文件发送后会话永远不结束。
- [x] 在同一 pairing 下测试重复发送、乱序、超时、ACK 丢失、手机重启、Watch 重启、配对切换与错误 ACK。待同步条数按会话聚合，最后保存时间由真实收据更新。
- [x] 运行 `sh apps/wrist-notes/scripts/test_watch_sync.sh` 与新脚本，V1 录音及闪念链路必须继续通过。

## Task 5：会话展示与范围播放

**Files:** 新增 `RecordingSessionModel.swift`、`RecordingSessionDetailView.swift`、`RecordingRangePlayback.swift`；修改 `WristNotesApp.swift`、`DaybookView.swift`、`DayRecord.swift`、`DaybookComponents.swift`、`NotesListView.swift`、`WatchContentView.swift`、`Localizable.xcstrings`；新增 `Tests/RecordingSessionPresentationSmoke.swift`。

**Interfaces:** model 从 repository 读取按时间分页的会话投影；detail 用 sessionID 导航；playback 输入任务 3 的 `[RecordingSourceRange]`。原 VoiceNote/AudioPlayback 仍服务旧笔记，不构造指向不存在音频的占位 VoiceNote。

- [x] 写投影和定位测试：一个会话的三个文件只产生一条记录；缺 ordinal 1 时显示缺口；seek 对应正确文件内帧；结束消息缺失显示“录音结束状态待同步”。

```text
range A = 0..<4800000 @ 16000 Hz
range B = 0..<160000 @ 16000 Hz
seek 305 seconds -> B at frame 80000
duration -> 310 seconds
```

- [x] 完整会话记录不与已适配的旧笔记重复展示；Watch 列表保持一个会话一个条目，展开查看分片进度。跨午夜投影沿用设计的日期交叠规则。
- [x] 用 AVFoundation 受限队列预取下一范围，消费后释放旧媒体对象；跨文件播放与 seek 用同一帧范围映射，波形继续固定点数小缓冲采样。AAC padding 和实际缺口不能被误计为已录声音。
- [x] 新会话展示“待分段处理”，禁止调用旧单 URL 整段推理路径。旧笔记继续采用现有 ASR 和说话人保护；不因新界面绕过 30 分钟保护。
- [x] 删除派生记录/整次原录音语义在 UI 中区分，当前 A 仅提供删除完整会话的既有确认流程；删除文件失败保留清理状态并重试。
- [x] 检查中文/英文/日文状态文案与 VoiceOver，运行新脚本及源成员检查。

## Task 6：集成门槛与设备验证

**Files:** 修改 `scripts/test_local.sh` 加入新脚本；新增 `verification/segmented-recording.md`；精确更新工程源成员，保留 CocoaPods/SwiftPM 现有配置。

- [x] 运行 `sh apps/wrist-notes/scripts/test_local.sh` 和 `git diff --check -- apps/wrist-notes`；记录失败及修复，不把旧测试命令的缺陷解释为产品通过。
- [x] 构建命令：

```sh
xcodebuild -workspace apps/wrist-notes/WristNotes.xcworkspace \
  -scheme WristNotes -configuration Debug \
  -destination 'generic/platform=iOS' \
  -disableAutomaticPackageResolution build
```

- [x] 设备验证前复制必要的测试数据备份到仓库外；以相同 bundle ID 保留容器安装，禁止卸载清空。使用合成/明确允许的录音，日志只记录身份、时长、状态和校验结果。
- [ ] Watch 断开 iPhone 连续录音超过 15 分钟，跨至少三个分片边界后停止；重连后全部分片保存、一个会话、总有效时长一致、每份 hash 一致、播放跨边界连续。
- [ ] 录音中切后台、手机锁屏接收、人工终止 Watch App 后重开、写入/索引失败恢复、重复传输和延迟结束消息，分别记录步骤和结果。
- [ ] 完成至少 6.5 小时长录音的真机耐久测试并记录 Watch 续航、温度、峰值内存、分片数、文件总时长及实际中断；短时测试通过不能代替该项。
- [ ] 确认 10 月 21 日原长录音仍能打开，元数据时长正确，原件 hash 未变。旧 SQLite SIGBUS 单独列出是否复现及证据，未复现不能等同已修复。
- [x] 将 A 的已实现、已验证、设备未测项分别写入验证文档。此时可以交付 A；B/C 进入各自实施计划，不能声称自动内容分段已完成。

## 自查记录

- 覆盖设计 A 的物理分片、恢复、同步、时长、UI/回听、兼容、删除与设备门槛；设计 B/C 明确另行实施。
- 所有跨任务接口在本文件定义或属于已检查的现有文件；原始文件路径与协议身份分开。
- schema 迁移、文件系统和 ACK 之间的非原子窗口均有恢复/重放测试。
- 输入帧、音频有效时长、现实时间跨度分开，未把“文件存在”当作“录音成功”。
