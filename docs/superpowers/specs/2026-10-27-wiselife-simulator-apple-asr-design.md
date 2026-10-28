# WiseLife Apple ASR 首选与回退方案

日期：2026-10-27
状态：已实施；完整 App 构建与模拟器运行验收受本机 CocoaPods / CoreSimulator 环境阻塞

## 问题与目标

WiseLife 当前 Apple ASR 使用 iOS 26 `SpeechTranscriber`。在本机 iOS 26.3 模拟器中，`SpeechTranscriber.isAvailable` 为 `false`，因此模拟器不能使用这条路径。目标是在不改变 Apple 端上处理边界的前提下，统一支持以下优先级：

1. 首选 `SpeechTranscriber`。
2. 当设备不可用、语言不支持、语言资源未就绪或推理失败时，回退 `DictationTranscriber`。
3. 模拟器和真机均按同一运行时策略选择；不再使用 simulator compile-time 分支。

## 已确认的实现选择

- Apple ASR 配置的模型标签显示 `SpeechTranscriber` 优先、`DictationTranscriber` 回退。
- 用户选择 Apple ASR 语言后，设置页枚举两种引擎支持语言的并集，并下载该语言可用的首选与回退系统资源。
- 若 Speech 模块与语言都可用，实际先运行 Speech；若不可用或失败，才运行 Dictation。Speech 成功时不得调用 Dictation。
- `DictationTranscriber` 使用 `.timeIndexedLongDictation`，沿用 `SpeechAnalyzer` 及现有的定时文本段落输出。
- 将实际引擎标识随转写结果持久化，并在录音详情显示，避免把 Dictation 的输出标成 Speech。
- Whisper、分片、VAD、说话人分析、主题拆分、Watch 录音和传输逻辑均不变。

## 回退边界

- 语言不支持与资源缺失优先在执行前判断；可用 Dictation 路径时直接使用回退引擎。
- Speech 推理期间如发生可恢复的资源或引擎错误，则尝试 Dictation。
- `CancellationError`、Task 已取消及 `BoundedAudioError.invalidWindow` 不触发回退；这些情况应原样结束，避免重复处理已取消任务或无效音频。
- 两种引擎均不可用或回退也失败时，报告最终失败原因，不生成模拟转写文本。

## 语言资源

- 语言选择提供 Speech 与 Dictation 支持语言的去重并集。
- 资源状态只有在所有当前可用的 Speech/Dictation 路径均已安装，或某条路径被系统明确标为不支持时，才报告“已就绪”。
- 下载操作顺序安装支持的 Speech 与 Dictation 系统资源，并将两段进度合成为单调总进度。资源由 iOS 管理，不打入 App，也不上传音频。
- 保留现有 locale reservation 协调，防止资源下载、切换和推理并发修改系统资源状态。

## 展示与持久化

- Apple 配置标签明确写出首选和回退引擎。
- 单条 Note 与长录音的每个处理窗口均保存实际引擎名称；旧记录缺少该字段时仍可解码。
- 详情页优先显示持久化的实际引擎；历史记录没有引擎字段时，才显示配置标签。

## 验证

- 纯 Swift 测试覆盖：两引擎可用时 Speech 优先；Speech 不可用或语言不支持时选 Dictation；Speech 成功不重试；可回退错误运行 Dictation；取消和无效输入不回退；回退引擎名称随输出可见。
- 存储测试覆盖新引擎元数据往返，以及缺少新字段的旧 Note 与旧处理窗口 JSON 仍能读取。
- 编译 iOS Simulator 和 generic iOS device 目标，确认两种 SDK 都能编译 Speech 与 Dictation 路径。
- iOS 26.3.1 模拟器此前已用独立临时探测器下载系统中文资源，并成功将一条 16.26 秒 FLEURS 中文样本转写为非空文本。该历史探测验证了系统 Dictation API；完成实现后仍需单独标记是否重新从 App 链路跑过相同样本。
- 模拟器结果仅用于验证兼容路径和 App 处理链路，不代表真机 SpeechTranscriber 精度。

## 范围

仅更改 iPhone Apple ASR 引擎选择、系统语言资源、实际引擎来源元数据、详情展示和测试。不新增服务器识别，不更改 Whisper、Watch、录音存储及长录音切分策略。
