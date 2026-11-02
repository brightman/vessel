# WiseLife · 设计图还原版

独立的本地官网预览，依据用户提供的 1024 × 1536 设计图制作。当前首页和线上官网未被此版本替换。

## 预览

- 本地地址：http://localhost:8789/design-preview/
- 入口：[`index.html`](index.html)
- 在网站根目录启动：`python3 -m http.server 8789`

请通过 HTTP 预览，并保留网站根目录中的 `launch-preview/`、`assets/` 等资源：产品原型、演示视频和正式 App 图标复用了这些目录。

## 视觉与交互

保留原图的首屏人物与山景、Watch / iPhone / Mac 生态展示、Today 场景、功能卡片、产品选择与发布订阅区。正文和控件使用 HTML 重建，配图从设计图提取并清理文字。1024px 宽度下，六个区块的高度和位置与原图一致，总高度为 1536px；899px 以下切换为适合触屏的纵向布局。

已实现导航、手机菜单、产品演示、隐私选项、FAQ、视频播放，以及“记录 → 记忆 → 编辑行动 → 确认”的示例流程。支持弹窗键盘操作、焦点恢复和减少动态效果的系统偏好。

订阅表单仅验证输入并展示确认预览，不发送或存储邮箱。TestFlight 和 Mac 下载尚未配置真实发布地址；按钮会说明当前状态并提供可用的产品原型。价格为设计概念，Mac 标为 Preview。视频使用现有的 27 秒演示。示例健康分数等画面属于概念展示，不代表已经交付的功能。

## 资源来源

- 设计图：`/Users/karama/Downloads/WiseLife个人AI生态系统官网吗-1.png`
- 品牌母版：`/Users/karama/Documents/Vessel/apps/wrist-notes/design/brand/wiselife-icon-v1/wiselife-icon.svg`。导航使用同一图形的单色版本，favicon 使用正式 App 图标。
- 图标：Lucide，许可见 [`assets/lucide-LICENSE.txt`](assets/lucide-LICENSE.txt)。页面不依赖远程图标或字体服务。
- 图片出处及初始裁切范围：[`assets/source-manifest.json`](assets/source-manifest.json)。

`scripts/extract-assets.py` 保存了初始图片提取流程，依赖 Pillow、NumPy 和 OpenCV。最终 WebP 图片还经过背景修整、文字残影清理和移动端重新裁切；这些精修已保存为素材，不能通过初始脚本完整重建。不要直接运行该脚本覆盖最终素材。

## 验证记录

- [`evidence/verification.json`](evidence/verification.json)：响应式、资源加载、功能与本地数据边界检查，结果 PASS。
- [`evidence/behavior-inventory.json`](evidence/behavior-inventory.json)：交互清单。
- [`evidence/reference-vs-local.jpg`](evidence/reference-vs-local.jpg)：原图与本地实现并排对照。
- `evidence/desktop-or-mobile-*.png`：320、390、768、1024、1440 和 1920px 宽度截图。

验证未覆盖线上部署、真实订阅服务、支付或 App 分发。
