# WiseLife · 我的一天

一套本地优先的 iPhone 与 Apple Watch 个人每日记录 App。手表录音并保留待传文件；iPhone 收到音频后保存原文件，在设备上转写、编辑，默认使用 Apple 本地模型总结。可选用户自有的 OpenAI / Anthropic 兼容服务生成总结；不使用 Vessel API，也不需要自建中转服务器或 App 账号。

## 2026-10-21：长录音内容标题

iPhone 首页、我的记录和语音详情显示“长录音·内容标题”，开始时间只在时间轴／元数据中展示。转写后优先使用 Apple 本地模型生成标题，不可用时从转写提取简短标题；生成前显示“待生成标题”。旧默认日期标题自动处理，手动名称保留。实现与真机验证边界见 [录音标题验证记录](verification/recording-content-titles.md)。

## 2026-10-21：说话人联系人与 Apple 提醒事项

- **说话人关联联系人**：录音详情 → 全文 → 点击说话人 → 关联联系人。系统选择器选定后再确认，支持更换、解除和未关联时手动命名。仅保存选中联系人的标识、名称和小头像，关联限于当前录音；不会修改系统通讯录或自动识别今后录音中的此人。
- **可选 Apple 提醒事项**：新建／编辑提醒时，默认关闭“同时添加到 Apple 提醒事项”。主动允许后选择可写列表；支持修改、完成、确认后删除及失败重试。外部修改／完成在 App 刷新时读回，外部删除保留状态，不自动重建。
- **通知和隐私**：关联 Apple 的待办由 Apple 提醒事项通知，避免同时发 WiseLife 通知。只添加任务内容与时间，不添加录音或全文；选择 iCloud 等账户列表时按账户设置同步。解除关联会先删除 Apple 任务，再设置本地通知。
- **验证范围**：联系人／提醒状态与持久化测试、SQLite 迁移回归及 iPhone＋Watch＋录音组件模拟器构建通过；真实权限、联系人选择和 Apple 账户同步需真机验收。见 [实现与验证记录](verification/people-reminders-native.md)。

## 2026-10-20：iPhone 快捷录音

- 新增圆形锁屏“快捷录音”小组件：**长按锁屏 → 自定 → 锁定屏幕 → 添加小组件 → WiseLife → 快捷录音**。轻点麦克风开始；重复轻点保持同一段录音，通过实时活动“停止并保存”。App 内“设置 → 快捷录音”也有添加指引。构建、组件打包和录音状态回归通过，锁屏授权与实际收音待真机验收，见 [锁屏快捷录音验证记录](verification/lock-screen-recording.md)。
- 在 iPhone **设置 → 操作按钮 → 快捷指令 → 选取快捷指令** 中，选择 WiseLife 的 **开始／停止录音**。长按开始，再次长按结束并自动保存。也提供独立的“开始录音”和“停止并保存录音”快捷指令。
- 锁屏与灵动岛的实时活动显示录音状态、时长及“停止并保存”。快捷指令录音需要麦克风权限和实时活动权限；首次使用先打开 App 完成授权。App 的“设置 → 快捷录音”提供配置引导。
- 页面和快捷指令共用录音服务；中断后保存已录制部分，保存失败保留草稿并可重试。保存先写入本地音频与笔记，再排队进行端上转写。
- 已完成模拟器构建、录音状态测试及原生音频/存储测试。物理操作按钮、锁屏冷启动、后台麦克风和实际实时活动仍需真机验收，详见 [快捷录音验证记录](verification/quick-recording.md)。

## 2026-10-19：现有 App 升级为每日记录与 AI 回顾

原生入口已切换为 [`prototype/iphone-day.html`](prototype/iphone-day.html) 对应的“一天 / AI / 洞察”。保留现有 Bundle ID、Watch 协议、录音 UUID、VoiceNotes 目录和模型配置，不需要导出或迁移旧录音。已有外观设置继续生效；首次安装默认跟随系统。

- **一天**：选择日期、真实录音时长、闪念条数与实际照片张数（健康未开启或无可读数据时）、24 小时发生时刻、当天搜索／来源筛选、详情和确认删除。时间轴表示用户留下记录的时刻，不代表全天自动录音。
- **记一刻**：iPhone 实际录音，停止后保存并进入现有端上转写流程；图片支持拍照、系统相册选择、最多 6 张预览／移除／说明、Vision 端上 OCR、详情和缩放查看。图片以最长边 2800 像素的 JPEG 副本存入本机，移除原始元数据；没有把系统相册原文件搬走。
- **AI**：按日保存连续对话与追问；关键词和本地 SQLite Vector 共同检索允许读取的原文，提供稳定来源引用。空数据、无文字与记录数量由程序回答；其余默认使用 Apple 本地模型。一次查询一天；资料编辑、删除或撤销 AI 读取范围后重新核验依据。
- **自定义 AI**：复用现有 OpenAI／Anthropic 兼容配置。问答每次先展示问题、统计与将发送的全部摘录，确认后才发送；音频和图片不会上传。单条笔记总结也会在发送全文前确认。
- **洞察与建议**：本地模型从至少两条来源生成当日观察与下一步建议，支持查看依据、重试、取消和忽略。自动生成仅在前台、今天且频率、免打扰和录音状态允许时运行；建议可生成需要确认的提醒草稿。
- **本地提醒**：从原记录或提醒列表拟定内容与时间，确认后申请系统通知并保存。支持编辑、取消、完成、删除、来源回看，以及通知权限关闭／安排失败提示。免打扰只控制主动建议，已确认提醒按约定时间通知。
- **生活来源**：可选健康步数/睡眠、只读日历、保存时的一次定位；默认关闭，不在启动时请求权限。支持暂停、刷新、旧快照状态与独立 AI 读取范围。 健康来源支持数据变化通知与前台补刷，更新今天、昨天和所选日期；后台时间由系统调度，详见 [HealthKit 更新说明](docs/2026-10-20-health-background.md)。 地点在前台通过 Apple 地图解析为地址，并随原记录缓存在 SQLite；首次解析可能联网，见 [地点地址说明](docs/2026-10-20-capture-addresses.md)。
- **统一设置**：语音转写模型和语言包、AI 模型、本地语义检索资源与索引管理、主动建议频率／安静时段／数据范围、提醒管理、外观与音频导入。首页及设置提供硬件选择器；Apple Watch 和 EurekaRing 展示真实连接状态；Ring 支持录音控制与本地音频同步。

图片、提醒保留相邻的 `PhotoMoments`、`DaybookReminders` 本地目录；录音与现有 UUID 保持兼容。生活数据、会话与洞察使用系统 SQLite；可重建的文本向量也保存到本地数据库，端上资源不可用时回退关键词。跨天语义记忆及自有云备份尚未实现。EurekaRing 原生接入与设备验证边界见 [Ring 接入记录](verification/eureka-ring-native.md)。最新完成范围与验收见 [原型差异核对](docs/prototype-completion-audit.md)，存储与索引边界见 [本地存储与检索](docs/local-storage-and-retrieval.md)。此前阶段记录保留在 [`verification/daybook-native.md`](verification/daybook-native.md) 和 [`verification/prototype-parity.md`](verification/prototype-parity.md)。

Watch 单按钮界面方案见 [`prototype/watch-recorder.html`](prototype/watch-recorder.html)。轻点按钮开始或结束长录音，按住约 0.45 秒进入闪念并在松手时保存，上滑可取消。SwiftUI 已实现同一套单按钮交互、录音列表、上传状态和左划删除；具体核对记录见 [`verification/README.md`](verification/README.md)。

原 iPhone 列表与详情界面方案保留在 [`prototype/iphone-notes.html`](prototype/iphone-notes.html)。新版首页继续复用音频详情里的“总结 / 全文”、播放、编辑、重新转写和生成总结能力。网页中的内容是演示数据；App 正常启动不会添加示例笔记。

**2026-10-19 模型与下载接入：** 首页右上角提供真实 Watch 通信状态和设置入口。设置支持深色/浅色/跟随系统、iPhone端上转写、Whisper、音频导入，以及 Apple 本地 AI / 自定义 AI 模型。两种转写引擎均使用“选择语言 → 检查／下载资源 → 保存”流程。自定义 AI 可选择 OpenAI 或 Anthropic 兼容协议，先测试再保存，用于笔记总结。实现与验证记录见 [`verification/model-downloads.md`](verification/model-downloads.md)，先前设置验证见 [`verification/settings.md`](verification/settings.md)。

## 设备与系统

- 开发环境：Xcode 26.3。
- iPhone：最低 iOS 26；计划用 iPhone 16 Pro（iOS 26.5.2）验证。
- Apple Watch：最低 watchOS 10；计划用 Apple Watch SE（当前 watchOS 10.6.2）验证，暂不假定具体代数，也不要求先升级系统。
- Apple Intelligence 总结须由运行时 `SystemLanguageModel` 检查可用性和中文支持。不可用时原始音频和转写笔记仍可管理。

## 打开与安装

默认构建已关闭 Eureka Ring，不需要其原生 SDK。在 `apps/wrist-notes` 中运行 `pod install --no-repo-update`，再打开 `WristNotes.xcworkspace`。这会同时应用编译开关和 CocoaPods 依赖设置。

### Eureka Ring 编译开关

配置文件：`Config/BuildFeatures.json`，当前为 `{"eurekaRing": false}`。关闭时硬件页只展示 Apple Watch，Ring 模型、传输存储和 Ring 集成测试不编译，三个 Ring Pod 不解析或链接；已有 Ring 笔记仍保留并可在原笔记库中查看。其他测试继续保留在现有测试 target 中。

重新开启时，将 `eurekaRing` 改成 `true`，补齐下述依赖，再运行 `pod install`。仅修改 JSON 后直接点击 Build 不会更新已有 Xcode 工程。工程生成器也读取同一配置；日常切换无需重新生成整个工程。开关检查：`ruby Tests/BuildFeaturesSmoke.rb`。

### 仅开启 Ring 时准备 SDK

将用户指定的原生 SDK 仓库放在 Vessel 的相邻目录，使用 `dev-300` 分支（需要该 GitLab 项目的访问权限）：

```sh
git clone --branch dev-300 --single-branch git@git.100credit.cn:ai2c/app/flutter_lib/br_flutter_plugin_ble.git ../br_flutter_plugin_ble
```

以上命令从 Vessel 仓库根目录执行；后续步骤进入 `apps/wrist-notes`。

环境恢复注意：当前远端 `dev-300`（`627569fb`）只有原始 Flutter 插件，不含此工程需要的原生适配层。还需同步已有接入工作区中的 `ios/RecorderCore/`、`ios/BRRecorderCore.podspec` 和 `ios/bootstrap_recorder_core.sh`，才能执行下面的依赖准备步骤。当前恢复进度见 [钥匙串问题记录](verification/keychain-simulator.md#安装状态与外部依赖)。

补充提供的 `br_app_services/dev-301`（`d985c6f7`）已选择性提取到相邻 `br_app_services` 目录，作为本地硬件／传输逻辑参考。它是 Dart 服务层，不含上述 Swift 适配层；未引入 App 构建或替换现有 SQLite 存储。提取清单和逐文件校验记录见该目录的 `EXTRACTION.md` 与 `SOURCE_DOWNLOAD.json`。

`bairongble-ios/develop-sync`（`d70596a2`）已下载到相邻 `bairongble-ios` 目录，并链接至 `br_flutter_plugin_ble/ios/.native-sdk/BRBluetoothLib`。它补齐了 `BRBluetoothLib 3.0.0` 的源码路径，已通过独立 iOS Simulator 编译；`BRRecorderCore` 与 Opus 模块仍需恢复，尚未完成整个 App 的依赖安装。

### 安装步骤

1. 在本目录运行 `pod install`。仅 Ring 开启时，需要先运行 `sh ../../../br_flutter_plugin_ble/ios/bootstrap_recorder_core.sh` 准备其 SDK。用 Xcode 打开 `WristNotes.xcworkspace`，选择 `WristNotes` scheme。若重新运行 `ruby scripts/generate_project.rb`，之后需再次 `pod install`。
2. 在 `WristNotes`、`WristNotesWatch`、`WiseLifeRecordingActivity`、`WiseLifeWatchRecordingWidget` 四个 target 的 **Signing & Capabilities** 中选择同一个有权限的 Team；每个 Bundle ID 都需要对应描述文件，Watch 描述文件需要包含测试手表。已有设备更新应沿用原 Team 和 Bundle ID，以保留 App 身份与数据容器。新项目如需改 ID，须同步修改手机 ID、Watch ID、两个扩展 ID、Watch `Info.plist` 的 `WKCompanionAppBundleIdentifier` 和生成脚本；Watch ID 以手机 ID 加 `.` 开头，扩展 ID 以所属 App ID 加 `.` 开头。生成脚本保留现有 Team、手机版本和构建号，并把版本同步给 Watch 与扩展，其他 Xcode 设置仍可能被覆盖。
3. iPhone 解锁并信任 Mac，两端均开启开发者模式。在 Xcode 设备列表确认 Watch 的开发连接可用；与手机正常配对不代表 Mac 调试通道已连接。先用 `WristNotes` scheme 安装手机，再用共享的 `WristNotesWatch` scheme 选择真实手表运行，分别核对两端安装结果。只有手机安装成功时，不能判定手表已更新。

Watch 安装排查和本次签名／连接证据见 [Watch 安装诊断](verification/watch-installation.md)。无签名的 generic 构建只验证编译和嵌入结构，不能证明真机可安装。
4. 首次轻点手表红色按钮授权麦克风。闪念首次授权时，松开后再次按住按钮，触觉反馈后开始说话。
5. iPhone 设置 → 语音转写模型，先选转写引擎和语言，再下载所需资源并保存。已有系统资源直接复用；缺少资源时不会静默下载，也不会回退到云端转写。

此前原型对齐验证使用 iPhone 17 Pro（iOS 26.3）与 Apple Watch SE 3 44mm（watchOS 26.2）模拟器；这不代表实体设备型号已改变。本轮新增能力通过本地测试与 CLI 构建；模拟器界面操作被自动审批拒绝，新增权限、布局和向量质量仍需真机验收。

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

## Watch 表盘快捷录音

已新增 watchOS 10+ 的 WiseLife 录音复杂功能，支持圆形、矩形、内联文字与角落位置。安装更新后的 Watch App 后，在支持复杂功能的表盘上：

1. 长按表盘 →「编辑」→「复杂功能」。
2. 选择一个位置 → 选择「WiseLife 录音」。
3. 回到表盘并轻点入口：打开 Watch 上的 WiseLife，空闲时开始长录音；首次使用需要允许麦克风。
4. 正在录音时再次点击入口，只返回录音页。点击 App 中的停止按钮，保存并按现有流程传到 iPhone。

录音入口不会因为重复点击而停止录音。正常从 App 列表打开仍需手动开始。授权期间退出到后台会取消该次快捷启动；延迟过久则提示重新点击，不在之后打开 App 时重放旧请求。图标表示入口，不展示可能延迟的实时录音状态。首次安装若暂时找不到，请先确认 WiseLife 已安装在手表，并打开一次 Watch App，再进入表盘编辑。

这项功能的逻辑、编译与打包已验证；表盘添加、实际录音、震动和权限界面仍需在配对 Watch 上验收。测试命令及真机清单见 [表盘录音验证记录](verification/watch-recording-complication.md)。

## 本机验证

在仓库根目录运行：

```sh
xcodebuild -workspace apps/wrist-notes/WristNotes.xcworkspace -scheme WristNotes -configuration Debug -destination 'generic/platform=iOS' -derivedDataPath /private/tmp/wristnotes-derived CODE_SIGNING_ALLOWED=NO build
swiftc -module-cache-path /private/tmp/wristnotes-modulecache apps/wrist-notes/Sources/Shared/VoiceNote.swift apps/wrist-notes/Sources/iPhone/NoteRepository.swift apps/wrist-notes/Tests/NoteRepositorySmoke.swift -o /private/tmp/wristnotes-store-smoke
/private/tmp/wristnotes-store-smoke
```

通用构建只验证编译与打包，不代表真实录音、Watch Connectivity、普通话 ASR 或 Foundation Models 已在设备上通过。

### 模拟器中保存 AI API Key

要在模拟器中测试钥匙串，使用 Xcode 正常签名构建；不要把 `CODE_SIGNING_ALLOWED=NO` 的编译检查产物安装进去。关闭签名也会跳过模拟器的应用身份权限，导致 Keychain 返回 `-34018`，与设备是否解锁无关。

在完成上文的原生 SDK 准备及 `pod install` 后，从仓库根目录运行：

```sh
xcodebuild -workspace apps/wrist-notes/WristNotes.xcworkspace -scheme WristNotes -configuration Debug -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -derivedDataPath /private/tmp/wiselife-simulator CODE_SIGN_IDENTITY=- CODE_SIGNING_ALLOWED=YES build
xcrun simctl install booted /private/tmp/wiselife-simulator/Build/Products/Debug-iphonesimulator/WiseNote.app
```

仅在构建成功后执行安装。此操作更新现有 App，保留其数据；不需要卸载 App 或重置模拟器。设备名称可替换成已有的 iOS 模拟器。模拟器使用临时签名，真机继续使用项目原有的开发者签名设置。

无需完整 App 或外部 AI 服务即可运行钥匙串回归检查（先启动一个 iOS 模拟器）：

```sh
python3 apps/wrist-notes/Tests/test_keychain_simulator.py --device booted
```

检查使用独立测试身份与虚构 Key，覆盖无权限错误、保存、读取、更新、跨进程持久化，以及保存失败时保留原设置；不会读取现有 App 的 Key。诊断记录见 [`verification/keychain-simulator.md`](verification/keychain-simulator.md)。

## EurekaRing 本地录音

以下为开启 `eurekaRing` 编译开关并补齐 SDK 后的流程；当前默认构建关闭该接入，隐藏相关入口。

首页硬件胶囊 →「连接硬件」→ EurekaRing，或「数据与设置」→ EurekaRing。可扫描绑定、重新连接、开始／结束录音、蓝牙同步、断开、解绑和格式化。结束录音后自动尝试同步；设备历史录音可点「同步录音」。首次使用需允许 iPhone 蓝牙权限。

音频经 SDK CRC 校验后，以 Opus → PCM → AAC/M4A（16 kHz、单声道、32 kbps）保存在现有 `VoiceNotes` 目录，进入原有播放和 Apple／Whisper 本地转写流程。没有上传、服务端会议创建或业务入库步骤。断开、解绑和格式化都保留手机已有笔记；格式化会单独确认并清空硬件全部录音。

原生入口位于相邻 `br_flutter_plugin_ble/ios/RecorderCore`；只链接 BRBluetoothLib 3.0.0 和 BRRecorderOpus 1.6.1（官方 libopus 源码）。没有引入 Flutter、`br_app_services`、Wi-Fi 快传或打点页面。SDK 的现有 Wi-Fi 等代码作为原生库的一部分存在，本次流程不调用这些功能。

Ring 闪念由硬件触发，结束通知后自动同步。SDK 已通过 CRC 校验的实时文件复用同一恢复、转换和保存流程；实时数据缺失时从设备 BLE 补同步，离线闪念也支持补同步。闪念显示在现有“一天 → 闪念”分类，支持回听、编辑、搜索。音频自动在本地转写，再由 Apple 本地模型整理核心想法和明确待办。即使其他笔记选择自定义 AI，Ring 闪念的整理仍固定使用本地模型；模型暂不可用时保留录音和全文，提示重试，不回退到远程服务。SDK 未提供 App 开始／结束闪念的指令，需在硬件上操作。

当前 SDK 若连接时设备已经在录音，会缺少停止指令所需的录音上下文：App 会显示真实录音状态，并提示在 Ring 上结束，再同步。验证范围及恢复策略见 [`verification/eureka-ring-native.md`](verification/eureka-ring-native.md)。

## 原型对齐验证（2026-10-18）

- 两端 SwiftUI 已更新，并已安装到现有模拟器。
- 截图与边界说明见 [`verification/README.md`](verification/README.md)。
- 本地逻辑检查：`sh apps/wrist-notes/scripts/test_local.sh`（仓库根目录执行）。
- Watch → iPhone 已在配对模拟器完成端到端验证：合成 AAC 到达 iPhone 并保存为笔记，Watch 收到保存回执后标记为“已上传”。此结果验证模拟器分片通道；实体设备文件传输、断连重传和熄屏录音仍需真机验收。

## 本地说话人区分

Apple 端上转写和 Whisper 均接入 SpeakerKit，录音结束后在手机上区分说话人。说话人模型约 11 MB，与所选转写资源通过同一个下载按钮准备，已有文件直接复用。全文可显示时间段、修改说话人名称及逐段修正文稿；整段替换全文后会清除旧标记。自动标签可能误分，名称仅用于本条录音。

实现与测试边界、独立于 Ring SDK 的验证命令、真机检查步骤见 [说话人区分验证记录](verification/speaker-diarization.md)。
