# Vessel 文件共享设计：个人文件、团队盘与 Aliyun OSS

日期：2026-10-14；实现更新：2026-10-15。状态：文件 HTTP API 已实现，生产未发布。运行及验收见 [文件服务运行说明](files-runtime.md)。

本设计依据当前代码和文档，限定文件与文件夹功能。Page、Apps/表格由其他 coding agent 开发，本增量不修改其模型、接口、迁移和 MCP。产品保持 API-only，通过 HTTP、后续 CLI 和本地 MCP 使用。类 Google Drive 指目录、共享入口和版本管理体验；不承诺复制 Google Drive 的全部权限语义。

## 1. 实施前代码起点与本次范围（2026-10-14 快照）

| 当前依据 | 已实现行为 | 本设计的使用方式 |
| --- | --- | --- |
| `spaces/permissions.py` | personal/team 空间、Owner/Admin/Editor/Viewer；可锁空间行后判权 | 复用身份和团队成员，不另建 Team/Drive 身份系统 |
| `models/space.py`、迁移 `0007` | Space 和 TeamMember；个人空间唯一，团队由成员共同持有 | 每个空间一个文件根目录；空间是归属和配额边界 |
| `directories/router.py`、`models/directory.py` | 个人 Page 的扁平目录；归档目录会将 Page 移回根目录 | 不能用来实现递归文件夹；保留现有接口 |
| `assets/router.py`、`assets/storage.py`、`main.py` | 个人 Page 图片附件；开发环境本地存储，生产未配置附件存储 | 不能当成通用文件上传服务；新增独立 files 模块与 OSS 配置 |
| `pages/router.py`、`versions/router.py` | 按个人 Owner 判权，Page 修订与快照 | 本增量不迁移 Page，不把文件共享权限自动赋给 Page |
| `mcp/capabilities.py`、`mcp/server.py` | 单 Page/Run capability，独立 audience，Owner 查询 | 文件不使用这条 capability 授权路径 |

现有 `technical-design.md` 规划统一 items，但尚未实现。本设计提出资源级共享，超出该文档“首版无单项 ACL”的范围；它是文件增量的候选新契约，尚不替换已批准的全局范围。

首版支持：嵌套文件夹、任意二进制文件、个人空间、团队空间、向已有 active Vessel 用户共享个人文件/文件夹、Viewer/Editor 权限、权限继承、共享给我、文件版本、回收站、名称/元数据搜索、OSS 单段/分段直传。

首版不支持：匿名链接、未注册邮箱邀请、团队文件向非成员分享、跨空间移动/所有权转移、单项 deny/受限团队文件夹、评论角色、在线预览/Office 编辑、同步盘/FUSE、内容全文索引、Page/Apps 共享改造、S3 适配。用户引用文件 ID 的链接需要登录并判权，本身不授予访问能力。

## 2. 方案比较与推荐

| 方案 | 优点 | 代价 |
| --- | --- | --- |
| 只复用空间角色 | 实现最小，直接支持团队文件 | 不能把个人文件分享给指定用户 |
| **空间归属 + 个人资源 ACL + 文件夹继承（推荐）** | 复用当前团队规则，同时支持“我的文件/共享给我/团队文件” | 增加继承计算、共享与移动的并发协议 |
| 通用 ACL、任意 deny、匿名链接、跨组织转移 | 表达能力强 | 超出首版，撤权、泄露防护和迁移明显更复杂 |

推荐第二种。文件始终属于原空间；分享不复制文件，不把用户加入整个空间，也不改变配额归属。

## 3. 使用模型

```text
我的文件：个人空间根目录
  工作资料/
    报价.pdf       ← 直接授权 B Viewer
    项目资料/      ← 授权 C Editor，子文件自动继承

共享给我：B/C 获得访问权的共享入口，属于虚拟视图
团队文件：当前有效团队成员能够访问的团队空间根目录
回收站：自己管理的空间中已回收的目录树
```

每个 Item 只有一个物理父文件夹。共享给我不创建第二个 parent，不赋予源空间根目录的列表权限。用户能直接打开共享子文件，但不能通过面包屑获得未授权父文件夹的名称或兄弟节点。路径仅用于显示，所有变更使用稳定 ID。

首版只显示有效的直接共享入口；文件夹入口可递归浏览其继承可见子项。已有共享祖先时隐藏冗余子入口。访问被撤销、回收或过期的入口不进入有效共享列表。首版不提供隐藏入口或失效共享记录管理 API；收藏、快捷方式放后续。

## 4. 权限与继承

### 4.1 能力矩阵

| 身份 | 浏览/下载/读历史 | 新增子项/上传新版本/重命名 | 移动/回收/恢复 | 管理共享 | 永久删除 |
| --- | --- | --- | --- | --- | --- |
| 个人空间 Owner | 是 | 是 | 是 | 是 | 是 |
| 个人文件/文件夹共享 Editor | 是 | 是，新增要求父文件夹 Editor | 否 | 否 | 否 |
| 个人共享 Viewer | 是 | 否 | 否 | 否 | 否 |
| 团队 Owner/Admin | 是 | 是 | 是 | 首版不开放团队 ACL | 是 |
| 团队 Editor | 是 | 是 | 是，限本空间 | 否 | 否 |
| 团队 Viewer | 是 | 否 | 否 | 否 | 否 |

共享 Editor 不等于 Owner；在别人共享的文件夹中创建文件后，文件仍归该文件夹所在个人空间，创建者只是审计 actor。首版共享 Editor 不可调整目录位置或回收文件，减少误删及通过移动改变共享范围的风险。读权限包含全部保留的历史版本；如果历史版本需要单独授权，另行设计。

### 4.2 判权规则

1. 验证当前账号状态；读取资源的真实 space_id 和祖先链，拒绝冻结空间、purging/purged 项目。
2. 个人 Owner 获得全部能力。非 Owner 必须有目标或祖先上的有效 user grant；不可先用 space_access 拒绝所有非 Owner，再计算 ACL。
3. 个人 ACL 只支持 viewer/editor，允许直接及继承授权取较高权限。无 deny、无中断继承；将子项设为 Viewer 不能覆盖祖先 Editor。
4. 团队文件仅按当前 active 成员角色授权，保持团队成员默认可见；不做额外团队 ACL。
5. target 或任一祖先被回收后，普通读取/下载拒绝；回收站操作走独立管理权限。共享接收者不能浏览回收站。
6. 列表、搜索、历史、下载、上传状态、错误消息、批量接口都调用同一策略。知道 item_id 不构成权限。
7. 共享撤销删除的是一条授权来源；其他有效授权仍可能存在，响应应返回剩余来源。继承授权只能在其来源文件夹撤销。

返回 `effective_capabilities` 与当前用户可见的 `permission_sources`，用于客户端解释权限；共享清单和所有接收者身份仅 Owner 可查看。授权目标使用明确 user_id，不提供全局用户邮箱枚举；未来邮箱验证和邀请流程由 identity 增量负责。

ACL 可选 expires_at；过期每次判权计算。只允许 Owner 给 active 用户授权，无需团队邀请的接受流程；“共享给我”可隐藏，但隐藏不是撤销授权。指定 user_id 错误时返回通用目标不可用错误。

### 4.3 并发与撤权

沿用当前团队空间行锁协议：所有文件写入、共享变更、移动、回收和团队成员变更锁同一 spaces 行，锁后刷新成员/ACL/Item 状态，随后执行。不得使用 SQLAlchemy identity map 中锁前的旧成员角色；明确刷新或重查。首版牺牲同空间写并发换取可验证的一致性，性能不足时再改细粒度锁。

读请求从数据库当前提交状态判权；撤权提交后发起的新请求失权，已开始请求不承诺中断。默认下载 URL 有效 60 秒，撤权后可能仍可下载；严格下载模式采用鉴权流式代理，先实现默认模式。已下载的本地副本无法撤回。

幂等回执也必须先做当前判权，不能使被撤权用户重放旧请求获得内容。预签名 URL 不作为可长期重放的业务回执；需要时重新授权签发。

## 5. 目录、移动和回收站

每空间一个服务端创建的 root Folder，禁止重命名、移动和回收 root。父节点必须是同空间 active Folder；所有普通项都有非空 parent_id。限制最大深度 32，首版名称 NFC + casefold 后同父目录唯一，最多 255 UTF-8 字节，禁止空白名、控制字符、路径分隔符及 `.`/`..`。DB 对 active 项建立 `(space_id,parent_id,normalized_name)` 部分唯一索引；根项使用独立约束。

移动必须有空间结构管理能力，同时检查目标 Folder、无环、预期 metadata_version 和名称冲突。个人 Owner 移动共享项目时，通过 prepare/commit 返回新增/失去的继承授权来源；commit 绑定空间 acl_revision、源/目标版本和预览哈希，变化后返回 409。直接 ACL 随资源保留，继承权限按新父目录立即计算。团队内移动不改变成员权限。首版拒绝跨空间移动和复制，避免与另一 agent 的资源归属契约冲突。

回收采用批次：空间锁内锁定并标记整棵当前 active 子树，写 trash_batch_id。之前已单独回收的子项不加入新批次。恢复只恢复该批次，不复活以前单独删除的子项；原父目录不可用或名称冲突时要求明确新位置/名称。恢复会恢复直接 ACL 和新位置上的继承访问，预览需展示此效果。

默认保留 30 天，回收内容及历史版本仍占配额，直到对应物理对象清理完成。永久删除只接受已回收批次，并先进入 purging、撤销授权、写审计与 outbox；worker 删除精确 OSS 对象版本后标记 purged。首版不自动删除仍有效的旧文件版本；历史保留策略单独配置和验收。对象生命周期不得独立删除数据库仍引用的已发布版本。

## 6. 数据模型与团队开发边界

为避免与 Page/Apps 正在开发的统一 items 冲突，首版用文件域专用 `drive_items`，其含义是文件和文件夹的权威目录。未来接统一资源目录时保留 item_id，不另建第二套文件权限来源。字段命名与预留接口应先同步给其他开发者；本设计不自动向其他 chat 发消息。

| 新表 | 关键字段与约束 |
| --- | --- |
| drive_items | item_id UUID PK、space_id FK、kind folder/file、parent_id、name、normalized_name、metadata_version、status active/trashed/purging/purged、trash_batch_id、created_by/updated_by、时间戳；复合 FK 保证父子同空间，服务验证父类型与无环 |
| drive_files | item_id PK/FK、current_version_id；指针必须属于同一 file |
| drive_file_versions | version_id PK、item_id FK、ordinal、bucket、object_key、oss_version_id、size_bytes、sha256、crc64、declared_mime、created_by、created_at；(item_id,ordinal) 唯一，不变记录 |
| drive_file_uploads | upload_id、space_id、actor_user_id、mode、target_item_id、parent_id、expected_file_version、expected_metadata_version、声明 size/sha256、reserved_bytes、temp_key、OSS upload_id、状态、expiry、verified_object/version、failure_code |
| drive_grants | grant_id、item_id、user_id、role viewer/editor、expires_at、created_by、revoked_at、version；同 item/user 最多一条未撤销授权，仅 personal 资源 |
| drive_trash_batches | batch_id、root_item_id、原父位置、actor、删除/保留到期时间、状态 |
| drive_quota_usage | space_id PK、committed_bytes、reserved_bytes、limits；保留全部 file version 与暂存预约 |
| drive_idempotency_receipts | actor、operation、target、key、request_hash、状态、稳定结果、expires_at；唯一约束和事务保证并发不双写 |
| drive_audit_events / drive_outbox | actor、space/item、动作、前后版本、request_id；异步任务有唯一业务键、重试、租约与失败记录 |

新增 `drive_space_state(space_id PK/FK, root_item_id, acl_revision)`，避免直接改变由 identity/Page/Apps 共用的 Space 模型。ACL、移动、回收变更推进 acl_revision；它不替代团队当前成员检查。首版不持久化逐用户有效权限展开表，使用有界递归祖先查询；索引至少包含 `(space_id,parent_id,status)`、`(user_id,revoked_at,item_id)`、`(item_id,ordinal)` 和待执行 outbox 状态。

建议模块：`files/router.py`（传输契约）、`files/service.py`（事务）、`files/permissions.py`（有效权限与 SQL 可见性谓词）、`files/models.py`、`files/oss_storage.py`、`files/jobs.py`。API 依赖现有 auth 和 Space/TeamMember；不得让 auth 反向依赖 files。当前 current_user 放在 pages/router.py，文件首版可复用其依赖，迁至 auth 公共模块需与另一 agent 协商，不同时修改。

迁移号 `0008` 以后由并行开发者协商分配，不在本设计预占 Alembic revision。共用 main.py 注册路由及 models/__init__.py 的修改应集中合并，避免双 head/覆盖。

## 7. Aliyun OSS 存储与上传发布

### 7.1 首版配置

仅实现 Aliyun OSS，使用独立 `VESSEL_FILES_*` 配置，不复用 Page 图片路径。客户端只取得精确操作的短期签名指令，无 Bucket 列表、删除或最终键写权限。推荐独立私有暂存/版本 Bucket；版本区开启版本控制。按本轮用户明确选择，也支持复用 baizhi-agent 的现有未版本化 Bucket：须显式设置 `VESSEL_FILES_OSS_ALLOW_UNVERSIONED=true` 并使用独立前缀，客户端只写暂存区，最终键由服务端复制并禁止覆盖，再次校验最终字节。暂停版本控制状态拒绝；不修改现有 Bucket 设置。新对象请求 SSE-OSS，传输使用 TLS。

暂存键为 `{prefix}/uploads/{upload_id}`；发布键为 `{prefix}/files/{space_id}/{publication_id}`，ID 由服务端随机生成，名称和路径不进入对象键。版本化模式绑定实际 OSS versionId；显式未版本化模式存储字符串 `null`，使用独立、禁止覆盖的最终键。签名只允许服务端选择的 method/key/uploadId/partNumber 和必要 headers，禁止客户端传 endpoint、bucket、key 或 URL。

建议默认：单文件最大 512 MiB，超过 16 MiB 使用分段上传，part 建议 8 MiB，上传授权 10 分钟、会话 24 小时；空间默认 10 GiB，可部署配置。最大文件值为首版产品限额，不是 OSS 平台限额。首版限额避免大对象跨段复制发布增加实现复杂度，后续大文件再设计 UploadPartCopy。

### 7.2 状态机与步骤

```text
pending → uploading → verifying → publishing → ready
                  ↘ failed / expired / cancelled
publishing → conflict（本意图终止，短期保留对象用于清理对账）
```

1. 创建上传意图：当前判权，空间锁内预约字节/文件额度。create 绑定父文件夹；new_version 必须提供 item_id 与 expected_current_version_id，不能用名字推断目标。上传本身不暴露 ready 文件。
2. 单段上传：签名 PUT 到暂存 Bucket，签入 `x-oss-forbid-overwrite:true`、必要长度/类型/MD5 headers。分段只允许客户端 UploadPart，Initiate/Complete/Abort 由服务端执行。超时或 URL 过期须经 API 重新判权签发。
3. complete：客户端提交上传回执作为线索；服务端根据自己保存的 key/uploadId 核验对象和分片，锁上传任务并按状态幂等推进，不能相信客户端自行指定的对象来源。
4. verifying：核验长度、读取 OSS CRC64，并流式计算 SHA-256，与声明值比较。CRC64 用于传输校验，ETag/客户端 metadata 都不能证明 SHA-256。worker 与临时对象清理通过任务租约避免竞争。
5. publishing：已校验暂存对象复制至服务端独有的随机版本键，记录 CopyObject 返回的精确 versionId；失败或响应丢失时按 publication ID 对账，未被采用的额外版本进入垃圾清理。客户端始终不能修改最终对象。
6. 最终 DB 提交：取得空间锁，刷新 actor 状态/成员或共享 ACL、父目录和目标状态，比较版本/metadata；检查 reserved 与实际字节后写 FileVersion、切换 current_version、结算配额、写幂等回执与审计。失权/回收/冻结不发布；并发版本变化返回 conflict，不能默认 last-write-wins。
7. 清理暂存由 outbox 执行。上传意图先持久化，分段会话延后至签名时创建；按精确暂存键对账未登记分段会话。取消/过期释放预约，不假定签名 URL 会即时失效；立即清理并在意图到期后一小时再次清扫晚到对象。复制返回的对象身份独立登记，失去租约也不丢弃；响应丢失时扫描精确最终键对账，删除前检查引用。重新请求同键已签发的 PUT 无法触达已发布键。

上述 Copy/DB 无跨系统事务，以持久任务状态、稳定 publication ID 和重试对账收敛。ready 下载引用具体 OSS versionId，或显式未版本化模式下不可覆盖的私有最终键。版本化暂存固定来源 versionId；未版本化暂存使用签名防覆盖和条件复制，最终对象再次流式验证 SHA-256。

配额限制的是服务承诺的有效/预约数据，并非绝对阻止已泄露签名产生 OSS 费用；签名必须有界，重签限速、分片数量限制、过期 abort 和暂存生命周期共同控制风险。校验在同地域内网执行，worker 有并发与字节吞吐预算。

committed_bytes 按空间内仍被逻辑版本引用的不同物理对象版本计费，不重复计算历史恢复产生的引用；保留历史和回收文件仍计费。reserved_bytes 是上传意图的预约，不把暂存和待提交最终对象双算为用户正式用量；运维另统计暂存/孤儿实际 OSS 字节，并设置清理告警。物理对象只允许在同空间复用引用。

### 7.3 下载、版本和删除

`download` 先按当前权限检查目标文件及指定历史版本，再签精确 OSS versionId 的 GET，默认有效 60 秒，响应含 filename、size、sha256、expires_at。Content-Disposition 使用 attachment 和安全编码文件名；HTML/SVG 等内容不作为可信在线页面预览。短期 URL 和正文不写日志。

恢复历史版本要求 expected_current_version_id；产生新的逻辑版本记录引用原来的不可变对象，再切当前指针，原历史不改写。物理删除必须在所有逻辑引用消失后才执行，worker 删除精确对象版本，不能把共享对象上的一个逻辑版本删除扩散到其他引用。首版仅随整个已回收文件永久清理历史，不提供单个版本删除 API。

## 8. API 契约草案

完整请求、响应、状态和错误定义见 [文件 API 契约](api-contract-files.md)，通用风格对齐 [Pages/Apps API 契约](api-contract-pages-apps.md)。文件端点已注册；不改变 Pages/Apps 已确认的接口与权限范围。

采用 `/v1/spaces/{space_id}/file-items`、`/folders` 和 `/file-uploads` 作为空间入口；按 ID 使用 `/v1/file-items/{item_id}`、`/v1/folders/{folder_id}`、`/v1/files/{file_id}`、`/v1/file-uploads/{upload_id}`。不使用 `/v1/drive` 前缀，也不占用 Pages 的 `/v1/directories` 或 `/v1/assets`。首版没有隐式个人空间创建路径，客户端先选择 space_id。

使用 Vessel Bearer Token、服务端 UUID、UTC ISO 8601、资源名包裹的成功响应和现有 `{"detail":{"code":"..."}}` 业务错误体；FastAPI 字段验证沿用原生 422。请求关联 ID 使用 X-Request-ID 响应头，不改 Pages/Apps 错误体。

文件分页默认 50、最大 200；游标绑定空间/文件夹、筛选与排序，每页重新判权。元数据变更要求 expected_metadata_version，文件版本切换要求 expected_current_version_id，共享变更要求 expected_acl_revision。状态机、幂等重试与 OSS 指令由独立文件契约明确定义。

个人资源 ACL 是文件增量扩展：共享接收者可访问指定文件而不加入源空间；共享给我只返回可见入口，不能据此浏览空间根目录。Page、App、Page 图片和记录不会继承文件共享权。

## 9. 验收、发布与实施顺序

第一阶段：drive_items/root/目录与空间角色；个人/团队资源隔离、名称唯一、无环和并发目录操作。

第二阶段：真实 OSS 上传、校验、发布、下载、版本、配额和 outbox；这一阶段独立验收再开放文件存储。

第三阶段：个人文件/文件夹共享、继承、共享给我、移动预览和撤权；ACL 查询和所有文件端点一起上线，不能仅开放授予接口。

第四阶段：回收站批次恢复与永久清理；文件 CLI/MCP 与完整 E2E。CLI/MCP 输出和凭据库另有契约，不宣称现有 Page MCP 已兼容文件工具。

必测场景：

1. A 私有文件对 B 不可见；分享 Viewer 后可下载/读历史，但不能上传新版本。
2. 文件夹 Editor 可创建文件和修改子文件，所有权/配额仍属于 A；不可改变共享、移动、回收。
3. 单文件直接分享不泄露未授权父目录、兄弟文件、空间根目录。
4. 两条授权来源时撤销一条仍可访问；移除最后来源后旧 Token 新请求返回 404。
5. 撤销祖先共享使全部继承项失权，已独立直接分享的子项仍按直接授权可见。
6. 团队 Viewer 只读；团队 Editor 可写；成员移除与文件写入按空间锁提交顺序生效。
7. 目录交叉移动、删除期间创建子项、移动预览后 ACL 变化不会产生环、孤儿或静默权限变化。
8. 上传 A 后发起新版本 B/C；完成顺序反转时第二个发布冲突，不能静默覆盖。
9. 完成请求重试、DB 提交失败、OSS Copy 响应丢失、任务进程退出均可对账；至多一次逻辑发布/配额结算。
10. ready 后重放上传 URL不能修改已发布下载内容；缺失防覆盖 header 的签名请求拒绝；OSS 暂存 Bucket 版本状态异常阻断上传。
11. 上传期间撤权、回收文件夹/文件或冻结空间，worker 不发布，最终对象孤儿可清理。
12. 校验失败不 ready；并发上传不能超预约额度；取消和过期后迟到对象不泄露、不长期遗留。
13. 回收父目录并恢复不复活先前单独回收的子项；冲突需指定目标；恢复预览显示重新生效的共享。
14. 历史恢复保留对象引用，永久清理只删无引用的精确 OSS versionId，失败可重试。
15. 文件夹多层继承、共享入口分页及搜索不会泄露未授权项；Page/Apps 原有 API 回归不受影响。

运行 mock/unit 测试不等于 OSS 验收；必须使用隔离 PostgreSQL、真实 OSS 的测试 Bucket 或明确批准的独立对象前缀及真实 HTTP 服务完成上传/分段/发布/下载/撤权/回收/清理。不得清理其他前缀或修改既有 Bucket 设置。需报告内容校验和故障回归结果；版本化模式另记录具体 versionId，日志不包含签名 URL。本轮按用户授权复用既有 OSS，结果见运行说明。

设计通过后再写文件增量实施计划。发布前确定 OSS 地域、Bucket、服务端 RAM 身份、配额、保留期和 worker 部署；不要求用户在聊天中提供密钥。

## 10. 待产品确认的选择

1. 个人分享首版只按已有 active 用户 ID；邮箱邀请和匿名链接延后。
2. 团队继续默认共享，无私密子文件夹，也不向非成员授予文件权限。
3. 个人共享 Editor 不可移动或删除；团队 Editor 可在本团队移动/回收。
4. 同目录名称规范化后唯一；首版文件最大 512 MiB，默认空间 10 GiB、回收 30 天。
5. 文件域先独立 drive_items；与 Page/Apps 统一目录作为后续明确协作契约。

## 11. 官方资料与核验范围

- [OSS PutObject](https://www.alibabacloud.com/help/en/oss/developer-reference/putobject)：默认覆盖、版本 ID，以及版本控制开启/暂停时 forbid-overwrite 无效。
- [OSS CopyObject](https://www.alibabacloud.com/help/en/oss/developer-reference/copyobject)：服务端复制发布操作；实现时冻结所用 SDK 和 headers 契约。
- [OSS CRC64](https://www.alibabacloud.com/help/en/oss/user-guide/check-data-transmission-integrity-by-using-crc-64)：提供商传输完整性校验；SHA-256 由 Vessel worker 独立计算。
- [OSS multipart upload](https://www.alibabacloud.com/help/en/oss/user-guide/multipart-upload)：分段操作链路。

2026-10-14 核对设计资料；2026-10-15 完成文件 HTTP 实现与真实 OSS 联调。测试证据和限制见 [运行说明](files-runtime.md)。CLI/MCP、匿名分享、跨空间复制和生产发布不在本轮交付内。
