# 模拟器 API Key 读取恢复 · 2026-10-31

## 根因

AI 模型设置页显示 Keychain 错误 `-34018`。上轮交互测试将 `CODE_SIGNING_ALLOWED=NO` 的构建装到了模拟器；安装包只有 linker 临时签名，未嵌入应用的模拟器钥匙串身份。已有 Key 未丢失，但该构建无权读取它。

`KeychainSecretStore` 与 `WristNotesSimulator.entitlements` 原实现正确，本次没有修改凭据存储代码、清空钥匙串或要求用户重新输入 Key。

## 处理

重新执行带签名的模拟器构建：

```sh
xcodebuild -workspace apps/wrist-notes/WristNotes.xcworkspace \
  -scheme WristNotes -configuration Debug \
  -destination 'platform=iOS Simulator,id=332DEB86-4843-4543-8C73-4719B38DA704' \
  -derivedDataPath /tmp/wiselife-publish-20261028/build \
  CODE_SIGN_IDENTITY=- CODE_SIGNING_ALLOWED=YES build
```

构建通过后验证 `WiseLife.app-Simulated.xcent` 的 `application-identifier` 和 `keychain-access-groups`，执行 `codesign --verify --deep --strict`，再覆盖安装。安装后也直接核对实际 App 主二进制嵌入的模拟器 entitlement；应用身份与钥匙串组均为 `cloud.karama.wisenote`。

## 验证结果

- 签名构建、签名校验、模拟器 entitlement 校验通过。
- `Tests/test_keychain_simulator.py` 通过：无权限错误、保存、读取、更新、跨进程持久化、声音档案持久化。全部使用隔离身份与虚构 Key。
- 原 App 原生 UI 测试通过：AI 设置自动恢复原有配置；无需输入 Key 即显示可用状态；点击“测试连接”后成功；关闭并重新打开设置仍能读取。
- 网络验证仅由 App 使用已保存 Key 发送固定 `Reply with OK.` 测试文本。没有查询、记录或输出真实 Key 值，也没有修改或保存模型配置。
- 最新版保留之前的键盘交互与待保存录音修复。此轮只验收模拟器，不宣称真机验收。

证据根目录：`/tmp/wiselife-keychain-fix-20261031/`。

- `build.log`：`BUILD SUCCEEDED`。
- `keychain-regression.log`：隔离钥匙串回归通过。
- `ui.xcresult` / `ui.log`：1 项原 App UI 测试，0 失败。
- `screenshots/1E514074-B2EB-4AF6-A7A0-A63C662BBCD1.png`：连接成功，Key 字段由系统隐私保护隐藏。

已在上轮验证记录和计划中补充签名安装要求。后续只做编译检查时可关闭签名；用于安装和交互测试的模拟器产物必须保留签名与钥匙串身份。
