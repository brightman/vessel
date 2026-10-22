# WiseLife iPhone 快捷录音

日期：2026-10-20。实现范围：操作按钮快捷指令、录音实时活动、停止后自动保存。没有新增服务器或控制中心按钮。

## 已实现

- `WiseLifeRuntime` 在 App 进程中持有唯一的普通录音器、录音会话和 `NotesModel`。SwiftUI 与 App Intents 使用同一套状态，自动保存不依赖首页是否已出现。
- 提供“开始／停止录音”“开始录音”“停止并保存录音”三个 App Shortcuts。开始／切换使用 `AudioRecordingIntent` 和 iOS 26 的后台／动态前台模式；需要首次麦克风授权时请求前台继续。
- 开始成功后触觉反馈。锁屏、展开的灵动岛显示录音时长和停止按钮；紧凑灵动岛显示录音图标与时长。停止按钮携带录音 UUID，旧卡片不能停止新录音。共享停止 Intent 同时遵循 `LiveActivityIntent`，由主 App 处理。
- 通过快捷指令开始录音必须成功创建实时活动；关闭或创建失败时返回可操作的错误。App 内普通录音仍可在实时活动不可用时使用。活动被系统结束或用户移除时，会话尝试停止并保存。
- 先完成音频与本地笔记持久化，再启动已有端上 ASR 流程；ASR 失败不删除音频。保存失败保留草稿，首页提供重试。来电／音频中断保存已经录制的部分并保留提示。
- 草稿在 Application Support 中暂存，并在开始前写入元数据。恢复使用同一 UUID，防止重复笔记；文件路径按当前沙盒重建。损坏的元数据单独保留并提示，不阻塞其余有效录音恢复。尚未写完或无法解码的音频保留待处理，不承诺能修复强制终止时未完成的 AAC 容器。
- “我的声音”登记继续使用独立、临时且受保护的录音；麦克风占用统一协调，避免与普通录音同时启动。
- 新增“设置 → 快捷录音”引导，含麦克风和实时活动权限状态、绑定步骤。主要界面和快捷指令文案包含中文、英文和日文。

## 如何绑定

1. 安装新构建，打开 WiseLife → 设置 → 快捷录音，允许麦克风；确认系统允许 WiseLife 实时活动。
2. iPhone 设置 → 操作按钮 → 快捷指令 → 选取快捷指令 → **WiseLife：开始／停止录音**。
3. 长按操作按钮开始；再次长按结束并自动保存。也可点实时活动中的“停止并保存”。锁屏按钮操作是否需要解锁由系统决定。

App 不能代替用户修改系统操作按钮绑定。当前项目新增了 `WiseLifeRecordingActivity` 扩展 target；真机运行时需与 iPhone App 使用同一 Team 和有效签名。

## 已执行验证

环境：Xcode 26.3（17C529）、iPhone Simulator SDK 26.2、iOS 26.3 模拟器。使用 CLI 构建与 XCTest，没有执行原生模拟器界面自动化。

| 验证 | 结果 |
| --- | --- |
| `sh apps/wrist-notes/scripts/test_phone_recording.sh` | 通过：录音状态、串行开始／停止、保存失败重试、旧 session ID、取消／权限失败、活动移除、重启恢复、不可读文件恢复、路径迁移及异常元数据 |
| 原生录音 XCTest | 5 项通过：既有 3 项登记录音回归；真实 AAC 文件保存失败后重试；已入库但草稿尚未清理时重启，不重复生成笔记 |
| `sh apps/wrist-notes/scripts/test_local.sh` | 通过：既有录音存储、Watch 交互、设置、转写配置、笔记检索与会话、提醒、生活来源、SQLite 和语义检索回归 |
| iPhone App + Watch App + 实时活动扩展构建 | `BUILD SUCCEEDED` |
| 生成的 App Intents 元数据 | App 包含 4 个 action、3 个 App Shortcuts；扩展包含相同标识的专用停止 action |
| 工程与配置 | 新源文件有 target membership；扩展已嵌入；Bundle ID 前缀、版本与签名 Team 一致；`NSSupportsLiveActivities=true` |
| 范围保护 | `eurekaRing` 保持 `false`，ChatGPT 资格开关保持关闭；未提交或推送代码 |

完整构建命令（仓库根目录）：

```sh
xcodebuild -workspace apps/wrist-notes/WristNotes.xcworkspace \
  -scheme WristNotes -configuration Debug \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath /private/tmp/wiselife-quick-recording-build \
  CODE_SIGNING_ALLOWED=NO build
```

原生测试使用隔离的测试宿主，不申请麦克风权限，不读写用户的 WiseLife 数据：

```sh
ruby apps/wrist-notes/scripts/test_recording_ios.rb /private/tmp/wiselife-recording-native-tests
xcodebuild -project /private/tmp/wiselife-recording-native-tests/RecordingVerification.xcodeproj \
  -scheme RecordingVerification \
  -destination 'platform=iOS Simulator,id=D9857EEA-8E8C-4788-BBC0-4EB3B10EE506' \
  -derivedDataPath /private/tmp/wiselife-recording-native-tests/build test
```

复跑时将 simulator ID 换为本机可用 iPhone 模拟器。构建时不要强制 `-sdk iphonesimulator` 到整个 workspace，否则会把 Watch target 也按 iPhone SDK 编译。

本机日志：`/private/tmp/wiselife-quick-recording-build-final.log`、`/private/tmp/wiselife-recording-native-tests.log`、`/private/tmp/wiselife-quick-recording-local.log`；临时日志可能被系统清理。独立代码复核覆盖录音核心和完整接线；修复了重试、损坏草稿隔离和首次授权造成计时偏差的问题。

## 真机验收仍待完成

- iPhone 16 Pro 操作按钮发现／绑定、长按开始、再次长按停止、触觉反馈。
- 锁屏、App 不在前台和 App 进程未运行时的启动，首次授权／拒绝／撤销权限及实时活动被关闭。
- 锁屏和各种灵动岛尺寸的实际展示、计时、停止按钮，以及用户移除活动后的保存。
- 长时间后台录音、来电／Siri／蓝牙路由切换、低存储空间、保存失败后解锁重试、“我的声音”与操作按钮争用麦克风。
- 保存文件可播放、启动本地转写；后台转写受系统调度影响，可在下次回到 App 后恢复，不能根据构建成功保证一直后台处理。

ActivityKit 有系统时长和调度限制；本次不承诺无限录音。强制结束进程、断电时不能保证正在写入的 AAC 文件完整。上述物理设备行为尚未验证，模拟器构建和音频文件单元测试不能代替真机验收。

## 官方依据

- [AudioRecordingIntent](https://developer.apple.com/documentation/appintents/audiorecordingintent)：录音期间必须保持 Live Activity。
- [AppIntent supportedModes](https://developer.apple.com/documentation/appintents/appintent/supportedmodes)：iOS 26 后台与动态前台模式。
- [Widget / Live Activity 交互](https://developer.apple.com/documentation/widgetkit/adding-interactivity-to-widgets-and-live-activities)：LiveActivityIntent 在 App 进程执行；锁屏交互受系统认证限制。
- [操作按钮绑定快捷指令](https://support.apple.com/guide/shortcuts/apdfea15680b/ios)。
