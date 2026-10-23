# GPS / 内容分段：真机安装与测试

日期：2026-10-23。软件实现与模拟器验证见 [开发报告](2026-10-23-recording-location-content.md)。

## 当前结论

**整体交付状态：未完成。** Watch GPS 的软件实现与 iPhone 确定性分段已完成，但 Watch 安装/逐片 GPS 实测、真实 AI 主题整理、完整时间轴交互仍未闭环。

**iPhone 已安装并完成启动、数据升级、历史录音自动重新分段验证。随后在真机发现 `database is locked` 状态保存失败，已修复长时间分段占用写锁的问题并原位安装修复版；并发回归和数据保留核对通过，交互回访待确认。详见 [SQLite 并发修复报告](2026-10-23-sqlite-content-contention.md)。Watch 调试连接超时，尚未完成手表安装及 GPS / 边录边传实测。**

后续又修复整日片段读取的写锁问题，并落实每日回顾按日期只自动尝试一次。最新 iPhone 安装与验证见 [每日回顾补充报告](2026-10-23-daily-recap-once.md)；大日期读取较慢、手动生成的真机交互仍未完成验收。

### 19:39 再核对

- 从当前连接的 iPhone 再次导出数据库副本，`quick_check = ok`。
- 6 小时 42 分录音有 26 个有效内容段，18 段有转写；**有标题的片段 0，有摘要的片段 0**。不能把确定性分段完成表述为 AI 整理已跑通。
- `recording_location_samples` 和 `recording_location_addresses` 均为 0；尚无新版逐片 GPS 到达手机的实测证据。
- 当前 Watch 列表仍可显示 `available (paired)`，但 details 明确警告无法建立连接，`tunnelState = disconnected`，只返回缓存信息。不能由该列表状态推断新版已安装。
- 重新运行 `test_recording_locations.sh` 和 `test_content_segments.sh` 均退出 0；此为软件回归，不替代上述硬件/模型验收。
- 已将未完成的真机与模型验收加入原实现计划的 Task 4，保持未勾选。

本次新增私有证据：`gps-delivery-audit/Database/`、`gps-delivery-audit.json`、`copy-gps-delivery-audit.json`；路径根目录同本报告末尾。未更改手机数据库或用户配置。

| 项目 | 结果 |
| --- | --- |
| iPhone 16 Pro / iOS 26.5.2 | USB 已连接、已解锁、开发者模式启用 |
| Apple Watch SE / watchOS 10.6.2 | 系统保留配对信息；Xcode/CoreDevice 调试通道 disconnected |
| 签名真机构建 | `BUILD SUCCEEDED`，进程退出码 0 |
| iPhone 原位安装 | 成功；未卸载 App；`cloud.karama.wisenote`，1.0.1 (6) |
| Watch 包构建 | 成功嵌入 iPhone 包，最低 watchOS 10.0；不等于已安装到手表 |
| iPhone 启动与画面 | 启动成功，截图确认 WiseLife 首页显示；观察期内进程仍在运行 |
| SQLite 升级 | v10 → v12，`PRAGMA quick_check = ok` |
| 历史长录音自动分段 | 通过，详见下方 |
| 分段期间状态保存 | 初版真机出现 SQLite 写锁冲突；修复版已安装，真实双连接回归通过，详见上述报告 |
| 新 GPS 定位、独立位置同步、每 10 分钟采样 | 待 Watch 可调试后测试 |
| 新录音全链路、息屏录音、长时续航 | 未执行 |
| 实际 AI 主题合并与摘要质量 | 未单独验收；本次核对确定性分段结果 |

## 安装前保护

通过 CoreDevice 将 App 的 Documents 和 Application Support 复制到 Mac 私有报告目录；未修改设备数据库或卸载 App。Documents 备份包含 27 个文件，共 242,710,913 字节；SQLite 备份完整性检查通过。未读取或导出 Keychain 凭据。

安装使用已授权的现有签名配置和原 Bundle ID，保留现有数据。没有执行重置、取消配对或删除录音。

## iPhone 上实测的内容派生

安装后由 App 自身运行 SQLite migration、媒体引用更新和分段队列。分别在启动约 30 秒、约 2 分半时复制数据库读取检查：第一次仍是旧片段，第二次已完成新策略派生。确认是首次计算尚未完成，无需修改分段代码。

| 数据 | 安装前 | 安装后 | 校验 |
| --- | ---: | ---: | --- |
| 原语音笔记 | 16 | 16 | 按行流式 SHA-256 完全一致 |
| 原始 ASR 行 | 186,632 | 186,632 | 按行流式 SHA-256 完全一致 |
| 原始 VAD 区间 | 13,897 | 13,897 | 按行流式 SHA-256 完全一致 |
| 已注册音频源 | 4 | 4 | 音频指纹和 ASR 配置一致 |
| 处理任务 | 600 | 600 | ID、配置、状态、active、结果 hash 一致，未重新 ASR |

其中 6 小时 42 分录音由原来 1 段自动更新为 **26 段：18 段有文字，8 段未识别到文字**，采用 `asr-blank-180-chapters-1800-cap-2400-v2`。

逐条检查这份录音的 69,706 条有效转写与片段范围的归属：**0 遗漏、0 重复归属**。这是在手机实际派生结果上的检查，不是再在 Mac 上调用分段算法得到的结果。未将 Mac 实验数据库写回手机。

另外两份有内容的历史录音分别生成 2 段、5 段。旧录音没有新增的按片 GPS，不能由本次更新补出历史轨迹。位置样本/地址表当前均为 0，不能据此声称 GPS 实测已通过。

## Watch 当前阻塞

CoreDevice 两次读取设备详情/文件均未能建立通道；详细信息只返回缓存信息，文件读取失败退出码 1：

```text
com.apple.dt.CoreDeviceError 4000
A connection to this device could not be established.
NSPOSIXErrorDomain 60: Operation timed out
```

Xcode Devices 同样显示 Watch 为 Disconnected。手机 Watch 管理页截图显示 WiseLife 处于安装进度状态；新版 WiseLife 首页仍显示 `Install app`。这不足以确认手表安装成功，因此未宣称已更新 Watch。

已请用户将 Watch 解锁并靠近 iPhone，同时确认当前是否正在录音；截至本次报告尚未收到回复。恢复调试连接后应先检查/保护手表现有录音，再安装新版，进行至少一次跨越 10 分钟边界的采样与边录边传测试。若 Wi-Fi 关闭，可开启并优先连接到 Mac 可访问的同一网络以恢复本次 Xcode 调试；不要把调试通道与 App 日常配对/后台同步状态混为一谈。

## 本地证据

私有目录：`/Users/karama/Documents/WiseLife-Reports/2026-10-23-device-gps-content-h4mwrnk_/`

- `iphone-before/`：安装前备份。
- `iphone-after-1/Database/`、`iphone-after-2/Database/`：安装后只读分析用副本。
- `iphone-verification.json`：完整性、原始数据摘要、音频指纹和真实片段归属结果。
- `iphone-install.json`：CoreDevice 安装成功结果。
- `iphone-runtime.log`、`iphone-process-check.json`：启动与运行中进程证据。
- `iphone-after-launch.png`：实际 iPhone 首页。
- `watch-install-state-before.png`：手机上的 Watch 安装进度画面。
- `device-build.log`：完整签名真机构建日志。

截图、录音和数据库仅保存在上述本地目录，未放入仓库。此次未提交或推送代码。
