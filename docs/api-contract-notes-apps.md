# Vessel API 契约草案：Notes、Apps 与空间权限

状态：**三个 API 决策已确认；本轮接口已实现**。日期：2026-10-14。

本文记录 Notes 内容能力及从 Baizhi Apps 规则适配的表格能力接入 Vessel 独立账号与空间后的 HTTP API。下表中的「新增」和「已调整」均已在 Vessel 应用中注册；通用文件 API 与新 Note Agent 另行实施。

## 1. 通用约定

- API 基址由部署决定，业务路径以 `/v1` 开头。所有资源 API 使用 `Authorization: Bearer <Vessel access_token>`；注册、登录与 Refresh 除外。Vessel 独立签发 `aud=vessel-api`、`scope=vessel:session` 的 Token，不接受 Baizhi Apps/Pages 账号 Token。
- 用户注册时自动拥有一个个人空间；团队创建一个团队空间。团队 ID 即 `space_id`。资源的 `space_id` 创建后不可修改；本轮不提供跨空间移动、复制或资源级 ACL。
- `owner_user_id`、`created_by_user_id` 等现有字段只作创建者记录与审计用途。团队 Note 和 App 的访问权由持久化 `space_id` 与当前成员角色决定，创建者不额外获得私有权限。请求中的角色、创建者或用户 ID 不能覆盖服务端身份。
- Owner/Admin/Editor 可读写；Viewer 只读。非成员或无权查看的资源返回 404；已可查看但无写权限返回 403。成员移除或角色降级后，每个新请求重新查询成员状态。写入与成员变更要在数据库事务中确定顺序。
- 成功 JSON 使用资源名包裹，例如 `{"note": {...}}`、`{"app": {...}}`、`{"records": [...]}`；204 不返回正文。业务错误沿用当前实现的 `{"detail":{"code":"ERROR_CODE"}}`。Pydantic 字段验证错误仍是 FastAPI 的 422 格式。
- ID 是服务端生成的 UUID 字符串。时间为 UTC ISO 8601。列表默认按稳定排序；本轮 Notes/目录保持现有无分页响应，Apps 记录使用游标分页。

### 1.1 角色矩阵

| 操作 | 个人空间本人 | 团队 Owner/Admin | 团队 Editor | 团队 Viewer | 非成员 |
| --- | --- | --- | --- | --- | --- |
| 列表、读取、导出、版本、图片、表格记录查询 | 允许 | 允许 | 允许 | 允许 | 404/列表不可见 |
| 新建、修改、归档、恢复、上传图片、写记录 | 允许 | 允许 | 允许 | 403 | 404 |
| 管理邀请、角色、成员 | 不适用 | 允许，受 Owner 保护规则约束 | 403 | 403 | 404 |

版本恢复属于写操作。Vessel 为 Note Agent 使用独立的网关身份和 Run 记录；Edit 复用 Vessel 的提案校验与接受机制，Agent 不通过 Note MCP 写提案或内容。

## 2. 身份与团队：现有 API

以下端点已在当前工作区实现，本轮沿用其路径与主要字段。注册前邮箱验证码已完成本地开发与 Brevo 真实投递验收；生产部署需单独配置与验收，详见 [注册邮件说明](registration-email.md)。

| 方法与路径 | 请求 | 成功响应 |
| --- | --- | --- |
| `GET /v1/auth/options` | 无 | `registration_enabled`、`registration_email_verification_required`、`registration_email_resend_seconds` |
| `POST /v1/auth/registration/email-code` | `email` | 202；`challenge_id`、`expires_in=600`、`resend_after=60`；注册前验证邮箱 |
| `POST /v1/auth/register` | `name`、`email`、`password`；启用邮箱验证时还需 `challenge_id`、`verification_code` | 201；`access_token`、`token_type`、`expires_in`、`user`，设置 `vessel_refresh` Cookie |
| `POST /v1/auth/login` | `email`、`password` | 同上 |
| `POST /v1/auth/refresh` | `vessel_refresh` Cookie | 轮换 Cookie，返回新 Access Token |
| `GET /v1/auth/session` | `vessel_refresh` Cookie | `{"user": {...}}`；只读查询当前用户，不轮换 Cookie，响应禁止缓存 |
| `POST /v1/auth/logout` | Refresh Cookie | 204 |
| `GET /v1/auth/me` | Bearer Token | `{"user": {...}}` |
| `GET /v1/spaces` | Bearer Token | `{"spaces": [{"space_id", "kind", "name", "owner_user_id", "role", "status"}]}` |
| `GET /v1/spaces/{space_id}/permissions` | 无 | `space_id`、`role`、`can_read`、`can_write`、`can_manage_members`、`can_delete` |
| `POST /v1/teams` | `{"name":"Research"}` | 201；`{"space": {...}}`，创建者为 Owner |
| `GET /v1/teams/{space_id}` | 无 | `{"space": {...}}` |
| `GET /v1/teams/{space_id}/members` | 无 | `{"members": [{"user_id", "role", "status"}]}` |
| `POST /v1/teams/{space_id}/invitations` | `invitee_user_id`、`role` | 201；`{"invitation": {...}}`，有效期 7 天 |
| `GET /v1/teams/{space_id}/invitations` | 无 | Owner/Admin 的待处理 `invitations[]` |
| `GET /v1/team-invitations` | 无 | 当前用户的待处理 `invitations[]` |
| `POST /v1/team-invitations/{invitation_id}/accept` | 无 | `{"space": {...}}` |
| `DELETE /v1/teams/{space_id}/invitations/{invitation_id}` | 无 | 204 |
| `PATCH /v1/teams/{space_id}/members/{user_id}` | `{"role":"editor"}` | `{"member": {...}}` |
| `DELETE /v1/teams/{space_id}/members/{user_id}` | 无 | 204 |

角色是 `owner|admin|editor|viewer`。团队邀请只面向已存在且 active 的 Vessel 用户。生产默认关闭公开注册；注册邮箱验证接口已进入当前开发工作区，但尚未完成生产送达与部署验收。自助密码重置 API 尚未提供。

## 3. Notes：个人与团队空间路径

**路径决策：**保留现有 `/v1/notes`、`/v1/directories` 的列表和创建语义为「我的个人空间」。新增带 `space_id` 的规范入口供个人或团队空间使用。按 `note_id`、`directory_id` 访问的现有路径保留；服务端从资源行读取空间并判权，不要求客户端传创建者 ID。这样现有个人客户端无需改路径，团队客户端必须显式选择空间。

### 3.1 Note 与目录

| 方法与路径 | 状态 | 请求/用途 | 成功响应 |
| --- | --- | --- | --- |
| `GET /v1/spaces/{space_id}/notes?status=active|archived` | 新增 | 列出该空间 Note，默认 `active` | `{"notes": [Note]}` |
| `POST /v1/spaces/{space_id}/notes` | 新增 | `title`、`document`、可选 `directory_id` | 201；`{"note": Note}` |
| `GET /v1/notes`、`GET /v1/notes/archived` | 已调整授权 | 只列个人空间 Note | `{"notes": [Note]}` |
| `POST /v1/notes` | 已调整归属 | 同上创建体，固定创建在个人空间 | 201；`{"note": Note}` |
| `GET /v1/notes/{note_id}` | 已调整授权 | 页面内容 | `{"note": Note}` |
| `PATCH /v1/notes/{note_id}` | 已调整授权 | `expected_revision`，可选 `title`、`document`、`directory_id` | `{"note": Note}` |
| `POST /v1/notes/{note_id}/archive` | 已调整授权 | 归档 | 204 |
| `POST /v1/notes/{note_id}/restore` | 已调整授权 | 恢复 | `{"note": Note}` |
| `GET /v1/spaces/{space_id}/directories` | 新增 | 列出空间目录 | `{"directories": [Directory]}` |
| `POST /v1/spaces/{space_id}/directories` | 新增 | `{"name":"Research"}` | 201；`{"directory": Directory}` |
| `GET /v1/directories`、`POST /v1/directories` | 已调整归属 | 只操作个人空间 | 同现有格式 |
| `GET /v1/directories/{directory_id}` | 已调整授权 | 目录详情 | `{"directory": Directory}` |
| `PATCH /v1/directories/{directory_id}` | 已调整授权 | `{"name":"New name"}` | `{"directory": Directory}` |
| `POST /v1/directories/{directory_id}/archive` | 已调整授权 | 归档目录，空间内子 Note 转为无目录 | 204 |

`Note` 至少包含 `note_id`、`space_id`、`title`、`directory_id`、`document`、`markdown`、`revision`、`status`、`created_at`、`updated_at`。`Directory` 至少包含 `directory_id`、`space_id`、`name`、`status`、`created_at`、`updated_at`。任何 Note 的 `directory_id` 必须指向同一空间的有效目录；跨空间目录返回 `DIRECTORY_NOT_FOUND`，不迁移页面。

`document` 沿用 Notes 的 Tiptap 风格 JSON，根节点为 `{"type":"doc","schema_version":1,"content":[...]}`。顶层块必须有稳定的 `attrs.block_id`。服务端校验块类型、链接、图片 URL，保存规范化 JSON 并生成 Markdown。写入需提供 `expected_revision`；不匹配返回 409 `NOTE_REVISION_CONFLICT`。

```http
POST /v1/spaces/8e80f2dc-0b30-4a9f-b6c5-cd68e579bc56/notes
Authorization: Bearer <access_token>
Content-Type: application/json

{"title":"项目周报","directory_id":null,"document":{"type":"doc","schema_version":1,"content":[{"type":"heading","attrs":{"block_id":"intro","level":1},"content":[{"type":"text","text":"项目周报"}]}]}}
```

```json
{"note":{"note_id":"<uuid>","space_id":"8e80f2dc-0b30-4a9f-b6c5-cd68e579bc56","title":"项目周报","directory_id":null,"document":{"type":"doc","schema_version":1,"content":[{"type":"heading","attrs":{"block_id":"intro","level":1},"content":[{"type":"text","text":"项目周报"}]}]},"markdown":"# 项目周报\n","revision":1,"status":"active","created_at":"2026-10-14T00:00:00+00:00","updated_at":"2026-10-14T00:00:00+00:00"}}
```

### 3.2 Markdown、版本与图片

| 方法与路径 | 状态 | 读写能力/说明 |
| --- | --- | --- |
| `GET /v1/notes/{note_id}/markdown` | 已调整授权 | 读；返回 `text/markdown` 附件 |
| `PUT /v1/notes/{note_id}/markdown` | 已调整授权 | 写；`{"expected_revision":1,"markdown":"..."}`，生成新版本 |
| `GET /v1/notes/{note_id}/versions` | 已调整授权 | 读；返回 `versions[]` |
| `POST /v1/notes/{note_id}/versions/checkpoint` | 已调整授权 | 写；`expected_revision` |
| `POST /v1/notes/{note_id}/versions/{version_id}/restore` | 已调整授权 | 写；`expected_revision`，生成新修订 |
| `POST /v1/notes/{note_id}/assets` | 已调整授权 | 写；原始 PNG/JPEG/GIF/WebP 字节，请求 `Content-Type` 为图片类型 |
| `GET /v1/assets/{asset_id}/content` | 已调整授权 | 读；按关联 Note 的当前空间授权，返回图片字节 |

现有图片接口是 Note 附件功能，不等同于未来的通用 OSS/S3 文件 API。当前只在开发和测试环境配置私有本地图片存储；生产环境未配置图片存储，以上两条图片接口返回 503 `ASSET_STORAGE_NOT_CONFIGURED`，暂不能用于生产图片读写。

### 3.3 Note Agent

`GET /v1/notes/{note_id}/agent/status` 返回 Ask/Edit 的配置状态、Agent 连通状态 `online` 和当前用户未结束的 Run。`POST /v1/notes/{note_id}/agent/runs` 接受 `message` 与 `mode`（`ask` 或 `edit`）；Ask 需要空间读权限，Edit 需要空间写权限及 Agent Manage 中已保存的 JSON Schema。`GET /v1/notes/{note_id}/agent/runs/{run_id}/events` 转发 Agent SSE；`GET /v1/notes/{note_id}/agent/runs/{run_id}` 返回 Run 状态、回复和错误码；`POST /cancel` 取消 Run。Edit 的最终输出由 Agent Platform 依 Schema 约束，Vessel 再校验并生成提案预览，不向 Agent 传 Note MCP。`GET /v1/notes/{note_id}/proposals` 返回当前用户有效提案；`POST /v1/notes/{note_id}/proposals/{proposal_id}/accept` 带 `idempotency_key` 接受提案，按 `base_revision` 原子写入；`/reject` 拒绝。配置见 [Note Agent 说明](note-agent.md)。

### 3.4 数据库起点

给 `notes` 和 `note_directories` 增加非空 `space_id`；Vessel 按**全新数据库**部署，不执行历史 Note 或目录回填。已有 `owner_user_id` 在新建数据时记录创建者，不作为团队资源的判权依据。Note、目录和图片的创建者外键限制账号硬删除，以免级联删除空间资源；当前没有账号硬删除 API。若数据库已有旧 Note 数据，迁移应明确失败并要求使用空库，不能静默挂到某个个人空间。

## 4. Apps：表格存储 API

**资源模型：**一个 App 是一个空间内的表格集合，`app_id` 由 Vessel 生成；Manifest 描述多个表及字段。团队成员默认能读取该 App 下所有表和记录；不沿用 Baizhi Apps 的 `owner_id`/`permission` 逐行可见性、App 用户成员表、Agent grant 或 Baizhi 账号体系。App API 已适配源项目的 Manifest 标识符/类型校验、字段值规范化、受控记录操作及静态 H5 发布；数据和发布元数据存入 Vessel 自己的 PostgreSQL。

`owner` 与 `admin` 是 App 管理员，可创建 App、更新 App 资料、修改 Manifest、归档、恢复及读取审计事件；`editor` 可管理记录；`viewer` 只读。归档 App 保留 Manifest、记录和后续发布元数据，但只对管理员可见。

### 4.1 Manifest

创建请求中的 `manifest.tables` 非空。表名/字段名只允许安全标识符。首版字段类型为 `text|integer|numeric|boolean|timestamp|uuid|json`，每个字段有 `type` 和 `nullable`。`id`、`created_at`、`updated_at`、`created_by`、`updated_by`、`row_version`、`deleted_at` 为系统字段，不允许在 Manifest 中声明。请求不能包含原始 SQL、物理表名、逐行权限表达式或 AI Field Agent 绑定。

```json
{
  "name": "销售线索",
  "manifest": {
    "tables": {
      "leads": {
        "fields": {
          "company": {"type":"text","nullable":false},
          "score": {"type":"integer","nullable":true},
          "tags": {"type":"json","nullable":true}
        }
      }
    }
  }
}
```

| 方法与路径 | 请求/用途 | 成功响应 |
| --- | --- | --- |
| `GET /v1/spaces/{space_id}/apps?status=active\|archived` | 列出空间 App；默认 `active`，`archived` 仅管理员可查 | `{"apps":[AppSummary]}` |
| `POST /v1/spaces/{space_id}/apps` | `name`、`manifest`；仅管理员 | 201；`{"app": App}`，`manifest_version=1` |
| `GET /v1/apps/{app_id}` | App 详情与当前 Manifest | `{"app": App}` |
| `PATCH /v1/apps/{app_id}` | `expected_settings_version`、可选 `name`、`description`；仅管理员 | `{"app": App}`，`settings_version` 加 1 |
| `POST /v1/apps/{app_id}/archive` | `expected_settings_version`；仅管理员 | `{"app": App}`，状态为 `archived` |
| `POST /v1/apps/{app_id}/restore` | `expected_settings_version`；仅管理员 | `{"app": App}`，状态为 `active` |
| `GET /v1/apps/{app_id}/tables` | 表名、字段和当前 Manifest 版本 | `{"tables":[TableSummary],"manifest_version":1}` |
| `PUT /v1/apps/{app_id}/manifest` | `expected_version`、新的 `manifest`；仅管理员 | `{"app": App}`，版本加 1 |
| `GET /v1/apps/{app_id}/audit-events?limit=50&cursor=...` | 管理员审计日志，按 `created_at DESC,event_id DESC` 键集分页 | `{"events":[AuditEvent],"next_cursor":string\|null}` |

`App` 至少包含 `app_id`、`space_id`、`name`、`description`、`manifest`、`manifest_version`、`settings_version`、`status`、`archived_at`、`created_at`、`updated_at`。资料修改、归档与恢复都必须提供 `expected_settings_version`；版本不符返回 409 `APP_SETTINGS_VERSION_CONFLICT`。当前 Manifest 更新只允许**新增可空字段**和新增表；删表、删字段、改名、改类型、把可空改为非空返回 422 `APP_SCHEMA_CHANGE_UNSUPPORTED`。`expected_version` 不匹配返回 409 `APP_MANIFEST_VERSION_CONFLICT`。Manifest 与数据结构在同一数据库事务中生效，不暴露部分应用状态。

`AuditEvent` 包含 `event_id`、可空 `release_id`、`actor_user_id`、`action`、不含记录值或凭据的 `details` 和 `created_at`。游标不可修改；格式无效时返回 422 `APP_CURSOR_INVALID`。

### 4.2 记录读写

表名必须存在于当前 Manifest；传入的业务字段必须在该表声明。系统字段由服务端生成；不接受客户端传入 `created_by`、`row_version`、`owner_id`、`permission` 等字段。`integer` 为 PostgreSQL 32 位有符号整数；`numeric` 最多 38 位有效数字、小数位最多 18 位且整数位最多 38 位，在 JSON 响应中用十进制字符串表示；`timestamp` 使用带时区的 UTC ISO 8601。单次查询默认 50 条、最多 200 条；游标绑定 App、表、排序与筛选条件，按最后一条记录的排序字段续读，删除前页记录不会跳过后页。

| 方法与路径（前缀 `/v1/apps/{app_id}/tables/{table_name}`） | 请求/用途 | 成功响应 |
| --- | --- | --- |
| `POST /records` | `{"values":{"company":"A","score":7}}` | 201；`{"record": Record}` |
| `POST /records/bulk` | `{"records":[{"values":{...}}]}`；最多 100 条、整批事务 | 201；`{"records":[Record]}` |
| `GET /records?limit=50&cursor=...` | 按 `created_at,id` 顺序列出未删除记录 | `{"records":[Record],"next_cursor":string|null}` |
| `POST /records/query` | 白名单字段筛选、排序和可选 `search`，见下例 | 同上 |
| `POST /records/bulk-delete` | `{"records":[{"id":"...","expected_row_version":1}]}`；1–100 条、整批事务 | `{"deleted_count":2}` |
| `GET /records/{record_id}` | 读取未删除记录 | `{"record": Record}` |
| `PATCH /records/{record_id}` | `expected_row_version`、`values` | `{"record": Record}` |
| `DELETE /records/{record_id}` | `expected_row_version`；软删除 | 204 |
| `POST /records/{record_id}/restore` | `expected_row_version`；恢复软删除记录 | `{"record": Record}` |

`Record` 至少包含 `id`、`values`、`created_at`、`updated_at`、`created_by`、`updated_by`、`row_version`、`deleted_at`。首次创建的 `row_version=1`；每次更新、删除或恢复加 1。版本不符返回 409 `APP_RECORD_VERSION_CONFLICT`。不同空间、App 或表的记录 ID 不能交叉访问；不可见时统一返回 404。

```http
POST /v1/apps/<app_id>/tables/leads/records/query
Authorization: Bearer <access_token>
Content-Type: application/json

{"filter":{"field":"score","op":"gte","value":5},"sort":[{"field":"created_at","direction":"desc"}],"limit":50}
```

首版 `filter` 只允许单条件或由最多 10 个叶子条件组成的单层 `and`；操作符 `eq|ne|lt|lte|gt|gte|in|is_null`，业务字段必须在 Manifest 中声明，`json` 字段暂不支持筛选或排序，`in` 最多 50 个值。`search` 最长 120 字符，只在当前表声明的 `text` 字段上做大小写不敏感的字面子串匹配，特殊 SQL 通配符按普通文本处理；`search`、`filter` 和 `sort` 共同绑定到游标。排序最多 3 个字段，空值排在最后，再追加 `id` 稳定排序。`bulk-delete` 不能重复 ID；任一行不存在、已删除或版本不匹配时，整批返回 409 `APP_RECORD_VERSION_CONFLICT`，不会删除其他行。禁止任意 SQL、关联查询和跨 App 查询。较大文件导入与复杂查询由后续增量单独冻结 API。

### 4.3 静态 H5 草稿与发布

静态 H5 Release 属于一个 App，由 `owner` 或 `admin` 管理；`editor` 和 `viewer` 可以读取 Release 历史，但不能创建、上传、发布或回滚。一个 Release 有 App 内单调递增的 `version`，在创建时绑定当前 `manifest_version`。修改 Manifest 后，旧草稿不能发布，必须在当前 Schema 下重新建立草稿。

| 方法与路径 | 请求/用途 | 成功响应 |
| --- | --- | --- |
| `POST /v1/apps/{app_id}/releases` | 新建 H5 草稿；仅管理员 | 201；`{"release": Release}` |
| `GET /v1/apps/{app_id}/releases` | 按版本倒序列出 Release；所有可见成员可读 | `{"releases":[Release]}` |
| `POST /v1/apps/{app_id}/releases/{release_id}/upload` | `multipart/form-data`，字段 `file` 为 ZIP；仅管理员 | `{"release": Release,"preview_url":string|null}` |
| `POST /v1/apps/{app_id}/releases/{release_id}/publish` | 显式发布已校验草稿；仅管理员 | `{"release": Release}` |
| `POST /v1/apps/{app_id}/releases/{release_id}/rollback` | 将已发布版本设为当前版本；仅管理员 | `{"release": Release}` |
| `POST /v1/apps/{app_id}/releases/{release_id}/launch` | 为当前成员签发某个已发布版本的 H5 启动 URL | `{"launch_url":string}` |
| `GET /v1/apps/{app_id}/releases/{release_id}/preview/{path}?ticket=...` | 十分钟草稿预览票据；不需要 Access Token | 静态字节；未命中带扩展名的资源返回 404 |
| `POST /apps/{app_id}/releases/{version}/h5/session` | 已完成启动的发布页在同源路径换取 H5 Token | `{"access_token":...,"expires_in":300}` |
| `GET /apps/{app_id}/releases/{version}/{path}` | 已发布静态资源；公开只读；启动 URL 在入口资源追加 `?launch=...` | 静态字节；不可变缓存，仅在发布域名响应 |

`Release` 包含 `release_id`、`app_id`、`version`、`manifest_version`、`status`、`entry_file`、`file_count`、`total_size_bytes`、`checksum_sha256`、`validation_error_code`、`is_current`、创建和发布时间及操作者。已发布 Release 额外有绝对 `public_url`，控制台和外部调用方必须使用它打开 H5。状态为 `draft`、`validation_failed` 或 `published`；任何 App 最多一个 `is_current=true` 的已发布 Release。

上传只接受不超过 50 MiB 的 ZIP。服务端限制解压后最多 200 MiB、2,000 个文件、10 层目录和每文件 10 MiB；只允许 HTML/CSS/JS/JSON、字体、图片和 SVG 等静态资源，拒绝遍历路径、符号链接、可执行文件、环境或密钥文件、`file://` 引用和已知密钥标记。压缩包需要 `index.html` 或 `dist/index.html`；可选 `vessel-app.json` 可声明自身 `app_id`、所需表和 CRUD 操作。验证失败把草稿记录标记为 `validation_failed`，不会改变当前发布版本。

草稿 ZIP 和最终静态对象都保存在私有存储中。最终对象路径固定为 `vessel-apps/{app_id}/releases/{version}/`，不会覆盖已发布版本；重试发布仅接受内容完全相同的已有对象。上传成功后服务端返回十分钟有效的草稿预览 URL；票据不落库、不写审计日志，篡改或过期返回 401。公开路径只读取 `published` Release 的静态字节，缺少带扩展名的资源不回退到 HTML，扩展名为空的客户端路由才回退到入口 HTML；响应带 `X-Content-Type-Options: nosniff` 和一年不可变缓存。

控制台先使用当前登录 Access Token 调用 `POST /v1/apps/{app_id}/releases/{release_id}/launch`。服务端生成五分钟有效、绑定 `user_id`、`app_id`、`release_id` 和 `release_version` 的签名启动 URL。该 URL 只能请求相应版本的入口资源；发布网关验证后写入 `HttpOnly`、`SameSite=Strict`、路径限定为 `/apps/{app_id}/releases/{version}/h5/` 的启动 Cookie，并重定向到无票据的地址。H5 页面只能在该发布域名下通过相对路径 `/apps/{app_id}/releases/{version}/h5/session` 换取五分钟 App 专属 Token；直接公开发布 URL 不会产生 Token。该 Token 的 `aud=vessel-app-h5`、`scope=vessel:app-h5`、`app_id` 和 `release_version` 都由服务端签发；它只可调用同一 `app_id` 的记录接口，并在每次请求时重新检查当前空间成员角色。它不能读取另一个 App、Notes、Files、团队配置、App Settings 或发布接口。

`NOTES_APP_RELEASE_ORIGIN` 是发布区的完整 `http`/`https` Origin，生产环境必须配置为 HTTPS，且其 hostname 必须与 `NOTES_ISSUER_URL` 不同。它不是共享的 Bundle Origin：当配置为 `https://apps.karama.cloud` 时，App `<app_id>` 的发布、草稿预览和启动页都在 `https://<app_id>.apps.karama.cloud`。默认端口会规范化，因此 `https://apps.example:443` 等同于 `https://apps.example`；非默认端口保留。生产环境必须为 `*.apps.karama.cloud` 配置通配 DNS 和覆盖该通配符的 TLS 证书；本地可用 `apps.127.0.0.1.nip.io`，其子域同样解析到 loopback。草稿和启动票据只用于各自 App Host 的第一次请求，网关写入 host-only、路径受限 Cookie 并重定向到不含票据的 URL，以便同一 Bundle 的 CSS、JS 和图片继续加载。H5 session 端点拒绝带有其他 App Origin 的请求。只有请求路径中同一 `app_id` 派生出的 Origin 发往 `/v1/apps/{app_id}/tables/{table}/records...` 才会收到 CORS 预检和响应头，允许 `Authorization`、`Content-Type` 及 `GET|POST|PATCH|DELETE`。`/v1/auth/refresh` 对任何发布区 Origin 的浏览器请求返回 403 `AUTH_ORIGIN_INVALID`。

发布包如果要读写 App 数据，应在前端配置 API Origin，并在运行时交换 Token，不能把长期 Access Token 或 Refresh Token 写入 ZIP、代码或浏览器存储。可选的 `vessel-app.json` 已携带 `app_id` 时，页面可以读取它来拼接请求路径：

```js
const apiOrigin = "https://api.karama.cloud";
const appId = "<vessel-app.json app_id>";
const session = await fetch(`${window.location.pathname.replace(/\/[^/]+$/, "")}/h5/session`, {
  method: "POST",
}).then(response => response.json());
const records = await fetch(`${apiOrigin}/v1/apps/${appId}/tables/meals/records`, {
  headers: { Authorization: `Bearer ${session.access_token}` },
});
```

## 5. 典型调用顺序

1. 人类用户在 Vessel 登录，Agent 客户端在其授权下持有 Access Token。`GET /v1/spaces` 选择个人或团队 `space_id`。
2. 团队 Owner 创建 App 和 Note；Editor 通过同一 `space_id` 列表看到资源，按 ID 修改 Note 或记录；Viewer 可读取和导出，但写入返回 403。
3. Owner 移除 Editor 或将其降为 Viewer。旧 Token 仍识别该用户身份，但后续团队资源请求立即按新成员状态判定；已移除者收到 404。
4. 对 Note `revision`、App `manifest_version`、Record `row_version` 的写入使用对应预期版本；冲突时客户端重读并决定是否重试。

## 6. 错误与边界

| HTTP | 典型 code | 含义 |
| --- | --- | --- |
| 401 | `AUTHENTICATION_REQUIRED`、`INVALID_ACCESS_TOKEN`、`INVALID_REFRESH_TOKEN`、`APP_PREVIEW_TICKET_INVALID` | 未登录、Access/刷新 Cookie 或草稿预览票据无效 |
| 403 | `SPACE_PERMISSION_DENIED`、`APP_MANAGER_REQUIRED` | 已是成员，但角色不允许写；或 Editor/Viewer 试图变更 App 资料、Schema 或读取审计日志 |
| 404 | `SPACE_NOT_FOUND`、`NOTE_NOT_FOUND`、`DIRECTORY_NOT_FOUND`、`APP_NOT_FOUND`、`APP_RECORD_NOT_FOUND` | 不存在或不可见，避免枚举 |
| 409 | `NOTE_REVISION_CONFLICT`、`APP_SETTINGS_VERSION_CONFLICT`、`APP_MANIFEST_VERSION_CONFLICT`、`APP_RECORD_VERSION_CONFLICT`、`APP_RELEASE_NOT_PUBLISHABLE` | 乐观锁冲突或无效发布状态转换 |
| 422 | `NOTE_DOCUMENT_INVALID`、`APP_MANIFEST_INVALID`、`APP_FIELD_VALUE_INVALID`、`APP_SCHEMA_CHANGE_UNSUPPORTED`、`APP_CURSOR_INVALID`、`APP_BULK_DELETE_INVALID`、`H5_*` | 内容、结构、游标、批量删除请求或静态包不符合契约 |
| 503 | `APP_RELEASE_STORAGE_UNAVAILABLE` | 当前部署未配置或无法安全访问 App Release 私有存储 |

本轮范围是 Notes 的内容、目录、图片与版本 API，以及 Apps 的表格 Schema 和记录 API。独立 `vessel` CLI v1 已实现为现有 HTTP API 的客户端；新 Note Agent 接入、公开分享、跨空间复制、CSV 大文件导入、全文搜索和 MCP 桥接仍按 [总体技术设计](technical-design.md) 后续实施。现有 Notes 的本地图片存储不作为通用文件服务对外承诺。

## 7. 已确认的三个 API 决策

1. **团队 Note 路径：**新增 `/v1/spaces/{space_id}/notes` 和 `/directories`，旧 `/v1/notes` 与 `/directories` 列表/创建固定为个人空间。
2. **Apps 资源边界：**一个 App 包含多张表，App 属于一个空间；团队角色统一管整套 Manifest 和全部记录，没有逐行私有权限。
3. **首版 Schema 与查询：**Manifest 仅支持新增表/可空字段；记录查询只支持有界、声明字段的筛选与排序。
