# 2026-10-22 长录音退出与时长修复

## 已确认的证据

- iPhone 在 10 月 22 日 00:18:24 的 Jetsam 日志中，WiseNote 为前台进程，退出原因是 `per-process-limit`。16,384 字节页大小 × 216,582 页约为 3.3 GiB。
- 10 月 21 日长录音的 SQLite 元数据为 `duration = 0`、转写 `ready`、说话人识别 `running`。全文 52,206 字符，带时间戳的片段 49,371 个。
- 手机中的原始 AAC 文件为 78,055,389 字节、16 kHz 单声道。文件头标记 305,201,088 个有效帧，即 **19,075.068 秒（5:17:55.068）**。以 65,536 帧缓冲逐段解码副本，实际读到相同帧数，无解码错误。
- 安装前用复制出的数据库和音频验证修复，时长修正到 19,075.068 秒，标题、全文、时间戳片段等已有数据保留。该步骤仅操作副本；后续真机安装验证见下。
- 用户提供的 10 月 16 日 `bug_type = 211` 文件是更早的分析日志，不能解释本次退出；上述证据来自本次连接的 iPhone。

音频和数据库诊断副本仅保存在本机临时目录，未纳入仓库。没有检查到 Watch 原始文件，不能据此认定上传丢失了音频，也不能确认用户观察到的约 6.5 小时中缺少的部分能恢复。旧 Watch 计时器显示的是墙钟经过时间，可能与实际录入时间不同，尚不能证明它就是此次差异的原因。

## 原因分析与本次修复

### 多小时音频的内存风险

`NotesModel.resumePendingProcessing` 会恢复 `running` 的说话人识别。原 `LocalTranscriptionService.diarizeWithIdentity` 调用 WhisperKit 的 `AudioProcessor.loadAudioAsFloatArray`，将整个文件累积到 `[Float]`，随后交给说话人模型。此录音单份 16 kHz Float32 PCM 即约 1.22 GB，复制和模型工作内存会继续增加。该路径与实际内存退出、数据库中未完成的识别状态一致，是本次主要嫌疑；用户安装修复版后已反馈没有再崩溃。

- 新增 `SpeakerAudioInput`：先读实际音频文件头，再决定是否允许整段解码，不依赖可能为零的 Watch 元数据。
- **当前超过 30 分钟的录音暂不运行说话人识别**，自动恢复和手动重试均适用。已有错误处理将其保存为 `unavailable`，避免每次启动自动重试大内存分配。界面说明音频和全文保留。
- 时间轴预览只向 SwiftUI 传入前 240 个字符；全文存储和详情数据不截断。

30 分钟是当前整段加载实现的临时保护阈值，不是所有设备上模型推理的内存保证。后续需要分段解码、分段推理、跨段说话人合并和持久化进度。Whisper ASR 自身的整段音频加载路径此次未改造。

### 0 秒元数据

- 新导入、重复传输补文件、孤立文件恢复和启动时修复，均可从本地音频头补全零时长。
- SQLite 的 `duration` 列和 JSON payload 在同一事务内更新，保留原有标题、全文、总结和处理状态。
- 可选的历史时长修复失败时保留可读笔记，下次打开重试；音频不可读时保留原件，不编造时长。
- Watch 停止录音后以最终文件的实际时长为准，失败时退回录音器计时；运行中计时改用 `AVAudioRecorder.currentTime`。恢复文件和已有零时长条目也读取实际时长。

本次没有实现 Watch 分段录音，也没有补齐所有中断、断电、索引损坏等恢复场景。

## 验证

- `sh apps/wrist-notes/scripts/test_audio_duration.sh`：通过。覆盖真实 AAC、导入、SQLite 重开修复、重复传输、孤立音频恢复、写入失败回滚/重试、原文件保留，以及多小时文件在大内存加载前被拒绝、短音频仍可解码。
- `sh apps/wrist-notes/scripts/test_local.sh`：通过。
- iOS generic Debug 签名构建（包含 Watch 目标）：`BUILD SUCCEEDED`。
- `git diff --check -- apps/wrist-notes`：通过；本地化 JSON 可解析。
- 实际设备数据副本：时长修复、全文与时间戳保留、大内存加载入口被阻止，均已验证。
- 实际音频副本：逐段完整解码通过。
- **修复版已于 00:42 安装到 iPhone 并启动**：重新连接后以相同 bundle ID 保留数据更新，安装、签名检查及启动均成功。
- 安装后重新复制真机 SQLite 核验：`quick_check = ok`，20 条笔记保留；目标录音 SQL 与 payload 时长均为 19,075.068 秒，说话人状态由 `running` 变为 `unavailable`；全文、总结、转写 revision、全部时间戳片段、采集时间和音频文件名均未改变。原默认标题由既有自动标题流程生成了全文摘录标题（`titleSource = transcriptExcerpt`，`titleManuallyEdited = false`）。
- 安装后重新读取目标音频，与安装前副本的大小及 SHA-256 一致，确认音频未改写。
- 首次检查中 App 进程仍运行，未发现安装后的新 WiseNote/Jetsam 退出日志。请求用户验证切换到 10 月 21 日、打开详情及播放后，用户反馈“没有崩溃”。此为用户报告的闪退回归结果；没有另行收到逐项播放与界面时长确认。

## 另一个独立的退出日志

10 月 21 日 23:07:50 有一份旧的 SQLite 路径崩溃：`EXC_BAD_ACCESS / SIGBUS`，`FS pagein error: 1 Operation not permitted`，栈包含 `sqlite3_step` → `DaybookDatabase` → `NoteRepository.importRecording`。它与上述最新内存超限事件不同，可能涉及锁屏数据保护与 SQLite 映射访问，尚未证明具体机制。本次未改变数据库保护级别，也未将这份旧崩溃标为已修复。
