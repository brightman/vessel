# iPhone 设置与 AI 总结实施计划

**Goal:** 按 `prototype/iphone-notes.html` 增加手表状态、设置及可用的自定义模型总结。

**Architecture:** 复用现有 WCSession，只增加状态观察；普通配置存 UserDefaults，Key 单独存 Keychain。总结按已保存配置选择 Apple Foundation Models 或直接请求用户指定的 Chat Completions 服务。设置草稿与已保存配置隔离。

**Tech Stack:** SwiftUI、Combine、Foundation URLSession、Security、WatchConnectivity。

## 约束

- iOS 26 / watchOS 10；保留已有传输、ASR、签名和工程配置。
- 默认本地；自定义连接测试只发固定文本，总结只发所选全文，不发音频。
- 自定义配置测试成功才可保存；修改配置或返回使在途测试失效。
- Whisper 尚无运行时，本次显示未接入，不提供无效的可选项。
- 不读取真实凭据，不在日志输出 Key、请求正文或服务错误正文。

## 实施与检查

- [x] 配置与请求：新增 `AIConfiguration.swift`、`CustomAISummarizer.swift`、`AppSettings.swift`、`KeychainSecretStore.swift`。先在 `Tests/AISettingsSmoke.swift` 验证地址约束、请求响应、错误、分段无截断与持久化。
- [x] 交互状态：新增 `AISettingsModel.swift` 和 `PhoneWatchStatus.swift`；测试保存门槛、修改后失效、过期测试结果、Watch 状态映射。
- [x] 接入：修改 `NotesModel.swift` 的总结路由及 `PhoneConnectivity.swift` 状态回调；保留现有文件传输实现。
- [x] UI：新增 `SettingsViews.swift`，更新 `NotesListView.swift`、`NotesStyle.swift`、`NoteDetailView.swift`、`WristNotesApp.swift`。包含外观、转写语言、导入、AI 配置与真实测试状态。
- [x] 工程与验证：增量添加 source membership；运行 `scripts/test_local.sh`、模拟器和未签名真机构建、嵌入检查；隔离预览核对新页面。
- [x] 文档：记录实测结果与真实服务/真机尚未验证范围。用户已反馈传输、真机 ASR 通过。
