# Watch 表盘快捷录音

用户已确认：开发表盘复杂功能入口，而不是 App 列表图标。点击未录音的入口打开 WiseLife 并开始长录音；正在录音时只返回录音页，由现有停止按钮结束并保存。

## 范围

- 新增 watchOS 10+ WidgetKit 扩展，圆形、矩形、内联文字、角落四种 accessory family。
- 静态麦克风图标表示“快捷录音入口”，不伪装成实时录音指示器；支持表盘主题着色和 VoiceOver。
- widgetURL 使用独立的 `wiselife-watch://record`，由 Watch App 接收。仅此精确路由可启动，不复用手机录音 Intent。
- Widget 无麦克风操作、状态写入或网络。Watch App 在前台启动现有长录音，继续使用原来的本地保存与 WatchConnectivity 传输。
- 首次授权等待系统弹窗；授权拒绝显示录音页错误。重复点击、已在录音、权限处理中均不能创建多个录音。
- 在系统授权弹窗引起的 inactive 期间暂存请求；进入 background 取消。其他未就绪请求 10 秒过期；授权完成后最多等待 10 秒前台激活，过期提示重新点击。
- 正常从 App 列表打开不录音；退出、落腕、再次进入不重放已消费的请求。外部入口从不调用 stop。

## 工程

独立 Sources/WatchRecordingShared 保存 URL 契约；Sources/WatchRecordingWidget 保存静态 UI；Sources/Watch/WatchRecordingLauncher.swift 管理前台／权限时序。SwiftUI App 持有唯一 recorder 和 launcher。

新扩展嵌入 Watch App 的 PlugIns，Watch App 仍嵌入 iPhone App 的 Watch 目录。保持 watchOS 10 deployment target、当前签名团队、构建版本；定向修改当前 Xcode 工程，同时更新生成器，不重建整个脏工程。

## 验证

测试真实启动协调器，替换系统权限回调和麦克风启动边界：冷启动、前台、重复点击、已录音、拒绝、授权 inactive、进入后台取消、超时、异常 URL、旧回调与新请求。

构建完整 iPhone/Watch/两类 Widget；检查嵌入层级、bundle ID、平台和版本。真机添加表盘、麦克风授权、声音／震动与离线保存须单列验收，不以模拟器编译代替。
