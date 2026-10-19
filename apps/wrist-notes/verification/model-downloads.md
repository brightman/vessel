# 原生模型设置与下载验证 · 2026-10-19

## 已实现

- 对齐 `prototype/iphone-notes.html` 的模型选择、语言选择、资源状态、下载／取消／重试及保存流程。
- `iPhone端上转写` 使用设备运行时支持的语言列表；通过 `AssetInventory` 检查和下载系统语言资源。资源就绪后才可保存。
- Apple 资源使用共享 lease 管理：下载、已安装资源复用和转写都持有预留；失败／取消不会释放其他使用者的资源；达到系统预留上限时只回收未使用的预留，并优先保留已保存语言。
- Whisper Tiny / Base / Small 多语言模型，99 种语言及自动检测；按模型下载，不逐语言下载。切换 Whisper 语言不取消同一模型下载。
- 实际字节进度、完整文件缓存、取消／重试、哈希校验和最终安装标记；下载不完整不能显示为就绪。失败后保留已校验的完整文件，当前未完成的单个文件需重下。安装和缓存操作按目录串行。
- 保存配置实际驱动笔记转写。每个任务提交时固定配置，转写串行执行，完成／失败后释放 Whisper 模型内存；转写失败不覆盖已有全文。
- 自定义总结模型增加“API 接口兼容”：OpenAI Chat Completions / Anthropic Messages。旧配置默认 OpenAI；改协议后需重新测试。Key 仍在 Keychain。

## 下载内容与边界

| 模型 | 下载字节数（含 tokenizer） | 语言资源 |
|---|---:|---|
| Whisper Tiny | 79,400,740 | 多语言，共用一次下载 |
| Whisper Base | 149,484,796 | 多语言，共用一次下载 |
| Whisper Small | 489,252,808 | 多语言，共用一次下载 |
| iPhone 系统模型 | 由 Apple 管理 | 根据设备和所选语言决定 |

- WhisperKit 固定 `0.15.0`，swift-transformers 固定 `1.1.2`，仅链接 iPhone target。
- 模型源：`argmaxinc/whisperkit-coreml@0f63a7800b00dd0226abd051b906c246e1907482`。
- 原版多语言 tokenizer 源：`openai/whisper-tiny@169d4a4341b33bc18d8881c4b69c2e104e1cc0af`，供三种大小共用。
- `WhisperModels.json` 固定每个文件的 URL、大小和 SHA256 / Git blob SHA1。共 22 个文件／模型。
- 下载只向公共模型站点获取文件；转写从已安装的本地模型和 tokenizer 加载，禁止 WhisperKit 的模型下载和 tokenizer 网络回退。不向下载站点发送录音。
- 安装文件和完整文件缓存位于 Application Support，排除备份；缓存及安装／Core ML 编译会额外占空间，表格数值仅为网络下载量。
- 保持下载页面打开；返回或切换资源取消下载，未实现退出 App 后的后台续传。系统语言包保留／回收由 iOS 管理，使用前会再次检查。

## 本轮验证结果

| 验证 | 结果与范围 |
|---|---|
| `scripts/test_local.sh` | 通过：原有仓储、Watch 状态／手势、编辑、AI 配置；新增转写设置、Apple 预留、Whisper 缓存／取消／重试测试 |
| 通用 iOS Simulator 构建 | 通过，包括嵌入的 Watch Simulator App |
| 通用 iOS 构建（关闭签名） | 通过，包括 watchOS App；`EmbeddedWatchSmoke.sh` 通过 |
| 真实 Tiny 下载与加载 | 在 Apple Silicon Mac 上下载 22 个文件，校验并安装，重新打开 store 后仍可使用 |
| 指定英语／自动检测 | 均输出 `This is a local speech recognition test, the recording stays on this device.` |
| 禁网后新进程推理 | 使用 `sandbox-exec` 拒绝 `network*` 后，指定英语／自动检测仍通过；使用新版本生产源码，未替换网络或模型实现 |
| 原生界面 | iPhone 17 Pro / iOS 26.3 模拟器截图已检查；Apple 不可用提示、Whisper 缺资源／就绪状态及 API 协议字段正常 |
| 独立代码审查 | 初次发现的 Apple 预留生命周期和 Whisper 中断缓存问题均已修复；复审无 Critical / Important 问题 |

日志：[本地测试](model-downloads/local-tests.txt)、[真实下载及转写](model-downloads/whisper-download.txt)、[禁网进程转写](model-downloads/whisper-offline.txt)。第一次测试允许网络下载；禁网结论以第二次测试为准。

### 截图

使用 `scripts/prepare_ui_preview.py` 创建独立 `.preview` App，WatchConnectivity 关闭，笔记为样例。Whisper“就绪”截图将上面下载并校验的真实 Tiny 文件复制到预览 App 沙盒，仍由生产校验逻辑判断就绪；未使用假的 ready 状态。

- [系统模型实际不可用状态](model-downloads/iphone-apple-asr.png)
- [Whisper 下载入口](model-downloads/iphone-whisper-asr.png)
- [Whisper 就绪与保存](model-downloads/iphone-whisper-ready.png)
- [Anthropic 兼容接口](model-downloads/iphone-ai-protocol.png)

## 复现

在仓库根目录：

```sh
sh apps/wrist-notes/scripts/test_local.sh
xcodebuild -project apps/wrist-notes/WristNotes.xcodeproj -scheme WristNotes -configuration Debug -destination 'generic/platform=iOS Simulator' -derivedDataPath /private/tmp/wristnotes-model-derived build
xcodebuild -project apps/wrist-notes/WristNotes.xcodeproj -scheme WristNotes -configuration Debug -destination 'generic/platform=iOS' -derivedDataPath /private/tmp/wristnotes-model-device-derived CODE_SIGNING_ALLOWED=NO build
sh apps/wrist-notes/Tests/EmbeddedWatchSmoke.sh /private/tmp/wristnotes-model-device-derived/Build/Products/Debug-iphoneos/WristNotes.app
```

可选真实 Whisper 集成测试（macOS 26+、Apple Silicon、Xcode 命令行工具；首次需联网获取 Swift 包及约 80 MB 模型）：

```sh
sh apps/wrist-notes/scripts/test_whisper_integration.sh
```

该脚本生成英文测试音频，先下载／转写，再以禁网新进程重跑。模型缓存默认在 `/private/tmp/wristnotes-whisper-test-models`；可用 `WRISTNOTES_TEST_MODEL_DIR` 指定，脚本不读取用户录音。

## 真机仍需验收

本轮没有连接用户 iPhone 16 Pro，也没有在其上执行新的系统语言包下载或 Whisper 推理。用户先前报告的真机传输／ASR 通过属于原有路径，不能替代此次新增功能验收。

1. 设置 → 语音转文本 → iPhone端上转写：确认语言列表，选未安装的语言并下载，检查实际进度、取消／重试、保存、重启及断网转写。
2. 选 Whisper Tiny，下载并保存；导入中文及英文录音，分别指定语言和自动检测，开启飞行模式重试。检查耗时、发热和内存。
3. Base / Small 共用已验证的安装与校验代码，但本轮未下载、运行其完整真实模型；仍需真机验证性能和长录音质量。
4. 两种自定义总结协议已通过可控 HTTP 请求／响应合同测试；本轮未用用户真实 Key 调用远程服务。

已有 Watch 录音和传输源码保持不变。
