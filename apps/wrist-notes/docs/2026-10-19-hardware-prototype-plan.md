# iPhone Day 硬件连接原型

## 范围与交互

基于用户指定的 `prototype/iphone-day.html` 最新版本扩展硬件入口，保留现有页面、语言和主题。

- 支持 Apple Watch 和 EurekaRing 两款硬件，状态彼此独立，可以同时连接。
- 首页沿用现有状态胶囊：无连接时灰色并提示连接；一款连接时显示其图标和已连接；两款连接时显示两款图标与连接数量。
- 点击首页入口进入“连接硬件”，列出两款硬件。设置页也列出相同设备。
- 设备详情沿用 Apple Watch 现有结构：设备图标、名称、状态、电量、上次同步、待同步录音，以及连接/断开操作。断开后的值显示为不可获取，历史记录保留。
- 默认 Apple Watch 已连接、EurekaRing 未连接。所有状态为本页演示数据，刷新恢复；不读取真实硬件。

## 实现计划

**Goal:** 完成两款硬件选择、连接及状态回看流程。

**Architecture:** 新增独立 `createDaybookHardware` 模块，复用现有弹层及事件入口；设备状态统一用于首页、设置列表和详情。健康、日历、地点来源继续使用现有逻辑。

**Tech Stack:** 原有 HTML、CSS、原生 JavaScript；沿用中英日三语翻译机制。

- [x] 新增 `prototype/daybook-hardware.js` 与 `daybook-hardware.css`，封装两款设备状态、列表、详情及连接/断开交互。
- [x] 接入 `iphone-day.html` 与 `daybook.js`；设置页区分硬件与其他数据来源，移除原先单独的手表状态实现。
- [x] 为新增文案补齐中文、英文、日文，验证深浅色样式。
- [x] 浏览器检查未连接、单设备、双设备、断开、重连、关闭重开，以及窄屏布局；保留截图和检查记录。

结果见 [验证记录](../verification/hardware-connection/README.md)。

本次只更新 HTML 交互原型。EurekaRing 真机协议和原生 App 集成不在本次范围内。
