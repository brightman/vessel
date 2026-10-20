# Vessel 本地 Pod 发布包

这里保存随仓库交付的 Pod 包；App 内 `apps/wrist-notes/Pods` 是 CocoaPods 安装生成的目录。

`br_flutter_plugin_ble` 提供 iPhone 真机 arm64 与模拟器 arm64/x86_64 的原生二进制 SDK。App 默认使用 Native 子模块，集成测试继承搜索路径并仅显式链接 Opus 编码器；不链接 Flutter 或 `br_app_services`。

使用方式：

```sh
cd apps/wrist-notes
pod install --deployment
open WristNotes.xcworkspace
```

包的校验命令：`python3 apps/wrist-notes/scripts/verify_ble_pod.py`。升级方法、来源和许可见包内 README、manifest.json 与 Licenses。
