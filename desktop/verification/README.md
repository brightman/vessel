# Desktop integration verification

在 `dev-desktop` 分支完成，未提交或推送。桌面为 SwiftUI 原生 App，手机继续使用原生录音与本地转写。

已通过：

- macOS Debug／Release 构建，Release 产物包含 arm64 与 x86_64；`codesign --verify --deep --strict` 通过。
- 实际启动 Release App，本机同步 TLS 监听器已就绪。
- `desktop/scripts/test.sh`：真实本机 TLS 连接、证书指纹拒绝、一次性配对、匿名说话人／时间轴、重复请求、游标与持久化、手机与 Mac 总结往返、原文修改后旧结果拒收、删除传播、解除配对重试与凭据撤销、V2 会话、整数毫秒日期序列化指纹稳定、长文本分段检查点、引用校验、模型重定向拒绝、本机／HTTPS 模式地址约束。
- `desktop/scripts/test_ios.sh`：新建独立 iPhone Air（iOS 26.3）模拟器，使用实际 `PhoneDesktopSyncModel`、系统 Keychain 与证书固定的 TLS 通信，完成配对、文字同步、总结回传与解除配对。测试后清理临时模拟器和凭据。模拟器需 ad-hoc 签名，不能关闭签名后验证 Keychain。
- 原有 `test_metadata_sqlite.sh`：迁移、回滚、重试、旧实例、媒体删除标记等回归。
- 原有 `test_content_segments.sh`：分片、合并、删除、撤销、覆盖范围、重试、分页与源删除回归。同步触发器使用 `ON CONFLICT DO NOTHING`，不会与原业务的 `INSERT OR REPLACE` 冲突。
- 按用户本次授权，使用隐藏的 TTY 输入做 DeepSeek 实际接口测试：模型列表成功、连接测试成功、`deepseek-flash` 合成会议总结成功，引用和来源指纹保存成功。只使用合成材料，未读取真实录音／转写；Key 未保存到源文件、命令参数、测试日志或持久配置。
- `git diff --check` 与构建脚本语法检查通过。

桌面窗口预览见 [desktop-preview.png](desktop-preview.png)。图中为 Debug 隔离预览资料，不代表用户的真实录音。

待真机验收：iPhone Air 当前开发连接不可用，尚未向真机安装本次新版。真实相机扫码、局域网权限、路由器客户端隔离与 IP 变化需要实机检查。本机模型运行时尚未配置；本机模型接口流程用确定性 fixture 验证，实际模型速度与总结质量待选定模型后确认。Mac 包采用本机 ad-hoc 签名，未做 Developer ID 公证。
