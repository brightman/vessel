# Sign in with ChatGPT 原型验证 · 2026-10-20

入口：[iPhone 最新原型](../../prototype/iphone-day.html) → 设置 → AI 模型。

**顺序：Apple 本地模型 → ChatGPT 账号 → 自定义模型。**

## 验证方法

本地 Playwright Chromium，通过实际页面控件操作；截图使用 reduced-motion 以避免官网动画影响取景。16 组检查通过；修改过的 JavaScript 语法检查和 `git diff --check` 通过。运行方式（从仓库根目录）：

```sh
python3 -m http.server 8766 --bind 127.0.0.1 --directory apps/wrist-notes/prototype
```

另一个终端运行：

```sh
node apps/wrist-notes/verification/chatgpt-prototype/check.mjs
```

结果：[checks.json](checks.json)。脚本检查授权状态、取消与保存、远程内容预览、已有功能回归、窄屏溢出、浏览器错误和外部请求。账户、模型和响应均为演示。

## 检查内容

- ChatGPT 紧接 Apple 本地模型；Apple 保持默认。
- 取消授权、关闭授权弹层、网络失败与资格不足不会启用保存。
- 首次套餐提示确认前不能保存；账号连接后取消模型草稿仍保持原模型选择。
- 确认保存后更新 Ask AI；发送前展示准确问题与本次引用文字；取消或 Escape 保留问题。
- 跨日睡眠问题包含两日依据；关闭语音数据范围后，远程预览不包含转写记录。
- 授权过期和用量上限阻止后续提问；上限页提供官方管理用量入口。
- 断开有确认与取消；旧回答保留原模型标记；无静默回退。
- 主动切换 Apple 本地模型后可直接模拟回答；自定义模型保留校验、模拟测试与保存流程。
- 原有 ASR 和“我的声音”设置仍可访问。
- 390px 浅色中文、390px 深色英文、320px 深色日文：新界面翻译、无弹层横向溢出。修正长弹层底部按钮被裁切的问题，新增按钮完整可见的检查；已人工查看截图。
- 刷新清空演示连接；不新增账号、Token 等持久化数据；无 JavaScript 错误或外部请求。

## 截图

| 场景 | 截图 |
|---|---|
| 模型顺序 | [01-model-order.png](01-model-order.png) |
| 未连接 / 授权中 | [02-disconnected.png](02-disconnected.png) / [03-authorizing.png](03-authorizing.png) |
| 首次套餐提示 / 已连接 | [04-plan-notice.png](04-plan-notice.png) / [05-connected.png](05-connected.png) |
| 发送内容预览 / Ask AI | [06-send-preview.png](06-send-preview.png) / [07-chatgpt-answer.png](07-chatgpt-answer.png) |
| 用量上限 | [08-usage-limit.png](08-usage-limit.png) |
| 浅色中文 | [09-390-zh-Hans-light.png](09-390-zh-Hans-light.png) |
| 深色英文 / 日文窄屏 | [09-390-en-dark.png](09-390-en-dark.png) / [09-320-ja-dark.png](09-320-ja-dark.png) |

## 验证边界

未连接真实 ChatGPT 账号、未调用模型、未读取已有 ChatGPT 聊天记录。实际应用接入资格、OAuth、安全令牌管理、套餐计量、真实模型返回及 iPhone 原生集成均待后续实现与验证。此结果不是上线接入成功的证明。
