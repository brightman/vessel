# WiseLife 模拟器 Apple ASR 兼容路径设计

日期：2026-10-27  
状态：待用户审阅

## 问题与目标

WiseLife 当前 Apple ASR 使用 iOS 26 `SpeechTranscriber`。它在本机 iOS 26.3 模拟器中返回 `isAvailable == false`，因此当前转写和资源界面都将 Apple ASR 判定为不可用。目标是在模拟器中运行 Apple 本地语音转写，以便开发和验收录音处理链路；真机继续使用现有 `SpeechTranscriber`。

## 方案与取舍

1. **仅在真机验证**：保留当前行为；不能在模拟器中验证 Apple ASR 驱动的处理链路。
2. **推荐：模拟器专用 `DictationTranscriber`**：模拟器使用 Apple 提供的兼容转写模块及 `AssetInventory` 系统语言资源，真机继续使用 `SpeechTranscriber`。同一接口下的两个构建路径清晰隔离；结果是实际 Apple ASR 输出，但不能作为真机 `SpeechTranscriber` 精度基准。
3. **模拟识别结果**：适合界面预览，但不能验证音频识别和语言资源流程。

选择方案 2。已在 iOS 26.3.1 模拟器通过独立临时探测程序验证：`SpeechTranscriber.isAvailable` 为 false；`DictationTranscriber` 支持 `zh_CN`，下载并安装系统中文资源后，成功转写一段 16.26 秒 FLEURS 中文音频。探测程序及其 App 已移除，Watch 传输模拟器未修改。

## 数据与处理流程

- 使用 `#if targetEnvironment(simulator)` 选择实现，不通过运行时失败触发静默回退。
- 模拟器 Apple 转写使用 `DictationTranscriber` 与 `SpeechAnalyzer`，沿用现有录音文件输入、最终文本收集和时间戳段落输出约定。
- 模拟器语言列表、资源状态与下载调用分别基于 `DictationTranscriber.supportedLocales`、`installedLocales`、`AssetInventory.status` 和 `assetInstallationRequest`。按 Apple 系统资源管理机制下载语言资源，不把模型打入 App。
- 真机继续使用 `SpeechTranscriber`、现有 locale reservation 协调器和系统资源下载流程；不改变识别语言、结果保存、分段或后续主题处理行为。
- 错误信息需区分模拟器兼容引擎与真机引擎，并说明模拟器识别结果不代表真机精度。

## 展示语义

- 模拟器设置及处理详情将 Apple 引擎明确标为“Apple Dictation（模拟器）”。
- 真机仍显示现有 Apple 端上转写名称。
- 未安装语言资源时允许用户从现有设置入口发起下载；下载中、可用、语言不支持及失败状态继续可见。
- 不把 `DictationTranscriber` 的结果标记为 `SpeechTranscriber`，也不宣称两者质量相同。

## 验证

- 添加针对模拟器路径选择与资源状态的测试，证明模拟器不依赖 `SpeechTranscriber.isAvailable`，真机构建仍使用 `SpeechTranscriber`。
- 在 iOS 模拟器安装后验证中文系统资源下载和一段公开中文样本的非空转写；同时确认 Settings 及录音处理流程能消费该结果。
- 编译 iOS 真机目标，检查真机分支仍编译并保留 SpeechTranscriber/locale reservation 路径。
- 模拟器验收只证明兼容 API 和链路可运行；真机准确率、设备性能与正式模型行为仍以实体 iPhone 测试为准。

## 范围

只调整 iPhone App 的 Apple ASR 实现选择、Apple 语言资源适配、模拟器引擎标识和对应测试。不开启服务器识别，不改 Whisper、说话人分析、VAD、录音存储和 Watch 传输；不修改已存在的用户工作区改动。
