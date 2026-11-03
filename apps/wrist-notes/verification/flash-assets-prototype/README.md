# Flash assets prototype verification

Date: 2026-10-21. Scope: HTML prototype only.

## Open

- Asset library: http://127.0.0.1:8776/iphone-day.html?preview=assets#product
- One flash capture: http://127.0.0.1:8776/iphone-day.html?preview=flash#product
- Actions: http://127.0.0.1:8776/iphone-day.html?preview=actions#product
- Alternate states: `preview=flash-waiting`, `flash-unavailable`, `flash-empty`.
- Source: `apps/wrist-notes/prototype/iphone-day.html`.
- Product design: `apps/wrist-notes/prototype/flash-assets-design.md`.

## Verified

Headless Chromium 153 through local Playwright against the served prototype. Browser checks passed:

1. Six asset filters return their respective records; todo/reminder/event are Action types.
2. Unconfirmed expense excluded from totals; edited and confirmed 41.50 CNY included.
3. Dismiss/restore preserves capture, source text and asset count. Source opens Full text.
4. Todo without a date, completion/undo; event end-time validation; original capture date anchors tomorrow; external toggle off by default, results labeled simulated.
5. Asset to reminder links source; opening it again does not duplicate an action.
6. Waiting/unavailable/no-assets states preserve source navigation.
7. Keyboard tab navigation; existing life-insight plans visible under Action.
8. Dark appearance; 390 and 320 px viewports have no asset-panel or nav horizontal overflow.
9. Existing contact and Apple Reminder preview routes still open.
10. No JavaScript page errors across these flows.

Evidence: `browser-checks.log`, seven PNG screenshots. Light, dark, 320px, capture sheet and Action screenshots visually inspected. Existing phone proportions retained. Earlier verification interruptions were ambiguous Playwright locators; narrowed to the active panel/sheet, with no app workaround needed.

`node --check` passed for daybook-flash-assets.js, daybook.js and daybook-locales.js. `git diff --check` passed for edited tracked prototype files. Current task changes reviewed against pre-task snapshots in `/private/tmp/wiselife-flash-assets-before/`, preserving existing dirty edits.

## Limits

Fictional fixtures and in-memory edits only. No actual extraction, ASR, audio playback, permanent asset storage, contacts/calendar/reminder access, native Swift changes or physical-device validation. New asset copy is a Chinese design preview; only core navigation/type/action labels are added to the existing English/Japanese chrome dictionaries. No complete localization QA claimed. All reminder/calendar saves in this new flow are simulated and reset on reload.

The temporary browser verification driver is `/private/tmp/wiselife-flash-assets-verify.mjs`; product state is reset with page reload. No commit or push performed.

## 2026-10-31 update

Scope: updated HTML prototype for idea/bookkeeping storage in WiseLife and automatic execution of explicit flash commands. The 2026-10-21 results above describe the older six-type, confirmation-based design; they are not acceptance evidence for this revision. Current product contract: [flash-assets-design.md](../../prototype/flash-assets-design.md).

### Environment and observed results

Local Python HTTP server on `127.0.0.1:8778`, macOS native Chrome controlled through CUA accessibility and screenshot tools. Desktop browser zoom was 80%. Test fixtures only; each page reload resets modifications.

1. Mixed capture renders `整理／全文`, 1 idea, 1 expense and 3 automatically created action results. Full text contains all five source statements; returning to 整理 retains the results.
2. Expense editor saved 38.00 → 41.50 CNY and displayed the revised amount. No second confirmation was required.
3. After a fresh fixture load, ledger showed 73.00 CNY expenses (38 + 35); revoking the 38 CNY entry changed the ledger to 35.00. Missing-amount coffee remained excluded.
4. Coffee entry accepted 26 CNY through 补充信息 → 保存并记账 and changed to 已记账. The missing-time reminder stayed pending independently.
5. Entering 2026-10-20 09:00 for the pending reminder and 保存并安排 changed it to 已安排. 撤销 changed it to 已撤销 with the no-auto-recreation explanation.
6. Missing notification authorization displayed 未安排. 处理权限 → 模拟已授权并重试 changed the demo state to 已安排; no real permission request occurred.
7. Pure-idea fixture rendered only one saved idea, with no automatic tasks. Edited its title, revoked it, then restored it; the revised title was retained.
8. Final flash management menu rendered 编辑标题与全文、查看整理结果、删除录音. Ordinary voice route retained 总结／全文.
9. Ledger entry initially led to the deferred Insights → AI redirect. Corrected it to an independent 想法与账目 sheet and reran the ledger flows successfully. Added 我的想法／我的账目 links to 我的记录.
10. Viewed screenshots of the main detail and scrolled result cards. Cards, amounts and editing controls fit the phone sheet at the tested desktop setting. Cropped screenshot evidence: [organized results](2026-10-31-organized-results.png), containing only the prototype panel.

### Static checks

Passed `node --check` for `daybook-flash-assets.js`, `daybook.js`, and `daybook-record-management.js`. Scoped `git diff --check` and local Markdown/HTML asset-link existence checks passed. Changes were compared with pre-task snapshots under `/tmp/wiselife-flash-20261031-before/`; existing unrelated work was preserved. Cache-version strings were updated so Chrome loads the revised script/menu.

### Current limits

No Swift changes, SQLite migration or persistence, live model extraction, audio processing, notifications, EventKit writes, or simulator/device acceptance in this revision. No new full dark-mode, mobile-width, full-localization or runtime-console error audit is claimed. Currency totals are implemented separately; the browser walkthrough exercised CNY expenses only. Waiting/unavailable/empty routes are fixture states. Production idempotency, retry recovery after process restart, currency minor-unit handling and source-deletion behavior still require native implementation and verification. No commit, push or deployment performed.

### 2026-10-31 notebook navigation follow-up

- User refinement: Settings → 数据来源 ends with 记事本; notebook has 我的想法／我的记账. Idea rows show one paragraph and recording time, with thin dividers and no duplicate card title/status/source decoration.
- Verified in native Safari through CUA: settings accessibility state places 记事本 immediately after 原始录音 and before the section footnote. Clicking this entry opens 记事本 with 我的想法 selected; screenshot shows two paragraph/time rows. Keyboard Right switches to 我的记账 with the existing CNY 73.00 expense total, Left returns to ideas. Screenshot: [compact ideas](2026-10-31-notebook-ideas.png).
- Chrome automation timed out or reported concurrent user changes; Safari provided the completed entry and tab-switch verification. Safari's accessibility tree omitted modal descendants, so the rendered list and tab results were checked in screenshots.
- `node --check` passed for the two changed scripts; scoped `git diff --check` passed. This follow-up remains HTML-only. No native build, database or full responsive regression validation performed.

<a id="native-20261031"></a>

## 2026-10-31 native implementation

Scope: [current contract](../../prototype/flash-assets-design.md), [implementation plan](../../docs/superpowers/plans/2026-10-31-flash-notebook-native.md). Earlier HTML-only statements above describe their original verification stage.

### Delivered code

- SQLite `flash_batches` and `flash_assets` with transactional action outbox, optimistic revisions, source snapshots independent of source deletion, integer minor-unit accounting, currency-separated SQL totals, incomplete/revoked exclusions and restoration.
- Structured flash extraction shared by configured providers; quote grounding, explicit-command gate, no guessed times without recording timezone, historical captures do not execute automatically. Remote confirmation is bound to current text/configuration/revision. Completed batches never regenerate after reopening or retranscription.
- Runtime integration for new thought transcripts; iPhone explicit flash entry within voice capture, durable draft kind/timezone, Watch thought origin timezone. Existing ordinary recording processing remains separate.
- Native 整理／全文 details; settings-last notebook, compact paragraph/time idea list, notebook tabs, detail/edit/source/undo/restore, bookkeeping pending filter, My Records shortcuts.

### Automated checks

- `sh scripts/test_flash_capture.sh`: passed. Real SQLite reopen/deduplication, edit conflicts, revocation preservation, atomic rollback, missing bookkeeping fields, separated CNY/USD totals, JPY/KWD scale, negated/reported commands, unknown recording timezone, historical markers.
- `sh scripts/test_actions.sh`: passed existing action parser/persistence regression.
- `sh scripts/test_phone_recording.sh`: passed recording-session regression plus flash mode/timezone after draft reload.
- Simulator XCTest generated by `ruby scripts/test_actions_ios.rb /tmp/wiselife-flash-action-tests`: execution/acknowledgement-loss retry, cancellation, incomplete time, reminder scheduling and busy-outbox coverage. Busy-outbox test first failed with one saved object instead of two; production now waits for ongoing saves before draining. Final result recorded below.
- `ruby Tests/ProjectSourceMembershipSmoke.rb`: passed. Added the new flash files to project and generator; repaired two existing generator omissions (AppleQueryTranslator/DaybookQueryExpansion).
- Scoped `git diff --check`: passed.

### Simulator evidence and limits

Dedicated iPhone 17 Pro, iOS 26.3.1, UDID `D69E30DA-2FDF-478C-B714-D0AE8F58B804`. Fixture tool `Tests/FlashNotebookFixture.swift` accepts only a Simulator container and inserts fictional records, no real audio or system actions. App launched successfully; screenshot shows a flash source with `1 个想法 · 1 笔账目 · 0 项行动`: [native home](2026-10-31-native-home.png). SQLite holds two ideas and two expenses (one incomplete), three completed batches, zero actions; integrity_check returns ok. App was terminated/relaunched to check startup retention.

CUA could not attach to the native Simulator window (`cgWindowNotFound`) even after application relaunch. The image above was obtained through `simctl io screenshot`; **notebook clicks, editing interactions and tab visuals were not manually verified**. XCTest exercises ActionStore with fake system adapters; it does not prove actual EventKit writes or notification delivery. Live model extraction accuracy, live microphone/ASR, Watch transfer and physical-device acceptance remain unverified in this task. No real recording text was sent to any AI provider.

Build commands use `WristNotes.xcworkspace`, scheme `WristNotes`, Debug, destination `332DEB86-4843-4543-8C73-4719B38DA704`, derived data `/tmp/wiselife-publish-20261028/build`, `CODE_SIGN_IDENTITY=- CODE_SIGNING_ALLOWED=YES`. Logs remain in `/tmp/wiselife-flash-build-final.log` and `/tmp/wiselife-flash-action-tests/`; durable conclusions are recorded here. No Git commit/push or TestFlight release.

### Final automated result

Final build reports `BUILD SUCCEEDED`, exit 0; the 6 ActionIntegrationTests report 0 failures, exit 0. Strict App signature verification passed. The final build is update-installed to the original iPhone Simulator `332DEB86-4843-4543-8C73-4719B38DA704`, preserving its data; no synthetic fixtures were inserted there.

Final link audit checked 499 local links across the current product design, implementation plan, index and verification record: zero missing targets. Scoped diff whitespace check passed.


<a id="timeline-20261031"></a>

## 2026-10-31 — Result-first flash timeline prototype

**Scope:** HTML/CSS/JavaScript design review only. This update is not implemented in Swift. Earlier native build/install results above apply to the earlier notebook and flash organization implementation, not this timeline redesign.

Current design: [flash-assets-design.md](../../prototype/flash-assets-design.md#2-信息结构与入口). Review entry: [result timeline](http://127.0.0.1:8778/iphone-day.html?preview=flash-timeline#product). The preview focuses the first structured flash group, with a design explanation alongside the existing phone. “我的记录：查看全部整理结果” exposes all examples, including pending and failure states.

### Changes

- Automatic todos/reminders/calendar events use their actual result title, scheduled date and current execution status as the timeline content. No extra recording-title card for the same source.
- One source group shares a recorded timestamp and one audio/transcript footer. Mixed ideas and expenses remain directly visible and individually clickable.
- Standalone event fixture added; example recording times are staggered so source groups are distinct. All examples remain fictional 2026-10-19 records.
- Timeline/My Records refresh from the same in-memory result objects after completion, edits, cancellation or permission retry. Action-list deletion of an automatic action leaves its cancellation status at the source.
- Result groups do not inherit the source recording’s swipe-delete action; single-item management lives in its detail. Existing raw recordings keep their prior behavior.
- Search includes current organized content and action titles as well as the original transcript. Dates beyond the example year include their year.

### Actual checks

Safari on macOS, local server `127.0.0.1:8778`, via CUA:

1. Opened `preview=flash-timeline`; rendered Watch 15:42 group with todo, reminder, calendar event, idea and expense. Actual result titles and 10月20日 execution dates visible; recording title not repeated in that group.
2. Clicked the todo directly from the timeline; entered its detail with edit, source, undo and complete controls. Marked complete, closed the sheet; timeline visibly changed to “已完成”.
3. Clicked the standalone calendar event; verified 10-20 14:00–14:30. Cancelled it and closed the source sheet; timeline visibly showed “日程 已撤销”. Other actions remained unchanged.
4. Opened My Records; observed “提醒 未安排 … 通知权限未开启”, “提醒 待补充时间 … 尚未安排” and incomplete coffee bookkeeping excluded from accounts.
5. Clicked the 15:42 “原话与录音” footer; observed Apple Watch, 1分18秒, 整理／全文 tabs. Switched to 全文 and verified the original mixed commands remained visible.
6. Reloaded to reset demo mutations and visually checked the final dedicated review layout. Screenshot was inspected in the tool output; no new screenshot file is claimed.

`node --check` for the two changed JavaScript modules and scoped `git diff --check` passed. Final audit checked 500 local documentation links across the design, index and verification record: zero missing targets.

**Limits:** Browser actions only mutate page memory. No real audio playback, extraction, SQLite writes, calendar/reminder/notification APIs or native App behavior were tested in this task. Mobile-width, dark appearance and all-language visual coverage were not repeated. No Git commit, push or release.

<a id="timeline-native-20261031"></a>

## 2026-10-31 — 结果时间轴原生同步

类型：实现与验证记录。用户评审后要求“同步开发代码”；当前分支 `codex/pages-api-base`，基于 `99b203c` 加本机未提交改动。此前原型阶段“尚未实现 Swift”和早期无法操作模拟器的说明保留当时事实，本节记录后续完成情况。[当前设计](../../prototype/flash-assets-design.md)、[同一实施计划](../../docs/superpowers/plans/2026-10-31-flash-notebook-native.md)。

### 实现范围

- 首页、我的记录共用 `FlashTimelineRow`：录制时间为组节点，行动／想法／账目独立点击；行动用实际标题、安排时间、执行状态；每组仅一次“原话与录音”，不重复源录音标题卡。
- `FlashActionDetailView` 供时间轴、整理页和行动详情共用，编辑／补充／重试／撤销／完成状态实时更新。已删除行动从常规列表隐藏，来源组保留墓碑；取消／删除失败不假报成功。
- 从既有 SQLite 整理项和行动读取分组，无新增 schema。当前整理项补充本地字面搜索，不改 Ask AI 或向量索引；不改 Watch 传输和 ASR。
- 验证时发现编辑已完成待办会被通用保存逻辑重置为 active，补回归测试后修复，保留 completed。

### 自动验证

在仓库根目录执行：

```sh
sh apps/wrist-notes/scripts/test_flash_capture.sh
ruby apps/wrist-notes/Tests/ProjectSourceMembershipSmoke.rb
ruby apps/wrist-notes/scripts/test_actions_ios.rb /tmp/wiselife-flash-action-tests
xcodebuild -project /tmp/wiselife-flash-action-tests/Actions.xcodeproj \
  -scheme Actions -destination 'platform=iOS Simulator,id=332DEB86-4843-4543-8C73-4719B38DA704' \
  -derivedDataPath /tmp/wiselife-flash-action-tests/build \
  CODE_SIGN_IDENTITY=- CODE_SIGNING_ALLOWED=YES test
xcodebuild -workspace apps/wrist-notes/WristNotes.xcworkspace \
  -scheme WristNotes -configuration Debug \
  -destination 'platform=iOS Simulator,id=332DEB86-4843-4543-8C73-4719B38DA704' \
  -derivedDataPath /tmp/wiselife-publish-20261028/build \
  CODE_SIGN_IDENTITY=- CODE_SIGNING_ALLOWED=YES build
```

结果：

- 闪念 smoke 通过，覆盖混合结果、来源隔离、编辑后检索、待执行和失败状态不报成功、删除墓碑，以及原有 SQLite／金额／历史／幂等行为。
- ActionIntegrationTests **8 项通过，0 失败**。新增 `testFlashDeletionRemainsInSourceTimelineAfterReopen` 验证删除失败、重试、墓碑重开及不重新创建；`testFlashEditingCompletedTaskKeepsCompletion` 先出现 active 不等于 completed 的失败，修复后通过。
- App 工作区构建 **BUILD SUCCEEDED**，包含 iPhone、Watch 和 Widget targets；项目及生成器 source membership 通过。
- 最终限定改动范围的 `git diff --check` 通过；5 份关联文档的 508 个本地链接检查通过，无缺失目标。
- 最终日志为 `/tmp/wiselife-flash-timeline-edit-green.log`、`/tmp/wiselife-flash-timeline-build-verified.log`；上述命令和结果摘要是长期记录，不依赖临时日志存在。

### 模拟器实际操作

本轮 CUA 能读取并操作 Simulator。当前验证环境显示 **iOS 26.3**，专用设备 WiseLife Notebook Verification（`D69E30DA-2FDF-478C-B714-D0AE8F58B804`）。上节早期记录中的 26.3.1 不作为本轮环境信息。

`Tests/FlashNotebookFixture.swift` 仅向专用模拟器写虚构数据，三类行动为本地模拟成功状态，没有调用真实系统日历或通知。实际操作：

1. 首页直接显示待办、提醒、日程、想法和账目，左侧为录制时间；行内为翌日安排时间，同组没有重复录音标题。
2. 从时间轴打开待办详情并标记完成，首页即时显示“已完成”。完成后编辑为 `WiseLife sketch`，保存仍为“已完成”，原话不被修改。
3. 我的记录显示同样结果组；搜索编辑后才出现的 `sketch` 能找到该组，其他不匹配记录被过滤。
4. 日程详情撤销后，来源时间轴显示“已撤销”；同组其他项目保留各自状态。缺时间提醒和缺金额账目保持“待补充”。
5. “原话与录音”打开原录音详情，保留整理／全文入口。虚构样本没有音频文件，未把导航通过视为音频播放通过。
6. 终止并重新启动 App 后，新标题、“已完成”与“已撤销”均保留；截图视觉检查显示各结果及单一来源页脚：[结果时间轴](2026-10-31-native-result-timeline.png)。
7. 最终构建已覆盖安装并启动到原用户模拟器 `332DEB86-4843-4543-8C73-4719B38DA704`，保留容器数据，未注入测试样本。

过程中曾在构建仍修改产物时安装，导致一次 FBS 启动拒绝；等待构建完成后重新安装、启动成功，最终更新均在构建结束后执行。CUA 的剪贴板还原与模拟器粘贴存在时序差异，最终改用逐键输入并确认字段后保存；未将错误粘贴内容保存为测试结果。

### 边界

真实模型提取、ASR、音频播放、系统 EventKit 写入、通知送达、Watch 文件传输及真机尚未在本轮验证。自动测试使用真实 SQLite 和假的系统执行适配器；模拟器 UI 验证使用虚构记录，不证明真实系统执行。本轮未完成全语言／深色／所有尺寸验收，未提交、推送或发布。


<a id="notebook-four-categories-20261103"></a>

## 2026-11-03 四类记事本可交互原型

类型：产品原型验证记录 · 状态：浏览器主流程已验证，产品待评审，未同步原生 · 更新：2026-11-03。

关联：[当前设计第 10 节](../../prototype/flash-assets-design.md#notebook-four-categories) · [原型](../../prototype/notebook.html) · [索引](../../docs/INDEX.md)。用户授权先制作原型讨论；沿用本记录，不新建原生实施计划。

> 本节初版的地点采集状态与往返规律已被下方“地点简化与按天去重”评审更新替代；保留初版验证作为历史记录。

### 修改范围与运行

- 新增 `prototype/notebook.html`、`notebook.css`、`notebook.js`；主原型 `iphone-day.html` 的闪念设计入口区增加四类记事本链接。既有两类记事本原型和 Swift 行为未替换。
- 本地服务：`python3 -m http.server 8778 --bind 127.0.0.1 --directory apps/wrist-notes/prototype`；入口 `http://127.0.0.1:8778/notebook.html`。hash 可使用 `ideas`、`money`、`people`、`places`。
- 所有数据均为虚构；AI 结果由本页逻辑模拟。状态仅在页面内存，刷新恢复。不读取数据库、通讯录、照片、录音或定位，不产生外部请求或系统权限弹窗。
- 用户关于“无需主动开启”的地点采集措辞待澄清。原型默认展示首次授权后自动低功耗采集，并可切换仅媒体位置方案；这两个选项是设计对照，不是已完成的采集能力。

### 浏览器实际走查

环境：macOS 原生 Google Chrome，通过 CUA 操作可见 UI；窗口截图 2940 × 1750 像素。430 px 标准框与 360 px 窄框为 CSS 宽度，不代表真机测试。

| 操作 | 实际结果 |
| --- | --- |
| 灵感选择两条 → 输入“组合成一个小方案” → 模拟失败 → 重试 | 显示生成中、连接中断、保留选择与方向提示；重试得到三条演示候选 |
| 保存默认第一条候选 | 列表由 5 条变 6 条；新项带 AI 再创作标记，详情包含两个原始灵感入口；原项仍在 |
| 编辑原始灵感正文 | 保存后显示修改后的文字，录下时的原话及 Apple Watch 来源保持不变 |
| 记账筛选收入、切换 10 月／11 月 | 11 月收入 3,600.00；10 月支出 4,624.50、收入 18,500.00、结余 13,875.50 |
| 待补充咖啡补金额 32.50 | 11 月 CNY 支出由 4,429.00 变 4,461.50，结余由 -829.00 变 -861.50，待补充数清零 |
| 切换 USD | 支出 20.00、收入 0.00、结余 -20.00，未与人民币相加 |
| 新增虚构联系人“许知夏”，选择同学＋朋友并自定义跑友 | 保存后关系三项都显示，关联录音数为 0；列表由 4 人变 5 人 |
| 打开林茜 → 产品方向讨论 | 展示明确绑定的发言、日期与 03:20–04:08 时间范围；不播放真实音频 |
| 地点规律 → 查看依据 | 展示 12 天家→公司→家，以及最近 4 个日期的 07:45／09:30／20:10 顺序；未绘制缺失路线 |
| 将未标记地点命名为梧桐咖啡，类型选咖啡馆 | 保存成功，地点仍为 6 次、6 天，列表名称和图标更新 |
| 自动地点说明 → 暂停 → 恢复 | 显示已暂停和恢复入口；返回列表恢复自动记录状态，既有示例记录保留 |
| 空状态 → 切换仅媒体采集方案 | 空状态描述同步切换为录音／照片附带位置；评审栏同步变更 |
| 深色与 360 px 窄屏 | 截图检查字体、四栏标签、地点列表和数量可读，无横向裁切；内容在手机框内滚动 |
| Escape 关闭弹层 | 多次在灵感、人物、地点详情关闭成功 |

桌面手机框高度调整为随视口缩放，完整边框和底部指示条可见。一次原生 AX 索引失效后重新读取状态恢复；没有把失败的工具调用计为验证通过。

### 静态验证与未覆盖范围

- `node --check apps/wrist-notes/prototype/notebook.js`：通过。
- HTTP：HTML／CSS／JS 均返回 200，响应内容与磁盘一致。本地资源、设计／验证／索引的文件链接及新增锚点存在。`git diff --check -- apps/wrist-notes/prototype/iphone-day.html apps/wrist-notes/prototype/flash-assets-design.md apps/wrist-notes/verification/flash-assets-prototype/README.md apps/wrist-notes/docs/INDEX.md` 通过；新原型三文件单独检查无行尾空白。索引重新计数为 210 份文档（另有 1 份 JSON 验证附件），修正了已有总数漂移。
- 未测试真实模型、SQLite 持久化、系统定位授权、后台采集覆盖和耗电、真实联系人绑定／录音播放、原生 App、模拟器或真机交互。尚无完整 VoiceOver、全键盘、Safari、手机浏览器或全页面深色回归验收。
- 合成地点归组仅用于展示，尚未实现真实坐标聚类、归组纠错、合并／拆分、位置权限撤回与删除策略。公司改学校的数据路径已提供，未完成独立学生样例的浏览器走查。
- 无 commit、push、构建、安装或发布。


### 2026-11-03 地点简化与按天去重

用户在原型评审中要求仅保留高频地点，同一地点每天最多计 1 次。已同步[主要说明](../../prototype/flash-assets-design.md#notebook-four-categories)、原型和索引；本段替代初版中地点次数／生活规律／采集状态的现行说明。

- 移除低功耗采集状态、暂停／恢复、采集方案切换、生活节奏与规律依据、时段分布；删除相应演示逻辑及样式。
- 高频地点按近 30 天的地点 ID＋原始本地日期去重后降序排列。详情按天合并，展开保留当天全部来源；不删除原始记录。
- Chrome / CUA 实际刷新后：列表依次为公司 18 次、家 12 次、梧桐路附近 6 次、河畔公园 4 次，显示“近 30 天 · 按天去重”，未出现旧采集状态或规律卡片。
- 点击家：显示总计 12 次、12 个日期；点击 10 月 27 日：保留 07:45 与 20:10 两条录音来源，明确显示当天共计 1 次。已验证跨日分别计数、同日多次合并、各地点独立统计与排序。
- 浏览器截图检查简化列表及名称／地址／次数排版。正常刷新曾命中旧脚本缓存，随后添加 CSS／JS 版本参数，再次正常刷新确认读取新文案和统计。
- 本次只修改原型与文档，未改 Swift／SQLite／真机设置；未构建、安装或发布。未重复验证其他三类全部交互。
- 静态检查：`node --check apps/wrist-notes/prototype/notebook.js` 与文档 scoped `git diff --check` 通过；原型三文件 HTTP 200、服务响应与磁盘一致，无行尾空白；已检查移除的采集／规律文案及逻辑不再存在。


<a id="notebook-native-four-20261103"></a>

## 四类记事本原生实现与验证（2026-11-03）

类型：实现与验证记录 · 状态：代码／自动检查完成，人工原生交互与真实模型未验收。用户在评审原型及设置返回路径后明确要求“开发新的记事本功能”。范围以[产品规则第 10 节](../../prototype/flash-assets-design.md#notebook-four-categories)为准；沿用[同一实施计划](../../docs/superpowers/plans/2026-10-31-flash-notebook-native.md)。最初实现位于 `codex/pages-api-base` 的未提交工作区；该阶段未提交、推送、发布或修改真机数据。后续用户授权 GitHub 推送的隔离分支验证见本节末尾。

### 已实现

四栏 SwiftUI 记事本，设置入口／返回，闪念分类入口及基于持久化来源种类的录音／照片跳转；灵感新增、编辑、多选、真实模型接口、候选草稿及选择另存；月度币种收支与筛选；本地联系人多选／自定义关系和关联发言；高频地点近 30 天、按自然日去重及手动标记。来源列表和汇总后台执行；旧数据增量保留。

### 自动验证

macOS / Xcode / Swift，所有 SQLite 用临时数据库或专用测试模拟器的合成数据。

| 命令 | 结果与覆盖 |
| --- | --- |
| `sh scripts/test_notebook_ledger.sh` | 通过：v1 旧表升级与重开、账目跨月、待补充录制月、撤销排除、多币种、分页、JSON 边界、过期来源拒绝、生成快照、重复采纳、草稿删除不删内容、本地限制跨代传播、取消中的草稿不写入。 |
| `sh scripts/test_notebook_people.sh` | 通过：关系空值／多选／自定义／去重、同名不同 ID、旧联系人、修订冲突、解绑／删来源保留联系人、真实来源及复核状态；含 iOS SwiftUI typecheck。 |
| `sh scripts/test_notebook_places.sh` | 通过：同日多次、A→B→A、跨日／30 天边界、时区稳定、样本及文件证据、名称／计数独立、来源删除、缓存地址精确关联；含 iOS SwiftUI typecheck。 |
| `sh scripts/test_notebook_sources.sh` | 通过：独立 SQLite 查询历史 session／photo 类型，来源删除返回缺失；不依赖最新 50 条的 UI 缓存。 |
| `sh scripts/test_flash_capture.sh` | 通过：既有来源校验、金额精度、编辑冲突、撤销、历史记录和去重回归。 |
| `sh scripts/test_places.sh` | 通过：采集元数据、位置生命周期、照片元数据和地点投影四组件。照片新增原始日与时区保存断言。 |
| `sh scripts/test_speaker_contacts.sh` | 通过：联系人／说话人／声纹 owner 三组件。旧 runner 补全当前真实依赖；payload-only 旧联系人预期改为 needsReview=true，并保留其余字段完整相等比较，符合现有归一化规则。 |

代码复查发现并修复：联系人分页过期请求影响状态；地点漏读独立地址缓存；AI 配置／取消跨 await 的旧请求落库；历史 session 不在 UI 缓存时错误跳转照片。均已定向复查；未声称真实网络 AI 运行已验证。

### 构建与运行

```
xcodebuild -workspace apps/wrist-notes/WristNotes.xcworkspace -scheme WristNotes -configuration Debug -destination 'platform=iOS Simulator,id=3898445B-1B0A-4D10-94DA-FFA88744E5C5' -derivedDataPath /private/tmp/wiselife-notebook-build CODE_SIGN_IDENTITY=- CODE_SIGNING_ALLOWED=YES build
```

结果：`BUILD SUCCEEDED`。专用设备 `WiseLife Notebook Review`（iPhone 17 Pro / iOS 26.3），安装 `cloud.karama.wisenote` 并通过 simctl 启动；launchctl／进程检查确认运行。`Tests/NotebookUIFixture.swift` 只允许该独立模拟器容器，写入虚构灵感、账目、人物、照片位置与合成 AI 候选。合成候选不代表实际模型输出质量。

### 未验证与已知限制

- 当前工具环境未安装 Simulator 图形应用。CUA 获取 `com.apple.iphonesimulator` 返回 Invalid app；尝试 Xcode 官方 Simulator.app 路径返回文件不存在。未进行原生点击／视觉验收，不把构建或进程启动等同于 E2E 通过。
- 真实模型输出、网络异常端到端、真机 ASR／后台位置与用户数据升级未实测；本次未安装真机、未改版本号、未上传 TestFlight。
- 地点使用稳定近似坐标区域分组，边界可能拆分，近邻可能合并；尚无手动合并／拆分。未知历史时区按固定 UTC 日计数并显示依据。未新增后台定位能力。
- 附属表／列迁移保留旧数据，回退保留数据库供旧版忽略；不要清库回退。真实已有数据的升级接受度仍需设备验收。


### GitHub 分支整理与复验（2026-11-03）

用户明确要求“代码推送到 github 分支上”。以已发布的 `origin/dev-card-1103`（`7ed237f`）为基础，在隔离 worktree 整理 `codex/wiselife-notebook`；原 `codex/pages-api-base` 的脏工作区和空暂存区保持原样。

- 范围：四类记事本原生代码、SQLite 增量迁移及测试；已评审的独立／集成 HTML 原型；对应产品说明、数据规则、prompt、实施计划与验证记录。未携带原工作区中其他回顾、录音性能、播放器时间、版本号及 Vessel 后端／Web 改动。
- 在隔离分支重新运行上述 7 个 `test_notebook_*`／既有回归脚本，全部退出 0；包含人物／地点的 iOS SwiftUI typecheck。
- `node --check` 检查 `daybook.js`、`daybook-locales.js`、`daybook-flash-assets.js`、`notebook.js`，全部通过；两个 HTML 的资源路径存在且 ID 无重复；新增文档链接存在。索引保留独立 Huawei 项目的 7 条既有跨项目引用，当前 checkout 不包含这些文件。
- Xcode 核对 12 个 Notebook Swift 文件各有且仅有一个 WristNotes target source entry；完整 Debug iOS Simulator 构建退出 0，结果 `BUILD SUCCEEDED`。构建基于隔离代码，复用本机已锁定 CocoaPods 和 Swift Package 依赖；依赖目录不入提交。

```sh
xcodebuild -workspace apps/wrist-notes/WristNotes.xcworkspace -scheme WristNotes -configuration Debug -destination 'platform=iOS Simulator,id=3898445B-1B0A-4D10-94DA-FFA88744E5C5' -derivedDataPath /private/tmp/wiselife-notebook-publish-build -clonedSourcePackagesDirPath /private/tmp/wiselife-notebook-build/SourcePackages -disableAutomaticPackageResolution CODE_SIGN_IDENTITY=- CODE_SIGNING_ALLOWED=YES build
```

本轮为代码分支交付复验，未重复安装模拟器、未操作真机或发布 TestFlight；原生点击／视觉和真实模型验收边界保持如上。
