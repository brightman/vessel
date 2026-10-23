# Watch 安装诊断（2026-10-23）

用户确认失败入口是 **iPhone 的 Watch App → 安装**。Mac 的开发连接断开会阻止采集设备日志和 Xcode 直接部署，不能单独解释这个入口的失败。尚未拿到本次手机分发失败的安装错误码，不能把下面的隐患全部判定为本次根因。

## 已核实的结果

| 检查 | 结果与含义 |
| --- | --- |
| 当前 Release 归档嵌入 | `WiseNote.app/Watch/WristNotesWatch.app` 正确；表盘组件位于 Watch 的 `PlugIns`，没有放进手机 `PlugIns`。 |
| 当前归档的身份与版本 | 手机 `cloud.karama.wisenote`，Watch 为其 `.watchkitapp`；`WKCompanionAppBundleIdentifier` 正确；四个 bundle 均为 1.0 (5)。没有复现归档的版本或伴随 ID 错误。 |
| 当前正式签名构建 | 不开放在线签名更新的 Debug generic iOS 构建退出 65，四个 target 均报 `No profiles for … were found`。这是当前电脑正式签名资产缺失的证据，不是手机上本次点击失败的设备日志。 |
| 最近打出的临时开发包 | `dist/WiseLife-1.0.5-iPhoneAir-core-dev-clean.ipa` 使用 `com.vessel.wristnotes.dev9jzlk3xhyk` 及对应 Watch ID、团队 `9JZLK3XHYK`；与工程的正式 ID/团队不同，不能视为同一 App 的原位更新。手机目前实际安装的是哪套身份仍待连接核实。 |
| 临时包签名 | 手机和 Watch 的 `codesign --verify --deep --strict` 均通过；签名 entitlement 与各自 profile 的 App ID、Team 一致；两份 profile 都包含本次测试 Watch 和 iPhone UDID，检查时尚未过期。不能把缺少手表 UDID或当前已过期作为这份包的失败原因。 |
| 临时包有效期 | Watch profile 到期为 2026-10-26 08:59:27 UTC，手机为 09:40:30 UTC。需要重新签名才能继续使用过期后的开发包；该临时包不含两端录音组件。 |
| Mac 开发通道 | 两端缓存状态为 `developerModeStatus: enabled`、`pairingState: paired`、`tunnelState: unavailable`，当前不能读取安装中的设备日志。Xcode Watch scheme 没有可用的物理手表目的地。查询到的 OS 版本属于缓存，不将其当作本次实时连接信息。 |
| 历史直接部署记录 | 本机历史 JSON 有 Watch 临时开发 ID 安装成功的记录；另有 CoreDevice 连接建立失败记录。说明调试通道确实有过不稳定，但不能据此判定手机 Watch App 的安装错误。 |

## 本次修正

- 生成脚本原本将手机构建号重置为 4，Watch 的 Info.plist 则写死 5；重新生成工程会产生不一致。现在保留手机 Debug/Release 各自版本与构建号，Watch 和两个组件同步使用对应配置；Watch Info.plist 从构建设置展开版本。
- 增加共享 `WristNotesWatch` scheme，便于在 Xcode 单独部署并核实手表结果；手机部署成功不再作为 Watch 已更新的验收依据。
- 补充四个 target 的签名文档，避免漏掉 `WiseLifeWatchRecordingWidget`。
- 扩展已有嵌入检查：核对手机/Watch 的伴随 ID、版本，以及两端扩展的 ID 范围、平台和版本。该检查明确不验证签名。

## 本次验证

- `WatchInstallConfigurationSmoke.rb` 通过：当前工程四个 target 的版本与 Team 一致；临时目录内新建工程、修改手机各配置版本后重新生成，版本保留并同步；共享 scheme 的启动目标为 Watch。
- `WatchRecordingWidgetProjectSmoke.rb` 和 `ProjectSourceMembershipSmoke.rb` 通过。
- `EmbeddedWatchSmoke.sh` 在原归档和修正后的 Debug 真机架构产物均通过；故意改错构建号或伴随 ID 时被拒绝。
- `test_watch_recording_widget_bundle.py` 在修正后的完整 Debug 产物通过。
- workspace Debug generic iOS 无签名构建通过，包含 Watch 和两端组件。日志 `/private/tmp/wiselife-watch-install-unsigned-build.log`。
- 正式签名失败日志 `/private/tmp/wiselife-watch-install-signing-check.log`；未执行在线 profile 创建、换 Team、卸载或清空数据。

## 手机 Watch App 安装失败的下一次取证

1. 手机连接 Mac、解锁，先确定当前手机 App 的 Bundle ID、构建号和 profile 有效期；核对手机实际携带的 Watch 包，不能以仓库内最新归档代替已安装版本。
2. 在手机 Watch App 点安装时，捕获 iPhone 的安装/Watch 分发日志（包括 `installd`、`appconduitd`、`ACX` 相关错误），必要时补充 Watch 安装日志；保留错误域、错误码和失败阶段，不采集录音内容。
3. 签名或授权失败：沿用设备现有 App 的身份，补齐该身份的手机、Watch 和两个组件的有效签名；核实描述文件设备清单。传输失败：再核对手机与手表连接、空间和系统错误。
4. 部署前确认手表没有进行中的录音，并保全尚未同步的原件；原位覆盖安装后分别核对两端版本、Watch 普通启动和原有录音保留。

参考：[Apple 的真机运行与签名说明](https://help.apple.com/xcode/mac/current/en.lproj/dev5a825a1ca.html)、[watchOS 伴随 App 的 Bundle ID 关联规则](https://developer.apple.com/documentation/technotes/tn3157-updating-your-watchos-project-for-swiftui-and-widgetkit)。
