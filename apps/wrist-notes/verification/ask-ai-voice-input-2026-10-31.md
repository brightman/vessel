# Ask AI native voice input — 2026-10-31

类型：持续验证记录。更新：2026-11-02。下方 10/31 结果为当时事实；最新启动与转写交互见 [11/02 修复](#voice-capture-20261102) 和[当前产品说明](../prototype/ai-date-range-design.md)。

## Delivered

- Hold the native Ask AI microphone for 0.2 seconds to begin capture; release to stop and transcribe into the draft. A short tap does not record. The listening card contains only status, waveform and timer. VoiceOver retains accessible start/stop activation.
- The native waveform uses real microphone average power, sampled every 70 ms. Nineteen recent energy samples scroll with fast attack and smooth decay; quiet input returns to baseline. Non-finite meter values are rejected, and each take starts with a fresh bounded history. Reduce Motion disables bar interpolation.
- Releasing during model/microphone preparation cancels the operation, preventing a late recording after permission completion. Interrupted gestures, navigation and backgrounding discard the take. The keyboard stays in place while holding, so the microphone does not move away from the finger.
- A maximum 60-second protected temporary recording using the iPhone microphone. No location collection, timeline item, automatic question submission, or remote ASR.
- The selected Apple or Whisper configuration is captured when input starts. Inference uses `LocalTranscriptionService.shared` and its existing serial model gate. Missing resources link to transcription settings; microphone denial links to system settings.
- Text replaces the selected draft range (or appends), then the user can edit and send. The native 300-character question limit remains; recognized text is retained for editing even when too long.
- Cancellation invalidates late callbacks. Temporary takes are discarded on success, failure, cancellation, navigation, backgrounding and parent-sheet presentation. Draft text survives tab changes in memory.
- Current microphone route is the built-in iPhone microphone, reusing the protected disposable capture path. Bluetooth headset capture is not selected for this input path.

## Verification

| Check | Result |
| --- | --- |
| `sh apps/wrist-notes/scripts/test_assistant_voice.sh` | Passed: energy response/history/silence/bounds/reset, release during preparation and recording, selected configuration, repeated start/finish, character-range/emoji insertion, missing model, recorder denial, interruption, empty speech, cancelled/late ASR, temporary-file cleanup, preservation of long transcript. Hardware and ASR are injected for these state tests. |
| `sh apps/wrist-notes/scripts/test_phone_recording.sh` | Passed existing recording-session tests. |
| `ruby apps/wrist-notes/Tests/ProjectSourceMembershipSmoke.rb` | Passed all source/asset membership checks. |
| Xcode simulator Debug build, `WristNotes.xcworkspace`, scheme `WristNotes` | Passed on iOS 26.3 simulator `332DEB86-4843-4543-8C73-4719B38DA704`. |
| Native XCTest UI test of installed simulator app | Passed, 1 test / 0 failures. Verified short tap does not record, a 6-second hold actually enters listening, release enters transcription without another tap, no card buttons, disabled sending, no automatic question submission, and preserved draft on leaving during transcription. Screenshot taken during the hold confirms the status-only card and keyboard position. |
| HTML prototype in headless Chromium | Passed pointer/keyboard hold and release, brief taps, cancellation, clock, display-only card and manual sending; no page errors. HTML remains an explicitly labeled demo without microphone access or ASR. |
| Generic iOS Debug build and `codesign --verify --deep --strict` | Passed. Existing unrelated deprecation/Watch asset warnings remain. |
| Install on connected Bright iPhone 16 Pro | Succeeded, bundle `cloud.karama.wisenote`. |

Native UI test artifacts and build logs: `/tmp/wiselife-ask-ai-native-20261031/`. The native UI project is isolated outside the repository. Latest results: `hold-ui-results.xcresult`, `hold-ui.log`, `hold-build.log`, `hold-device-build.log`, `hold-listening.png`, `prototype-hold.png` and `prototype-hold-test.cjs`. Earlier tap-based results remain archived as `ui-results.xcresult`.

Original build commands (the simulator command below was compile-only and must not be used for interactive installation):

```sh
xcodebuild -workspace apps/wrist-notes/WristNotes.xcworkspace -scheme WristNotes -configuration Debug -destination 'platform=iOS Simulator,id=332DEB86-4843-4543-8C73-4719B38DA704' -derivedDataPath /tmp/wiselife-publish-20261028/build build CODE_SIGNING_ALLOWED=NO
xcodebuild -workspace apps/wrist-notes/WristNotes.xcworkspace -scheme WristNotes -configuration Debug -destination 'generic/platform=iOS' -derivedDataPath /tmp/wiselife-publish-20261028/device-build build
```

Follow-up: installing the unsigned simulator output removed its effective Keychain entitlements and caused `-34018` in AI settings. Interactive simulator builds must use `CODE_SIGN_IDENTITY=- CODE_SIGNING_ALLOWED=YES`; validate `WiseLife.app-Simulated.xcent` before installation. See `keychain-installation-2026-10-31.md` for the corrected build and acceptance results.

## Device acceptance remaining

The simulator UI check verifies actual microphone startup and release-to-transcription, not recognition accuracy or waveform calibration on hardware. A full spoken question → local transcript → edited/manual-send interaction on the physical iPhone remains to be exercised. No physical-device ASR success is claimed by this report.

Launching the installed app on the phone was blocked by its lock screen: CoreDevice error `10002`, underlying `FBSOpenApplicationErrorDomain` error `7` (`Locked`). Installation itself succeeded; unlock the phone and open WiseLife to exercise the new input.

The installed development build includes the checkout's existing uncommitted work. This task did not create a Git commit or push.

<a id="voice-capture-20261102"></a>

## 2026-11-02：计时正常但文件为空、启动与松手反馈

环境：Bright iPhone 16 Pro，iOS 27.2，1.0.2 (10)。用户确认在真机直接长按，反馈启动等待、初始化及松手后卡片残留。

### 证据与修改

- LLDB 只检查采集状态、时长与音频格式。一次未在启动处暂停的长按在 `stop()` 读到 5.79848 秒，但停止后 `AVAudioFile` 仅有 960 个有效帧／44100 Hz，即 0.021769 秒；`afinfo` 和 `ffprobe` 独立确认仅有 3 个 AAC 包，非 ASR 返回空文本。测试音频仅留本机临时目录，不入库、不上传或提交。
- 会话跟踪没有发现开始到松手之间的额外 deactivate。系统输入未静音，路由是 `MicrophoneBuiltIn`。提前开启 metering 仍复现；48 kHz 的 duplex 对照也未恢复有效采集。退出 Device Hub 的 iPhone 屏幕流后同配置仍失败。
- 同机切为 `.record / .measurement / []` 的临时采集对照，4 秒录音得到 3.96916 秒有效音频。内置麦克风专用路径采用此配置；普通录音的蓝牙配置保持原逻辑。**后续反例否定其为已确认根因：**安装后用户仍报无有效音频，相同配置在后续测试中也有成功与失败，不能认定改 category 已修复采集问题。
- ASR 资源预检移到松手后；麦克风权限准备时松手仍取消。波形卡只用于准备／聆听，松手后切换紧凑的转写进度与取消入口；资源检查及转写总等待 60 秒超时，不自动发送。
- Ask AI 持有单独的采集活动 token 到转写结束／取消，避免 PhoneRecorder 停止时立即恢复批量长录音处理、抢占短语音的推理队列。仍使用统一串行门控，不并发加载第二套重模型。
- 缺少 draft 不再一概报短录音；计时超过 1 秒但音频不足 0.2 秒显示“麦克风未采集到有效音频”。

### 验证状态

- `test_assistant_voice.sh`：原基线通过；新用例在旧预检顺序与缺失超时处理上分别失败，修复后通过。覆盖慢资源不阻塞采集、松手立即退出聆听、权限准备取消、资源等待取消、超时清理、迟到结果不影响下一次录音及既有草稿插入行为。
- 原生签名构建与 `codesign --verify --deep --strict` 通过；15:05 安装至 Bright，BuiltAt `2026-11-02T07:04:15Z`。随后用户在真机报告仍出现“麦克风未采集到有效音频”，因此这轮安装未通过完整验收。
- 额外对照：同一 App 进程，基本采集／指定内置麦克风／prepare+文件保护／排除备份四组均有 0.021769 秒结果；切离 Device Hub 屏幕流后也复现。后来三组含 0／500／1000 ms 等待的 3 秒采集均得到 2.970703 秒，包含零等待组。环境随时间恢复，不能把延迟等待或退出投屏单独归为原因；没有据此添加固定延迟。
- 用户随后报告第一次输入已成功写入草稿、第二次长按要约 4 秒才显示波形卡。已停止自动采集实验，避免与手工操作重叠。
- 发现确定的刷新放大：`duration`、`waveform` 每 70 ms 发布到整页观察的对象，重建会话及其资料摘要校验。新增订阅测试先在旧实现失败，再将采样数据分离到仅由 `AssistantVoiceListeningCard` 观察的 `AssistantVoiceMeter`，回归通过。此修复减少刷新范围，不宣称已经证明 4 秒延迟全部由它造成。
- 第二轮签名构建通过（`meter-device-build.log`），尚未覆盖安装：用户明确保留了未发送草稿，等待其发送／保存后继续真机验证。录音 session 回归、源成员检查、JS 语法和 `git diff --check` 通过；浏览器工具 host unavailable，未验证本轮 HTML 视觉效果。调试器已解除附加，未提交或推送。

### 15:39：第二轮构建已安装

用户明确回复“可以安装”后，复核签名并使用 `xcrun devicectl device install app` 将 BuiltAt `2026-11-02T07:24:26Z` 的优化版安装到 Bright，返回成功（bundle `cloud.karama.wisenote`）。启动命令已发出，Device Hub 显示“WiseLife is protected”，尚待用户在真机完成 Face ID。

本轮由用户连续输入两段语音（第一段不发送）验证启动延迟、松手状态及草稿追加；不同时运行自动采集，避免干扰。安装成功不等于上述真机验收已通过，结果待用户反馈。未重新安装或操作 Watch，未提交／推送。

### 第二轮真机反馈：采集仍失败

用户再次报告“麦克风未采集到有效音频”。因此第二轮安装未通过采集验收；波形刷新优化不能作为音频采集已修复的证据。继续采集真实长按路径的启动耗时、AudioQueue 输入回调及停止事件，先定位丢失边界，再决定修复。不与用户同时启动自动录音。

### 15:52：安装无调试器诊断版，仍待采集复现

- 当前进程临时跟踪没有捕获到用户长按，不能得出新的输入回调结论；已解除 LLDB 附加并退出。没有并发运行探针录音。
- `PhoneRecorder` 增加仅 Debug 启用的本地元数据日志：权限、category／activation／preferred input／prepare／record 各阶段时间、每秒最多一次 metering、route／interruption／media-services 通知、保护数据可用性、前后台状态和停止前时钟／封存后有效时长。
- 日志不包含语音、转写、路径、位置、设备名称或凭据；异步写入临时目录 `wiselife-microphone-diagnostics.log`，完整文件保护，超过 128 KiB 覆盖。仅供本机排查，不入业务数据库或上传。不以诊断代替修复。
- `test_assistant_voice.sh`、`test_phone_recording.sh`、源成员检查、指定文件 `git diff --check` 通过。真机 Debug 构建与签名检查通过；BuiltAt `2026-11-02T07:48:32Z`，同为 1.0.2 (10)。确认输入框无草稿后，沿用此前安装授权安装至 Bright，`devicectl` 返回成功。
- 真机采集／转写验收仍未通过：需要在此构建上复现一次后读取日志。未改录音算法，未安装 Watch，未提交或推送。

### 15:55–16:02：确认 Device Hub 屏幕共享干扰采集

用户确认诊断版仍报无有效音频。读取 `tmp/wiselife-microphone-diagnostics.log` 得到：权限允许；启动到 `record()` 成功 0.189 秒；全程内置麦克风、未静音、前台、保护数据可用；没有中断／media-services reset；音量持续为 -120 dB。录音时钟 9.394 秒，封存后有效音频仅 0.021769 秒。因此不是 ASR 或初始化花费了整个说话时间。

随后在同一 App 进程（PID 2837）运行串行、3 秒短录音对照。两种格式交替：AAC 44.1 kHz 和未压缩 PCM 48 kHz，均为内置麦克风／record／measurement。只读取帧数、时长、音量；各段测试音频当场删除。用户未同时启动录音。

可复查的脱敏元数据：[14 次采集对照结果](ask-ai-microphone-devicehub-2026-11-02.json)。

| 屏幕共享状态 | 样本 | 结果 |
| --- | --- | --- |
| Device Hub 正在显示 iPhone 屏幕 | 2 AAC + 2 PCM | 全部失败；AAC 仅 960 帧／0.021769 秒，PCM 为 0 帧；均 -120 dB |
| 关闭屏幕共享，界面回到 `View Screen` | 2 AAC + 2 PCM | 全部成功；有效时长 3.040、3.151、3.110、3.128 秒，音量有变化 |
| 再次点 `View Screen` 开启共享 | 1 AAC + 1 PCM | 再次全部失败；AAC 960 帧、PCM 0 帧；均 -120 dB |
| 再次关闭 Device Hub 共享 | 2 AAC + 2 PCM | 再次全部成功；有效时长 3.087、3.036、3.087、3.128 秒。该轮同时采用 App 的 complete 文件保护和 `record(forDuration:60)`，手动 3 秒停止 |

**结论边界：**当前 iPhone 16 Pro／iOS 27.2／Mac Device Hub 屏幕共享组合可重复导致采集不到输入，停止共享即可恢复。此处的“关闭”有 `View Screen`／退出应用的界面证据，不能与此前仅切换设备列表混同。结果覆盖同一进程内的 AVAudioRecorder 采集，尚不能断言所有 iOS 投屏方式都会如此，也不能替代 Ask AI 的长按→本机 ASR→草稿验收。尝试直接在 LLDB 构造内部 `PhoneRecorder` 时类型不可见，未执行；没有把该尝试计入通过数。

16:02 已解除 LLDB 并退出，Mac 设备共享保持关闭；未再次安装 App，仍为 BuiltAt `2026-11-02T07:48:32Z` 的诊断版。请用户直接在 iPhone 连续输入两段（第一段不发送），确认实际 UI、ASR 与草稿追加。保留调试元数据记录；没有为该外部干扰重写录音引擎或更改 ASR。
