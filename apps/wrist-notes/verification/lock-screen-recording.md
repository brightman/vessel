# WiseLife 锁屏快捷录音

日期：2026-10-20。范围：圆形锁屏小组件，复用现有快捷录音和实时活动。

## 已实现

- 在现有 WidgetKit 扩展中加入“快捷录音”，支持 `accessoryCircular`。界面为圆形背景上的麦克风，包含“开始录音”无障碍标签。
- 按钮调用共享 `StartWiseLifeRecordingIntent`，使用 `AudioRecordingIntent` 与 `LiveActivityIntent`，由主 App 持有的唯一录音会话执行。复用首次麦克风授权、受保护数据检查、实时活动创建和自动保存流程。
- 开始动作具有幂等性：录音中重复轻点保持同一个录音 UUID，不停止、不新建第二条录音。停止保存使用现有实时活动按钮，原有操作按钮和三个快捷指令保留。
- 组件使用静态 timeline，不展示个人数据，不需要 App Group 或定时刷新。若系统将动作错误地路由到扩展，明确报错引导打开 App，不报告虚假的录音成功。
- “设置 → 快捷录音”增加添加步骤、重复点击行为、停止保存和系统授权说明。新增文案覆盖简体中文、英文和日文。

## 安装和使用

1. 用 Xcode 将新构建安装到 iPhone。iPhone 与 `WiseLifeRecordingActivity` 扩展需使用有效的签名配置；本次 CLI 构建未签名，不能直接装到真机。
2. 打开 WiseLife → 设置 → 快捷录音，允许麦克风访问，并确认系统允许 WiseLife 实时活动。
3. **长按锁屏 → 自定 → 锁定屏幕 → 添加小组件 → WiseLife → 快捷录音**，添加圆形麦克风。
4. 轻点麦克风开始，说话后通过实时活动的“停止并保存”结束。录音先保存本机，再进入已有转写流程。

系统可能要求 Face ID 或解锁；首次使用应先在 App 内完成权限设置。组件本身不会绕过系统认证。

## 本次验证

环境：Xcode 26.3、iPhone Simulator SDK 26.2。只使用 CLI 构建、测试、产物检查和代码审查，未执行原生模拟器界面自动化。

| 检查 | 实际结果 |
| --- | --- |
| 原有构建产物的集成检查 | 预期失败：`Lock Screen extension has no start-recording action` |
| 完整 workspace 构建 | `BUILD SUCCEEDED`，退出码 0；包含 iPhone、Watch 和 WidgetKit 扩展 |
| 新构建产物的集成检查 | `Built recording widget contract: passed`，退出码 0 |
| 录音状态回归 | `PhoneRecordingSession tests passed`，退出码 0；包括重复开始、串行操作、停止保存、失败重试、中断和草稿恢复 |
| 工程源文件归属 | `ProjectSourceMembershipSmoke.rb` 通过；共享 Start 在 App 和扩展，组件仅在扩展 |
| 工程生成脚本 | `ruby -c` 返回 `Syntax OK`；未重新生成项目 |
| 本地化与格式 | 两个 `.xcstrings` JSON 解析通过；新增源码无行尾空格，`git diff --check` 通过 |
| 独立代码审查 | 无阻塞问题；检查动作路由、重复开始、权限、原有停止路径和本地化 |

构建产物检查验证扩展已嵌入、Bundle ID 前缀与版本一致、实时活动声明存在；App 和扩展均包含标识一致、无需参数的开始动作及 `AudioRecording` / `SessionStarting` 协议元数据；原有停止动作与三个快捷指令仍在。此检查不证明系统实际执行了动作。

命令（仓库根目录）：

```sh
xcodebuild -workspace apps/wrist-notes/WristNotes.xcworkspace \
  -scheme WristNotes -configuration Debug \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath /private/tmp/wiselife-quick-recording-build \
  CODE_SIGNING_ALLOWED=NO build

python3 apps/wrist-notes/Tests/test_recording_widget_bundle.py \
  /private/tmp/wiselife-quick-recording-build/Build/Products/Debug-iphonesimulator/WiseNote.app

sh apps/wrist-notes/scripts/test_phone_recording.sh
ruby apps/wrist-notes/Tests/ProjectSourceMembershipSmoke.rb
ruby -c apps/wrist-notes/scripts/generate_project.rb
git diff --check -- apps/wrist-notes docs/superpowers/plans/2026-10-20-lock-screen-recording.md
```

本机日志：`/private/tmp/wiselife-lock-widget/build.log`、`/private/tmp/wiselife-lock-widget/recording-tests.log`，可能被系统清理。审查记录：`.superpowers/sdd/2026-10-20-lock-screen-recording/review.md`。

## 真机待验收

- 组件在锁屏图库中出现，麦克风显示、点击区域和 VoiceOver 正确。
- App 不在前台、进程未运行、锁屏或完成 Face ID 后均按系统允许的路径启动录音，实时活动正常出现。
- 连续点击多次只生成同一段录音；录音计时连续，实时活动可停止并保存。
- 保存后在“一天”中只有一条对应笔记，音频可播放，按已有设置进入本地转写。
- 麦克风被拒绝、实时活动被关闭时有明确引导，不显示录音已经成功；来电中断与长时间后台录音行为按真机实测确认。

录音计时、后台麦克风、锁屏认证和实际音频均未在物理设备上验证。既有录音核心的验证与限制见 [快捷录音记录](quick-recording.md)。

保留 `eurekaRing: false` 和 `WiseLifeChatGPTPublicClientEnabled: false`。本次未提交或推送代码，未更改其他功能的开关。
