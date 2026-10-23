# Watch Recording Complication Plan

**Goal:** 已确认的表盘点击开始／录音中返回交互，运行于 watchOS 10+。

**Architecture:** 静态 WidgetKit URL → Watch App → 带生命周期和权限保护的启动协调器 → 现有 WatchRecorder。iPhone 的录音快捷指令不参与。

**Tech Stack:** Swift、SwiftUI、WidgetKit、AVFAudio、Xcodeproj Ruby。

## Constraints

- 当前分支 codex/pages-api-base 有依赖中的未提交原生功能；沿用当前 checkout 和既有依赖，定向编辑，变更前快照在 /private/tmp/wiselife-watch-complication-before。
- 不重建工程、不操作凭据、不提交／推送；不使用先前被拒绝的原生模拟器 UI 自动化。
- 不降低 iPhone 版本要求，不增加 Watch 手势或 Siri 入口。

## Tasks

- [x] 启动契约与时序：先写 WatchRecordingLauncherSmoke，验证缺少启动行为时失败；实现精确 URL 校验、前台等待、权限去重、后台取消、10 秒超时、已经录音不变更。
  - Sources/WatchRecordingShared/WatchRecordingLink.swift
  - Sources/Watch/WatchRecordingLauncher.swift
  - Tests/WatchRecordingLauncherSmoke.swift
  - scripts/test_watch_recording_launcher.sh
- [x] Widget 与 App 接线：四类表盘布局，widgetURL，App onOpenURL/onChange，URL Types 和本地化资源。
  - Sources/WatchRecordingWidget/{WatchRecordingWidget.swift,Info.plist,Localizable.xcstrings}
  - Sources/Watch/{WristNotesWatchApp.swift,Info.plist}
- [x] 工程集成：新增 watchOS Widget 扩展目标并嵌入 Watch；更新 generate_project.rb、source membership 和 test_local.sh。
- [x] 验证和文档：启动测试、现有触控状态机回归、工程 membership、全工作区 Simulator 构建、产物平台和嵌入检查；按 requesting-code-review 技能做独立代码评审，处理问题后记录真机步骤。

验证结果与待执行的 Watch SE 真机验收见 [表盘录音验证记录](../../../apps/wrist-notes/verification/watch-recording-complication.md)。

## Acceptance

空闲点击启动一条长录音；重复点击与已录音点击不停止／重开；正常打开 App 不自动录音；权限延迟、拒绝、退出不产生隐式录音；所有 Widget 路由落到 Watch App 而不是 iPhone。
