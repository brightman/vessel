# 我的声音：原生实现与验证

日期：2026-10-20。代码位于 `apps/wrist-notes`，本次未提交或推送。

## 已实现

- 两个原生设置入口均在「语音转写模型」下方显示「我的声音」，直接观察登记状态。
- 使用 iPhone 内置麦克风真实录制，30 秒后可结束，60 秒自动停止。提供准备、录制、确认、验证保存、已登记、重录和确认删除流程。
- 保存前要求独立讲话确认；解码实际音频长度，检查有效讲话、重叠和声音一致性。新档案保存成功前保留旧登记。
- Apple 与 Whisper 共用后续 SpeakerKit / WeSpeaker 本地处理管线。匹配有把握的说话人显示「我」；短片段、不一致或不确定的匹配保留通用说话人名称。手动名称优先。
- 原始登记录音在保存成功、取消或退出后删除；持久化档案只有声纹向量和必要元数据，设置 iOS 完整文件保护，排除 iCloud / 设备备份。推理不上传音频。
- 取消、删除、重录以及全文修改均有过期结果保护；声纹识别失败保留已有转写和说话人分离结果，并提供重试。
- 模型随现有转写资源一起下载，没有独立模型下载入口；补全资源复用已下载文件。录制/结束采用红色按钮，保存采用主题主按钮，支持深浅色与中英日文。
- 保持当前 `Config/BuildFeatures.json` 的 `eurekaRing: false`，未修改独立 Ring SDK。

## 模型与登记策略

WeSpeaker Core ML：`FluidInference/speaker-diarization-coreml`，固定版本 `7eab74f3463c736418d0eb10296261ae581146c9`，5 个文件共 **7,954,144 bytes**。逐文件 SHA-256 校验；该 legacy 模型适用 CC BY 4.0，归属与许可见随 App 打包的 `VoiceIdentityModels-NOTICES.txt`。

输入为 16 kHz 单声道，输出归一化的 256 维特征。登记需 30～60 秒录音、至少 15 秒清晰讲话及 3～20 个有效特征窗口；所有登记窗口之间的余弦相似度至少 0.80。匹配至少需要两个清晰窗口，每个查询窗口与所有登记窗口的相似度至少 0.82。这些是尚未经过真人数据集校准的保守工程默认值，不能据此宣称识别准确率。

实际测试发现 SpeakerKit 会把单人讲话拆成连续的两个编号，因此登记不会仅凭编号数量拒绝。当前逻辑：

1. 重叠讲话累计达到 2 秒时拒绝。
2. 独立计算每个编号的完整讲话区间；任何总时长至少 2 秒的编号都必须提供至少 2 秒无重叠讲话，否则拒绝。
3. 为各编号分别提取窗口，避免将不同人的声音先拼成同一窗口；全部窗口通过上述一致性验证后才能登记。超出窗口上限直接拒绝，不截去后出现的说话人。

## 验证结果

| 检查 | 结果与范围 |
| --- | --- |
| 完整 iPhone / 嵌入式 Watch 工程 | iOS Simulator 构建成功，使用当前关闭 Ring 的配置 |
| iOS XCTest | **18 项通过，0 失败，0 跳过**；iPhone 17 Pro / iOS 26.3.1 Simulator；不包含 UI 点击或麦克风真机测试 |
| `scripts/test_local.sh` | 全部通过，包含现有笔记、Watch 状态、设置、资源下载、Daybook、SQLite 与语义检索回归 |
| 新增纯逻辑检查 | 声纹持久化、替换/删除/备份标记、手动名称优先、窗口截取、重叠拒绝、连续编号、讲话不足均通过 |
| 真实离线 WeSpeaker 推理 | 通过；256 维有限特征，L2 norm 0.9999999；损坏模型校验拒绝 |
| 两种合成语音的生产管线 | 登记、同声音匹配、不同声音不匹配、混合会话识别与混合登记拒绝全部通过，见下表 |
| 独立代码审查 | 重叠声音可绕过检查的问题已修复；最终复审无剩余高/中等级问题 |
| 本地化 | 字符串目录有效；新增入口、流程、错误和资源文案有 zh-Hans / en / ja 条目 |

### iOS 集成测试覆盖

包括取消后晚到结果、登记中删除、错误替换保留旧档案、重叠讲话拒绝后保留旧档案、匹配时删除/重录、手动标注优先、识别失败保留全文与分离结果，以及已完成音频的真实时长读取。另保留已有转写/分离的持久化与失败恢复测试，以及三个模型资源组的缺失、失败、重试与复用检查。

重叠登记回归先在旧行为下实际失败，修复后通过。连续编号回归先被错误拒绝，修复后通过；没有降低相似度阈值。

### 合成语音端到端结果

使用本机 `say` 生成两种声音，登记与查询文本不同。混合会话由两种查询语音拼接。执行真实生产 `enrollVoice` → 声纹档案 → `diarizeWithIdentity`，使用真实 SpeakerKit 与 WeSpeaker 模型。

| 登记声音 | 登记长度 / 特征窗口 | 同声查询 | 异声查询 | 混合会话 | 混合登记 |
| --- | --- | --- | --- | --- | --- |
| Samantha | 33.169625 秒 / 6 | 匹配「我」 | 无匹配 | 仅 speaker-1 匹配 | 拒绝 inconsistentVoice |
| Daniel | 35.203875 秒 / 7 | 匹配「我」 | 无匹配 | 仅 speaker-2 匹配 | 拒绝 inconsistentVoice |

混合会话仍被 SpeakerKit 分成三个编号，而实际来源为两种声音；声纹功能没有消除该分离模型的过度拆分。此测试输入人工生成的时间戳，**没有执行 Apple ASR 或 Whisper ASR**，验证的是其共用后处理管线。合成语音不能代表中文真人、相似音色、嘈杂环境或跨设备识别表现。

证据保存在 [my-voice-native/](my-voice-native/)：XCTest 汇总、完整本地回归日志、真实模型日志及两组语音结果。原始 XCTest bundle 在 `/private/tmp/wiselife-speaker-ios-derived/Logs/Test/`。

## 复现

从仓库根目录运行：

```sh
bash apps/wrist-notes/scripts/test_local.sh
VOICE_IDENTITY_REAL_MODEL=1 sh apps/wrist-notes/scripts/test_voice_identity.sh
ruby apps/wrist-notes/scripts/test_speakers_ios.rb /private/tmp/wiselife-voice-ios
xcodebuild test -project /private/tmp/wiselife-voice-ios/SpeakerVerification.xcodeproj \
  -scheme SpeakerVerification -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -derivedDataPath /private/tmp/wiselife-speaker-ios-derived -parallel-testing-enabled NO
xcodebuild build -workspace apps/wrist-notes/WristNotes.xcworkspace -scheme WristNotes \
  -destination 'generic/platform=iOS Simulator'
VOICE_PIPELINE_DOWNLOAD_MODELS=1 sh apps/wrist-notes/scripts/test_voice_pipeline.sh \
  /private/tmp/wiselife-speaker-models /private/tmp/wiselife-identity-installed
```

合成语音管线脚本固定 SDK 及依赖版本，在隔离工作目录生成音频并编译生产源码；上面的显式开关允许下载缺少的公开模型，已有模型直接复用。运行环境需要 macOS 26、Xcode、Swift、Samantha / Daniel 两种 `say` 声音与 ffmpeg；模型和生成音频保留在仓库外，不包含用户录音。脚本已用两组重新生成的语音完整运行通过；失败的验证会返回非零状态。

## iPhone 16 Pro 真机验收

1. 设置 → 语音转写模型 → 下载或补全离线资源 → 保存。
2. 设置 → 我的声音；在安静环境独自讲话 30～60 秒，确认后保存。确认重开 App 仍显示登记日期与时长。
3. 录制本人独白、他人独白及两人轮流讲话；查看全文中的「我」，逐段对照播放。分别使用 Apple 与 Whisper，再在断网时重复。
4. 用 Apple Watch / EurekaRing 来源的录音复测，记录误匹配与漏匹配；跨麦克风结果不能由 iPhone 登记或 Mac 推理推断。
5. 检查 60 秒自动停止、权限拒绝、系统中断、取消和重录；验证旧登记在失败后保留，删除后新录音不再自动匹配。

本次没有完成原生 UI 视觉验收、物理麦克风/路由测试、iPhone 上的推理性能或真人识别率验证。此前 Computer Use 拒绝使用 Simulator（`Computer Use was not approved to use Simulator`），未通过其他 UI 控制方式绕过。当前 Ring 开关关闭，跨 Ring 的验收需要该集成重新启用后进行。
