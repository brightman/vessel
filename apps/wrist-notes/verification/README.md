> 2026-10-19 新增：原生模型设置、Apple / Whisper 下载与离线验证见 [model-downloads.md](model-downloads.md)。本页保留先前录音／传输验证记录。

> 最新每日记录界面对齐与健康数据未授权时的首页统计，见 [prototype-parity.md](prototype-parity.md)。此页较早截图不代表本轮最终布局。

# 原生界面核对 · 2026-10-18

> **2026-10-19 更新：** 新的手表状态、设置、AI 模型配置与总结接入见 [settings.md](settings.md)。用户已反馈传输问题修复、真机 ASR 通过；下文传输和 ASR 的未验证说明属于 10 月 18 日的历史记录。

本轮范围：按 `prototype/watch-recorder.html` 和 `prototype/iphone-notes.html` 更新 SwiftUI，并保留本地优先架构。

## 实现

- Watch：单个红色按钮；轻点开始/结束长录音；按住 0.45 秒录闪念、松开保存、上滑取消；少于 0.3 秒的闪念不保存；长录音期间长按不停止。
- Watch：名称、开始时间、时长、未上传/已上传列表；左划显示删除。列表固定在录音控制下方，可滚动。
- Watch：上传确认后保留本地录音；兼容旧 `pending.json`。删除只影响手表副本。
- iPhone：深色卡片列表、搜索、语言菜单、文件导入、左划显示删除。
- iPhone：固定返回/保存栏、可编辑标题、真实音频播放及采样波形；播放器下方“总结 / 全文”标签。
- iPhone：全文编辑、重新转写、生成总结；保存不应提前结束正在进行的转写；更改全文会清除旧总结。

## 原生截图

Watch 使用当前 App 及原有待传列表。iPhone 三张截图来自隔离的临时预览 App，使用原型文案和 74 秒静音音频；其 Bundle ID 为 `com.vessel.wristnotes.preview`，关闭 Watch Connectivity，未接触原 App 数据，核对后已卸载。波形为静音音频的实际采样结果，因此呈直线。

| Watch 主界面 | iPhone 列表 |
| --- | --- |
| ![Watch](watch-home.png) | ![iPhone 列表](iphone-list.png) |

| 总结 | 全文 |
| --- | --- |
| ![总结](iphone-summary.png) | ![全文](iphone-transcript.png) |

## 已验证

- iOS Simulator + watchOS Simulator 两个 target 编译通过。
- 通用 iOS + watchOS 真机目标编译通过，关闭签名；此项不代表真机运行通过。
- `scripts/test_local.sh` 通过：本地存储、重复导入、丢失音频恢复、旧 Watch 记录读取/上传状态持久化、8 个手势状态场景、5 个编辑场景。
- 已查看上面四张原生截图，检查标题、列表、播放器、标签与文本区域。
- 实际 App 的最新构建已安装到当前配对模拟器。

## 尚未验证

- Computer Use 返回 `Computer Use was not approved to use Simulator`，因此本轮未通过自动点击执行完整手势、左划删除、文件选择器和播放流程。手势状态检查是逻辑测试，不能替代实际触摸验证。
- Watch → iPhone 文件接收与入库仍待排查。之前发现的 Watch App 嵌入目录问题已修正，系统伴侣识别已恢复；尚无端到端成功结论。
- 实体 Apple Watch SE 的触觉、长录音、后台行为，以及 iPhone 16 Pro 的普通话 ASR 与 Apple Intelligence 总结仍需真机验证。

## 重现命令

在仓库根目录：

```sh
sh apps/wrist-notes/scripts/test_local.sh
xcodebuild -project apps/wrist-notes/WristNotes.xcodeproj -scheme WristNotes -configuration Debug -destination 'generic/platform=iOS Simulator' -derivedDataPath /private/tmp/wristnotes-derived CODE_SIGNING_ALLOWED=NO build
sh apps/wrist-notes/Tests/EmbeddedWatchSmoke.sh /private/tmp/wristnotes-derived/Build/Products/Debug-iphonesimulator/WristNotes.app
```

`python3 apps/wrist-notes/scripts/prepare_ui_preview.py` 会创建临时工程副本并输出路径，可用于复查 iPhone 视觉状态。构建安装副本后，使用 `SIMCTL_CHILD_WN_PREVIEW_SCREEN=list|summary|transcript` 环境变量启动。该脚本不会改生产源文件；预览的初始页选择与演示数据只存在于临时副本中。
