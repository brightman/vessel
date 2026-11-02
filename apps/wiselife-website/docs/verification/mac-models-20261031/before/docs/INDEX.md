# WiseLife 官网文档索引

> 类型：导航与变更 · 状态：current · 更新：2026-10-31 · 范围：`apps/wiselife-website/`

入口：[项目说明与运行方式](../README.md)。官网与 [`../wrist-notes/`](../../wrist-notes/README.md) 原生 App 并列；本目录为官网唯一维护源。

## 页面与方案

- [现有首页](../index.html) / [同版独立入口](../index-next.html)：当前采用 V2 高清版；[上次默认首页](../index-before-v2.html)保留比较。
- [英文发布方案](../launch-preview/README.md)：[页面](../launch-preview/index.html)、[方案](global-launch-design.md)、[源建议](global-launch-source.md)。
- [设计图第一版](../design-preview/README.md)：[页面](../design-preview/index.html)。
- [设计图第二版](../design-preview-v2/README.md)：[页面](../design-preview-v2/index.html)。
- [两版和原图对比](../compare-designs/index.html)：V1 / V2、原图 / V2。
- [早期新版首页设计记录](home-next-design.md)：保留当时方案与验证。
- [隐私政策](../privacy/index.html) / [服务条款](../terms/index.html)。

## 维护与验证

- [目录迁移与恢复](directory-migration.md)：来源、备份、源码边界与验证。
- [Tencent Cloud 部署记录](tencent-deployment.md)：当前发布、历史部署和回滚方式。
- [官网品牌素材](../assets/brand/README.md)：App 品牌母版位置与导出说明。
- [V2 高清版交互验证](verification/hd-v2-20261031/browser/verification.json)、[图片密度与真实原型审计](verification/hd-v2-20261031/asset-audit.json)。
- [原设计 V2 历史验证](../design-preview-v2/evidence/verification.json)。
- [目录迁移前文件清单](verification/directory-migration/source-manifest.json)。
- [迁移完整性检查](verification/directory-migration/checks.json)、[14 个页面及兼容跳转检查](verification/directory-migration/routes.json)、[迁移后交互检查](verification/directory-migration/browser.json)。

## 2026-10-31

- 官网迁入 `apps/wiselife-website/`，与 `apps/wrist-notes/` 并列。保留原首页、所有设计版本、资源、原型演示与历史验证；官网媒体脚本和政策检查同步迁移。
- 旧独立 checkout 完整备份；旧路径改为兼容符号链接，原 App 中专用旧首页入口改为跳转。根目录新增官网启动与检查命令。验证与边界见[迁移记录](directory-migration.md)。

- V2 替换低分辨率设计裁片，使用高清摄影、正式 SVG Logo 和当前 iPhone / Watch / Mac 产品原型的 3 倍截图；提供放大与交互原型入口。320～1920px 检查和 Retina 图片密度审计通过，V1 保持不变。以 V2 作为默认首页，部署状态见[腾讯云记录](tencent-deployment.md)。

- V2 高清版已部署到 `https://wiselife.karama.cloud`，发布号 `20261031T121307Z-hd-v2`。240 个公开文件校验一致，HTTPS、7 种屏幕宽度和 2 倍图片密度线上检查通过；前一发布保留回滚。[发布证据](verification/hd-v2-20261031/deployment.json)。

- 根据反馈补齐官网 Watch 的表带、表壳、表冠和侧键，真实屏幕保持原样；主图与放大预览一致。首屏换为用户指定的 V1 山间抬腕人物图，并加入录音、行动两个功能提示。该指定头图源分辨率为 1024 × 369，保留此限制；其他产品与场景图片继续高清显示。[当前检查](verification/watch-hardware-20261031/local/verification.json)。

- 完整 Watch 与指定头图已发布，版本 `20261031T132507Z-hd-v2`，242 个文件校验通过；前一高清版保留回退。[本次发布](verification/watch-hardware-20261031/deployment.json)。
