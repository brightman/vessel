# 模拟器 AI 设置保存失败

日期：2026-10-19；2026-10-20 补充关闭 Ring 后的完整构建及安装验证。

## 根因

用户截图显示连接测试成功，但保存时提示“请解锁 iPhone”。模拟器 `securityd` 对同一 App 的读取和更新操作明确返回：

```text
NSOSStatusErrorDomain Code=-34018
Client has neither application-identifier nor keychain-access-groups entitlements
```

当前模拟器安装的是旧 `WiseNote` 构建 1，二进制只有 linker 生成的临时签名，没有可用的钥匙串应用身份权限。`CODE_SIGNING_ALLOWED=NO` 适合只检查编译，不适合验证 Keychain。

原 `KeychainSecretStore` 把所有 Security 框架错误都变成“请解锁 iPhone”，丢失了真实错误码，误导了排查。

## 修改

- 读取、更新、新增失败均保留实际 OSStatus。
- `-34018` 提示应用签名缺少钥匙串权限；只有 `errSecInteractionNotAllowed` 才建议解锁；其他错误显示实际状态码。
- 读取成功但数据无法解码时按 `errSecDecode` 报错。
- 继续使用原来的 Keychain service/account 与 `WhenUnlockedThisDeviceOnly`，没有迁移、清除或明文保存 Key。
- README 补充正常签名构建和覆盖安装方式。

## 验证

`python3 apps/wrist-notes/Tests/test_keychain_simulator.py --device <booted-ios-udid>` 使用实际生产 `KeychainSecretStore` 和 `AppSettings`，在模拟器中运行无 UI 的命令行测试进程：

1. 修改前，无权限错误未保留 `-34018`，回归检查按预期失败。
2. 修改后，无权限读取／保存返回准确错误，保存失败不会启用或持久化新配置。
3. 使用与 Xcode 相同的模拟器权限机制，Keychain 新增、读取、更新全部通过。
4. 三个独立进程验证初始 Key、更新后的 Key 及配置持久化。
5. 测试 Key 不进入 UserDefaults；只清理随机测试命名空间中的虚构 Key。

模拟器的 iOS 权限由 Xcode 链接到 Mach-O 的 `__TEXT,__entitlements` 段。不能直接把 iOS 受限权限加到 macOS 的临时代码签名中；测试遵循 Xcode 的模拟器机制，没有修改系统安全设置。

原有 `AISettingsSmoke` 也已通过，覆盖配置验证、持久化、模型请求、错误处理、测试竞态和 Watch 状态。

日志：`/private/tmp/wiselife-keychain-red.log`、`/private/tmp/wiselife-keychain-green.log`。测试不访问网络，也不读取用户 API Key。

## 安装状态与外部依赖

- TestFlight 构建 3 的已签名包包含 `S56V68L4NP.cloud.karama.wisenote` 应用身份；这只验证签名配置，不代表已经在 TestFlight 真机上完成 Keychain 交互验收。
- 最初完整源码的模拟器重编译遇到独立的依赖缺失：`Pods-WristNotes.debug.xcconfig` 不存在，Podfile 指向的原生适配层及 Opus 尚未恢复。相邻插件和蓝牙 SDK 目录现已按下面记录下载；随后用户明确要求关闭 Ring，默认构建已解除该阻塞，见下节。
- 用户已指定 `git@git.100credit.cn:ai2c/app/flutter_lib/br_flutter_plugin_ble.git`，分支 `dev-300`。用户在 Chrome 登录后，已通过 GitLab 下载源码 ZIP 并解压到 `/Users/karama/Documents/br_flutter_plugin_ble`，未读取浏览器凭据。它是源码快照，不含 Git 历史。
- ZIP 注释确认提交 `627569fbb186a5615651a9344b285656f7d138dc`，完整性检查通过；SHA-256 为 `67daf8b9ce5c7aaba57c13204c0510c864112903500eb35e6a803108e4565e22`。来源记录保存于 SDK 根目录 `SOURCE_DOWNLOAD.json`。
- 2026-10-20，按用户补充的 `br_app_services` / `dev-301` 下载源码 ZIP，提交 `d985c6f72154ea12bb31e2d7712bea01deba3a0d`，SHA-256 `2149dd33c5354c7c3cc5924fd569d0eb0d53a81a490ec3eb7ebef008f85d3f3f`。只提取设备门面、本地传输／转码适配、闪念分类及其相对 import 依赖，共 49 个 Dart 文件和 3 个上游说明文件，保存至 `/Users/karama/Documents/br_app_services`；`SOURCE_DOWNLOAD.json` 记录逐文件哈希，`EXTRACTION.md` 说明范围。该目录是源码参考快照，没有引入 App 构建。
- 该 services ZIP 全量文件列表中没有 Swift／Objective-C／头文件／podspec／RecorderCore。其音频转换器通过 Flutter 插件调用 Opus → MP3，不能代替本工程的原生 AAC/M4A 转换器。上游 `pubspec.yaml` 指向 BLE 插件 `v3.0.0`，与用户下载的 `dev-300` 不同；未安装 Flutter 依赖或改变现有版本。
- 2026-10-20，按用户补充的 iOS SDK 下载 `bairongble-ios/develop-sync`；原地址 `.gi` 已由 GitLab 页面及 podspec 核对为 `.git`。提交 `d70596a298cb4844641ff05cdbbe384b7f804d46`，ZIP SHA-256 `0c4a07c341d5adaea202c28f8c1888e6ea45260d34935dff9e41994aaf1ed4b8`。提取源码、测试、podspec、Package.swift 和说明文件到 `/Users/karama/Documents/bairongble-ios`，共 99 个上游文件；源码保持原样。完整 ZIP 留在 Downloads，未解压示例或发布二进制。
- 该 SDK 提供真正的 `BRBluetoothLib 3.0.0`。已将 `br_flutter_plugin_ble/ios/.native-sdk/BRBluetoothLib` 链接到上述源码目录，补齐现有 Podfile 对应路径；Podfile 和锁文件未变，也未假定其校验和与此前工作区完全相同。68 个 Swift 源文件已完成独立 iOS Simulator 编译，`vtool` 核对产物为 `IOSSIMULATOR` / arm64；命令与日志位于 `/private/tmp/wiselife-brbluetooth-develop-sync-20261020/`。这是 SDK 编译验证，未运行真实硬件交互，也不代表整个 App 已编译。
- **仅开启 Ring 时仍有阻塞**：三个下载的分支均不包含 App 所需的 `ios/RecorderCore/`、`ios/BRRecorderCore.podspec`、`ios/bootstrap_recorder_core.sh`；`.native-sdk/Opus` 仍缺失。蓝牙 SDK 不实现 Opus 解码，不能直接代替这些模块。需恢复已有适配层／转换器源码，或基于已取得的 SDK 重新实现并通过现有 Ring 集成测试。

## 2026-10-20：默认关闭 Ring，完整构建及覆盖安装

按用户明确要求增加 `Config/BuildFeatures.json`，`eurekaRing` 默认 `false`。Podfile 与工程生成器共用配置读取器；每次 `pod install` 后定点更新 Swift 条件编译和源文件排除配置，不重新生成当前工程。关闭时隐藏 Ring 入口，不初始化客户端，不编译 `EurekaRingModel.swift`、`RingTransferStore.swift`、`RingIntegrationTests.swift`，也不解析或链接三个 Ring Pod。已有 Ring 笔记的来源元数据与处理策略保留。

验证结果：

- 新检查先得到预期失败：关闭配置仍声明三个原生依赖。修改后，`ruby Tests/BuildFeaturesSmoke.rb` 的 3 项检查、85 项断言通过，覆盖关闭／开启依赖图、反复切换以及保留其他设置和 Watch 配置。
- `pod install --no-repo-update` 成功，0 dependencies / 0 pods；没有尝试读取缺失的 RecorderCore 或 Opus。
- 正常签名的完整 `WristNotes` scheme 模拟器构建成功，包含内嵌 Watch App。编译输入列表没有 Ring 模型／传输文件，产物符号不含 Ring 模型、详情页、传输存储及三个原生模块；签名验证通过。
- App 模拟器权限包含 `application-identifier = S56V68L4NP.cloud.karama.wisenote`。原 Keychain 检查再次通过无权限错误、保存、读取、更新、跨进程持久化、配置回滚和虚构 Key 清理；未读取用户真实 Key。
- 已通过 `simctl install` 覆盖安装到 iPhone 17 Pro / iOS 26.3 模拟器 `D9857EEA-8E8C-4788-BBC0-4EB3B10EE506`，安装名称 WiseLife、构建号 3、原 Bundle ID 保持不变。未卸载或重置。系统重新分配了数据容器路径；Documents 和 Application Support 的 50 个原有文件，其相对路径、字节数和修改时间摘要与安装前一致，总大小 159277974 字节。
- 未进行模拟器界面点击验收：此前 Simulator UI 操作被自动审批拒绝；本次仅使用 CLI 构建、非 UI 的独立测试进程、安装及元数据核对。设置页面实际点击保存仍待用户复测。

日志与证据：`/private/tmp/wiselife-ring-disabled-build.log`、`/private/tmp/wiselife-ring-disabled-keychain.log`、`/private/tmp/wiselife-ring-disabled-pods.log`、`/private/tmp/wiselife-ring-disabled-artifact.json`、`/private/tmp/wiselife-ring-disabled-install.json`。
