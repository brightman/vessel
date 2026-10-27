# 详情页管理入口原型

日期：2026-10-24。依据本轮已确认的入口规划，仅修改 HTML 原型。

## 交互约定

- 语音、闪念、图片、内容片段均通过详情页右上角「⋯」进入管理。
- 菜单按能力展示：编辑记录、生成/重新生成总结、调整片段、查看处理状态、删除对应对象。
- 总结为空时，内容区保留生成按钮；生成过程及删除确认仅为页内演示，无模型或存储请求。
- 内容片段播放器只展示当前时间范围。10 分钟物理文件可被多个片段按范围引用；不增加完整录音播放入口。
- 调整片段在独立面板中预览拆分、合并相邻片段和边界调整；保存后更新本页时间轴，可撤销最近一次未被后续编辑覆盖的调整。
- 原始文件按录制批次列于「设置 → 数据管理 → 原始录音」，展示 10 分钟文件、末尾短片和处理状态。
- 原型示例状态仅保存在内存。刷新页面恢复，原始录音、SQLite、Swift 与真实 AI 均不参与本次修改。

## 实施清单

- [x] 新建 `daybook-record-management.js/css`，集中管理菜单、编辑、总结、片段范围与原始文件示例。
- [x] `daybook.js` / `daybook-photos.js` 接入共享详情页菜单，保留原有播放器与总结/全文排版。
- [x] `iphone-day.html` 增加菜单容器、数据管理入口与明确的 review 快捷入口。
- [x] 接入现有语言表，检查脚本语法、页内状态流转与资源引用。
- [x] 尝试浏览器验收；工具不可用时记录具体限制，不将静态检查表述为视觉验收。

## 评审入口

本地启动：`python3 -m http.server 8769 --bind 127.0.0.1 --directory apps/wrist-notes/prototype`。

| 场景 | URL |
| --- | --- |
| 内容片段 · 26 分钟 | `http://127.0.0.1:8769/iphone-day.html?preview=segment#product` |
| 普通语音 | `http://127.0.0.1:8769/iphone-day.html?preview=record-voice#product` |
| 闪念 · 总结为空 | `http://127.0.0.1:8769/iphone-day.html?preview=record-thought#product` |
| 图片记录 | `http://127.0.0.1:8769/iphone-day.html?preview=record-image#product` |
| 原始录音 | `http://127.0.0.1:8769/iphone-day.html?preview=raw-recordings#product` |

桌面端右侧也提供这五类入口；手机窄屏可通过时间轴、设置或上面的 URL 进入。

### 可点击的流程

1. 内容片段右上角「⋯」→ 调整片段 → 拆分 / 合并相邻 / 调整边界；预览后确认，或取消返回。两段示例分别为 14:00–14:26 和 14:26–14:40，可合并成 40 分钟。
2. 调整后，片段全文按示例时间范围更新，总结清空待重新生成；最新一次调整可撤销。如果之后修改了片段内容，撤销入口禁用以保留编辑。
3. 普通语音与闪念支持编辑标题、全文；图片支持编辑标题、补充说明，保留图片与图片文字。
4. 总结为空时显示行内「生成总结」，已有总结时菜单为「重新生成总结」。只对当前记录生效，生成结束不重新打开已关闭的详情页。
5. 删除操作单独确认。删除内容片段后，原始录音文件仍可从数据管理查看；其他片段保留。
6. 原始录音按两次录制展示：40 分钟为 4 个文件，42 分钟为 4 个 10 分钟文件及 1 个 2 分钟末片。此处可返回关联内容片段，不提供整次录制的播放入口。

## 验证与边界

- `node --test apps/wrist-notes/prototype/tests/record-management.test.cjs`：6 项通过，覆盖不修改数据的预览、范围守恒、跨记录保护、撤销保护、边界重叠拦截与缩短后扩展的文字恢复。
- 整页 DOM 检查：`tests/record-management-dom.mjs`。在仓库外安装 `happy-dom`，通过 `WISELIFE_TEST_DOM` 指定模块文件运行；没有添加 App 或仓库级依赖。例如：

  ```sh
  WISELIFE_TEST_DOM=/tmp/wiselife-record-management-dom/node_modules/happy-dom/lib/index.js node apps/wrist-notes/prototype/tests/record-management-dom.mjs
  ```

- DOM 检查覆盖菜单关闭、编辑/取消、总结完成后的页面状态、拆分/合并/边界/撤销、处理状态、图片返回、删除片段保留源文件及末尾短片。
- JavaScript 语法与本地资源引用已检查。浏览器工具返回 `Sky Computer Use native pipe startup failed`，且浏览器列表为空，**尚未做真实浏览器截图、布局或触摸验收**。
- 音频仅计时演示；示例转写按预设文字时间范围分配，不能用于评价真实 ASR 或分段质量。总结由当前文字的少量句子模拟，无模型请求。刷新页面重置所有记录操作。
