# Vessel repository guidance

When a task asks you to work with Vessel data through the service, use the `vessel` CLI from [tools/vessel-cli/README.md](tools/vessel-cli/README.md).

- Require a named environment for each network command. Confirm the signed-in identity with `vessel auth whoami` before writes.
- Inspect the target space, Page, App, table or file by exact ID before changing it. Preserve expected revision/version fields.
- Read request bodies and binary data from local files. Never put passwords, tokens, file contents or signed URLs in chat or command arguments.
- Treat nonzero exit codes and JSON `ok: false` as failures. Keep API error codes in the report.
- Production writes require explicit user authorization and `--confirm`; `--confirm` alone is not authorization.

The CLI accesses the HTTP API as the user's account. Do not access the database or object store directly for user operations.

## 文档生成与维护

遵循 [项目文档生成与维护规则](docs/documentation-rules.md)。以下约定适用于本仓库内的项目与后续任务。

### 文档位置与入口

- 仓库级及跨项目文档放在 `docs/`；独立 App 的专属文档放在对应 App 的 `docs/`。
- WiseLife 文档根目录为 `apps/wrist-notes/docs/`，开始相关任务前阅读 [文档总索引](apps/wrist-notes/docs/INDEX.md) 和对应模块的当前说明。
- WiseLife 已有 `prototype/`、`verification/` 和 `docs/superpowers/` 路径继续使用；通过索引引用散落在仓库根目录的历史资料。新任务优先归属 App，不因本规则批量搬迁历史文件。
- 文本说明以 Markdown 为维护源，交互原型使用 HTML，流程图优先使用 Mermaid。HTML 文档门户从同一份内容生成。

### 生成与修改

- 新建前先搜索，优先更新已有文档；每个主题维护一份主要的当前产品或技术说明。
- 文档量随任务风险与复杂度确定。小型 Bug、文案、样式调整可更新现有说明并记录必要验证，不机械生成整套设计、计划和验收文档。
- 新功能明确目标、范围、关键状态和验收标准；需要评审的 UI 先更新原型。数据库、协议、权限和数据生命周期调整补充兼容、迁移与恢复设计。
- 产品行为、技术规则、默认参数或数据结构变化时，同步更新主要说明及相关原型；任务完成时将稳定结论合入当前说明。
- 一次任务持续更新同一份计划与验证记录，不按聊天轮次新建文档。现有任务沿用原目录；新项目按需使用 `docs/work/YYYY-MM-DD-topic/`，不预建空白文件。
- 使用 Superpowers 等 skills 时，先查现有设计与任务；产物遵循上述项目路径和文档规模约定。计划、验证和日期记录链接主要说明，避免重复维护同一规则。

### 历史、状态与完成检查

- 当前说明原位更新，版本历史交给 Git；确有并存版本时写明适用范围。历史实验和验收保留当时事实，勘误与后续结果追加说明。
- 被替代文档注明后继文档并建立关联；不靠最新文件名或修改时间推断当前有效方案。
- 独立文档注明类型、状态、更新日期、适用范围及关联文档；旧文档无明确日期时标为“未标注”。批准信息必须有实际依据。
- 分别记录设计获批、代码完成、自动测试、模拟器、真机和发布状态；验证附环境、命令或操作、实际结果及未验证项。
- 完成前更新项目已有变更入口（CHANGELOG 或索引日期章节）；新增、改名、替代文档时更新索引，并检查链接、关键参数与代码／原型的一致性。
- 长期验证记录保留可复查的结果摘要和必要脱敏证据，不仅依赖 `/tmp` 日志；不提交凭据、未脱敏用户资料及大体积临时产物。
- 需要提交代码时，将相关文档一并纳入提交或 PR 的检查范围；提交、推送及发布遵循用户授权。
