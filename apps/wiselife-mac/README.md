# WiseLife Mac Companion

按 `2026-10-23-wiselife-mac-mlx-companion-design.md` 实现的独立原生 macOS 本地 AI 伴侣。与仓库原有 `desktop/` 录音同步客户端使用不同工程、Bundle ID、存储目录、钥匙串服务及 Bonjour 服务；不修改 iOS／Watch 工程。

## 构建与启动

开发要求：Apple silicon、macOS 15+、Xcode 26.3／Swift 6.2。此最低版本是本次构建配置，产品支持范围仍需 M3 Air 验收。

```sh
cd apps/wiselife-mac
open WiseLifeMac.xcodeproj
# 或构建本机 ad-hoc 签名 App 和 zip：
sh scripts/build.sh
open dist/WiseLifeCompanion.app
```

首次构建需联网获取 Swift 包与 MLX 的源代码子模块。若 `xcrun metal --version` 提示缺少工具链，先执行 `xcodebuild -downloadComponent MetalToolchain`。必须使用 Xcode 构建推理程序，`swift build` 不会编译 MLX Metal shaders。

App 默认启用 App Sandbox、Hardened Runtime，以及网络 client/server 权限。初次启动不下载模型，不启动局域网监听器。服务处于暂停状态时，模型库和下载不访问配对钥匙串；进入设备页、配对或开启服务时才异步读取配对凭据，避免本地签名变更后的系统授权阻塞主界面。正式分发需要自己的 Developer ID 签名和公证；脚本的 ad-hoc 签名仅用于本机验证。

工程可通过 Homebrew Ruby 与 `xcodeproj` gem 重新生成：

```sh
/opt/homebrew/opt/ruby/bin/ruby scripts/generate_project.rb
```

## 使用

1. 打开「模型库」，App 会读取本机芯片与物理统一内存，在固定模型目录中推荐适配项。模型卡片直接显示来源、许可证、下载大小与建议内存；点击「下载模型」立即从 Hugging Face 下载，不再出现额外确认弹窗。来源与固定 revision 可在卡片展开查看。
2. 下载后点击「加载模型」。加载前再次验证全部文件的大小与 SHA-256；模型切换前卸载旧模型，同时只保留一个模型。
3. 开启「为配对的 iPhone 提供本地 AI」，并选择「配对 iPhone」。二维码含服务身份、证书 SHA-256 指纹、256-bit 一次性秘密与 2 分钟有效期，不含地址或长期令牌。
4. 在 iPhone 构建 6 或之后版本打开「设置 → AI 模型 → 附近的 Mac」，扫描并确认使用这台 Mac。手机已接入 `nearbyMac` 路由、扫码、NWBrowser 与证书 pinning。配对后，总结、标题与问答使用这台 Mac 当前加载的模型，保留手机端发送授权。实机验收状态见 [接入验证](../wrist-notes/verification/nearby-mac-integration-2026-10-24.md)。
5. 关闭窗口后可通过菜单栏继续控制服务。可暂停服务、取消生成、卸载模型、撤销设备。睡眠会停服并卸载；唤醒后按用户的服务开关重新发布，但不会自动重新加载模型。

网络绑定当前选择的 RFC1918／IPv4 link-local 本机接口，不接受通配或公网绑定；网络地址变化后重新绑定，Bonjour 仅发布版本与 opaque ID。IPv6-only LAN、热点客户端隔离、真实 iPhone 权限弹窗仍需兼容性验收。

## 浅灰界面与内存推荐（0.2.0）

桌面端沿用 iPhone `NotesStyle` / `DaybookStyle` 的浅灰背景（`#f5f5f7`）、白色卡片、蓝灰文字和操作色（`#335f83`），使用统一的 18pt 卡片圆角与分组样式。

| 本机配置 | 当前目录内的保守推荐 |
| --- | --- |
| Apple silicon，8–12 GB | Qwen3-1.7B-4bit，轻量方案 |
| Apple silicon，16 GB 或以上 | Qwen3-4B-4bit，保留 1.7B 轻量选择 |
| 不足 8 GB 或非 Apple silicon | 不推荐内置模型，下载按钮不可用 |

推荐只根据总物理内存与固定模型目录，不代表空闲内存测量或硬件性能验收。系统压力偏高时显示关闭其他应用／选择轻量模型的建议，不静默改变用户已选择的模型。当前开发机读取结果为 Apple M4／16 GB，推荐 4B Q4。

点击下载后显示已下载／总大小、百分比、网络速度、文件校验阶段和取消按钮。只有全部文件校验并完成原子安装后才显示成功和「加载模型」；网络失败或取消可重新下载，取消后的临时文件会清理。完成下载不会自动加载或启动服务。

## 结构

- `Sources/CompanionCore/`：模型目录与文件完整性、分阶段下载、Keychain、TLS identity、配对、串行推理调度、OpenAI 兼容 API、NIO HTTPS 与 Bonjour。
- `Sources/CompanionMLX/`：固定版本 `mlx-swift-lm` 的本机目录加载、完整 prompt tokenization、单次独立 KV cache、GPU 同步与取消。
- `Sources/WiseLifeCompanion/`：SwiftUI 设置窗口与菜单栏；概览、模型库、设备和隐私说明。
- `Sources/CompanionBenchmark/`：显式运行的合成中文任务及 Metal 检查，不会静默下载权重。
- `Tests/CompanionCoreTests/`：不依赖模型权重的可重复测试，包含真实本机 TLS 通信。

Swift 包固定为 MLX `0.29.1`、mlx-swift-lm `2.29.3`、SwiftNIO `2.104.0`、NIOSSL `2.37.5`、Swift Certificates `1.19.3`。完整传递依赖与 commit 见 `Package.resolved` 和工程 workspace 内的副本。版本选择基于当前 Xcode 构建兼容性；没有采用需要更新工具链的最新 MLX 包。

模型 pins 与文件校验值见 `Sources/CompanionCore/ModelCatalog.json`。维护者仅在审核上游 license／兼容性后运行 `python3 scripts/pin_catalog.py` 更新；该脚本只下载元数据与少量配置，不下载权重。模型仓库声明 Apache-2.0，App 包含第三方许可证，下载保留固定版本模型卡。

## 协议 v1

所有接口仅通过 TLS 1.2+。客户端发现 `_wiselife-llm._tcp`，匹配 QR 的 service ID，先验证服务器叶证书 DER 的 SHA-256 指纹，之后才发送配对秘密或 bearer token。不得信任任意本地证书、使用全局 ATS 例外、跟随重定向或把 token 放入 URL。

QR 格式：`wiselife-mac://pair?v=1&service=<opaque-id>&fingerprint=<sha256>&nonce=<base64url>&expires=<unix-seconds>`。这仅是协议说明，真实配对码不写入日志。

| 接口 | 授权 | 返回／用途 |
| --- | --- | --- |
| `GET /health` | 无 | 版本、模型状态、活跃与等待数量、服务开关；不返回设备资料 |
| `POST /pair` | 未过期一次性 nonce | JSON `nonce`、`device_id`（UUID）、`device_name`；返回 `token`、`service_id`、`device_id`、`protocol_version` |
| `DELETE /pair` | `Authorization: Bearer …` | 撤销当前设备并取消其工作；手机需删除自身 Keychain 项 |
| `GET /v1/models` | 已配对且服务开启 | 当前选中模型及 `ready`；手机使用返回的 ID |
| `POST /v1/chat/completions` | 已配对且服务开启、模型就绪 | 一条 system + 一条 user 字符串消息、`stream: false`；OpenAI `choices[0].message.content` 响应 |

生成只接受 `model`、`messages`、`stream`、`max_tokens`、`temperature`。不接受额外消息字段、图像、音频、tools、流式请求或其他生成设置。temperature 为 0–1；正整数 max_tokens 被钳制至 2,048；输入模板化后的 token 数与输出预算合计不超过 8,192，超限显式拒绝，不截断。

| HTTP | 稳定错误码示例 |
| --- | --- |
| 400 | `invalid_request`、`unsupported_stream`、`context_length_exceeded` |
| 401 | `unauthorized`、`invalid_pairing_code` |
| 404 | `unknown_model`、`not_found` |
| 409 | `cancelled` |
| 413 / 415 | `body_too_large`、`unsupported_media_type` |
| 429 | `queue_full`、`pairing_rate_limited` |
| 500 | `inference_failed` |
| 503 / 504 | `model_not_ready`、`service_paused`、`generation_timeout` |

请求上限 1 MiB，单活跃推理、最多两个等待任务，每个请求从入队起 120 秒预算。取消／超时后仍等待底层生成真正退出，避免下一个任务与 GPU 工作重叠。连接断开、撤销、停服、退出和内存警告均可取消；不记录正文或凭据，无云端回退路径。HTTP 每个 TLS 连接处理一条请求后关闭，最多 24 个连接，读取／握手总预算 20 秒。

## 数据与隐私

模型目录为当前应用 Application Support 下的 `WiseLifeMacCompanion/Models`，sandbox App 位于自身 container 内。只保存固定模型文件与验证 receipt；下载先进入 0700 staging 目录，逐文件大小／SHA-256 校验后在同一卷原子重命名。网络重定向仅在下载模型时允许 HTTPS 的 Hugging Face/CDN 主机，生成服务本身没有重定向。

Mac TLS 私钥与设备 token 校验值保存在 `cloud.karama.wiselife.mac-companion` Keychain service，不使用 UserDefaults 保存秘密。服务开关、非秘密模型选择可保存到 UserDefaults。配对尝试按来源限流；单次 nonce 在凭据持久化后消费。设备最多 16 台。Mac 不保存提示、转写、回复或完整会话；内存指标只含 token 数与耗时。瞬时内存不宣称安全擦除。

空闲 10 分钟卸载模型；内存 pressure warning／critical 时取消任务并卸载。每次活跃推理仅持有有超时上限的临时防休眠 assertion，所有退出路径释放。不会长期阻止系统休眠。

## 验证与基准

```sh
sh scripts/test.sh
# 可选：真实 Hugging Face + CDN 下载检查（约 11 MB 分词器和模型卡，无模型权重）：
WISELIFE_HF_DOWNLOAD_SMOKE=1 sh scripts/test.sh
# Xcode 编译 Metal 后，运行无权重 GPU 检查：
sh scripts/benchmark.sh --check-metal
```

真实模型下载及测试由明确命令触发，在 M3 Air／16GB 上分别执行，不能并行加载：

```sh
# 首次 --download 明确授权下载所选候选模型；已安装可去掉该参数。
sh scripts/benchmark.sh --run --download --model mlx-community/Qwen3-4B-4bit \
  --minutes 30 --output /absolute/path/qwen3-4b-m3.json
sh scripts/benchmark.sh --run --download --model mlx-community/Qwen3-1.7B-4bit \
  --minutes 30 --output /absolute/path/qwen3-1.7b-m3.json
```

命令行基准与 sandbox App 的 Application Support 是各自独立位置，首次运行各自需要下载。报告只使用代码内置的合成中文材料，包含摘要、标题、引用、insight JSON 和 content decision；记录输出用于人工质量审核、冷加载时间、prompt 长度、首 token／总耗时、生成数量、进程峰值、内存压力、热状态、系统与模型版本。`ru_maxrss` 是进程生命周期高水位，不是单次请求独占内存。报告不自动判定通过；必须在真实 M3 Air 上审核，建立数值门槛，必要时降低上下文或采用小模型。

本机测试证据与未完成的硬件验收项目见 `verification/README.md`。Debug 版本提供 `--preview`、`--snapshot <absolute.png>`、`--page 模型库`，预览不读写用户 Keychain，不启动网络、不下载模型。Release 没有预览入口。

## iPhone 接入与验证边界

手机构建 6 已添加服务声明、权限说明、NWBrowser、扫码 TLS pinning、Keychain、连接状态和 Nearby Mac provider。文本生成经共享路由，保留授权、引用、验证、取消和过期结果检查；发送凭据及正文前重查当前配置。自动录音片段总结需要已允许自动发送；也可逐条确认。每日洞察为 Mac 选择仅准备允许的录音文字。代码／传输测试通过不等于手机与真实 MLX 模型的端到端验收完成，最新状态记录在上方接入验证文档。

上游参考：[MLX Swift](https://github.com/ml-explore/mlx-swift/tree/0.29.1)、[mlx-swift-lm](https://github.com/ml-explore/mlx-swift-lm/tree/2.29.3)、[SwiftNIO](https://github.com/apple/swift-nio)、[NIOSSL](https://github.com/apple/swift-nio-ssl)、[Swift Certificates](https://github.com/apple/swift-certificates)。
