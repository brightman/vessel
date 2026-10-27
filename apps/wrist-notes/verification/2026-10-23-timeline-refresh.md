# 首页与我的记录周期性加载修复

## 原因

`PhoneConnectivity` 每 30 秒调用 `resumeRecordingInbox()`，保证持久化回执可以补发。`RecordingChunkReceiver.drainLocked()` 原先每次成功打开仓库就发出 `didChange`，即使收件箱为空，也没有发生恢复或导入。

`ContentSegmentModel` 收到该通知后会增加版本、取消当前读取并重新查询当天内容、录音库与月份；每次都设置 `loading = true`。首页与“我的记录”分别把同一状态显示为“正在读取内容片段…”和“正在读取完整日期资料”。后台 ASR/分段通知也使用这条路径。因此，已经加载好的日期会反复出现加载动画，并产生无效数据库读取。

## 修改

- 保留 30 秒回执补发与同步健康回调；空队列检查不再发送内容变化通知。新文件、结束标记、位置导入仍通知。仓库恢复的实际新增提交和完成文件清理通过可消费标记通知一次。
- 区分首次日期读取 `loading` 与后台读取 `refreshing`。已有日期（包括空日期）后台更新保留当前列表；只有首次进入尚未读取的日期显示加载提示。
- 单个读取任务合并连续通知，最多保留一个后续刷新请求。请求标记阻止旧日期结果覆盖新选择。
- 同一日期/月重复选择不重读；数据相同时不重复发布记录。列表分页仍在读取期间禁用重复加载。
- 保留删除墓碑过滤、来源版本校验及 AI 所需完整日期读取。此次没有修改分段策略或每日回顾自动生成规则。

## 验证

先复现失败，再验证修复：

- 传输测试旧代码失败：`empty receipt retries must not invalidate timeline content`。
- 日期读取测试旧代码失败：`background refresh must not show a first-load spinner`。
- `test_recording_transfer.sh` 通过：20 次空队列检查不发内容变化通知，仍发布同步健康；实际文件和结束标记通知保留，原有确认/重试覆盖通过。
- `test_content_refresh.sh` 通过：真实 `ContentSegmentModel` 与 SQLite；仅替换 UIKit/推理入口。覆盖已有/空日期静默更新、首次日期加载、重复选择、20 次通知合并、无变化不发布、跨日期读取竞争和完整证据读取。
- `test_recording_repository.sh` 通过：提交/发布/回收中断恢复，新增恢复仅通知一次，清理状态变化仍可通知。
- `test_streaming_recording.sh` 通过：600 秒文件结束前接收与处理、回执、重复传输、重开、最终短尾与跨文件静音分段。
- `WristNotes.xcworkspace` / `WristNotes` / Debug / `WISELIFE_CONTENT_LAB` 模拟器构建成功，退出码 0。

日志位于 `/private/tmp/wiselife-empty-retry-{red,green}.log`、`wiselife-content-refresh-{red,green}.log`、`wiselife-recovery-change-test.log`、`wiselife-streaming-refresh-test.log`、`wiselife-timeline-refresh-build.log`。

## 安装与限制

已安装并启动于已有 **WiseLife Content Lab** 模拟器（`012F6CC3-6B1C-4D05-A9FC-2E729A8E30E5`）。安装前备份 SQLite；安装后核对全部 31 个片段的 ID、标题、摘要、版本与定稿状态一致，时间轴仍为 19 条有效记录、69,706 条缓存转写。原始录音 SHA-256 未变。真机未更新。

CUA 仍返回 `Sky Computer Use native pipe startup failed`，不能声称已连续观察真实界面不再出现加载提示。上述运行验证来自真实读取模型、SQLite 和传输链路的回归测试。
