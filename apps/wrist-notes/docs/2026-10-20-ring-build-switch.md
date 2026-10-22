# Eureka Ring 编译开关

用户要求：暂时关闭 Eureka Ring 接入，使其不参与编译。

## 设计

统一配置 `Config/BuildFeatures.json` 中的 `eurekaRing`，默认 `false`。CocoaPods 和工程生成器读取同一配置：关闭时不声明三个 Ring Pod，不编译 Ring 模型、传输存储与集成测试；Swift 条件编译排除 App 初始化、页面入口和录音导入方法。Watch、转写、AI 设置及已有录音数据继续使用原流程。

重新开启：将配置改为 `true`，补齐原生依赖后运行 `pod install`。运行时设置无法开启未编译的模块，因此不增加 App 内开关。当前工程只做定点配置更新，避免重建工程覆盖其他进行中的修改。

## 实施与验证

- [x] 使用临时工程测试开关切换，确认 SDK 依赖、Swift 条件与源码排除一致，其他配置保留。3 项检查、85 项断言通过。
- [x] 添加共享配置读取器；Podfile 与工程生成器使用该读取器。
- [x] 条件编译 Ring 初始化、页面、导入代码；关闭时硬件页仅显示 Apple Watch。
- [x] 执行关闭状态的 `pod install`；完整签名构建 iPhone/Watch 模拟器 App，检查源码列表和产物不含 Ring 模块。
- [x] 运行 Keychain 模拟器验证；覆盖安装同一 Bundle ID，原 50 个文档／支持文件的路径、大小和修改时间摘要保持一致。界面验收受此前 Simulator UI 自动审批拒绝限制。
- [x] 更新 README 与验证记录；不提交其他工作区改动。

验证详情见 [keychain-simulator.md](../verification/keychain-simulator.md)。重新开启 Ring 的依赖图已检查，但由于适配层和 Opus 源码仍缺失，未运行开启状态的整包构建或 Ring 硬件测试。
