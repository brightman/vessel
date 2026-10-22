# 外部 AI 发送确认偏好

日期：2026-10-22

后续更新：免提示偏好已扩展到长录音标题的自动生成。下文保留本次原始验证记录；新的触发范围和验证见 [AI 长录音标题与完整时长](ai-recording-titles-duration.md)。

## 已实现

- Ask AI 和两处笔记总结入口的发送确认增加「下次不再提示」勾选项，每次出现新的确认框时默认未勾选。
- 勾选后确认发送才写入本机 `UserDefaults`。取消、关闭确认框和过期的确认请求不会保存选择。
- 选择在 App 重启后保留，适用于所选 ChatGPT 或自定义外部 AI 的主动问答与总结；后续主动发送跳过确认框。
- 「设置 → AI 模型 → 发送给外部 AI 前确认」可即时恢复提示，无需重新测试或保存模型配置。
- 已展示但内容或模型发生变化的确认请求仍会被拒绝。免提示路径继续检查资料权限、模型配置、ChatGPT 可用性和凭据。
- Apple 本地模型、硬件闪念的本地处理及自动处理触发条件保持现有行为。此偏好不会开启后台外部 AI 任务。
- `prototype/iphone-day.html` 的 Ask AI 确认和 AI 设置也已同步。原型偏好只保留在页面内，刷新恢复默认，不发送真实 AI 请求。
- 新增文案提供中文、英文和日文。

## 验证

### 真实模型与设置逻辑

```sh
sh apps/wrist-notes/scripts/test_conversations.sh
```

通过。新增用例覆盖默认提示、取消、过期确认、未勾选确认、勾选确认、设置重新加载、免提示发送、设置恢复、资料撤回，以及本地 AI。语义检索完成后的自动发送也通过测试。已有对话持久化、配置变更、权限及检索回归全部通过。

测试使用真实 AppSettings、UserDefaults、检索和对话模型，仅替换模型服务与钥匙串边界。未调用真实外部 AI。

先运行针对已有代码的回归，因已保存的免提示偏好没有生效而失败；实现后通过：

- 失败日志：`/private/tmp/wiselife-remote-ai-red.log`
- 通过日志：`/private/tmp/wiselife-remote-ai-green.log`

### 完整构建

```sh
xcodebuild -workspace apps/wrist-notes/WristNotes.xcworkspace \
  -scheme WristNotes -configuration Debug \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath /private/tmp/wiselife-quick-recording-build \
  CODE_SIGNING_ALLOWED=NO build
```

结果：`BUILD SUCCEEDED`，无编译错误。日志：`/private/tmp/wiselife-remote-ai-build.log`。

### 原型与差异

`node --check` 检查 `daybook-ai.js`、`daybook-model-settings.js`、`daybook-chatgpt.js`、`daybook.js` 均通过，任务文件 `git diff --check` 通过。

当前工具没有可用浏览器接口，因此没有完成原型视觉及浏览器交互验收。没有执行原生模拟器 UI 自动化或真机外部 AI 请求；编译与逻辑验证不代表这些路径已实测。

## 独立评审

按 requesting-code-review 技能完成限定范围只读评审，未发现阻塞或具体正确性问题。总结入口与 SwiftUI 状态生命周期经过静态评审；自动化 smoke 用例覆盖共享授权逻辑与 Ask AI，未直接执行 NotesModel 的远程总结请求。隐私政策和使用条款的发送确认说明也已同步为默认确认、可主动选择免提示。

## 手动验收路径

1. 使用已配置的外部 AI，在 Ask AI 提问，检查首次出现的勾选项未选中。
2. 勾选后取消，再次提问仍提示，勾选项重新为空。
3. 勾选后确认发送；再次提问以及从两处笔记详情生成总结均不再提示。
4. 重启 App，主动发起外部 AI 问答仍不提示。
5. 在 AI 模型设置中开启发送前确认，再次问答或总结恢复提示。
6. 使用本地模型不显示外部 AI 发送确认。

代码保留在本地工作区，未提交或推送。
