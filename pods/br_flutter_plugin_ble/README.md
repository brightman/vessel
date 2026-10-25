# br_flutter_plugin_ble · 原生 iOS Pod 包

此目录是供 Vessel SwiftUI App 使用的本地二进制 Pod，包含 BRBluetoothLib、BRRecorderCore、BRRecorderOpus 三个静态 XCFramework；不包含 Flutter 运行时、Dart 或 br_app_services。

- 真机：iOS arm64；模拟器：arm64 + x86_64；最低 iOS 14。
- Swift 模块保持原名称，现有 `import BRRecorderCore` / `import BRRecorderOpus` 无需修改。
- 默认 Native 子模块提供完整录音、闪念、BLE 同步和 AAC 转换。测试通过宿主继承搜索路径，只显式链接 BRRecorderOpus 编码器；避免为同一个 XCFramework 创建两份复制任务。
- Opus 1.6.1 的上游 BSD 许可及作者说明随资源 bundle 分发。

Vessel 的 `apps/wrist-notes/Podfile` 通过 `../../pods/br_flutter_plugin_ble` 引用。使用方只需 `pod install --deployment` 并打开 `WristNotes.xcworkspace`，不需要相邻 SDK 仓库、准备脚本或私有 SDK 下载凭据。Swift Package Manager 的原有 App 依赖仍按 Package.resolved 安装。

升级 SDK 时在 br_flutter_plugin_ble 仓库运行 `python3 ios/package_native_pod.py --output <新的包目录>`，验证后整体替换本目录并更新 Podfile.lock。原 Flutter Podspec 不变。构建来源、工具链和逐文件 SHA-256 见 `manifest.json`。
