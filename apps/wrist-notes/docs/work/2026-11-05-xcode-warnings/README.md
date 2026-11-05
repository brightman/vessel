# WiseLife Xcode issues 与运行时卡顿诊断

类型：修复与验证记录。更新：2026-11-05。状态：代码与定向自动测试完成，最终构建结果见下文；真机验收待完成，未发布。范围：iPhone／Watch 原生 App。

证据范围：下文现场诊断、完整 Release 归档及 IPA hash 来自 `/Users/karama/Documents/Vessel` 的未提交工作区，该工作区还包含其他任务。文末“GitHub 分支整理”单独记录本次抽取到 `codex/wiselife-notebook` 的代码与复验结果；历史 IPA 不作为该隔离分支的发布产物证明。

关联：[录音详情](../../../prototype/record-management-design.md)、[生活数据读取](../../2026-10-20-health-background.md)、[Watch 录音](../../watch-to-iphone-hourly-recording-sequence.md)、[HealthKit 打包修复](../../testflight-release-2026-10-19.md#healthkit-signing-20261105)。

## 现场与修复

通过 computer-use 打开 `WristNotes.xcworkspace` 的 Xcode Issue Navigator，实际看到 12 项构建 issue（1 项推荐设置、3 项 iPhone Swift 警告、8 项 Watch 警告）以及历史调试会话的 2 项运行时诊断。`WiseLife - 1295` 中的 1295 是进程号，不是警告数量。

| 诊断 | 原因与修复 |
| --- | --- |
| `ASPresentationAnchor.init()` 弃用 | 登录 session 使用持有已验证 key window 的 presentation provider，移除无 scene 的空窗口兜底；取消时释放。 |
| 两项 weak capture 所有权不一致 | 明确 AudioProcessing 外层 weak self 与 NotebookIdeas 外层 settings 生命周期；不改生成行为。 |
| 7 项 OSAtomic 弃用 | Watch 使用 C11 strong sequentially consistent CAS／load；编译期要求 int32 始终 lock-free，保持采集回调无锁和四状态所有权协议。 |
| Watch 缺少 AccentColor | 补入已有品牌红色资源。 |
| 推荐项目设置 | 开启 dead stripping、脚本 sandbox、独立目标并行、字符串与资源符号生成；同步生成脚本。 |
| 字符串生成重名 | 推荐设置暴露“这一天还没有地点记录”与带句号版本生成同名符号；仅对带句号版本设 `generatesSymbol=false`，保留两条文案、全部翻译及原调用。 |
| Watch AppIntents metadata skipped | 主 Watch App 无 App Intents，只有该 target 设置 `LM_SKIP_METADATA_EXTRACTION=YES`；iPhone、Activity、Watch Widget 仍提取。未全局屏蔽警告或添加无用框架。 |
| AVAudioSession Hang Risk | `AudioPlayback` 与范围播放器的 activation／deactivation 移到串行后台队列；普通文件播放器的创建／准备／播放／暂停／停止／进度读取同样归队列所有，UI 只接收值快照。lease 取消、所有权、录音 barrier 防止迟到播放抢占录音或旧页面停止新播放。 |
| CoreLocation 主线程同步调用 | 先读授权状态并使用 delegate；仅 denied 时在后台读取系统定位总开关，缓存并更新 denied／unavailable，前台状态刷新继续重查。 |
| HKHealthStore 初始化读文件 | 按需独立 worker 初始化一次；普通启动异步等待，冷后台启动使用直接完成屏障，在 delegate 返回前安装观察查询；来源关闭不初始化。 |
| 模拟器缺少健康声明 | 模拟器专用 entitlement 补齐 HealthKit 与 background-delivery，保留原 Keychain 配置；实体发布包由独立校验器检查。 |

录音取消时只有实际持有 recorder 的对象可以停用会话；capture token 保留到停用完成。未激活的详情页关闭不会触碰其他音频。没有数据库结构、录音格式或权限范围变更。

## 定向验证

环境：macOS、Xcode 27.2（本机 SDK）；iPhone 最低 iOS 26、Watch 最低 watchOS 10 保持。

以下检查通过：

- `sh scripts/test_chatgpt_loopback.sh`：协议／回调回归与 Swift 6 iOS adapter typecheck。
- `sh scripts/test_content_v2.sh`：84 项及生产路径 smoke；`sh scripts/test_notebook_ledger.sh`。
- `sh scripts/test_playback_audio_session.sh`：后台线程、idle／stale／幂等 release、取消启动、快速重启、播放与录音交接、取消录音清理、激活错误。测试替换 OS 音频调用，队列与所有权采用生产实现；去掉取消检查的临时 mutation 按预期失败。
- 同一脚本的 `PlaybackFileTransportSmoke` 验证生产 AudioPlayback 的后台播放器操作、pause／resume、EOF／重播、取消准备后的清理屏障、过期快照、播放失败及系统中断。审查发现并修复了“中断误判为 EOF”“play 返回覆盖新的中断”“零时钟抹掉恢复进度”三处边界；最终复查通过。播放对象仅由队列字典持有，析构清理也归队列。
- `sh scripts/test_recording_playback_clock.sh`、`sh scripts/test_phone_recording.sh`、`sh scripts/test_health.sh`，以及 `test_local.sh` 对应 LifeSourceModelSmoke 编译运行通过。`test_local.sh` 已接入新播放测试并修正该模型当前所需的编译输入；本轮未据此声称完整 test_local 全部运行。
- `sh scripts/test_health_preparation.sh`：实际 LifeSourceReader 配合替代 OS 边界的 HKHealthStore 子类，验证后台仅初始化一次、普通启动不等待、关闭／不可用、准备及投递期间暂停／重开、重复注册、pending／active 读取取消；冷后台屏障返回前已注册查询且幂等。独立审查未发现屏障死锁／重复注册问题。
- `sh scripts/test_capture_pool_rejection.sh` 与 `CAPTURE_TSAN=1 sh scripts/test_capture_pool_rejection.sh`：拒绝路径、held slot／拷贝隔离／FIFO、100,000 次并发双声道可变帧交接、首错优先；TSan 无发现。
- `sh scripts/test_hourly_recording.sh`：小时边界、元数据、持久化、重开与删除检查。
- Watch `arm64`、`arm64_32` 的 watchOS 10 C `-Wall -Wextra -Werror` 和 Swift `-warnings-as-errors` 编译／类型检查通过；C helper 不依赖原子锁 fallback。
- `ruby Tests/ProjectSourceMembershipSmoke.rb`、`ruby -c scripts/generate_project.rb`；`xcstringstool generate-symbols` 在修复重名后通过。

## 完整构建与现场复查

首次 Debug Simulator 构建成功，完整日志无 warning／error；随后启用字符串符号生成时暴露上述冲突，已修复，保留失败事实。

10:07 computer-use 复查 Xcode：通用 iOS 设备构建 `Build Succeeded`，原 12 项构建 issue 全部消失；只保留历史会话的两项运行时诊断。之后通过 Product → Destination 菜单切换到 `WiseLife Notebook Review` 并运行，新调试会话的 Issue Navigator 为空；没有使用 Clear All Issues 或过滤器隐藏诊断。

`simulator-final.log`、`package-final.log` 和 `package-verified.log` 对应中间构建／归档／导出成功，均为 0 warning、0 error。后两份 IPA 的实际签名及 profile 两项 HealthKit 权限均通过；`package-verified` 包含最终资源符号设置。这些产物早于下述新增 HealthKit 初始化修复，不作为最终代码的验收产物。后续一次 `final-release` 归档为等待播放中断边界修复而主动中止（`ARCHIVE INTERRUPTED`），不是编译错误。

模拟器冷启动检查在系统日志中另捕获了 `Slow Launch Risk`／`Hang Risk`。符号化发现一组应用调用为 `WiseLifeAppDelegate → WiseLifeRuntime → LifeSourceReader → HKHealthStore.init → NSData`，已按上表修复；仅异步注册的中间方案经审查发现可能改变后台唤醒时序，最终增加冷后台屏障，未发布该中间方案。另外存在系统 `dlopen`／`NSBundle` 及现有启动存储 I/O 的诊断，不能用一次调试启动认定生产耗时或声称全量运行时风险已消除。模拟器专用 entitlement 原本未声明 HealthKit，已补齐；最终模拟器连接结果见后续复查。

模拟器播放交互：在专用 QA 设备中追加一段 15 秒、低音量的合成正弦音频（ID `F16EBA93-46D6-437B-909D-A78C43144290`），由现有孤立文件恢复路径导入；未读取或录制用户音频。computer-use 依次打开“查看全部 → 原始录音 → 完整录音”，点击播放，观察到“暂停播放”及播放位置从 0 到 1 秒；暂停、关闭、重开时位置为 0；再次播放并立即关闭也回到列表。Xcode 新会话 Issue Navigator 为空，但进一步检查系统日志发现 `AudioPlayback.startPlayer → AVAudioPlayer.play` 隐式准备硬件仍可能触发主线程诊断，因此继续修复播放器操作队列。合成音频无语音、QA 缺少转写资源导致 ASR 失败，不把该示例作为转写验收。

最终代码 Debug Simulator 构建 `simulator-accepted.log` 退出 0，`BUILD SUCCEEDED`，完整日志 0 warning、0 error。`simctl install` 与 `simctl launch --terminate-running-process` 均退出 0，启动返回应用 PID；没有卸载或清空 QA 数据。最终模拟器生成的 `WiseLife.app-Simulated.xcent` 包含两项健康声明；模拟器 capability 不以实体设备的签名 plist 方式表示，不能用模拟器 `codesign -d` 不含该键判定发布签名失败。

10:56 再次通过 computer-use 在 Xcode 执行 Build，界面显示 `Build Succeeded`，Issue Navigator 为空，过滤文本为空、`Show only latest issues` 与 `Only errors` 都未开启。最终交互复查受 Device Hub 持续 `Connecting display…` 阻塞：重启该 QA 模拟器及重新打开 Device Hub 后仍未恢复显示，因此最终队列播放器的自然结束／重播 UI 未完成复查；上述模拟器播放交互仅适用于重构前，最终播放行为由生产路径定向测试验证。

最终 Release 产物 `release-accepted` 包含上述健康初始化和完整播放器队列修复。`package_release.sh` 退出 0，`release-accepted.log` 同时包含 `ARCHIVE SUCCEEDED`、`EXPORT SUCCEEDED`，完整日志 0 warning、0 error。归档与 IPA 校验 JSON 均为 `ok: true`，实际签名及 profile 的 `healthkit`、`healthkit.background-delivery` 均为 true；最终 IPA 的 `distribution: true`（含 `get-task-allow=false` 检查）。

- 产物：`/private/tmp/wiselife-warnings-20261105/release-accepted/export/WiseLife.ipa`。
- 标识：1.0.3（13），16,340,596 字节。
- SHA-256：`397b3757c3623269c3b09c36f4fc5b5cef6b776b5ef492271c1a778f616132cf`。
- 最后定向复核：`playback-accepted.log`、`health-preparation-final.log`、`health-final.log` 对应测试通过；项目源文件归属检查、Ruby 语法检查与 `git diff --check -- apps/wrist-notes` 通过。

复现命令从仓库根目录执行：

```sh
xcodebuild -workspace apps/wrist-notes/WristNotes.xcworkspace -scheme WristNotes \
  -configuration Debug \
  -destination 'platform=iOS Simulator,id=3898445B-1B0A-4D10-94DA-FFA88744E5C5' \
  -derivedDataPath /private/tmp/wiselife-notebook-build \
  -disableAutomaticPackageResolution -jobs 3 \
  CODE_SIGN_IDENTITY=- CODE_SIGNING_ALLOWED=YES build

sh apps/wrist-notes/scripts/package_release.sh OUTPUT_DIRECTORY \
  /private/tmp/wiselife-testflight-build13 \
  /private/tmp/wiselife-notebook-build/SourcePackages
```

日志目录：`/private/tmp/wiselife-warnings-20261105`；本记录保留命令、结果及限制，不将临时日志作为唯一证据。

## 尚未验证与发布边界

本次 `devicectl list devices` 中实体 iPhone `Bright` 为 unavailable。历史调试会话的两条运行时诊断没有人为删除；实际硬件上的反复打开详情、播放／暂停、播放转录音、权限取消，以及长时间 Watch 录音仍需真机复测。自动测试、编译成功不能证明实际音频可听或量化 UI 耗时。独立代码审查未发现此次播放重构必须修复的问题；PhoneRecorder 既有的录音 session 配置仍为同步主线程调用，本次只处理现场指向的播放调用及其交接，不能声称全部 AVAudioSession 调用都已移出主线程。

本次没有安装实体设备、上传 TestFlight、提交或推送代码。签名包沿用 1.0.3（13）只用于验证；再次发布必须增加 build number。HealthKit 签名修复另见关联发布记录。

## GitHub 分支整理（2026-11-05）

用户随后明确要求推送 GitHub。复用干净的 `/private/tmp/wiselife-notebook-publish-20261103`，以 `codex/wiselife-notebook` 的 `3b9d0e5` 为基线，抽取联系人五字段代码／原型、上述 Xcode 与 HealthKit 修复及相关文档。保留基线已有提交历史与主工作区其他改动；未带入 Watch 保留期、回顾／Face ID／播放时刻等其他任务。版本对齐为 1.0.3（13），本轮不上传发行包。

抽取后使用通用 iOS Simulator 目标重新构建，完整日志 `build-final.log` 为 `BUILD SUCCEEDED`、0 warning、0 error。该目标额外编译 Intel 架构，首次暴露第三方 `distance-sse2.c` 的 64 位汉明距离累加值窄化警告；累加器改为 `int64_t` 后，iOS Simulator x86_64 的 `-Wshorten-64-to-32 -Werror -fsyntax-only` 检查与重建通过。未屏蔽警告。

独立集成审查确认 iPhone、Watch、Activity、Widget 的实际 source list 与 generator 一致，新 PlaybackAudioSession／RecordingAtomics 和相关测试依赖完整。项目归属、Ruby／原型 JS 语法与差异空白检查通过。全量旧 `test_local.sh` 未通过：既有编译命令漏传 `AudioStableID`／`AudioSourceID` 及联系人存储依赖；临时补齐后又遇到 `AudioProcessingSmoke: invalid operation accepted`，另一个旧 AppleReminders 测试断言数据库版本过期。对应生产／断言文件逐字节与基线一致；临时扩大范围的脚本改动已撤回，没有放宽断言或据此宣称全量测试通过。新功能的专项结果另列于下方。

本次分支构建命令（仓库根目录）：

```sh
xcodebuild -workspace apps/wrist-notes/WristNotes.xcworkspace -scheme WristNotes \
  -configuration Debug -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath /private/tmp/wiselife-notebook-publish-build \
  -clonedSourcePackagesDirPath /private/tmp/wiselife-notebook-build/SourcePackages \
  -disableAutomaticPackageResolution -jobs 3 CODE_SIGNING_ALLOWED=NO build
```

日志目录：`/private/tmp/wiselife-github-push-20261105`。该无签名命令仅用于模拟器编译，实体发布仍必须使用前述带签名归档脚本。

隔离分支专项复验均通过：

- `test_notebook_people.sh`（含 SwiftUI typecheck）、`test_speaker_contacts.sh`：五字段、额外资料保留、冲突、磁盘重开与录音关联。
- `test_capture_pool_rejection.sh`、`test_hourly_recording.sh`：C11 原子采集、100,000 次并发交接与小时文件生命周期。
- `test_chatgpt_loopback.sh`：登录回调与 iOS adapter typecheck。
- `test_playback_audio_session.sh`（由完整测试入口前段执行通过）：生产播放模型及会话队列的取消、交接、暂停／恢复、过期结果和中断。
- `test_health_preparation.sh`、`test_health.sh`：独立 worker、冷后台观察注册屏障及健康快照生命周期。
- `test_content_v2.sh`、`test_notebook_ledger.sh`：84 项内容检查、生产路径 smoke 与记账／灵感存储回归。
- SSE2 实际 x86_64 二进制测试：0–257 字节共 258 个长度，SIMD 汉明距离均与标量 popcount 参考一致。
