# External AI confirmation preference

**Goal:** 在外部 AI 发送确认中提供默认未勾选的「下次不再提示」，确认发送后保存，下次主动调用外部 AI 时跳过确认。

**Architecture:** AppSettings 保存本机的全局发送提示偏好。Ask AI 与总结复用偏好和确认控件；现有模型、原文与资料权限有效性检查继续生效。设置中的恢复开关即时保存，与模型配置保存独立。

**Tech Stack:** SwiftUI、UserDefaults、现有 Swift smoke 测试；HTML 原型同步交互。

## Constraints

- 沿用含必要未提交原生功能的当前 checkout，只编辑任务文件；变更前快照在 `/private/tmp/wiselife-remote-ai-confirmation-before`。
- 不提交、不推送、不发真实 AI 请求，不使用之前被拒绝的原生模拟器 UI 自动化。
- 偏好适用于 ChatGPT 和自定义 AI 的主动问答与总结。不会开启后台发送或改变本地模型、硬件闪念的处理规则。
- 不勾选继续逐次提示；取消、过期确认不保存勾选。勾选并确认才记住，在 App 重启后保留。
- 设置 → AI 模型 →「发送给外部 AI 前确认」可以随时恢复。

## Tasks

- [x] 为真实 AppSettings 与 DaybookAssistantModel 增加回归：默认提示、取消不记住、勾选确认后持久化、重启跳过、恢复提示、过期内容拒绝发送与保存选择、免提示仍遵守资料撤回和模型变更。
- [x] 实现 `requiresRemoteAIConfirmation` 与 `authorizeRemoteAISend(confirmationIsCurrent: Bool?, rememberChoice: Bool)`；未展示确认时只允许已关闭提示的主动发送，显式过期确认始终拒绝。
- [x] Ask AI 普通与语义检索路径接入偏好；两处总结入口与服务层同时接入；共用勾选控件，仅确认动作传入选择。
- [x] AI 设置提供即时保存的恢复开关，更新状态文案、中英日本地化和 HTML 原型。
- [x] 运行定向逻辑回归、完整 Simulator 编译、JS 语法与任务差异检查，记录验证范围。

## Verification commands

```sh
sh apps/wrist-notes/scripts/test_conversations.sh
xcodebuild -workspace apps/wrist-notes/WristNotes.xcworkspace -scheme WristNotes -configuration Debug -destination 'generic/platform=iOS Simulator' -derivedDataPath /private/tmp/wiselife-quick-recording-build CODE_SIGNING_ALLOWED=NO build
node --check apps/wrist-notes/prototype/daybook-ai.js
node --check apps/wrist-notes/prototype/daybook-model-settings.js
node --check apps/wrist-notes/prototype/daybook-chatgpt.js
```

结果与未验证边界见 [验证记录](../../../apps/wrist-notes/verification/remote-ai-confirmation.md)。
