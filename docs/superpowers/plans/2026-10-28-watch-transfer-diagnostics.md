# Watch 与 iPhone 整文件传输清理计划

> 按确认后的 [设计规格](../specs/2026-10-28-watch-transfer-diagnostics-design.md) 实施。

## 范围

- Watch 已封存的每个 M4A 通过 WatchConnectivity `transferFile` 整体发送。
- iPhone 持久保存后通过 `transferUserInfo` 回传单文件确认。
- 删除旧 `RecordingV2` 网络分片队列、接收器、能力协商、回执、结束/撤回协议及状态数据库投影。
- 保留本机录音的小时文件存储、文件描述、内容分析、连续文件主题关联和必要的文件级诊断。
- 模拟器与真机使用相同整文件路径；不保留消息分块测试通道。

## 已实施

- [x] 双端诊断 UI 使用单文件状态、短 ID 和最近 20 条事件。
- [x] iPhone 收件箱检查平面 M4A 与配套 JSON 元数据。
- [x] 从 Xcode 工程与生成器移除 V2 Watch 队列、iPhone 收件器和旧 Watch 会话存储。
- [x] 移除旧 V2 握手、wire envelope、能力协商、分片回执、取消/撤回模型、快照和 SQLite 投影。
- [x] 将仍使用的本地小时录音文件限制/元数据与传输协议区分命名。
- [x] 清除只服务于旧 V2 传输的脚本与过期 smoke fixture；其余脚本不再引用已删除源文件。
- [x] 保存确认统一经 `transferUserInfo`，音频文件只经 `transferFile`。
- [x] 执行 Swift 语法解析、Ruby/Shell 语法检查和 `git diff --check`；旧 V2 标识符扫描无残留。
- [x] Xcode iOS 模拟器构建成功并覆盖安装到配对的 iPhone 和 Watch 模拟器；Watch 短录音可封存。
- [ ] 真机验收文件传输和回执：Apple 模拟器不支持 `transferFile` 和 `transferUserInfo`。
- [ ] 更新本机录音存储测试：旧 `RecordingSessionRepositorySmoke` 仍调用已删除的 V2 导入及回执接口，当前无法编译。
- [x] 使用连续合成音频跨越 1 小时验证两个独立文件、有效帧数、文件名、M4A 元数据、本地持久化、重开和删除。修复了删除时仍按旧文件名校验的问题。
- [ ] 补齐录音组结束判定：当前 `AudioProcessingModel` 对已收到的录音组固定设置 `complete: true`，没有可靠的最后文件标记，不能保证尾部话题等到下一文件才定稿。

## 隐私边界

不在日志/UI 中显示音频、转写、完整录音 UUID、文件系统路径或坐标。短 ID 为 UUID 前 8 位。
