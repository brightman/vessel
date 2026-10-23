# WiseLife for Mac

SwiftUI 原生 macOS 客户端。沿用 iPhone「我的一天」的蓝灰配色、卡片和圆角；提供录音列表、全文／说话人时间轴、本机模型总结、原文依据与设备配对。

## 启动

要求 macOS 15+、Xcode 26；iPhone 使用本仓库包含桌面同步功能的新版 App。

```sh
open desktop/WiseLifeDesktop.xcodeproj
# 或在仓库根目录构建本机安装包：
sh desktop/scripts/build.sh
open desktop/dist/WiseLife.app
```

产物为 `desktop/dist/WiseLife.app` 和 `desktop/dist/WiseLife-macOS.zip`。脚本采用本机 ad-hoc 签名；向其他 Mac 正式分发需要开发者自己的 Developer ID 签名和公证。默认不启用 App Sandbox，独立运行本机同步监听器；不需要 Vessel 账号或服务。

工程生成器使用 `xcodeproj` Ruby gem。本机已有 Homebrew Ruby 时：

```sh
/opt/homebrew/opt/ruby/bin/ruby desktop/scripts/generate_project.rb
# 只补齐 iPhone 工程的文件引用，不重建其余配置：
/opt/homebrew/opt/ruby/bin/ruby desktop/scripts/connect_iphone.rb
```

iPhone 原工程生成器也已包含这些共享源码和手机同步文件。没有引入 Flutter 服务层、Vessel API、云存储或新网络依赖包；保留当前 Ring 构建开关。

## 配对及使用

1. Mac 与 iPhone 连接同一局域网，在 Mac WiseLife 左下角打开「同步与配对」。有多块网卡时选择手机能访问的网络。
2. iPhone「设置 → Mac 桌面同步」，扫描 Mac 二维码，或复制／粘贴配对链接，点击「配对并同步录音文字」。两端首次使用时允许局域网权限。
3. 默认同步该手机的全部录音文字与后续变化，可关闭自动同步并使用「立即同步」。Mac 关闭窗口后仍运行，退出 App 或休眠时暂停；手机回到前台后重试。
4. Mac「AI 模型」选择本机模型，填写已启动服务的 Base URL、模型名称和可选 Key，读取模型列表／测试连接后保存。可开启同步完成后自动总结。也可选择「自定义 AI 服务」，填入 DeepSeek 等兼容 HTTPS 接口；此模式逐条确认发送的转写文字，不自动发送。
5. 打开录音，点击「生成总结」。可取消；长文本已成功处理的分段留有检查点。模型输出包含原文编号，点击「回到原文」的依据可定位文字。
6. 手机下次同步时接收结果。旧录音详情、内容片段和完整会话详情均显示「Mac 模型总结」，标明本机／自定义服务与服务地址，与 iPhone 既有总结分别保留。

本机模型兼容服务示例：Ollama 的 `http://127.0.0.1:11434/v1`、llama.cpp 的本机 `/v1` 地址。App 不包含模型权重或推理运行时，需要用户先安装并启动。本机模式只接受 `localhost`、`127.0.0.1`、`::1`；拒绝重定向，不回退云端。没有配置或服务离线时保留原文并提示重试。

自定义服务模式必须使用 HTTPS；Key 保存系统钥匙串。DeepSeek 预设为 `https://api.deepseek.com`、`deepseek-flash`，可读取实际可用模型列表后选择。仅对官方 DeepSeek 主机添加关闭 thinking 的兼容参数，以固定总结输出预算。接口依据 [DeepSeek 官方文档](https://api-docs.deepseek.com/api/create-chat-completion/)。连接测试只发送固定短提示；录音总结逐条显示服务主机、模型和文字发送范围后确认，不开启远端自动总结。

首版只同步文字。桌面时间戳定位原文，不提供音频回听。说话人编号来自手机识别，不推断真实身份，也不发送联系人名称、头像或声纹。

## 数据与协议

- `Shared/`：两端直接编译同一份 Codable 数据协议、日期／指纹规范化、TLS 连接与 Keychain 封装；iPhone 不编译桌面 SQLite 包装器。
- `Sources/Core/`：Mac SQLite 资料库、局域网监听器、证书身份、本机模型适配与长文本总结。
- `Sources/App/`：SwiftUI 窗口、菜单栏、配对、模型设置和详情。
- iPhone 的 `PhoneDesktopSyncRepository` 使用现有 `daybook.sqlite3`，schema v10 加入事务内 dirty 标记、投影、合并后的待发事件、每台 Mac 游标及独立总结表。新增的触发器使用 UPSERT，兼容原领域的 `INSERT OR REPLACE`。
- 一条完整录音对应一条桌面记录：`legacyNote:<UUID>` 或 `session:<UUID>`。新会话从已保存的转写窗口读取原始时间偏移；不重复导出由同一来源派生的内容片段。缺失时间戳保持未知，未结束／未完成转写的来源不能自动总结。
- 投影只含标题、日期、时长、采集设备类别、原文和匿名说话人分段；不含音频、文件路径、设备序列号、健康、位置、联系人或声音档案。
- 首次同步和后续事件复用同一增量日志；每个来源仅保留最新待发状态。SQLite 提交后 Mac 才确认，手机提交确认后才推进游标，重复发送幂等。手机编辑后通过内容指纹使旧总结失效；模型各轮和最终落库均核对当前来源。
- 日期通过整数 Unix 毫秒传输，避免不同平台序列化后内容指纹漂移。原始录音时间偏移仍使用 Double 秒。
- 发现服务为 `_wiselife-sync._tcp`；传输是 TLS 1.2+ 上的长度前缀 JSON，每连接一个请求，消息上限 8 MiB。手机扫描的配对码带证书指纹、5 分钟有效的一次性凭据和连接地址，TLS 校验证书指纹后才发送身份。后续使用独立设备令牌；Mac 数据库只存令牌摘要，证书和手机凭据在系统钥匙串保存。Bonjour 在 IP 变化后重新发现同一 Mac，并继续校验原证书。
- Mac SQLite 位于 `~/Library/Application Support/WiseLifeDesktop/library.sqlite3`，目录权限 0700、数据库 0600，启用 WAL／FULL synchronous／外键。数据库保存本机明文资料，不宣称自带磁盘加密。日志不输出正文、凭据和协议包。
- 手机删除录音后，下一次同步删除 Mac 转写、总结与相关检查点；Mac 离线时无法立即清除，手机显示待同步数量。手机「解除配对并清除 Mac 副本」须连通 Mac；「仅移除本机配对」不会声称已删除离线副本。Mac 可独立移除设备并清除其资料。

## 验证

```sh
# 真正的本机 TLS 通信、两端 SQLite 与确定性本机模型 HTTP fixture：
sh desktop/scripts/test.sh
# 新建临时 iPhone Air 模拟器，调用实际 PhoneDesktopSyncModel，与 Mac fixture 配对及回传：
sh desktop/scripts/test_ios.sh
# 原有存储与内容片段回归：
sh apps/wrist-notes/scripts/test_metadata_sqlite.sh
sh apps/wrist-notes/scripts/test_content_segments.sh
```

集成检查覆盖证书指纹拒绝、一次性配对、设备重启身份、增量和重复发送、匿名说话人／时间轴、总结回传、编辑后拒收旧结果、事务回滚、删除传播、解绑、V2 会话、长文本检查点、模型重定向拒绝与引用范围校验。测试模型是确定性 fixture，用于验证处理流程，不代表真实模型总结质量。

Debug App 支持 `--preview` 使用隔离的内存预览资料，`--snapshot /absolute/path.png` 导出当前窗口预览并退出。Release 不启用这两个入口。真实 iPhone Air 的扫码、局域网权限、不同路由器隔离及实际自建模型的质量／耗时需要实机验收。
