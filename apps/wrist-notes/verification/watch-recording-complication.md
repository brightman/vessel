# Watch 表盘快捷录音验证记录

日期：2026-10-22

## 实现范围

- 新增独立 watchOS WidgetKit 扩展 `WiseLifeWatchRecordingWidget`，最低支持 watchOS 10。
- 提供圆形、矩形、内联文字和角落四种布局；可选位置由当前表盘决定。
- 点击通过 `wiselife-watch://record` 打开 Watch App：空闲时启动长录音，已在录音时只返回界面。
- 停止和保存沿用 App 内现有录音按钮。正常从 App 列表进入不会自动录音。
- 启动协调器处理冷启动、重复点击、麦克风授权、前后台切换和请求过期。退出到后台取消待启动请求，旧权限回调不会重新触发它；等待用户授权的时间不计入启动超时。
- 组件是静态快捷入口，不表示实时录音状态。录音仍在手表本地完成，保存和同步沿用现有流程。

## 自动验证

在仓库根目录运行：

```sh
bash apps/wrist-notes/scripts/test_watch_recording_launcher.sh
ruby apps/wrist-notes/Tests/WatchRecordingWidgetProjectSmoke.rb
ruby apps/wrist-notes/Tests/ProjectSourceMembershipSmoke.rb
```

结果：

- 启动协调器 12 个场景通过：前台启动、已在录音、普通启动、非法 URL、冷启动、权限请求去重、拒绝授权、后台取消、请求过期、延迟授权、其他入口已启动录音，以及权限请求期间再次主动点击。
- 现有录音按钮交互 8 个场景通过。
- 扩展目标、源码边界、URL 注册、Watch 嵌入关系和现有工程 source membership 检查通过。
- Ruby 语法、相关 plist 格式及任务文件的 `git diff --check` 通过。
- 新测试经历失败后通过的过程；初始失败日志保存在 `/private/tmp/wiselife-watch-launcher-red.log`，首次通过日志在 `/private/tmp/wiselife-watch-launcher-green.log`。

## 完整构建与产物

环境：Xcode 26.3，Watch Simulator SDK 26.2。

```sh
xcodebuild \
  -workspace apps/wrist-notes/WristNotes.xcworkspace \
  -scheme WristNotes \
  -configuration Debug \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath /private/tmp/wiselife-quick-recording-build \
  CODE_SIGNING_ALLOWED=NO build

python3 apps/wrist-notes/Tests/test_watch_recording_widget_bundle.py \
  /private/tmp/wiselife-quick-recording-build/Build/Products/Debug-iphonesimulator/WiseNote.app
```

构建结果：`BUILD SUCCEEDED`。日志：`/private/tmp/wiselife-watch-complication-build.log`。

构建包含一条 AppIntents 元数据提示：`Metadata extraction skipped. No AppIntents.framework dependency found.` 本入口使用 WidgetKit URL 路由，无 AppIntent。

产物检查通过：

- 扩展位于 `WiseNote.app/Watch/WristNotesWatch.app/PlugIns/WiseLifeWatchRecordingWidget.appex`，没有直接嵌入 iPhone 的 PlugIns。
- Bundle ID 为 `cloud.karama.wisenote.watchkitapp.recording-widget`，版本 `1.0`、构建号 `5` 与 Watch App 一致。
- 扩展点为 `com.apple.widgetkit-extension`，设备族为 Watch（`4`），最低系统版本为 `10.0`。
- 二进制平台为 `WATCHOSSIMULATOR`；arm64、x86_64 的最低版本均为 `10.0`。
- Watch URL scheme、扩展可执行文件以及中文、英文、日文本地化资源存在。
- 既有 Watch App 嵌入检查通过。

## 独立评审

按 `requesting-code-review` 技能安排只读评审。评审检查了启动请求消费、后台取消、已有录音保护、延迟权限回调，以及 watchOS 目标隔离和打包。未发现具体的阻塞或其他级别问题，未修改源码。

## 安装和使用

1. 用 Xcode 打开 `apps/wrist-notes/WristNotes.xcworkspace`，按现有开发者签名配置将更新后的 App 安装到配对 iPhone 和 Watch；以上未签名构建产物仅供编译检查。
2. 确认手表已安装 WiseLife，并打开一次 Watch App。
3. 长按支持复杂功能的表盘 →「编辑」→「复杂功能」→ 选择一个位置 →「WiseLife 录音」。
4. 回到表盘，轻点入口开始录音；首次使用需允许麦克风。
5. 正在录音时再次点击入口，只返回录音页；在 App 内点击停止按钮保存。

## Watch SE 真机验收（待执行）

- [ ] 表盘编辑列表可找到入口，当前表盘支持的布局无裁切；图标颜色随系统表盘样式正常显示。
- [ ] 首次点击进入授权界面；允许后开始一条长录音，拒绝后显示提示且不录音。
- [ ] App 未运行和已在后台两种情况下，点击均能打开并启动录音。
- [ ] 录音期间返回表盘再点击入口，时长继续累计，未停止、重开或新增文件。
- [ ] 权限请求期间退出 App，再授权或普通打开 App，不会触发旧录音请求。
- [ ] 正常从 App 列表打开不自动录音。
- [ ] 录音后灭屏／放下手腕，检查持续录音、系统中断和恢复；停止后可播放完整音频。
- [ ] 检查现有震动反馈、保存和传到 iPhone 的流程。

本次没有执行原生模拟器 UI 自动化，也没有安装到用户真机。上述逻辑测试、编译和产物检查不能证明 Watch SE 上的表盘渲染、实际权限回调顺序、持续录音或 Watch ↔ iPhone 传输已通过。未提交或推送代码。
