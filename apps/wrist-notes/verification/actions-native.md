# 行动 Tab 原生实现 · 2026-10-23

## 范围

- SwiftUI 独立行动 Tab，全部/待办/提醒/日程，待确认建议、已加入、已取消分组，手动创建、编辑、完成/恢复、删除。
- 待办允许无截止时间，不触发通知。提醒复用现有提醒协调器。日程要求起止时间，结束不等于完成；全天区间按指定时区零点规范化，结束日期不包含当天。
- ActionRepository 使用主本机 SQLite 的独立表，乐观版本校验、软删除与候选去重。现有提醒按原 ID 接入，不重新安排通知，不重建系统关联。
- EventKit 管理明确关联的待办/日程，使用稳定 UUID URL 标记确认所有权。新建项目仅写标题/时间/标记；原话、本机备注和录音不写入系统。
- 系统操作先持久化意图，失败保留并可重试；读状态失败的重试只读，避免覆盖外部修改。外部已删除标记 missing，不自动重建。旧编辑在调用系统前校验版本。
- 录音详情和 Ask AI 引用可转为行动。保存原话、来源 ID、录音位置（有来源定位时）并支持回看；原记录不可用时保留行动与原话。
- 配置的 Apple 本地/自定义 API/ChatGPT 提取至多5项结构化建议，验证来源 UUID、原话子串、时间格式、标题及大小。提取完成只写“待确认”，用户确认后才激活。
- 远程提取沿用发送确认与免提示选择，预览展示处理指令与实际文字。来源/权限/配置变化或取消使旧结果失效。
- 原录音没有时区字段时不猜测相对日期。用户可以核对录制时区后提取；未核对则时间留空，确认时手填。

## 文件

- `Sources/iPhone/ActionItem.swift`：模型、校验、SQLite、去重。
- `ActionStore.swift`：操作协调、既有提醒适配、失败恢复、外部状态刷新。
- `ActionSystemService.swift`：EventKit 待办/日程适配与关联所有权检查。
- `ActionViews.swift`：列表、详情、编辑。
- `ActionProposal.swift` / `ActionProposalView.swift`：结构化提取、校验、发送确认与原话转行动。
- DaybookView / DaybookAssistantView、Info.plist、工程和生成脚本已接入。

## 验证

1. `sh apps/wrist-notes/scripts/test_actions.sh`：通过。验证无时间待办、时间校验、SQLite重开、候选去重/保留用户编辑、版本冲突、原话校验及未知时区不猜时间。
2. `ruby apps/wrist-notes/scripts/test_actions_ios.rb /private/tmp/wiselife-action-verification`，再对生成工程运行 `xcodebuild test`：2 项集成测试通过。真实运行 ActionStore、SQLite 及既有提醒协调器，系统边界使用 fake。覆盖失败后重开/重试、读取失败只读重试、删除失败保留、旧编辑拒绝、原提醒 ID/notificationID 保留、无时间待办不通知、完成恢复、全天日期规范化。
3. `sh apps/wrist-notes/scripts/test_apple_reminders.sh`：通过。既有提醒迁移/同步/权限/磁盘失败/通知回滚/并发等回归通过。旧测试将当前数据库版本写为10，已按现有数据库版本13修正断言；未修改数据库版本。
4. `ruby apps/wrist-notes/Tests/ProjectSourceMembershipSmoke.rb`：通过。
5. `xcodebuild -workspace apps/wrist-notes/WristNotes.xcworkspace -scheme WristNotes -configuration Debug -destination 'generic/platform=iOS Simulator' -derivedDataPath /private/tmp/wiselife-quick-recording-build CODE_SIGNING_ALLOWED=NO build`：退出0，BUILD SUCCEEDED。

## 尚未实测的边界

- 真实 Apple 账户的创建/移动/修改/删除与权限弹窗、设备通知送达、真实 AI 提取质量，需真机验证；测试未向真实模型发送资料。
- EventKit 关联丢失且标识变化时，日程标记回查覆盖原定时间前后一年；超出范围标记缺失，不主动重建已知系统项目。
- 本次未完成交互截图验证，未提交或推送 GitHub；保留工作区其他改动。
