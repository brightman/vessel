# 每日洞察沿用 AI 配置

用户明确要求复用每日回顾的提供商和授权逻辑，本次直接按既有设计实现。

## 行为

- Apple 本地 / 自定义 OpenAI 或 Anthropic 兼容服务 / ChatGPT，沿用设置，不静默切换。
- 免提示已开启时自动生成；否则点「生成 / 刷新洞察」展示所选模型与准确发送摘录，允许一次发送或记住选择。保持现有来源权限、静默时段、至少两条来源、每日自动次数限制。
- 确认过期不发送、不保存免提示选择；记录、配置、密钥版本、语言、来源权限或确认偏好改变时取消或拒绝旧结果。失败不在定时刷新时反复发送。
- 按提供商配置隔离缓存及尝试标记，数据库迁移可回滚；旧本地结果继续按本地解释。
- UI 展示实际模型、外部发送确认，不再声称始终仅在本机分析。共用确认控件的说明加入每日洞察。

## 实施与验证

1. 先添加 `Tests/DaybookInsightRemoteSmoke.swift` 和 `scripts/test_daily_insights.sh`，验证授权、自动发送、配置变更、过期结果和提供商缓存，观察未实现接口导致的失败。
2. 修改 `DaybookInsightService.swift` 的生成协议与三种路由，复用 `CustomAISummarizer` 安全网络层；扩展 `DaybookInsightModel.swift` 的精确请求确认和当前性校验。
3. 在 `DaybookInsightStore.swift` 添加可回滚的提供商键列，持久化可选结果模型标签；扩展原有本地与 SQLite 测试编译入口。
4. 修改 `DaybookInsightView.swift`、`DaybookView.swift` 和共用确认文案，接入设置、确认弹窗与设置变化观察。
5. 执行洞察/SQLite/授权相关本地测试、iOS Simulator workspace 构建；只读代码审查并修复具体问题。保存验证说明。无原生 UI 自动化、真实外部 AI 调用、提交或推送。

## 结果

以上步骤已完成。远程模型测试先失败后通过；审查发现的提供商缓存互相清除问题已复现并修复。洞察、SQLite、每日回顾回归测试与最终 iOS Simulator workspace 构建通过。详见 `apps/wrist-notes/verification/daily-insights-ai.md`。
