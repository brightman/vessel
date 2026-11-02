# 键盘交互与待保存录音验证 · 2026-10-31

## 范围与结果

已安装最新 Debug 构建到 `WristNotes Transfer Test iPhone`（iOS 26.3，`332DEB86-4843-4543-8C73-4719B38DA704`）。本轮按用户要求先验收模拟器；不宣称真机交互已通过。

后续更正：本记录最初的交互测试安装了关闭签名的构建，键盘测试未发现其 Keychain `-34018` 回归。现已覆盖安装正确签名版本，已有 API Key 自动恢复读取，原 App 连接测试通过，详见 [模拟器钥匙串恢复](keychain-installation-2026-10-31.md)。

### 统一键盘

- `AppKeyboardCoordinator` 在 App 窗口监听键盘实际遮挡范围，首页搜索、Ask AI 和编辑/设置页面使用同一套逻辑。
- 键盘显示时隐藏底部导航；点击输入框外收起键盘；滚动交互式收起。
- 点击输入框、切换字段、移动光标保留编辑；页面导航先收起旧键盘，搜索入口仍可自动聚焦。
- 窗口手势不吞掉按钮事件，也不处理 Ask AI 的长按麦克风，避免按住时键盘移动导致录音中断。

### 待保存录音

- 原问题录音 `B315D0A7-013C-44A2-9668-C5AB81F3AA52` 的 M4A 有 280,534 字节，但缺少可读 `moov` atom，清单时长为零，没有已封存分片。普通重试无法将该损坏文件保存为正常录音；本轮未修复音频内容。
- 失败提示条增加直接删除入口和二次确认。恢复音频异常时仍保留待处理录音身份，确保可以删除；文件删除失败显示具体错误，并保留重试目标。
- 原音频和清单已复制备份，删除前验证 SHA-256 一致。通过 App 删除、重启后，原清单与目录均消失，不再显示待保存提示。
- 测试过程中发现另一条新建的零时长未封装草稿 `69A46B1B-3927-4BDD-B627-23B200FC6933`（开始时间 09:54:30，195,507 字节），也单独备份并通过同一 UI 删除流程验证。未确认其创建来源，不将其算作原草稿复活。

临时备份保留在：

- `/tmp/wiselife-keyboard-20261031/pending-recording-backup/`
- `/tmp/wiselife-keyboard-20261031/second-pending-recording-backup/`

## 验证证据

本轮产物根目录：`/tmp/wiselife-keyboard-20261031/`。

| 检查 | 结果 | 证据 |
| --- | --- | --- |
| 修复前搜索键盘 | 复现底栏仍在、点击标题/页头不收起的 3 个断言失败 | `before.xcresult` / `before.log` |
| 搜索、Ask AI、设置数字键盘 | 三个 UI 场景通过；包含草稿保留、搜索自动聚焦、按钮操作及设置页滑动收键盘 | `keyboard-rebooted.xcresult` |
| 行动编辑表单 | 单独补测通过：多行字段切换、点外部收起、草稿保留、关闭表单恢复导航 | `form-final.xcresult` |
| 麦克风交互回归 | 通过：短点不录音且不触发收键盘；长按 6 秒、松开进入转写；不自动发送；离开取消后保留输入草稿 | `voice-regression.xcresult` |
| 原待保存录音 | 通过：重试错误、取消删除、确认删除、重启不再出现 | `discard-recheck.xcresult` |
| 第二条草稿 | 同一流程通过，清理后待保存清单为零 | `discard-second.xcresult` |
| 录音状态回归 | 通过；包含删除遭文件系统拒绝、再次删除及不影响其他文件 | `sh apps/wrist-notes/scripts/test_phone_recording.sh` |
| 语音输入模型回归 | 通过：能量波形、按下/松开、取消、草稿插入与临时文件清理 | `sh apps/wrist-notes/scripts/test_assistant_voice.sh` |
| 工程文件归属 | 通过 | `ruby apps/wrist-notes/Tests/ProjectSourceMembershipSmoke.rb` |
| 模拟器构建 | 通过 | `app-build-final.log` |
| 真机构建 | 编译通过，未完成真机交互验收 | `device-build-final.log` |
| 本次涉及路径的 diff 格式 | 通过 | `git diff --check` |

测试中的非产品失败也已保留：一次 XCTest 等待表单动画结束超时，一次重启后的测试 Runner 在 UIKit 初始化时崩溃，以及一次表单测试被删除确认弹窗打断。表单随后单独运行通过；不将早期整套测试结果描述为全绿。语音回归验证到转写状态与取消，不证明实际识别文本准确率。

未提交测试问题给 AI、未保存表单或模型配置，也没有提交或推送 Git。保留工作区原有其他修改。
