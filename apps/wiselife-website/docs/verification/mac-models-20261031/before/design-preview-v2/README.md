# WiseLife · V2 高清官网

> 类型：当前说明 · 状态：已部署并通过线上检查 · 更新：2026-10-31

延续第二版设计的浅蓝配色、六段内容结构和设备组合布局，替换低分辨率设计图裁片。用户要求优化后部署到 `wiselife.karama.cloud`，本版已选为默认首页。

## 页面入口

- 当前首页：`/` 与 `/index-next.html`，由本目录生成并保持一致。
- 独立 V2：`/design-preview-v2/`。
- 旧默认首页：`/index-before-v2.html`。
- V1：`/design-preview/`，35 个文件的 SHA-256 保持不变。
- 对比入口：`/compare-designs/`。V2 不再追求设计图的固定区块高度，以真实设备比例和可读性优先。

## 高清素材与真实产品

- 当前头图按用户指定改用 V1 的山间抬腕人物图，源图为 1024 × 369，原样复用；这一张不属于 2 倍像素的高清摄影，未通过放大文件伪造清晰度。
- 其余生活场景使用 Unsplash 的原始高清摄影，按屏幕尺寸输出 WebP 和 `srcset`；运行时不请求外部图片。
- iPhone Day / Ask AI：1170 × 2532；Mac 知识库：4320 × 2682；Watch 录音：1080 × 1293。
- 所有设备截图均从当前产品交互原型以 3 倍像素密度截取，未重绘或生成屏幕内容。示例数据保持原样；它们不是原生 App 的真机截图。
- iPhone 与 Watch 源：`Vessel/apps/wrist-notes/prototype/`；Mac 源：`/Users/karama/Documents/wiselife-mac-source/apps/wiselife-mac/prototype/`。发布的静态副本位于网站 `product-demos/`，不修改 App 源文件。
- 点击设备可放大、查看原尺寸图片、进入对应交互原型。Watch 使用完整的 SVG 表壳、表冠、侧键和上下表带，内嵌未修改的真实录音原型；主页面和放大窗口一致。
- 设备外框、隐私说明图和图标使用 CSS / SVG。首屏新增“Record a thought…”和“Turn it into action.”两个可点击提示，分别打开录音与行动示例。
- 官网 Logo 直接使用正式 App 的 SVG 母版，位于 `assets/brand/app-icon.svg`。
- 图片来源与许可：[sources.json](assets/hd/sources.json)；导出尺寸：[dimensions.json](assets/hd/dimensions.json)；原型来源与哈希：[prototype-source.json](../docs/verification/hd-v2-20261031/prototype-source.json)。字体和图标许可保留在 `assets/`。

## 交互与发布文案

保留导航、27 秒早期真实原型演示视频、隐私模式切换、Capture → Insight → Action 示例、FAQ、定价说明以及弹窗历史导航。新增四个真实截图的深链接放大窗口。

CTA 改为可实际访问的产品演示，不声称 App Store 已发布；不再保留无依据的用户数量。隐私文案说明端上优先及用户主动配置外部 AI 的情况。落地页不收集表单、不调用麦克风、不写浏览器存储；产品原型可在浏览器记住演示偏好。演示提醒不写入系统提醒事项。

## 维护与复现

在网站目录执行：

```sh
npm run dev
node scripts/capture-product-previews.cjs
python3 scripts/prepare-hd-assets.py --photos /path/to/originals
python3 scripts/sync-homepage.py
npm run test:legal
npm run test:design
node scripts/audit-hd-assets.cjs
python3 scripts/package-release.py
```

摄影原件命名为 `hero.jpg`、`work.jpg`、`rhythm.jpg`、`remember.jpg`。海岸原片至少 3200px，禁止放大低清原片。原始下载地址见来源清单。`capture-product-previews.cjs` 读取静态副本；更新产品界面时先按来源同步副本。

通过 `WISELIFE_ORIGIN` 切换检查站点，通过 `WISELIFE_VERIFY_OUTPUT` 保存新结果；历史验证不覆盖。发布包仅包含公开网页及媒体，排除源码截图 PNG、脚本、文档、证据、Git 和本地配置，版本对比所需的公开设计参考图除外。

## 验证记录

- [交互及响应式结果](../docs/verification/hd-v2-20261031/browser/verification.json)：320 / 390 / 768 / 900 / 1024 / 1440 / 1920px，无横向溢出、JS 错误和失败资源；全部弹窗、截图放大、键盘、历史导航通过。
- [高清与原型审计](../docs/verification/hd-v2-20261031/asset-audit.json)：390 / 1440 / 1920px 的 Retina 环境，30 个可见图片实例均至少 2 倍有效像素；iPhone / Watch / Mac 原型实际渲染成功。
- 隐私与条款的 4 项检查通过。V1 文件哈希未变。
- 完整 Watch 与指定头图的当前检查：[验证记录](../docs/verification/watch-hardware-20261031/local/verification.json)、[图片审计及头图分辨率说明](../docs/verification/watch-hardware-20261031/local/asset-audit.json)。
- [部署记录与回滚](../docs/tencent-deployment.md)记录实际发布状态，网页检查不代表原生 App 或硬件功能验证。

旧版设计图裁片、提取脚本和历史 `evidence/` 仅保留作来源对照；本次源码修改前快照位于 `docs/verification/hd-v2-20261031/before-source.tar.gz`。
