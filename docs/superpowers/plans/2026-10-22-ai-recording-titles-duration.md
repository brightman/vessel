# AI recording titles and duration display

**Goal:** 长录音跟随当前 AI 模型生成内容标题；已授权免提示的外部 AI 自动生成。录音时长显示完整小时、分、秒。

**Architecture:** 将标题任务排队、授权与过期检查提取为可独立验证的 RecordingTitleCoordinator，由 NotesModel 提供本机存储与模型服务。沿用现有标题 provenance 和手动标题保护。共享 RecordingFormat 输出完整三段时长，时间戳保持专门 timecode 方法。

**Tech Stack:** SwiftUI、Combine、Foundation Models、既有 OpenAI/Anthropic 兼容与 ChatGPT 客户端。

## Boundaries

- 使用当前包含必要未提交功能的 checkout，快照在 `/private/tmp/wiselife-ai-titles-duration-before`；不提交、不推送、不自动调用真实外部 AI。
- 不勾选免提示时，通过「AI 生成标题」确认后才发送；勾选后，新转写和仍需模型标题的记录自动排队。手动命名不被自动覆盖。
- 仅发送转写开头、中间、结尾的有限摘录；明确在确认框展示。资料、标题、模型、授权变化后拒绝过期结果。
- 本地模型不可用或自动推理失败时保留转写摘句作为临时标题，允许后续手动重试。已生成的有效模型标题不因刷新重复请求。
- 中文录音时长为 `0小时3分5秒`、`1小时2分3秒`；英文/日文使用对应单位。列表、详情、App 内计时、锁屏实时活动与灵动岛同步。实时活动通过系统 `TimeDataSource` 和 `DiscreteFormatStyle` 更新；实际布局与熄屏刷新效果待真机验收。
- 不执行此前被拒绝的原生 UI 自动化。

## Tasks

- [x] 先添加格式、标题升级与队列授权回归，并观察失败。
- [x] 实现共享标题提示词、有限摘录及远程标题调用，保留现有安全请求路径。
- [x] 实现标题协调器、自动任务去重、配置/授权变化监听、手动确认与失败提示；对接 NotesModel 和两个详情入口。
- [x] 修改共享时长格式、首页时长和受影响布局，保持 speaker 时间戳用途独立；同步原型及授权说明。
- [x] 运行定向测试与完整 Simulator 构建；完成独立评审，记录未实测范围。

交付与验证记录：[AI 长录音标题与完整时长](../../../apps/wrist-notes/verification/ai-recording-titles-duration.md)。

## Verification

```sh
sh apps/wrist-notes/scripts/test_recording_titles.sh
sh apps/wrist-notes/scripts/test_recording_title_coordinator.sh
sh apps/wrist-notes/scripts/test_conversations.sh
xcodebuild -workspace apps/wrist-notes/WristNotes.xcworkspace -scheme WristNotes -configuration Debug -destination 'generic/platform=iOS Simulator' -derivedDataPath /private/tmp/wiselife-quick-recording-build CODE_SIGNING_ALLOWED=NO build
```
