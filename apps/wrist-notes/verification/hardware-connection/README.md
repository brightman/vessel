# 硬件连接原型验证 · 2026-10-19

目标：`prototype/iphone-day.html`，只验证 HTML 交互，不代表原生硬件已接入。

## 检查结果

- `node --check` 检查 `daybook-hardware.js`、`daybook.js`、`daybook-locales.js` 通过。
- `git diff --check -- apps/wrist-notes/prototype` 通过。
- 使用本机 HTTP 静态服务及 Playwright Chromium，实际点击完成：
  - 默认 Apple Watch 已连接、EurekaRing 未连接；选择页包含两款。
  - EurekaRing 连接后显示电量 82%、上次同步 16:30、0 条待同步；首页显示双设备。
  - 断开 Apple Watch 后，EurekaRing 保持连接，首页只显示戒指图标。
  - 全部断开后，入口变灰并显示“连接硬件”；详情电量、同步等字段显示 `—`。
  - 从设置重新连接；首页、列表、详情保持一致。
  - 关闭、重开弹层保留状态；刷新页面恢复默认演示数据。
  - 英语详情无残留中文；切换日语后连接第二款，数量文案正确；切回中文正常。
  - 深浅色、320px 与 390px 宽度检查：首页工具栏无重叠，页面和详情无横向溢出。
  - 浏览器无 JavaScript 运行错误。
- 查看下列实际渲染截图，确认样式沿用原有 Apple Watch 状态页。

## 截图

- [硬件选择](hardware-list.png)
- [EurekaRing 已连接](ring-connected.png)
- [英文深色状态](ring-dark-en.png)
- [390px 移动端](ring-mobile.png)

两款硬件均为页面内模拟状态，无真实蓝牙、WatchConnectivity 或戒指协议调用。此次未修改 Swift 代码。
