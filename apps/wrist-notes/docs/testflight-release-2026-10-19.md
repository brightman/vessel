# WiseLife TestFlight 发布记录

日期：2026-10-19。

## 当前结果

- 当前源码的 Release archive：`ARCHIVE SUCCEEDED`。
- App Store Connect 签名导出：`EXPORT SUCCEEDED`。
- iPhone 与内嵌 Watch 的签名均通过 `codesign --verify --deep --strict`，TeamIdentifier 为 `S56V68L4NP`。
- 两端显示名 WiseLife，版本 `1.0`，当前本地构建号 `3`。
- iPhone Bundle ID：`cloud.karama.wisenote`；Watch：`cloud.karama.wisenote.watchkitapp`。
- Watch 配置修复后已重新归档，`ARCHIVE SUCCEEDED`；修正版签名导出 `EXPORT SUCCEEDED`，iPhone/Watch 签名及内嵌 Watch 路径检查通过。
- **最新构建 3 上传成功**：2026-10-19 23:24:38（UTC+8），Apple 返回 `Upload succeeded` 和 `Uploaded package is processing`，Xcode 命令退出码为 0，末尾为 `EXPORT SUCCEEDED`。上传明细确认版本 `1.0 (3)`、Apple ID `6824527456`、`processingState=PROCESSING`。此前构建 1、2 分别于 22:04:53、22:18:52 上传成功；后续应使用包含新图标和隐私声明的构建 3。
- App Store Connect 显示名称现已保存为 **WiseLife: Apple Watch Recorder**。目前等待 TestFlight 构建处理完成，尚未验证可安装。
- 已创建内部组 `WiseLife Internal`（`6504f464-c2fe-43df-b210-eac3826978b0`），关闭自动分发。经用户明确指定两位受邀者后，当前账号已加入内部组；另一位不在 App Store Connect 团队用户列表，需要外部测试。尚无关联构建。
- Beta 描述、反馈邮箱和免登录使用说明已保存；尚未提交外部 Beta Review。
- **当前待办**：用户已恢复 Chrome 登录，已确认正确团队和 App；最新 TestFlight 页面仍显示 `No Builds`。上传日志确认最新构建 3 关联 Apple ID `6824527456` 并处于 `PROCESSING`，未取得失败原因。Mail 应用访问被自动审批拒绝，未绕过限制，已请用户提供 Apple 处理失败邮件（若有）。

### 构建 2 的补充声明

构建 1 上传后约十分钟尚未出现在 TestFlight。独立检查发现两端发布包缺少隐私清单，而实际使用了 required reason API；目前没有来自 Apple 的处理失败邮件或页面错误，不能认定清单缺失就是延迟原因。

已按 [Apple required reason API 要求](https://developer.apple.com/documentation/bundleresources/describing-use-of-required-reason-api) 补充两端 `PrivacyInfo.xcprivacy`，并加入 Xcode 资源及项目生成器：

- iPhone：`UserDefaults` / `CA92.1`，用于本 App 设置；`FileTimestamp` / `C617.1`，用于本 App 容器内文件元数据。
- Watch：`FileTimestamp` / `C617.1`，用于恢复本 App 容器内录音时间。
- 无广告跟踪。这里补充的是 required reason API 声明，没有将可选自定义云端 AI 描述为“绝不发送数据”。
- 两端构建号递增为 `2`。清单格式、项目资源/源码检查、Release 归档、Apple 上传校验全部通过。构建 2 签名导出成功，两端签名与清单入包检查通过。

## 首次失败原因与后续核对

Apple 返回：

```text
Error Domain=CDWebService Code=1085
No provider associated with App Store Connect user
error: exportArchive Error Downloading App Information
```

以上是上传早期的配置警告，并非最终失败原因。后续日志确认取得团队 `S56V68L4NP`，按 Bundle ID 查询 App 的请求返回 HTTP 200，但结果为 0 条；最终错误是：

```text
IDEDistribution.DistributionAppRecordProviderError.missingApp(bundleId: "cloud.karama.wisenote")
```

不能据此推断用户未登录，也不能推断 App 在所有团队中不存在。通过 CUA 控制原生 Chrome 成功访问用户已登录的 Apple Developer 与 App Store Connect，确认账号对应团队 `YONG FENG` / `S56V68L4NP`。网页中现已可访问匹配的 App 记录：

- Apple ID：`6824527456`
- Bundle ID：`cloud.karama.wisenote`
- SKU：`cloud.karama.wisenote`
- 主要语言：简体中文
- 原名称：`WiseNote`
- App Information：<https://appstoreconnect.apple.com/apps/6824527456/distribution/info>

复用该记录及已有归档重试上传，没有新建重复 App。首次日志的空结果与网页当前记录之间的变化原因尚未确认。

尝试将商店名称更改为 `WiseLife` 时，Apple 明确返回名称已被占用。随后按用户指定改为 **WiseLife recorded by watch**，页面显示 `Saved`，应用选择器同步显示该名称。设备内显示名仍为 `WiseLife`。

Xcode 界面曾被工具自动审批拒绝，未绕过该限制。浏览器专用连接不可用，但 CUA 的原生 Chrome 控制已成功；全程复用现有登录会话，没有读取或导出密码、私钥、Cookie 或会话令牌。

## Apple 包校验修复

第二次上传在 Apple 服务端校验时返回：

```text
Invalid Info.plist value. The value for the key 'WKBackgroundModes'
in bundle WiseNote.app/Watch/WristNotesWatch.app is invalid.
```

检查源码发现同时声明了 `UIBackgroundModes=audio` 与 `WKBackgroundModes=audio`。根据 [Apple 后台模式说明](https://developer.apple.com/documentation/xcode/configuring-background-execution-modes) 与 [WKBackgroundModes 定义](https://developer.apple.com/documentation/bundleresources/information-property-list/wkbackgroundmodes)，音频后台模式使用 `UIBackgroundModes`，`WKBackgroundModes` 用于运动及特定延长运行会话，不接受 `audio`。

已仅删除 Watch Info.plist 中无效的 `WKBackgroundModes`，保留 `UIBackgroundModes=audio`。`plutil -lint`、重新归档、内嵌 Watch 包检查通过，修正版也已通过 Apple 实际上传校验。

## 当前机器上的发布产物

- 历史构建 2 Archive：`/private/tmp/wiselife-testflight-20261019/WiseLife-build2.xcarchive`。归档关闭签名，后续导出已完成 App Store Connect 签名。
- 历史构建 2 已签名 IPA：`/private/tmp/wiselife-testflight-20261019/export-build2/WiseNote.ipa`。
- 已解包验证：`/private/tmp/wiselife-testflight-20261019/signed-verification-build2/Payload/WiseNote.app`。
- 签名、构建号、隐私声明及 IPA SHA-256：`/private/tmp/wiselife-testflight-20261019/release-verification-build2.json`。
- `WiseLife-release.xcarchive` / `export-fixed/WiseNote.ipa` 是已上传的构建 1，缺少隐私清单，后续以构建 3 为准。
- 原 `WiseLife-unsigned.xcarchive` 与 `export/WiseNote.ipa` 含无效 Watch 配置，是失败诊断产物，不应继续分发。
- 导出配置：`/private/tmp/wiselife-testflight-20261019/ExportOptions.plist`。
- 上传配置：`/private/tmp/wiselife-testflight-20261019/UploadOptions.plist`。自动管理上传时的构建号；以 TestFlight 最终显示为准。
- 构建 2 日志：`/private/tmp/wiselife-testflight-archive-build2.log`、`/private/tmp/wiselife-testflight-export-build2.log`、`/private/tmp/wiselife-testflight-upload-build2.log`。
- 构建 1 修正版日志：`/private/tmp/wiselife-testflight-archive-fixed.log`、`/private/tmp/wiselife-testflight-export-fixed.log`、`/private/tmp/wiselife-testflight-upload-fixed.log`。
- 首次/第二次失败日志：`/private/tmp/wiselife-testflight-upload.log`、`/private/tmp/wiselife-testflight-upload-retry.log`。

这些是本机临时产物；后续源码有变化时需重新归档。

## 本次成功上传命令

已执行成功，记录供后续发布参考：

```sh
xcodebuild -exportArchive \
  -archivePath /private/tmp/wiselife-testflight-20261019/WiseLife-build2.xcarchive \
  -exportOptionsPlist /private/tmp/wiselife-testflight-20261019/UploadOptions.plist \
  -exportPath /private/tmp/wiselife-testflight-20261019/upload-build2 \
  -allowProvisioningUpdates
```

## 继续步骤

1. 访问 [TestFlight](https://appstoreconnect.apple.com/teams/489f53fc-82e7-4439-b492-2a62c4991028/apps/6824527456/testflight)，确认构建 3 的处理结果。若出现处理失败，按 Apple 实际错误修复；不要把上传成功当成处理成功。
2. 如有加密合规问卷，按当前源码使用的系统 HTTPS/Keychain/CryptoKit 与实际依赖填写，确认最终测试状态。
3. 将构建 3 加入 `WiseLife Internal`，确认用户已授权添加的当前账号收到安装邀请。
4. 创建外部测试组并添加用户指定的另一位测试者，补齐 Apple 实际要求的 Beta 审核资料后提交；不得将对方直接添加成具有后台权限的 App Store Connect 团队成员。
5. 记录外测审核/邀请状态；Apple 审核未完成时不可宣称外部测试者已能安装。

用户已授权邀请两位测试者，当前账号已添加到内部组，登录失效前页面状态仍为 `No Builds Available`；外部测试者尚未添加，尚未提交外部 Beta Review。网页会话现已恢复，仍待构建处理完成，**完整测试分发尚未完成**。


## 图标与名称更新（构建 3）

- 按用户指定，将 `design/brand/wiselife-icon-v1/wiselife-icon-1024.png` 原样替换 iPhone 和 Watch 的 `AppIcon.png`。
- 两端源资产 SHA-256：`62991a854c536236c1b5d7cbe6979a1eaa840ddf2693ae3230a75c622fea862c`；均为 1024 × 1024、不透明 RGB PNG，未预裁圆角。
- 两端构建号递增至 3；项目生成器同步构建号并显式配置 `ASSETCATALOG_COMPILER_APPICON_NAME=AppIcon`。
- 项目源码/资源成员检查、Info.plist 格式和两端图标哈希检查通过；构建 3 `ARCHIVE SUCCEEDED`、`EXPORT SUCCEEDED`，两端 `codesign --verify --deep --strict` 通过。已核对两端版本号、隐私清单和编译资源，目视确认归档内 iPhone 小尺寸图标，Watch 资产中包含 1024 px `AppIcon`。
- 用户原指定商店名称 `WiseLife,recorded by Apple Watch` 共 32 字符，超出页面显示的 30 字符限制。用户确认建议名称后，已改为 **WiseLife: Apple Watch Recorder**（30 字符），App Store Connect 明确显示 `Saved`。设备显示名仍为 `WiseLife`。

### 构建 3 产物

- Archive：`/private/tmp/wiselife-testflight-20261019/WiseLife-build3.xcarchive`。
- 签名 IPA：`/private/tmp/wiselife-testflight-20261019/export-build3/WiseNote.ipa`。
- IPA SHA-256：`3a013f62344ad2321913ff85da3b4baa55303bcb92187560aacbc468f6f7fbf3`。
- 校验记录：`/private/tmp/wiselife-testflight-20261019/release-verification-build3.json`。
- 日志：`/private/tmp/wiselife-testflight-{archive,export,upload}-build3.log`。
- 首次上传因网络错误失败：`RETRIEVE UPLOAD OPERATIONS (ASSET_UPLOAD)`，状态 `-19235`，`The HTTP request did not return a response`。已确认 App Store Connect 重新可达（HTTP 200），重试已成功，日志 `/private/tmp/wiselife-testflight-upload-build3-retry.log`。2026-10-19 23:24:38（UTC+8）返回 `Upload succeeded` / `EXPORT SUCCEEDED`，退出码 0；明细确认版本 `1.0 (3)` 和 `processingState=PROCESSING`。上传后刷新网页，应用选择器显示新名称，TestFlight 仍显示 `No Builds`，尚不能关联测试组或生成安装邀请。
