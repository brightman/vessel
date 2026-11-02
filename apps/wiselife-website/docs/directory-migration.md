# WiseLife 官网目录迁移

> 类型：技术与验证记录 · 状态：current · 更新：2026-10-31 · 范围：本地官网源码组织
>
> 关联：[官网入口](../README.md)、[文档索引](INDEX.md)、[原生 App](../../wrist-notes/README.md)

## 当前结构

```text
Vessel/
├── apps/
│   ├── wrist-notes/             # iPhone / Apple Watch App 与当前交互原型
│   ├── wrist-notes-huawei/      # Huawei 项目
│   └── wiselife-website/        # 独立官网，静态 HTML/CSS/JavaScript
│       ├── index.html           # 保持原有默认首页
│       ├── index-next.html      # 与默认首页同版
│       ├── assets/              # 图片、图标、字体、视频与字幕
│       ├── launch-preview/      # 英文发布方案及产品演示
│       ├── design-preview/      # 第一张设计图版本
│       ├── design-preview-v2/   # 第二张设计图版本
│       ├── compare-designs/     # 两版与原图对比
│       ├── privacy/             # 隐私政策
│       ├── terms/               # 服务条款
│       ├── scripts/             # 官网媒体采集与渲染
│       ├── Tests/               # 官网政策检查
│       └── docs/                # 官网维护与验证记录
└── package.json                 # 官网开发与检查快捷命令
```

官网无需原生 App 编译、Vessel API 或新增服务器。现有 App 演示已包含在官网目录中，所有页面保留原有相对资源路径。原生 App 的 Swift 源码、当前交互原型及品牌母版继续由 App 目录维护。

## 迁移与恢复

- 原独立目录：`/Users/karama/Documents/wiselife-website`。
- 当前维护目录：`/Users/karama/Documents/Vessel/apps/wiselife-website`。
- 原目录的完整备份：`/Users/karama/Documents/wiselife-website-backup-20261031T183818`，保留 `.git`、历史提交、工作区内容及未提交状态。备份不作为第二份日常开发目录。
- 原路径现在是指向当前维护目录的符号链接，继续兼容原有预览服务器和本地链接。
- 新目录没有嵌套 `.git`，由 Vessel 仓库正常追踪；未执行提交、推送或 Git 远端修改。
- 来源文件清单：[source-manifest.json](verification/directory-migration/source-manifest.json)。原目录 212 个文件在初次复制时逐个通过 SHA-256 校验。迁移后仅更新说明及验证脚本的模块解析/输出路径，页面、视觉资源和默认首页保持原内容。
- 官网专用的 `capture_website_media.mjs`、`render_website_media.py` 和 `test_website_legal_pages.py` 从 App 移到官网。已修正资源输出目录与默认预览地址。
- 原 App `prototype/index-next.html` 作为兼容跳转，保留查询参数和片段；当从项目根目录提供静态服务或用本地文件打开时可跳转到同级官网。只服务 App 的 `prototype/` 子目录时，需使用下述独立官网地址。
- `wiselife-next.css` / `wiselife-next.js` 与官网文件逐字节一致，移除 App 中的重复副本。较早 `iphone-day.html` 中与 App 演示共用的历史网站外壳继续保留，不作为官网发布来源。

如需回退本次目录调整，先保存新目录后续改动，再使用完整备份恢复旧路径；不要用备份直接覆盖新增工作。线上站点没有变化，无需服务器回滚。

## 运行与验证方式

从 Vessel 根目录启动：

```sh
npm run dev:wiselife-website
```

- 首页：http://localhost:8789/
- 新版：http://localhost:8789/design-preview-v2/
- 对比：http://localhost:8789/compare-designs/

服务器运行后执行 `npm run test:wiselife-website`。浏览器检查通过 Node 标准模块查找使用 Vessel 根目录安装的 Playwright，不再假定官网位于仓库外。

保留历史证据时，为检查指定单独输出目录：

```sh
WISELIFE_VERIFY_OUTPUT=/tmp/wiselife-website-migration-browser npm --prefix apps/wiselife-website run test:design
```

该目录用于临时截图，稳定结果摘要复制到本文同级的迁移验证目录。既有页面视觉验收截图不重写。本次不重新生成视频或截图素材。

## 验证状态

在 macOS 本地工作区（存在未提交修改）执行。迁移结果见 [checks.json](verification/directory-migration/checks.json)；网页交互结果见 [browser.json](verification/directory-migration/browser.json)。

- 212 个来源文件完整备份，208 个迁入文件保持逐字节一致，4 个文件仅涉及迁移说明和检查脚本的路径/输出设置。
- 290 个 App 源文件 SHA-256 未变化；新目录无嵌套 Git 仓库。
- 351 处 HTML/CSS 本地资源引用无缺失；4 项政策检查通过。
- [14 个入口页面与旧入口跳转](verification/directory-migration/routes.json)通过，无浏览器运行错误或资源失败。
- 320–1920px 的 7 种宽度，以及导航、对话框、视频、隐私选项、示例行动和版本对比检查通过。原预览 URL 继续指向新目录。

验证覆盖文件完整性、原 App 源码未改动、官网政策检查、浏览器资源/交互和既有预览入口。Swift 原生功能、真机同步、线上部署不在本次目录任务范围内。
