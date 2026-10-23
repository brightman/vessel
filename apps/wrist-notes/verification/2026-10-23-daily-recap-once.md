# 每日回顾：每天仅自动尝试一次

日期：2026-10-23。

## 规则

每个回顾日期只允许一次自动生成尝试。开始尝试后，无论成功、失败、取消、切到后台或进程中断，后续生成均需用户手动触发。新增录音、ASR/分段完成、资料修订、日期切换、重新打开 App 都不会恢复该日期的自动次数。手动生成和更新仍可多次执行。

没有可用文字、外部 AI 尚需发送确认等条件不满足时，不发起自动生成。写入尝试标记失败时不调用 AI，并回滚事务。

## 复现与修复

旧逻辑只看当前模型读到的 `current == nil`。两个页面/模型生命周期同时读取空档案后，可以各自发起一次自动生成。新增测试以两个真实 SQLite 连接和受控的首轮读取，复现重复调用。

现在由 `DaybookRecapStore.beginAttempt` 在短写事务内执行：

1. 检查按 `day` 主键保存的 `daily_recap_attempts`。
2. 自动请求仅在该日期尚未登记时继续。
3. 将日期登记与生成前的档案标记一起提交。
4. 提交成功后才进入 AI 调用流程。

`DaybookRecapModel` 将内部自动入口与用户手动 `generate` 入口分开。手动尝试始终允许，同时登记该日期，避免之后另行自动生成。

自动次数单独保存在 SQLite，不随回顾正文、证据快照或档案行的替换/移除而清除。迁移对已经存在档案的日期保守登记，避免 App 升级重新触发历史日期。

同时修正两条相关读取路径：

- `ContentSegmentSnapshot.read` 的整天转写读取使用 WAL 读事务，避免占用唯一写锁。旧实现的第二条连接状态保存可复现 `SQLITE_BUSY`，修复后通过。
- 回顾读取遇到明确的 `.changed`（读取期间资料版本变化）最多读取 3 次；这只重试读取，不重试 AI。真正的存储失败及取消不进入此重试。
- 日期加载入口将 `ContentSegmentError.staleRevision` 明确映射到上述 `.changed`；真实 SQLite 错误继续传播。

## 验证

| 场景 | 结果 |
| --- | --- |
| 双模型同时读取空档案 | 旧代码触发两次；新代码只调用一次 |
| 档案移除后重新创建模型/连接 | 自动次数仍保留，不自动调用 |
| 已消耗自动次数后手动更新 | 可以生成并保存新回顾 |
| 新资料、失败、中断、重新打开 | 原有自动次数与 consent 回归通过 |
| 尝试标记保存失败 | 事务回滚，不消耗未真正开始的尝试，不调用 AI |
| 旧档案迁移 | 保留正文，不自动生成历史日期 |
| 读取中资料变化 | 一次变化可恢复；持续变化最多 3 次，无 AI 调用 |
| 实际存储错误 | 继续报告，保留原始档案 |
| 日期快照并发写 | 独立状态写入成功；完整片段证据保留 |
| iPhone 签名构建 | `BUILD SUCCEEDED`，退出码 0 |
| 独立代码复核 | 无阻塞问题；复核者独立运行并发与回顾全套测试通过 |

执行命令：

```sh
sh apps/wrist-notes/scripts/test_content_contention.sh
sh apps/wrist-notes/scripts/test_content_segment_presentation.sh
sh apps/wrist-notes/scripts/test_daily_recaps.sh
```

回顾模型测试使用本地 fixture/stub，不向真实 AI 服务发送私人资料。

## iPhone 真机

19:24–19:25 原位安装并启动；补齐日期加载入口的版本冲突映射后，于 19:30 再次构建并原位安装最终版本，CoreDevice 返回 success。均保留原 Bundle ID 和应用数据。

启动后的数据库副本确认：

- `daily-recap-attempts-v1` 迁移完成一次。
- 10 月 22 日已有档案已登记自动次数；档案 payload 与安装前逐字节一致。
- SQLite 完整性检查 `ok`。
- 16 条录音、186,632 条转写和 13,897 条 VAD 数据全部保留，逐行摘要一致。
- 6 小时 42 分录音仍有 26 个有效内容段。

最终版本再次启动后，`daily_recap_attempts` 的日期与首次登记时间完全相同，仍只有 10 月 22 日的一条记录。档案中的证据 `fingerprint/references` 随资料校验更新，`text`、`generatedAt`、`attemptKey` 均未新增，符合不重新发起自动生成的规则。安装前该日期的档案已经没有生成正文；本次没有凭空恢复或自动补跑旧正文。

19:26 首页实际截图显示正在读取每日资料，没有锁库弹窗。19:30 用户切回 10 月 22 日的实际截图同样没有锁库弹窗，但该日期的资料仍在加载。大日期完整读取较慢，尚未完成回顾详情与手动生成的真机交互验收；不能将加载中截图当作完整 UI 验收。

## 本地证据

私有目录：`/Users/karama/Documents/WiseLife-Reports/2026-10-23-device-gps-content-h4mwrnk_/`。

- `wiselife-daily-recap-once-red.log`：旧自动入口重复调用的失败回归。
- `wiselife-daily-recap-read-red.log`：资料版本变化误报存储失败的回归。
- `wiselife-daily-recap-final-green.log`：最终回顾测试。
- `wiselife-sqlite-date-contention-{red,green}.log`：整日读取的锁竞争修复前后。
- `wiselife-sqlite-date-presentation.log`：日期与片段呈现回归。
- `wiselife-sqlite-recap-final-device-build.log`：最终签名真机构建。
- `iphone-recap-final-install.json`、`iphone-recap-final-runtime.log`：最终安装与启动结果。
- `iphone-recap-stable-install.json`、`iphone-recap-stable-runtime.log`：补齐版本冲突映射后的最新安装与启动结果。
- `recap-before-final/Database/`、`recap-after-final/Database/`：真机数据库副本。
- `iphone-recap-final-verification.json`：迁移、自动次数与数据保留核对。
- `recap-after-relaunch/Database/`、`iphone-recap-relaunch-verification.json`：再次启动后次数标记保留与档案变化核对（证据字段更新，不是逐字节相同）。

没有卸载 App、重置数据、清空历史回顾或修改用户 AI 凭据；本次未提交或推送代码。
