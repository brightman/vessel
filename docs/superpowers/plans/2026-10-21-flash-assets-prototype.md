# WiseLife Flash Assets Prototype Plan

**Goal:** 在现有 iphone-day HTML 原型中展示 Capture → Insight → Action。

**Architecture:** 单独的 daybook-flash-assets.js 模块提供示例数据与页面内状态，复用既有 sheet、图标、toast、记录入口；样式集中在 daybook-flash-assets.css。daybook.js 仅添加接入点。

**Tech Stack:** 静态 HTML、CSS、JavaScript，Playwright 浏览器验证。

## Constraints

- 仅设计原型，不修改 Swift、麦克风、模型或系统服务。
- 保留本地未提交修改；不提交或推送。
- 提醒／日程／待办属于 Action；Insight 类型是想法／知识／感受／消费／人物／资料。
- 不猜测缺失时间、币种或人物；不自动执行行动。

## Steps

- [x] 增加独立模块与示例数据；`seed(records)` 在每日汇总快照前执行。
- [x] 集成洞察分段、行动入口、闪念详情入口；`entry(record)` 返回详情卡片，`handleClick(button)` 路由事件，`render()` 更新列表。
- [x] 实现资产编辑／确认／忽略／恢复与来源回看；消费确认校验金额／币种／日期。
- [x] 实现行动选择与表单；无日期待办、必填提醒时间、日程结束晚于开始；系统操作仅演示。
- [x] 检查 JS 语法、页面依赖与 diff；浏览器验证核心流程、手机窄屏与深色样式；保存截图和验证说明。

设计依据：`apps/wrist-notes/prototype/flash-assets-design.md`。本轮直接完成用于产品评审的 HTML 设计，不启动原生实施。

## Verification

浏览器 10 组流程验证通过，无 JavaScript 页面错误。包括六类筛选、消费确认汇总、忽略恢复、来源回看、待办与日程确认、重复打开、异常状态、旧功能入口、深色与 320/390px 布局。证据：`apps/wrist-notes/verification/flash-assets-prototype/README.md`。
