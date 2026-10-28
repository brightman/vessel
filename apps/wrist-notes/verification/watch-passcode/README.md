# Watch 两页界面与 App 密码

2026-10-27，版本 1.0.1（7）。

## 实现

- Watch 使用原生垂直分页，首页保留轻点录音、按住闪念和上滑取消；快速上滑或底部入口进入列表。原生品牌螺旋的金色光带以 15fps 流动，后台、熄屏、非当前页和减少动态效果时暂停。
- 列表合并旧单文件录音与分段长录音，按 session 统计而非按 chunk 计数，今日口径为本地日历下录音开始日期。时长使用 `mm:ss` / `hh:mm:ss`，防止小屏截断。
- 状态依据 WatchConnectivity 实际队列、传输进度和手机保存回执。传输完成不直接等同已同步。删除需要确认且拒绝活动 session；持久删除标记阻止迟到的 GPS、封段与结束回调重新生成记录。
- iPhone 首次六位密码设置可跳过，设置页可设密、改密和启用生物识别。PIN 使用独立随机盐、PBKDF2-HMAC-SHA256 与本设备 Keychain 保存，验证及持久等待在 actor 中执行。Face ID 不回退到设备锁屏密码；登记状态变化后关闭生物识别并要求 App PIN。
- 独立窗口覆盖原有 sheet 与全屏页面；应用后台后验证回调不能延迟解锁。页面下方录音和同步服务不因界面锁定而销毁。

## 已完成验证

- `sh scripts/test_app_passcode.sh`：六位校验、随机盐、摘要存储、初次设置不可覆盖、重启等待、密码修改、错误存储与损坏配置、跳过、后台认证竞态及凭据丢失。
- Watch library：跨日统计、旧记录与 session 合并、chunk 去重、活动时长避免重复、首段前活动记录和紧凑时长格式。
- `sh scripts/test_watch_recording_sessions.sh`：session 删除、迟到封段/结束/定位拒绝及重启持久化。
- `sh scripts/test_recording_transfer.sh`：分段采集与传输回归。
- `RecordingButtonInteractionSmoke.swift`：原有八种录音手势场景。
- Ruby Watch UI、工程源文件成员及安装配置校验。需使用已安装 `xcodeproj` 的 Homebrew Ruby。
- Debug 模拟器及 Release 真机架构（关闭签名）构建通过。独立 UI review 副本使用临时 Bundle ID、内存凭据和合成记录，不包含于正式构建；已检查 44mm Watch 首页、列表、录音态和 iPhone 设置/解锁/遮罩。截图与录音动画位于被 Git 忽略的 `build/ui-review-20261027/`。

## 复现预览

运行 `python3 scripts/prepare_watch_passcode_preview.py` 创建独立副本。构建其输出的 workspace，模拟器通过 `--preview-screen` 选择 `watch-home`、`watch-recording`、`watch-list`、`onboarding`、`unlock`、`settings`、`change` 或 `privacy`。预览使用合成数据，勿作为真机签名源。

## 真机验收边界

模拟器检查不代表已完成实体 Face ID、麦克风授权、离线重连、Watch 左划触感或长时电量验收。真实 App 密码由用户在设备上设置，本次不为用户预设 PIN。

签名使用原项目 Bundle ID、此前指定的 Team，更新版本为 1.0.1（7）。2026-10-28 已完成四个组件签名与安装配置校验，iPhone Air 与 Apple Watch Series 12 均已更新并启动 1.0.1（7），安装后的 Bundle Version 已通过 devicectl 复查。手表曾出现 CoreDeviceError 4000 / RemotePairingError 1001；用户唤醒手表并检查网络后恢复连接并完成安装。
