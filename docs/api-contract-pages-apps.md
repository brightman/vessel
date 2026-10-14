# Vessel API 契约草案：Pages、Apps 与空间权限

状态：**待审核，尚未实现本轮 Pages/Apps 团队对接**。日期：2026-10-14。

本文约定把迁入的 Pages 和 Baizhi Apps 表格能力接到 Vessel 独立账号与个人/团队空间后的 HTTP API。标记为「现有」的端点已在当前代码中注册；「拟新增」及「拟调整」是待审核的实现契约。现有端点目前仍按 Page 创建者隔离，**不能把本文描述的目标团队权限当成现网能力**。

## 1. 通用约定

- API 基址由部署决定，业务路径以 `/v1` 开头。所有资源 API 使用 `Authorization: Bearer <Vessel access_token>`；注册、登录与 Refresh 除外。Vessel 独立签发 `aud=vessel-api` 的 Token，不接受 Baizhi Apps/Pages 账号 Token。
- 用户注册时自动拥有一个个人空间；团队创建一个团队空间。团队 ID 即 `space_id`。资源的 `space_id` 创建后不可修改；本轮不提供跨空间移动、复制或资源级 ACL。
- `owner_user_id`、`created_by_user_id` 等历史字段只作迁移与审计用途。团队 Page 和 App 的访问权由持久化 `space_id` 与当前成员角色决定，创建者不额外获得私有权限。请求中的角色、创建者或用户 ID 不能覆盖服务端身份。
- Owner/Admin/Editor 可读写；Viewer 只读。非成员或无权查看的资源返回 404；已可查看但无写权限返回 403。成员移除或角色降级后，每个新请求重新查询成员状态。写入与成员变更要在数据库事务中确定顺序。
- 成功 JSON 使用资源名包裹，例如 `{"page": {...}}`、`{"app": {...}}`、`{"records": [...]}`；204 不返回正文。业务错误沿用当前实现的 `{"detail":{"code":"ERROR_CODE"}}`。Pydantic 字段验证错误仍是 FastAPI 的 422 格式。
- ID 是服务端生成的 UUID 字符串。时间为 UTC ISO 8601。列表默认按稳定排序；本轮 Pages/目录保持现有无分页响应，Apps 记录使用游标分页。

### 1.1 角色矩阵

| 操作 | 个人空间本人 | 团队 Owner/Admin | 团队 Editor | 团队 Viewer | 非成员 |
| --- | --- | --- | --- | --- | --- |
| 列表、读取、导出、版本、图片、表格记录查询 | 允许 | 允许 | 允许 | 允许 | 404/列表不可见 |
| 新建、修改、归档、恢复、上传图片、写记录 | 允许 | 允许 | 允许 | 403 | 404 |
| 管理邀请、角色、成员 | 不适用 | 允许，受 Owner 保护规则约束 | 403 | 403 | 404 |

Page 提案的接受、拒绝、版本恢复和 Agent 编辑运行属于写操作。只读 Agent 运行与提案预览属于读操作。短期 Page MCP capability 在每次工具调用时还要重查持有人当前空间权限；撤权后的旧 capability 不能继续读取或编辑团队 Page。

## 2. 身份与团队：现有 API

以下端点已实现，本轮沿用其路径与主要字段。

| 方法与路径 | 请求 | 成功响应 |
| --- | --- | --- |
| `GET /v1/auth/options` | 无 | `{"registration_enabled": boolean}` |
| `POST /v1/auth/register` | `name`、`email`、`password` | 201；`access_token`、`token_type`、`expires_in`、`user`，设置 `vessel_refresh` Cookie |
| `POST /v1/auth/login` | `email`、`password` | 同上 |
| `POST /v1/auth/refresh` | `vessel_refresh` Cookie | 轮换 Cookie，返回新 Access Token |
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

角色是 `owner|admin|editor|viewer`。团队邀请只面向已存在且 active 的 Vessel 用户。生产默认关闭公开注册；当前尚无邮箱验证与自助重置 API。

## 3. Pages：个人兼容路径与团队空间路径

**路径决策：**保留现有 `/v1/pages`、`/v1/directories` 的列表和创建语义为「我的个人空间」。新增带 `space_id` 的规范入口供个人或团队空间使用。按 `page_id`、`directory_id` 访问的现有路径保留；服务端从资源行读取空间并判权，不要求客户端传创建者 ID。这样现有个人客户端无需改路径，团队客户端必须显式选择空间。

### 3.1 页面与目录

| 方法与路径 | 状态 | 请求/用途 | 成功响应 |
| --- | --- | --- | --- |
| `GET /v1/spaces/{space_id}/pages?status=active|archived` | 拟新增 | 列出该空间 Page，默认 `active` | `{"pages": [Page]}` |
| `POST /v1/spaces/{space_id}/pages` | 拟新增 | `title`、`document`、可选 `directory_id` | 201；`{"page": Page}` |
| `GET /v1/pages`、`GET /v1/pages/archived` | 现有，拟调整授权 | 只列个人空间 Page | `{"pages": [Page]}` |
| `POST /v1/pages` | 现有，拟调整归属 | 同上创建体，固定创建在个人空间 | 201；`{"page": Page}` |
| `GET /v1/pages/{page_id}` | 现有，拟调整授权 | 页面内容 | `{"page": Page}` |
| `PATCH /v1/pages/{page_id}` | 现有，拟调整授权 | `expected_revision`，可选 `title`、`document`、`directory_id` | `{"page": Page}` |
| `POST /v1/pages/{page_id}/archive` | 现有，拟调整授权 | 归档 | 204 |
| `POST /v1/pages/{page_id}/restore` | 现有，拟调整授权 | 恢复 | `{"page": Page}` |
| `GET /v1/spaces/{space_id}/directories` | 拟新增 | 列出空间目录 | `{"directories": [Directory]}` |
| `POST /v1/spaces/{space_id}/directories` | 拟新增 | `{"name":"Research"}` | 201；`{"directory": Directory}` |
| `GET /v1/directories`、`POST /v1/directories` | 现有，拟调整归属 | 只操作个人空间 | 同现有格式 |
| `GET /v1/directories/{directory_id}` | 现有，拟调整授权 | 目录详情 | `{"directory": Directory}` |
| `PATCH /v1/directories/{directory_id}` | 现有，拟调整授权 | `{"name":"New name"}` | `{"directory": Directory}` |
| `POST /v1/directories/{directory_id}/archive` | 现有，拟调整授权 | 归档目录，空间内子 Page 转为无目录 | 204 |

`Page` 至少包含 `page_id`、`space_id`、`title`、`directory_id`、`document`、`markdown`、`revision`、`status`、`created_at`、`updated_at`。`Directory` 至少包含 `directory_id`、`space_id`、`name`、`status`、`created_at`、`updated_at`。任何 Page 的 `directory_id` 必须指向同一空间的有效目录；跨空间目录返回 `DIRECTORY_NOT_FOUND`，不迁移页面。

`document` 沿用 Pages 的 Tiptap 风格 JSON，根节点为 `{"type":"doc","schema_version":1,"content":[...]}`。顶层块必须有稳定的 `attrs.block_id`。服务端校验块类型、链接、图片 URL，保存规范化 JSON 并生成 Markdown。写入需提供 `expected_revision`；不匹配返回 409 `PAGE_REVISION_CONFLICT`。

```http
POST /v1/spaces/8e80f2dc-0b30-4a9f-b6c5-cd68e579bc56/pages
Authorization: Bearer <access_token>
Content-Type: application/json

{"title":"项目周报","directory_id":null,"document":{"type":"doc","schema_version":1,"content":[{"type":"heading","attrs":{"block_id":"intro","level":1},"content":[{"type":"text","text":"项目周报"}]}]}}
```

```json
{"page":{"page_id":"<uuid>","space_id":"8e80f2dc-0b30-4a9f-b6c5-cd68e579bc56","title":"项目周报","directory_id":null,"document":{"type":"doc","schema_version":1,"content":[{"type":"heading","attrs":{"block_id":"intro","level":1},"content":[{"type":"text","text":"项目周报"}]}]},"markdown":"# 项目周报\n","revision":1,"status":"active","created_at":"2026-10-14T00:00:00+00:00","updated_at":"2026-10-14T00:00:00+00:00"}}
```

### 3.2 Markdown、版本、图片与提案

| 方法与路径 | 状态 | 读写能力/说明 |
| --- | --- | --- |
| `GET /v1/pages/{page_id}/markdown` | 现有，拟调整授权 | 读；返回 `text/markdown` 附件 |
| `PUT /v1/pages/{page_id}/markdown` | 现有，拟调整授权 | 写；`{"expected_revision":1,"markdown":"..."}`，生成新版本 |
| `GET /v1/pages/{page_id}/versions` | 现有，拟调整授权 | 读；返回 `versions[]` |
| `POST /v1/pages/{page_id}/versions/checkpoint` | 现有，拟调整授权 | 写；`expected_revision` |
| `POST /v1/pages/{page_id}/versions/{version_id}/restore` | 现有，拟调整授权 | 写；`expected_revision`，生成新修订 |
| `POST /v1/pages/{page_id}/assets` | 现有，拟调整授权 | 写；原始 PNG/JPEG/GIF/WebP 字节，请求 `Content-Type` 为图片类型 |
| `GET /v1/assets/{asset_id}/content` | 现有，拟调整授权 | 读；按关联 Page 的当前空间授权，返回图片字节 |
| `GET /v1/pages/{page_id}/proposals`、`GET /v1/pages/{page_id}/proposals/{proposal_id}` | 现有，拟调整授权 | 读；团队成员可见同一 Page 的提案 |
| `POST /v1/pages/{page_id}/proposals/{proposal_id}/accept` | 现有，拟调整授权 | 写；`{"idempotency_key":"..."}` |
| `POST /v1/pages/{page_id}/proposals/{proposal_id}/reject` | 现有，拟调整授权 | 写 |

Page Agent Run、事件流及 `/mcp` 是从 Pages 迁入的兼容入口。本轮若继续开放，读/写均须按当前 Page 空间重新判权，且 capability 不能绕过成员撤销。它们依赖另行配置的 Baizhi Agent Platform；**Vessel 的核心 Page 存储 API 不依赖该外部服务**。图片接口是现有 Page 附件功能，不等同于未来的通用 OSS/S3 文件 API。

### 3.3 旧数据迁移

给 `pages` 和 `page_directories` 增加非空 `space_id`。对历史个人 Page/目录，以原 `owner_user_id` 对应的个人空间回填；原 Page ID、目录 ID、修订号、版本与提案保持不变。Page 的 `owner_user_id` 将保留为创建人字段，不再作为团队资源的判权依据。迁移后历史 `/v1/pages/{page_id}` 仍可由原用户访问，其他用户仍不可见。

## 4. Apps：表格存储 API（拟新增）

**资源模型：**一个 App 是一个空间内的表格集合，`app_id` 由 Vessel 生成；Manifest 描述多个表及字段。团队成员默认能读取该 App 下所有表和记录；不沿用 Baizhi Apps 的 `owner_id`/`permission` 逐行可见性、App 用户成员表、Agent grant、H5 发布或 Baizhi 账号体系。App API 将迁入并适配源项目的 Manifest 标识符/类型校验、字段值规范化和受控记录操作；数据存入 Vessel 自己的 PostgreSQL。

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
| `GET /v1/spaces/{space_id}/apps` | 列出空间 App | `{"apps":[AppSummary]}` |
| `POST /v1/spaces/{space_id}/apps` | `name`、`manifest` | 201；`{"app": App}`，`manifest_version=1` |
| `GET /v1/apps/{app_id}` | App 详情与当前 Manifest | `{"app": App}` |
| `GET /v1/apps/{app_id}/tables` | 表名、字段和当前 Manifest 版本 | `{"tables":[TableSummary],"manifest_version":1}` |
| `PUT /v1/apps/{app_id}/manifest` | `expected_version`、新的 `manifest` | `{"app": App}`，版本加 1 |

`App` 至少包含 `app_id`、`space_id`、`name`、`manifest`、`manifest_version`、`status`、`created_at`、`updated_at`。首版 Manifest 更新只允许**新增可空字段**和新增表；删表、删字段、改名、改类型、把可空改为非空返回 422 `APP_SCHEMA_CHANGE_UNSUPPORTED`。`expected_version` 不匹配返回 409 `APP_MANIFEST_VERSION_CONFLICT`。Manifest 与数据结构在同一数据库事务中生效，不暴露部分应用状态。

### 4.2 记录读写

表名必须存在于当前 Manifest；传入的业务字段必须在该表声明。系统字段由服务端生成；不接受客户端传入 `created_by`、`row_version`、`owner_id`、`permission` 等字段。`numeric` 在 JSON 响应中用十进制字符串表示，`timestamp` 使用带时区的 UTC ISO 8601。单次查询默认 50 条、最多 200 条；游标绑定 App、表、排序与筛选条件。

| 方法与路径（前缀 `/v1/apps/{app_id}/tables/{table_name}`） | 请求/用途 | 成功响应 |
| --- | --- | --- |
| `POST /records` | `{"values":{"company":"A","score":7}}` | 201；`{"record": Record}` |
| `POST /records/bulk` | `{"records":[{"values":{...}}]}`；最多 100 条、整批事务 | 201；`{"records":[Record]}` |
| `GET /records?limit=50&cursor=...` | 按 `created_at,id` 顺序列出未删除记录 | `{"records":[Record],"next_cursor":string|null}` |
| `POST /records/query` | 白名单字段筛选和排序，见下例 | 同上 |
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

首版 `filter` 只允许单条件或由最多 10 个条件组成的 `and`；操作符 `eq|ne|lt|lte|gt|gte|in|is_null`，字段必须在 Manifest 中声明，`in` 最多 50 个值。排序最多 3 个字段，追加 `id` 稳定排序。禁止任意 SQL、关联查询和跨 App 查询。较大文件导入与复杂查询由后续增量单独冻结 API。

## 5. 典型调用顺序

1. 人类用户在 Vessel 登录，Agent 客户端在其授权下持有 Access Token。`GET /v1/spaces` 选择个人或团队 `space_id`。
2. 团队 Owner 创建 App 和 Page；Editor 通过同一 `space_id` 列表看到资源，按 ID 修改 Page 或记录；Viewer 可读取和导出，但写入返回 403。
3. Owner 移除 Editor 或将其降为 Viewer。旧 Token 仍识别该用户身份，但后续团队资源请求立即按新成员状态判定；已移除者收到 404。
4. 对 Page `revision`、App `manifest_version`、Record `row_version` 的写入使用对应预期版本；冲突时客户端重读并决定是否重试。

## 6. 错误与边界

| HTTP | 典型 code | 含义 |
| --- | --- | --- |
| 401 | `AUTHENTICATION_REQUIRED`、`INVALID_ACCESS_TOKEN` | 未登录或 Token 无效 |
| 403 | `SPACE_PERMISSION_DENIED` | 已是成员，但角色不允许写 |
| 404 | `SPACE_NOT_FOUND`、`PAGE_NOT_FOUND`、`DIRECTORY_NOT_FOUND`、`APP_NOT_FOUND`、`APP_RECORD_NOT_FOUND` | 不存在或不可见，避免枚举 |
| 409 | `PAGE_REVISION_CONFLICT`、`APP_MANIFEST_VERSION_CONFLICT`、`APP_RECORD_VERSION_CONFLICT` | 乐观锁冲突 |
| 422 | `PAGE_DOCUMENT_INVALID`、`APP_MANIFEST_INVALID`、`APP_FIELD_VALUE_INVALID`、`APP_SCHEMA_CHANGE_UNSUPPORTED` | 内容或结构不符合契约 |

本轮范围是 Pages、其已有图片/版本/提案路径，以及 Apps 的表格 Schema 和记录 API。通用 Google Drive 式文件、OSS/S3 直传、统一目录、公开分享、跨空间复制、CSV 大文件导入、全文搜索与独立 CLI/MCP 桥接仍按 [总体技术设计](technical-design.md) 后续实施。现有 Pages 的本地图片存储不作为通用文件服务对外承诺。

## 7. 待审核的三个 API 决策

1. **团队 Page 路径：**新增 `/v1/spaces/{space_id}/pages` 和 `/directories`，旧 `/v1/pages` 与 `/directories` 列表/创建固定为个人空间。
2. **Apps 资源边界：**一个 App 包含多张表，App 属于一个空间；团队角色统一管整套 Manifest 和全部记录，没有逐行私有权限。
3. **首版 Schema 与查询：**Manifest 仅支持新增表/可空字段；记录查询只支持有界、声明字段的筛选与排序。
