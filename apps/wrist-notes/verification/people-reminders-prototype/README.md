# 产品原型验证

日期：2026-10-21。原型入口：[`iphone-day.html`](../../prototype/iphone-day.html)。产品说明：[`people-reminders-design.md`](../../prototype/people-reminders-design.md)。

## 实际验证

使用已安装的 Playwright + Chromium，通过本地 HTTP 服务打开原型。浏览器控制连接不可用，因此使用 CLI 驱动独立 Chromium；没有操作原生 Simulator。

- 说话人：搜索无结果、选择后取消、确认关联、同一 speaker 所有片段更新、更换、不同录音隔离、解除、手动命名均通过。
- 提醒：默认关闭、拒绝权限、保留草稿标题／日期／时间、允许权限、选择列表、来源页返回、保存和只读镜像检查均通过。
- 已关联任务：更新失败保留旧 Apple 镜像，改为成功后重试保持单条任务；标记完成反映到镜像；删除前确认后移除通过。
- 首次添加失败：保留 WiseLife 任务；编辑为仅 WiseLife 后清除过时的 Apple 错误提示通过。
- 390px 视口：英文深色／日文浅色页面无横向溢出，新增控件翻译生效。深色 Apple 卡片背景为 `rgb(17,23,29)`，文字为 `rgb(233,237,241)`。
- 浏览器用例未发现 JavaScript 页面异常。5 个改动 JS 文件均通过 `node --check`，相关改动通过 `git diff --check`。
- 独立代码审查完成；修复了深色卡片对比度、说话人姓名的翻译保护和 Apple 错误状态残留。截图检查后将提醒操作改为两列，避免窄屏按钮被挤成多行。

本机流程脚本保存在 `/private/tmp/wiselife-people-reminders-check.cjs`，临时目录可能被清理。它仅操作虚构原型数据。产品操作路径见上方产品说明。

## 截图

- [说话人管理](speaker-manage.png)
- [联系人选择](contact-picker.png)
- [已关联的全文](speaker-linked.png)
- [待办默认关闭](reminder-off.png)
- [开启 Apple 提醒事项](reminder-enabled.png)
- [添加成功](reminder-linked.png)
- [添加失败](reminder-failed.png)
- [英文深色窄屏](mobile-en-dark.png)
- [日文浅色窄屏](mobile-ja-light.png)

## 未验证／未实现

没有真实通讯录读取、系统授权、Apple 提醒事项写入或通知。没有开发人物详情页和按人 Ask AI。上述结果只证明 HTML 原型交互，不代表原生 App 功能已实现。
