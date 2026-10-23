# WristNotes · Huawei

独立的 HUAWEI WATCH GT 6 + iPhone 语音笔记项目。Android 为下一阶段。

目标设备：HUAWEI WATCH GT 6，用户于 2026-10-19 确认系统为 **HarmonyOS 6.1.0**；完整固件构建号尚未提供。手机优先适配 iPhone 16 Pro。

**当前是开发中的基础版本，不是已可在 GT 6 上录音的成品。**

- 产品交互沿用 Apple 版：轻点开始/结束长录音、长按闪念、松手保存、上滑取消；录音列表显示名称、时间、时长、上传状态，并支持删除。
- iPhone：复用 SwiftUI 笔记管理、播放、Apple 端上转写和 Apple 本地摘要。独立 Bundle ID，独立数据沙盒。
- 数据留在设备内；计划通过 Wear Engine 近端传输，不引入自建服务器。

## 尚未满足的接入条件

1. 尚未找到已核实、适用于 GT 6 第三方 JS 应用的麦克风录音 API。系统自带录音机不能作为第三方接口证明。
2. 本机未发现 DevEco Studio / 华为 SDK。GT 6 是 Lite Wearable，不能使用标准手表的 ArkTS/AVRecorder 工程。
3. Wear Engine iOS SDK、服务开通和应用身份配置尚未取得；未连接实际手表。现阶段 iPhone 不会显示虚构的已连接状态。
4. 已记录 HarmonyOS 6.1.0；第三方后台长录音、熄屏、来电、文件格式和容量仍需接口资料及真机确认。

官方系统录音机要求 GT 6 固件达到 `6.1.0.117(SP4C00M04)`；其手机同步条件限定了华为手机，不能作为当前 iPhone 路线的文件导入方案。该条件也不证明第三方应用可以录音。

详细证据及下一步见 [兼容性与设计](docs/design.md)。待华为确认的问题已整理为 [接入咨询草稿](docs/huawei-integration-inquiry.md)，尚未发送。

## 目录

- `iphone/HuaweiNotes.xcodeproj`：独立 iPhone 工程，Scheme 为 `HuaweiNotes`，最低 iOS 26。
- `iphone/Sources/`：本地笔记、音频播放、转写、摘要、外观设置和完整录音文件的校验入库入口。
- `watch/core/`：JS 手势状态机、串行传输队列及分片规划；尚无手表 UI、录音驱动或 HAP。
- `docs/transfer-protocol.md`：应用层录音清单和保存确认协议。
- `scripts/test_local.sh`：Node + Swift 本地逻辑验证。

## 运行 iPhone 工程

1. 用 Xcode 打开 `iphone/HuaweiNotes.xcodeproj`，选择 `HuaweiNotes` Scheme。
2. 模拟器可直接构建。真机运行时在 Signing & Capabilities 选择自己的 Team；Bundle ID 默认 `com.vessel.wristnotes.huawei`。
3. 通过设置页导入音频，验证播放、全文编辑和总结；端上模型依实际设备及 Apple Intelligence 可用性决定。
4. 不会创建示例笔记，也不会连接 Apple Watch。GT 6 状态明确显示未连接。

```sh
# 在 Vessel 仓库根目录
sh apps/wrist-notes-huawei/scripts/test_local.sh
xcodebuild -project apps/wrist-notes-huawei/iphone/HuaweiNotes.xcodeproj -scheme HuaweiNotes -destination 'generic/platform=iOS Simulator' -derivedDataPath /private/tmp/wristnotes-huawei-derived CODE_SIGNING_ALLOWED=NO build
```

本地检查中的 AAC 合成音频需要访问 macOS 音频组件；受限沙盒可能报 `AVFAudio 1718449215`。测试不使用麦克风。验证结果见 [verification.md](docs/verification.md)。

## 功能完成边界

- 已有：iPhone 文件导入、列表/搜索/删除、真实播放器、全文编辑、总结/全文标签、Apple 本地转写/摘要、外观和语言设置。
- 已有：经过测试的手表交互规则、发送队列、分片计划、iPhone 完整文件校验/去重/保存后确认边界。
- 未完成：GT 6 原生 UI、真实麦克风/后台录音、Wear Engine 两端连接、分片 I/O/重组、真实跨设备确认。
- 后续功能：Whisper、自定义 AI 配置/调用、Android 配套 App；这些不会在当前基础版本伪装成已支持。
