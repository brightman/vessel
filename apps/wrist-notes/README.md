# WiseNote · 我的一天

一套本地优先的 iPhone 与 Apple Watch 语音笔记原生 App。手表录音并保留待传文件；iPhone 收到音频后保存原文件，在设备上转写、编辑，默认使用 Apple 本地模型总结。可选用户自有的 OpenAI / Anthropic 兼容服务生成总结；不使用 Vessel API，也不需要自建中转服务器或 App 账号。

## 2026-10-19：现有 App 升级为每日记录与 AI 回顾

原生入口已切换为 [`prototype/iphone-day.html`](prototype/iphone-day.html) 对应的“一天 / AI / 洞察”。保留现有 Bundle ID、Watch 协议、录音 UUID、VoiceNotes 目录和模型配置，不需要导出或迁移旧录音。已有外观设置继续生效；首次安装默认跟随系统。

- **一天**：选择日期、真实录音时长、闪念条数与实际照片张数（健康数据未接入时）、24 小时发生时刻、当天搜索／来源筛选、详情和确认删除。时间轴表示用户留下记录的时刻，不代表全天自动录音。
- **记一刻**：iPhone 实际录音，停止后保存并进入现有端上转写流程；图片支持拍照、系统相册选择、最多 6 张预览／移除／说明、Vision 端上 OCR、详情和缩放查看。图片以最长边 2800 像素的 JPEG 副本存入本机，移除原始元数据；没有把系统相册原文件搬走。
- **AI**：按日期和中文关键词在允许读取的原文中检索，提供原记录引用。空数据、无文字与记录数量由程序回答；其余使用 Apple 本地模型。每个问题独立检索，一次查询一天，最多 5 段摘录；不是持续对话记忆或向量检索。
- **自定义 AI**：复用现有 OpenAI／Anthropic 兼容配置。问答每次先展示问题、统计与将发送的全部摘录，确认后才发送；音频和图片不会上传。单条笔记总结也会在发送全文前确认。
- **洞察与建议**：展示实际记录概览、可打开的来源，以及按用户设置出现的回顾入口。AI 生成的重点和下一步建议在用户提问后展示；没有后台持续分析或虚构的健康、情绪指标。
- **本地提醒**：从原记录或提醒列表拟定内容与时间，确认后申请系统通知并保存。支持编辑、取消、完成、删除、来源回看，以及通知权限关闭／安排失败提示。免打扰只控制主动建议，已确认提醒按约定时间通知。
- **统一设置**：语音转写模型和语言包、AI 模型、主动建议频率／安静时段／语音图片数据范围、提醒管理、外观与音频导入。

图片、提醒采用相邻的 `PhotoMoments`、`DaybookReminders` 本地目录；不改变原音频存储。后续阶段再接入向量索引、跨天分析、HealthKit 和日历。实现范围见 [`verification/daybook-native.md`](verification/daybook-native.md)；本轮原型对齐、更正和最新验证边界见 [`verification/prototype-parity.md`](verification/prototype-parity.md)。

Watch 单按钮界面方案见 [`prototype/watch-recorder.html`](prototype/watch-recorder.html)。轻点按钮开始或结束长录音，按住约 0.45 秒进入闪念并在松手时保存，上滑可取消。SwiftUI 已实现同一套单按钮交互、录音列表、上传状态和左划删除；具体核对记录见 [`verification/README.md`](verification/README.md)。

原 iPhone 列表与详情界面方案保留在 [`prototype/iphone-notes.html`](prototype/iphone-notes.html)。新版首页继续复用音频详情里的“总结 / 全文”、播放、编辑、重新转写和生成总结能力。网页中的内容是演示数据；App 正常启动不会添加示例笔记。

**2026-10-19 模型与下载接入：** 首页右上角提供真实 Watch 通信状态和设置入口。设置支持深色/浅色/跟随系统、iPhone端上转写、Whisper、音频导入，以及 Apple 本地 AI / 自定义 AI 模型。两种转写引擎均使用“选择语言 → 检查／下载资源 → 保存”流程。自定义 AI 可选择 OpenAI 或 Anthropic 兼容协议，先测试再保存，用于笔记总结。实现与验证记录见 [`verification/model-downloads.md`](verification/model-downloads.md)，先前设置验证见 [`verification/settings.md`](verification/settings.md)。

## 设备与系统

- 开发环境：Xcode 26.3。
- iPhone：最低 iOS 26；计划用 iPhone 16 Pro（iOS 26.5.2）验证。
- Apple Watch：最低 watchOS 10；计划用 Apple Watch SE（当前 watchOS 10.6.2）验证，暂不假定具体代数，也不要求先升级系统。
- Apple Intelligence 总结须由运行时 `SystemLanguageModel` 检查可用性和中文支持。不可用时原始音频和转写笔记仍可管理。

## 打开与安装

1. 用 Xcode 打开 `WristNotes.xcodeproj`，选择 `WristNotes` scheme。
2. 在 iPhone 和 Watch 两个 target 的 **Signing & Capabilities** 中选择自己的 Team。若 Bundle Identifier 被占用，一起修改 iPhone ID、Watch ID 与 Watch `Info.plist` 中的 `WKCompanionAppBundleIdentifier`，再运行 `ruby scripts/generate_project.rb` 前先同步修改生成脚本；重新生成工程会覆盖 Xcode 中直接改的项目设置。
3. iPhone 解锁并信任 Mac，开启开发者模式；确认 Apple Watch 已与该 iPhone 配对，在 Xcode 的设备列表中可选。先在 iPhone 上运行 `WristNotes`，再确认手表 App 已安装。Xcode 若无法看到手表，检查配对、同一 Apple ID、蓝牙/Wi-Fi 和设备支持组件。
4. 首次轻点手表红色按钮授权麦克风。闪念首次授权时，松开后再次按住按钮，触觉反馈后开始说话。
5. iPhone 设置 → 语音转写模型，先选转写引擎和语言，再下载所需资源并保存。已有系统资源直接复用；缺少资源时不会静默下载，也不会回退到云端转写。

本轮验证使用 iPhone 17 Pro（iOS 26.3）与 Apple Watch SE 3 44mm（watchOS 26.2）模拟器；这不代表实体设备型号已改变。真机签名、安装及长录音仍需在实际设备上验证。

## 使用流程

1. 手表轻点红色按钮开始长录音，再轻点结束；按住约 0.45 秒进入闪念，触觉反馈后说话，松开保存，上滑再松开取消。闪念不足 0.3 秒不保存；长录音期间长按不会误停。
2. 手表列表显示名称、开始时间、时长和“未上传 / 已上传”。“已上传”只在手机确认保存后显示；本地条目与音频仍保留，可左划删除。列表底部提供重试入口。
3. iPhone “一天”页按日期展示录音与图片，支持当天搜索、筛选和左划删除；导入音频、转写语言和外观在右上角设置；语音详情可播放录音，并在播放器下方切换“总结 / 全文”。全文可编辑，支持保存、重新转写和生成总结。修改全文会使旧总结失效，修改标题不会。
4. 音频和笔记分别存于各自 App 沙盒。卸载 App 可能删除本地数据；当前版本没有云备份、跨设备同步或导出功能。

模拟器的 WatchConnectivity 不支持文件传输和后台用户信息传输，因此模拟器构建用可达时的分片消息传送录音，并在 iPhone 保存后回执；真机仍使用 `transferFile` 与 `transferUserInfo`。模拟器验收时需让两端 App 保持运行。

## 转写模型与资源下载

- **iPhone端上转写**：iPhone系统语音模型，无需API Key，支持单语言转写，按需下载系统语言包。语言列表来自当前设备的 `SpeechTranscriber.supportedLocales`，不支持的设备会显示说明。
- **Whisper**：Tiny / Base / Small 多语言模型，分别约 80 MB / 150 MB / 490 MB，支持自动检测或指定一种语言。每个模型下载一次，99 种语言共用，切换语言无需再次下载。
- 下载有真实进度、取消和重试。返回页面／切换资源会取消当前下载；Whisper 已校验完成的文件会缓存，下次复用，正在下载的单个文件重新下载。首次加载 Core ML 模型可能需要一些时间。
- 下载需要网络；完成后音频在本机转写，不向模型下载站点发送录音。Whisper 文件来自 Argmax / OpenAI 的固定版本公共仓库，安装前校验大小和摘要；未完成或损坏资源不能保存为就绪。
- 保存后的配置用于新的转写任务。已有文字不会自动重写，可进入详情页点“重新转写”；设置更改不会影响已经提交的任务。
- 系统语言包由 iOS 管理，可能因系统存储策略被回收；缺少时到设置重新下载。下载页面需保持打开，暂不支持退出 App 后的后台续传。

## AI 模型配置

1. iPhone 首页右上角设置 → AI 模型 → 自定义模型。
2. 选择“API 接口兼容”：OpenAI 或 Anthropic。填写服务提供的模型 ID、Base URL（例如 `https://api.example.com/v1`，不带 `/chat/completions` 或 `/messages`）及 API Key。
3. 点击“测试连接”。测试仅发送固定短文本，测试通过后“保存”可用；修改任一字段需重新测试。返回会放弃未保存修改。
4. 进入一条笔记 → 总结 → 生成总结／重新生成 → 确认。只发送这条笔记的全文，不发送音频。长文本分段压缩后汇总。
5. 切回 Apple 本地模型后在 iPhone 上总结。模型不可用或失败时显示错误，不自动切换服务。已有笔记和总结不因更换配置被删除。

Key 保存在 iOS Keychain（仅本设备，解锁后访问），普通设置存在 UserDefaults。连接使用 HTTPS；仅允许本机 loopback 使用 HTTP（真机 localhost 指 iPhone 本身，不是 Mac）。不跟随 HTTP 重定向，需直接填写最终服务地址。支持 OpenAI Chat Completions 和 Anthropic Messages 的非流式文本响应；不包含语音 API。

## 真机验证清单

用户于 2026-10-19 反馈：Watch → iPhone 传输已在另一 agent 修复，真机 ASR 测试通过。以下长时录音、断连恢复等仍是扩展验收场景，本次保留已有传输实现；新增转写引擎选择与资源下载，仍需分别验证设备上的新路径。


- 手表长录音：录制 30 分钟以上，分别测试熄屏、抬腕、切换表盘、来电/通知中断；确认时长、文件可播放及电量表现。后台能否稳定持续录音以实测为准。
- 闪念：测试首次权限弹窗、短按、按住后松开、权限拒绝，以及长录音与闪念切换。
- 传输：录音后断开手机连接，确认手表待传文件仍在；重连后核对手机音频；重复传输只生成一条笔记；手机保存确认前手表不删文件。
- ASR：分别用普通话短录音和长录音，安装语音资源后开飞行模式重试；核对识别内容、耗时与失败提示。
- 总结：确认设备 Apple Intelligence 已开启且中文模型可用，再分别测短文本和长文本；核对总结是否忠实原文。不可用时验证音频、文本仍能访问。
- 持久化：杀掉并重开两端 App，检查笔记、音频、待传队列与处理状态。

## 本机验证

在仓库根目录运行：

```sh
xcodebuild -project apps/wrist-notes/WristNotes.xcodeproj -scheme WristNotes -configuration Debug -destination 'generic/platform=iOS' -derivedDataPath /private/tmp/wristnotes-derived CODE_SIGNING_ALLOWED=NO build
swiftc -module-cache-path /private/tmp/wristnotes-modulecache apps/wrist-notes/Sources/Shared/VoiceNote.swift apps/wrist-notes/Sources/iPhone/NoteRepository.swift apps/wrist-notes/Tests/NoteRepositorySmoke.swift -o /private/tmp/wristnotes-store-smoke
/private/tmp/wristnotes-store-smoke
```

通用构建只验证编译与打包，不代表真实录音、Watch Connectivity、普通话 ASR 或 Foundation Models 已在设备上通过。

## 原型对齐验证（2026-10-18）

- 两端 SwiftUI 已更新，并已安装到现有模拟器。
- 截图与边界说明见 [`verification/README.md`](verification/README.md)。
- 本地逻辑检查：`sh apps/wrist-notes/scripts/test_local.sh`（仓库根目录执行）。
- Watch → iPhone 已在配对模拟器完成端到端验证：合成 AAC 到达 iPhone 并保存为笔记，Watch 收到保存回执后标记为“已上传”。此结果验证模拟器分片通道；实体设备文件传输、断连重传和熄屏录音仍需真机验收。
