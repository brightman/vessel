# 长录音分段引发 SQLite 写锁：修复与真机验证

日期：2026-10-23。

后续真机回访又发现整日读取也占用写锁；最终版已一并修复并重新安装，另加每日回顾的按日期持久化自动次数限制。最终结果见 [每日回顾与整日读取补充报告](2026-10-23-daily-recap-once.md)。下文 19:14–19:15 的安装与核对属于第一轮修复。

## 问题与根因

实际 iPhone 截图确认，10 月 22 日首页出现：

```text
状态未保存：本机数据库错误（5）：database is locked
```

`ContentSegmentRepository.reconcile` 原先将整个分段派生包在 `BEGIN IMMEDIATE` 中。多小时录音的转写/VAD 扫描、内容签名计算和分章计算持续占用 SQLite 唯一写锁；`LifeSourceModel` 保存地点/数据源状态时，另一条连接等待超过 5 秒而失败。WAL 允许读写并行，但不能让两个写事务同时执行。

用两个真实 SQLite WAL 连接复现：在生产分段代码读取转写行时，第二条连接保存独立状态，旧实现返回 `SQLITE_BUSY`（5）。测试将第二条连接的 busy timeout 设为 0，确保验证的是写锁释放，而不是延长等待。

## 修复

- `DaybookDatabase.readTransaction` 使用 `BEGIN DEFERRED`，提供一致的 WAL 读取快照。
- 后续发现 `ContentSegmentSnapshot.read` 也使用写事务读取整日转写，最终版同样改为读事务，并新增该路径的真实双连接回归。
- 分段扫描、签名和分章计算在读取快照内完成，随后释放快照。
- 写入前用短事务重新校验音频源、处理 revision 和完整分段源状态行；匹配后原子保存片段、删除标记、派生状态与编辑历史。
- 若计算期间其他连接修改了音频源、手工片段或摘要状态，抛出 `staleRevision`，由处理队列重新派生；不会覆盖并发编辑，也不会误报为存储不可用。
- 保留原有忙等待、算法版本、ASR 结果和缓存。不通过清空数据库、删除录音或重跑 ASR 解决问题。

## 软件验证

| 验证 | 结果 |
| --- | --- |
| 修复前并发回归 | 复现 `database is locked` |
| `scripts/test_content_contention.sh` | 通过：派生时独立状态可写；源变化拒绝旧结果；并发手工拆分保留 |
| `scripts/test_content_segments.sh` | 通过：分段、范围、手工操作、撤销等回归 |
| `scripts/test_content_enrichment.sh` | 通过：主题/摘要、检查点、过期响应等回归 |
| `scripts/test_audio_relocation.sh` | 通过：媒体迁移、稳定身份与检查点保留 |
| iPhone 签名构建 | `BUILD SUCCEEDED`，退出码 0 |
| 独立代码复核 | 未发现阻塞问题；复核者再次运行并发回归通过 |

构建使用 `WristNotes.xcworkspace`、`WristNotes` scheme、Debug 和已连接的 iPhone 真机目标。

## 真机安装与数据核对

iPhone 16 Pro / iOS 26.5.2 于 19:14 原位安装修复版，Bundle ID 保持 `cloud.karama.wisenote`，版本仍为 1.0.1 (6)。CoreDevice 安装结果为 success。19:15 启动成功，实际首页截图没有锁库弹窗，后续进程检查确认主进程仍在运行。

安装前后分别复制数据库到 Mac 私有目录，只对副本执行查询。没有将 Mac 数据库写回手机。

| 数据 | 安装前 → 安装后 | 校验 |
| --- | --- | --- |
| SQLite | v12 → v12 | 两份副本 `PRAGMA quick_check = ok` |
| 语音笔记 | 16 → 16 | 全行摘要一致 |
| 原始转写行 | 186,632 → 186,632 | 全行摘要一致 |
| 原始 VAD 区间 | 13,897 → 13,897 | 全行摘要一致 |
| 处理任务结果 | 600 → 600 | 配置、状态、active、result、result hash 一致 |
| 已注册音频源 | 4 → 4 | 音频指纹与配置一致 |
| 分段范围 | 39 → 39 | 片段 ID、顺序、起止时间一致 |
| 内容片段 payload | 39 → 39 | 除容器路径和源 revision 外全部相同，标题/摘要保留 |
| 分段源检查点 | 4 → 4 | 全行一致 |

6 小时 42 分录音仍为 **26 个有效内容段：18 段有文字，8 段无文字**。

### 测试边界

本次真机启动复用了已完成的分段缓存，不能单凭没有弹窗宣称已在真机再次覆盖长时间派生并发场景；该竞争由真实 SQLite 双连接回归验证。已请用户切回 10 月 22 日并进入长录音，交互回访结果待确认。没有通过重置手机分段缓存来强行复现。

Watch 仍显示调试通道不可用，因此此次安装结果只适用于 iPhone；新 GPS 采样和 Watch 边录边传的硬件验收仍待连接恢复。

## 私有证据

本地目录：`/Users/karama/Documents/WiseLife-Reports/2026-10-23-device-gps-content-h4mwrnk_/`。

- `iphone-database-locked.png`：修复前实际错误截图。
- `iphone-lock-fix-home.png`：修复后实际首页截图。
- `lock-before-fix/Database/`、`lock-after-fix/Database/`：数据库副本。
- `iphone-lock-fix-verification.json`：安装、完整性、数据保留及进程核对结果。
- `iphone-lock-fix-install.json`、`iphone-lock-fix-runtime.log`、`iphone-lock-fix-process-check.json`：设备结果。
- `wiselife-content-contention-red.log`、`wiselife-content-contention-green.log`：并发回归修复前后证据。
- `wiselife-sqlite-lock-{segments,enrichment,relocation,device-build}.log`：其余测试与构建结果。

原始录音、截图、数据库和转写内容未加入仓库；此次未提交或推送。
