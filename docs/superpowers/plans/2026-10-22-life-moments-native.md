# Life Moments Native Implementation Plan

**Goal:** 按已批准的生活片段原型实现昨日步数归档、整夜睡眠/起床确认和大于 50 km 的地点变化。

**Architecture:** 在 DayRecord 添加可选 Codable 生活详情，旧记录兼容；健康聚合与地点推导均为 Foundation 纯函数。LifeSourceStore 用独立的域迁移附表保存详情，不改变其他正在开发的数据域。时间轴派生昨日归档及地点变化，保留原记录与权限分类。

**Tech Stack:** SwiftUI、HealthKit、MapKit、Combine、现有 SQLite 存储。

## Constraints

- 用户已经批准 `apps/wrist-notes/prototype/life-moments-design.md` 并要求开发，直接执行。无需新增 Linear 或重复审批流程。
- 当前 `codex/pages-api-base` checkout 包含前置功能及并行改动，在原目录增量修改。任务前快照：`/private/tmp/wiselife-life-moments-native-before`；不重置、不整体暂存、不提交/推送。
- 不新增服务器、持续定位或真实外部 AI 调用。既有来源暂停/AI 权限继续生效。
- 零点是归档归属，前台跨日、健康通知、解锁和重新进入时补刷，不承诺系统准点唤醒。
- 睡眠按结束日归属；起床估计可本人确认/撤销，保存在本机。没有评分时显示缺失，禁止由时长编造质量。
- 地点名称只来自结构化城市字段；解析失败保留坐标。仅依据两个采集点，不推断实际路线。
- 不执行原生 Simulator UI 自动化。允许 CLI 构建和本机逻辑/存储测试。

## Task 1 — Data and aggregation

Files: `DayRecord.swift`, new `LifeMomentBuilder.swift`, `Tests/LifeMomentsSmoke.swift`, `scripts/test_life_moments.sh`.

- [x] 先测试跨午夜、重叠样本/来源、清醒排除、午睡、时长未知和 50 km 边界；观察缺失功能失败。
- [x] 添加可选 `DayRecord.lifeMoment`，承载步骤统计范围/更新时间/归档标记、睡眠时间/分期/确认、地点证据。
- [x] `LifeMomentBuilder.health(day:steps:samples:now:calendar:) -> [DayRecord]` 保留日步数原始统计，睡眠按完整 episode 输出；`archive(records:day:updatedAt:calendar:)` 为前一日统计生成稳定 ID 的 00:00 片段。
- [x] `LifeMomentBuilder.movements(points:) -> [DayRecord]` 使用已有采集点，距离严格大于 50 km，过滤低精度和明显不可能的跳点，保存两个来源引用并用来源 ID 稳定去重。

## Task 2 — Storage and source lifecycle

Files: `LifeSourceStore.swift`, `LifeSourceModel.swift`, `LifeSourceReader.swift`, `CaptureMetadata.swift`, `AppleCaptureAddressResolver.swift`, `CaptureAddressModel.swift`.

- [x] 使用真实 SQLite 测试详情重开、确认刷新保留/时间变化失效、删除抑制。
- [x] 创建 `life_moment_metadata(record_id,payload)` 附表，外键随原生活记录删除；事务内增量写入，不改其他域 schema 版本。
- [x] HealthKit 读取含来源和分期的样本；查询日期前后余量保证跨午夜不截断，过滤未结束记录。
- [x] 模型增加确认操作与前台跨日刷新，保留观察器串行、失效和超时机制；历史日同步补刷前一天，以支持归档。
- [x] 地址缓存追加可选城市/地区字段；旧缓存可重试结构化解析，失败不编造城市。

## Task 3 — Native presentation

Files: new `LifeMomentViews.swift`, `DaybookView.swift`, `DaybookComponents.swift`, `LifeSourceViews.swift`, `Localizable.xcstrings`, project and generator.

- [x] 原日步数只用于概览，归档只进时间轴，防止双计数；生活筛选展示全部。
- [x] 新详情页展示统计日/实际更新、睡眠/起床确认、位置变化/两个可回看来源；展示等待、缺失及旧快照。
- [x] 位置变化和步数派生片段删除仅抑制该派生条目，不删除原始媒体；源数据变化立即重算。
- [x] 登记新增 Swift 文件，更新来源说明和关键新文案。

## Task 4 — Verification and review

- [x] `sh apps/wrist-notes/scripts/test_life_moments.sh`。
- [x] 健康后台、原生活存储、地点/地址、SQLite 定向回归和源文件登记检查。
- [x] `xcodebuild -workspace apps/wrist-notes/WristNotes.xcworkspace -scheme WristNotes -configuration Debug -destination 'generic/platform=iOS Simulator' -derivedDataPath /private/tmp/wiselife-quick-recording-build CODE_SIGNING_ALLOWED=NO build`。
- [x] 按 requesting-code-review 技能做独立只读评审，修复具体问题，保存真机待验项。

## Completion notes

- 2026-10-22: 四项已实施。新增数据/健康/地点/地址/SQLite 回归和 iOS Simulator CLI 构建通过，详细证据见 `apps/wrist-notes/verification/life-moments-native/README.md`。
- 独立评审发现并修复跨来源结束日期、未结束睡眠、夜间长清醒、午夜界面切日、待同步详情切换五处边界问题。
- 不使用无重试的 30 分钟延迟：可读取的已结束睡眠立即显示“估计”；仍有进行中样本时不生成结束片段。后续同步可修正并撤销不再匹配的确认。
- 当前地点规则：两条证据间隔不超过 48 小时；已知定位精度不超过 1 km，照片 EXIF 未提供精度时保留未知；排除明显不可能速度与短时间往返跳点。
- 保留当前 checkout。未操作原生模拟器界面、真机健康数据、真实 MapKit 坐标或外部 AI。未提交或推送。
