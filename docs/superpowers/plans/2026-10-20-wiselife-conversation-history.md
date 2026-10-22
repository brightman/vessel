# WiseLife AI Conversation History Implementation Plan

**Goal:** 全量 SQLite 保存，AI Tab 最近 10 轮并每次加载更早 10 轮，修复资料更新导致历史删除。

**Architecture:** 在现有对话表增加状态和排序时间；Store 提供游标分页及逐条保存；Model 保存请求生命周期；View 分页展示并区分历史证据。

**Tech Stack:** Swift / SwiftUI / system SQLite。

## Global Constraints

全部历史保留，10 为分页大小。优先本地，不引入服务。保留远端发送确认、权限保护、损坏与事务回滚行为。不重建 Xcode 工程，不覆盖无关工作，不提交或发布。

## 执行步骤

- [x] 测试先复现资料变更删除和存储裁剪：`Tests/DaybookRetrievalSmoke.swift`；补充分页与请求状态行为测试。
- [x] `DaybookConversationStore.swift`：迁移 `state` / `created_at`；`loadPage(before:limit:)` 使用时间+UUID游标；`saveTurn(_:day:)` 单行事务；旧档导入不裁剪；权限清理与中断恢复。
- [x] `DaybookAssistantModel.swift`：问题先保存，完成更新同轮；加载更早历史；将资料有效性与保留历史分离；存储失败阻止未保存请求，重试不恢复过期结果。
- [x] `DaybookRetrieval.swift`：历史只传完成且允许的轮次；过期资料的回答文本不进入本次上下文，旧编号仍核对当前来源。
- [x] `DaybookAssistantView.swift`：最近 10 轮、下拉/按钮加载更早、状态与历史提示、清空全部确认。
- [x] 运行对话专项、完整本地回归及 iPhone/Watch 构建，检查范围内 diff；更新本地存储说明与验收记录。
- [x] 处理追加的声音登记反馈：区分读取失败与未登记，增加生命周期和页面重读；真实文件恢复测试与 iOS UIKit 通知测试通过。

验收记录：[对话历史与声音档案恢复](../../../apps/wrist-notes/docs/2026-10-20-conversation-history-and-voice-recovery.md)。完整本地回归在审查修复前通过，修复后重新运行对话专项、声音恢复及 iOS 测试，最终完整 iPhone/嵌入式 Watch 模拟器构建通过。真机复测尚未完成。
