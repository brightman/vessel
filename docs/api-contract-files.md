# Vessel API 契约草案：文件、文件夹与 Aliyun OSS

状态：**文件 HTTP API 已实现，生产未发布**。日期：2026-10-14；实现更新：2026-10-15。运行与验收见 [文件服务运行说明](files-runtime.md)。

设计依据：[文件共享设计](shared-files-design.md)。通用 API 风格对齐 [Notes/Apps 契约](api-contract-notes-apps.md)。仅负责通用文件和文件夹，不修改另一 coding agent 负责的 Note、App、图片、记录或新 Note Agent 契约。首版存储仅 Aliyun OSS。

## 1. 通用约定与边界

- API 以 `/v1` 开头，所有文件端点使用 `Authorization: Bearer <Vessel access_token>`，audience 为 `vessel-api`。复用现有账号、spaces 和 team_members，不新增登录接口或 Drive 成员系统。
- 创建和列表显式选空间；按资源 ID 访问时，服务端读取真实 space_id。space_id 创建后不变，不支持跨空间移动或复制。首版没有 `/v1/files` 的隐式个人创建/列表入口。
- 文件 Folder 使用 `/folders`，不复用 Note 的扁平 `/directories`；通用文件不复用 `/assets`；文件夹不容纳 Note 或 App。
- 文件 Item 的 `file_id`、文件夹 Item 的 `folder_id` 均等于其 `item_id`，不是另一个生成的 ID。所有 ID 是服务端 UUID；客户端不能指定创建者、归属、对象键或当前版本。
- 成功 JSON 按资源名包裹；204 无正文。业务错误为 `{"detail":{"code":"ERROR_CODE"}}`，可附安全 message；字段验证沿用 FastAPI 原生 422。X-Request-ID 响应头用于请求关联，不改变 Notes/Apps 错误体。
- 时间为 UTC ISO 8601。所有列表默认 limit=50、最大 200，响应包含 next_cursor。默认 items 按 normalized_name,item_id 排序；版本按 ordinal DESC,version_id；其他列表按 created_at,id。游标绑定主体、目标、筛选和排序，篡改/错用返回 422 CURSOR_INVALID；每页重新判权，不承诺跨页快照。
- mutation 请求必须带 Idempotency-Key，最长 128 字符；同主体/操作/目标/key 同请求返回首个稳定结果，不同请求体返回 409 IDEMPOTENCY_CONFLICT。回执保留 7 天，超过期限不承诺去重。相同 key 的并发请求不得双写；执行中重放返回 409 REQUEST_IN_PROGRESS 和 Retry-After。当前授权先于回执返回。
- download 和 parts/sign 签发短期能力，不属于持久 mutation 幂等回执；每次新签发重新判权。不得把上传/下载 URL 写日志或作为长期业务结果缓存。

### 1.1 权限

个人 Owner 全权；个人直接/继承共享 viewer 只读，editor 可上传新版本、恢复历史文件版本、重命名，并可在有 editor 权限的共享文件夹内新增子项，不能移动、回收、恢复回收站条目、管理共享或永久删除。创建者只作审计，新文件归父目录空间。

团队 Owner/Admin/Editor 可读写、移动、回收、恢复；Viewer 只读；永久删除仅 Owner/Admin。团队文件对有效成员默认可见，本增量不提供团队文件 ACL、非成员分享或受限子文件夹。个人 ACL 只对已有 active Vessel user_id 生效，不新增邮箱邀请、匿名链接或用户搜索接口。此 ACL 扩展仅适用于文件，不推翻 Notes/Apps 的空间权限契约。

无查看权限返回 404；可查看但能力不足返回 403。共享文件不会使接收者出现在 GET /v1/spaces，也不会授予 GET /v1/spaces/{id}/permissions 或空间根目录权限。版本列表和下载按文件当前权限；读权包含保留的历史版本。

## 2. 空间入口、目录与元数据

以下端点均已注册为文件域接口。root 在文件功能初始化时创建，每空间一个，客户端不能移动、重命名或回收。

| 方法与路径 | 请求/用途 | 成功响应 |
| --- | --- | --- |
| GET `/v1/spaces/{space_id}/folders/root` | 空间角色授权，读取文件根目录 | 200；`{"folder":Folder}` |
| GET `/v1/spaces/{space_id}/file-items` | parent_folder_id 可选，默认 root；limit/cursor，kind 可选 file/folder | 200；`{"items":[Item],"next_cursor":string|null}` |
| POST `/v1/spaces/{space_id}/folders` | name、parent_folder_id 必填 | 201；`{"folder":Folder}` |
| GET `/v1/folders/{folder_id}/children` | limit/cursor，kind 可选；适用于共享文件夹 | 200；`{"items":[Item],"next_cursor":string|null}` |
| GET `/v1/file-items/{item_id}` | 读取文件或文件夹元数据 | 200；`{"item":Item}` |
| PATCH `/v1/file-items/{item_id}` | name、expected_metadata_version；不能在此改 parent/status/space | 200；`{"item":Item}` |
| GET `/v1/file-items/{item_id}/permissions` | 当前能力及可见授权来源 | 200；`{"permissions":Permissions}` |
| POST `/v1/spaces/{space_id}/file-items/search` | name_contains 可选、kind 可选、limit/cursor；至少一个过滤条件 | 200；`{"items":[Item],"next_cursor":string|null}` |

`Item`：item_id、space_id、kind、parent_folder_id、name、metadata_version、status、created_by_user_id、updated_by_user_id、created_at、updated_at；file 项附 current_version_id、size_bytes、sha256、content_type。`Folder` 为 kind=folder 的 Item，附 folder_id=item_id。metadata_version 初始 1，每次用户可见元数据变更加 1，包括版本切换、移动、回收及恢复；grant 变化使用独立 acl_revision。root 的 parent_folder_id=null。

`Permissions`：item_id、can_read、can_write、can_create_children、can_move、can_trash、can_restore、can_manage_sharing、can_purge、permission_sources。来源只返回当前用户有权知道的授权 ID/类型和来源节点；不可见祖先不返回名称或路径。权限快照仅用于展示，提交仍重新检查。

parent_folder_id 必须是同空间 active Folder，跨空间/不可见返回 FOLDER_NOT_FOUND。共享接收者只能列举自己有权访问的文件夹；空间 file-items 默认 root 对其不可见，指定授权 folder ID 时允许文件域 ACL 判权。搜索 SQL 限制可见文件，不泄露不可见祖先/兄弟名称，不要求个人共享接收者成为空间 Owner。

## 3. 个人资源共享与继承

| 方法与路径 | 请求/用途 | 成功响应 |
| --- | --- | --- |
| GET `/v1/shared-files` | 我的有效个人共享入口；limit/cursor | 200；`{"items":[Item],"next_cursor":string|null}` |
| GET `/v1/file-items/{item_id}/grants` | 仅个人 Owner，查询直接与继承授权 | 200；`{"grants":[Grant],"acl_revision":integer,"next_cursor":string|null}` |
| POST `/v1/file-items/{item_id}/grants` | grantee_user_id、role viewer/editor、expires_at 可选、expected_acl_revision | 201；`{"grant":Grant,"acl_revision":integer}` |
| PATCH `/v1/file-items/{item_id}/grants/{grant_id}` | role/expires_at、expected_acl_revision | 200；`{"grant":Grant,"acl_revision":integer}` |
| DELETE `/v1/file-items/{item_id}/grants/{grant_id}` | JSON expected_acl_revision；仅撤销本 item 的直接授权 | 204 |

`Grant`：grant_id、item_id、grantee_user_id、role、expires_at、created_by_user_id、created_at、inherited、source_item_id。继承条目不可在子项 PATCH/DELETE，返回 409 INHERITED_PERMISSION；需要修改来源 Folder。共享列表 acl_revision 是空间级共享/结构修订，初始 1，共享、移动、回收、恢复时推进；不替代成员角色或账号状态检查。Folder 和文件共用该令牌，变更后客户端重读。

只支持 additive 授权，直接和继承取较高角色。相同 item/user 不能重复创建未撤销 Grant，返回 409 FILE_GRANT_CONFLICT；修改用 PATCH。目标账号不可用返回 422 SHARE_TARGET_UNAVAILABLE。expires_at 必须晚于当前时间；到期不等于删除记录，但不能访问。

shared-files 是虚拟视图，保留原 space_id 和 item_id，不创建副本；有有效共享祖先时隐藏冗余子入口。撤销返回 204；若需确认仍有其他权限来源，随后读取 permissions。本轮仅有效共享列表，不提供隐藏共享入口的用户偏好 API。

## 4. Aliyun OSS 上传、状态与下载

| 方法与路径 | 请求/用途 | 成功响应 |
| --- | --- | --- |
| POST `/v1/spaces/{space_id}/file-uploads` | 上传意图，见下文 | 201；`{"upload":Upload}`，不含预签名 URL |
| POST `/v1/file-uploads/{upload_id}/parts/sign` | part_numbers；单段固定 [1]，分段每次最多 20 个 | 200；`{"instructions":[UploadInstruction]}`，每次重新判权 |
| POST `/v1/file-uploads/{upload_id}/complete` | 单段 `{}`；分段 parts=[{part_number,etag}]，服务端核验 | 202；`{"upload":Upload}` 和 Location 状态 URL；重复提交已 ready 时 200 |
| GET `/v1/file-uploads/{upload_id}` | 当前授权的上传发起人可读；空间 Owner/Admin 可管理读取 | 200；`{"upload":Upload}` |
| POST `/v1/file-uploads/{upload_id}/cancel` | `{}`；终止尚未发布的任务 | 200；`{"upload":Upload}`，取消与最终发布串行化 |
| POST `/v1/files/{file_id}/download` | version_id 可选，默认当前版本 | 200；`{"download":Download}` |
| GET `/v1/files/{file_id}/versions` | limit/cursor，读权限 | 200；`{"versions":[FileVersion],"next_cursor":string|null}` |
| POST `/v1/files/{file_id}/versions/{version_id}/restore` | expected_current_version_id | 200；`{"file":Item,"version":FileVersion}`，新逻辑版本引用不可变对象 |

意图公共字段：mode=create/new_version、size_bytes、sha256（64 位 hex）、content_type。create 另需 parent_folder_id、name；new_version 另需 file_id、expected_current_version_id 和 expected_metadata_version，不接受 parent/name。file_id 必须在路径空间内。create 名称冲突在发布事务中再次核验；new_version 发布事务再次比较文件版本和元数据。

`Upload`：upload_id、space_id、mode、file_id（create 待 ready 时 null）、status、size_bytes、sha256、content_type、transfer_mode single/multipart、part_size_bytes、part_count、expires_at、version_id（ready 前 null）、failure_code（无错误 null）、status_url。不返回长期凭据、任意 Bucket 配置或可由客户端改写的对象键。

`UploadInstruction`：part_number、method=PUT、url、headers、expires_at、size_bytes。客户端必须原样携带签名 headers；只能写指定暂存键/分片，不能列举 Bucket、完成 multipart 或写最终对象。长度/分片边界由服务端声明、OSS 操作和完成校验共同约束。

`FileVersion`：version_id、file_id、ordinal、size_bytes、sha256、crc64、content_type、created_by_user_id、created_at、source upload/restore、restored_from_version_id（可空）；不向客户端暴露最终 object_key 或 oss_version_id。

`Download`：file_id、version_id、name、size_bytes、sha256、content_type、url、expires_at；默认 URL 60 秒。版本化模式绑定具体 OSS versionId；用户明确允许的未版本化模式绑定独立、禁止覆盖的最终键。有效 URL 的剩余期限不承诺即时撤销。

状态为 pending/uploading/verifying/publishing/ready/failed/expired/cancelled/conflict。complete 接受后 202，任务失败由 GET 中 failure_code 表示，不把已接受的异步失败伪装为同步 HTTP 错误。ready/cancelled/expired/failed/conflict 是本次上传意图的终态；ready 取消返回 409 UPLOAD_STATE_CONFLICT。conflict 不提供覆盖式 retry API：客户端重读目标，使用新 key 和新意图重新上传，旧对象按保留期清理。

complete 的同 key 重放返回首次 202 回执，即使后台已 ready；GET 获取最新状态。不同 key 对 ready 意图 complete 返回 200 同结果，不再发布。parts/sign 和 GET 必须同时检查发起人当前文件写权限，不能仅凭 upload_id 或旧授权读取。

```http
POST /v1/spaces/8e80f2dc-0b30-4a9f-b6c5-cd68e579bc56/file-uploads
Authorization: Bearer <access_token>
Idempotency-Key: upload-report-20261014
Content-Type: application/json

{"mode":"create","parent_folder_id":"667f49e8-4c0e-428a-a788-f3f5ddc4ee71","name":"report.pdf","size_bytes":185234,"sha256":"0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef","content_type":"application/pdf"}
```

## 5. 移动、回收、恢复与永久清理

| 方法与路径 | 请求/用途 | 成功响应 |
| --- | --- | --- |
| POST `/v1/file-items/{item_id}/move/prepare` | target_parent_folder_id、expected_metadata_version、可选 name | 200；`{"move":MovePreview}` |
| POST `/v1/file-items/{item_id}/move/commit` | preview_id、preview_hash、expected_metadata_version、expected_acl_revision | 200；`{"item":Item}` |
| POST `/v1/file-items/{item_id}/trash` | expected_metadata_version | 200；`{"trash_batch":TrashBatch}` |
| GET `/v1/spaces/{space_id}/file-trash` | 空间 Owner/Admin/团队 Editor；limit/cursor | 200；`{"trash_batches":[TrashBatch],"next_cursor":string|null}` |
| POST `/v1/file-trash/{batch_id}/restore/prepare` | 可选 target_parent_folder_id/name，默认原位置 | 200；`{"restore":RestorePreview}` |
| POST `/v1/file-trash/{batch_id}/restore` | preview_id、preview_hash、expected_acl_revision | 200；`{"item":Item,"trash_batch":TrashBatch}` |
| POST `/v1/file-trash/{batch_id}/purge` | expected_batch_version；仅 Owner/Admin | 202；`{"purge":PurgeJob}` 和 Location 状态 URL |
| GET `/v1/file-purges/{purge_id}` | Owner/Admin；操作已登记后无需目标仍存在 | 200；`{"purge":PurgeJob}` |

MovePreview/RestorePreview 包含 preview_id、preview_hash、item_id、target_parent_folder_id、name、expected_metadata_version、expected_acl_revision、permission_changes、expires_at，默认 5 分钟有效。RestorePreview 的版本令牌包含 batch_version。预览绑定操作者和服务器保存的请求，commit 不接受客户端任意替换目标。结构/共享变化、预览过期或版本变化返回 409 FILE_OPERATION_PREVIEW_CONFLICT。生成预览也必须有结构管理/恢复权限。

TrashBatch 包含 batch_id、space_id、root_item_id、original_parent_folder_id、status trashed/restored/purging/purged、batch_version、trashed_at、retention_until。已单独回收的子项不加入新批次；恢复只恢复该批次。PurgeJob 包含 purge_id、space_id、batch_id、status pending/running/succeeded/failed、failure_code、created_at、updated_at、status_url；失败由 worker 幂等重试，保留任务记录以便查询。

移回收站会标记 active 子树，不能继续下载；删除不是 Note archive。恢复可能重新激活共享，需预览确认。文件/历史占配额直到物理对象清理完成；不能在进入 purging 时提前释放容量。名称冲突要求显式新位置/名字；跨空间目标拒绝，root 不允许结构变更。

## 6. 错误、审计与协作边界

| HTTP | 典型 code | 含义 |
| --- | --- | --- |
| 401 | AUTHENTICATION_REQUIRED、INVALID_ACCESS_TOKEN | 复用当前认证 |
| 403 | SPACE_PERMISSION_DENIED、FILE_PERMISSION_DENIED | 资源可见，但操作能力不足 |
| 404 | SPACE_NOT_FOUND、FILE_ITEM_NOT_FOUND、FOLDER_NOT_FOUND、FILE_NOT_FOUND、FILE_VERSION_NOT_FOUND、FILE_UPLOAD_NOT_FOUND | 不存在或不可见；跨空间目标也不能枚举 |
| 409 | FILE_METADATA_VERSION_CONFLICT、FILE_VERSION_CONFLICT、FILE_ACL_REVISION_CONFLICT、ITEM_NAME_CONFLICT、FILE_GRANT_CONFLICT、INHERITED_PERMISSION、FILE_OPERATION_PREVIEW_CONFLICT、UPLOAD_STATE_CONFLICT、IDEMPOTENCY_CONFLICT、REQUEST_IN_PROGRESS | 状态、授权来源、预期版本或幂等冲突 |
| 413 | FILE_TOO_LARGE、SPACE_QUOTA_EXCEEDED | 超限 |
| 422 | FILE_NAME_INVALID、FILE_QUERY_INVALID、CURSOR_INVALID、SHARE_TARGET_UNAVAILABLE、UPLOAD_CHECKSUM_MISMATCH | 业务内容验证失败；字段结构仍沿用 FastAPI 422 |
| 503 | FILE_STORAGE_UNAVAILABLE | OSS 或必要文件存储配置不可用 |

失败上传的 failure_code 可以包含 UPLOAD_CHECKSUM_MISMATCH、FILE_VERSION_CONFLICT、FILE_PERMISSION_REVOKED 等，不返回不可见目标名称、正文或凭据。异步冲突状态与 code 区分于同步 HTTP 返回。

GET `/v1/spaces/{space_id}/file-audit` 已新增，仅空间 Owner/Admin，响应 `{"events":[AuditEvent],"next_cursor":string|null}`，默认 50/最多 200；不占用未来统一 audit 路由。AuditEvent 包含 event_id、space_id、item_id、actor_user_id、operation、result、before_version、after_version、request_id、created_at，不默认记录内容或签名 URL。

请求时字段验证与业务执行分离；事务中锁当前 Space 并重新查成员/ACL/目标状态，写资源、幂等回执和审计同事务提交。文件签名与异步任务不会复用旧 Note MCP audience/capability。Notes/Apps 的无分页兼容接口不因文件分页而改变。迁移号、auth 公共依赖及 main 路由注册需在实现前与并行开发者协调。

## 7. 契约状态与验收

用户已授权开发本契约中的文件共享系统，请求 Schema 与路由已注册到 FastAPI/OpenAPI。个人 ACL、Editor 能力、512 MiB 文件限额和独立 drive_items 按当前设计实现。真实 OSS、PostgreSQL 和故障回归覆盖情况见运行说明；本轮不发布 CLI/MCP，也未修改 Notes/Apps 契约。
