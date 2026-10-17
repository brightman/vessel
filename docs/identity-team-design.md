# Vessel 用户、团队与权限设计

状态：身份与团队 API 已实现；Page/Apps 资源已接入。日期：2026-10-14。数据库定义见 [db-schema.md](db-schema.md)。

## 范围与归属

Vessel 使用自己的 `users`、密码凭据、Refresh Session、JWT 签名密钥和 PostgreSQL 数据库。每个新账号在同一事务中获得一个个人空间；`0007` 支持其引入时的旧账号回填。个人空间仅本人可访问。团队空间没有单一用户 Owner 字段，创建者成为第一位成员 Owner。Pages 与 Apps 已归属 `space_id`，创建者不会因此获得额外私有权限。

当前团队角色控制空间、邀请、成员、Page/目录/图片/版本和 Apps 表格 API。通用 OSS/S3 文件功能将在文件增量接入同一空间授权函数。

## 角色能力

| 角色 | 查看团队与成员 | Page/Apps 内容读 | Page/Apps 内容写 | 管理邀请和成员 | 永久删除能力 |
| --- | --- | --- | --- | --- | --- |
| Owner | 是 | 是 | 是 | 是 | 是 |
| Admin | 是 | 是 | 是 | 是；不能操作 Owner 或授予 Owner | 是 |
| Editor | 是 | 是 | 是 | 否 | 否 |
| Viewer | 是 | 是 | 否 | 否 | 否 |

`GET /v1/spaces/{space_id}/permissions` 返回 `role`、`can_read`、`can_write`、`can_manage_members` 和 `can_delete`。这是供客户端展示能力的快照；业务写入必须再次从数据库检查成员状态，不能信任客户端提交的角色或旧快照。

## API 契约

所有端点使用 `/v1`、Bearer Token 和现有 `{"detail":{"code":"..."}}` 错误形状。用户 Token audience 是 `vessel-api`，Refresh Cookie 名为 `vessel_refresh`。团队 ID 即团队 `space_id`。

| 操作 | 方法和路径 | 请求 | 主要响应 |
| --- | --- | --- | --- |
| 我的空间 | `GET /v1/spaces` | 无 | `spaces[]`，每项含 `space_id/kind/name/owner_user_id/role/status` |
| 空间权限 | `GET /v1/spaces/{id}/permissions` | 无 | 当前角色及能力布尔值 |
| 创建团队 | `POST /v1/teams` | `{"name":"Research"}` | 201，`space`；创建者成为 Owner |
| 团队详情 | `GET /v1/teams/{id}` | 无 | `space` |
| 成员列表 | `GET /v1/teams/{id}/members` | 无 | `members[]`，含 `user_id/role/status` |
| 邀请成员 | `POST /v1/teams/{id}/invitations` | `{"invitee_user_id":"...","role":"viewer"}` | 201，`invitation`；有效期 7 天 |
| 团队待处理邀请 | `GET /v1/teams/{id}/invitations` | 无 | Owner/Admin 可见的 `invitations[]` |
| 我的邀请 | `GET /v1/team-invitations` | 无 | 当前未过期的 `invitations[]` |
| 接受邀请 | `POST /v1/team-invitations/{id}/accept` | 无 | `space`；只能由目标账号调用 |
| 撤销邀请 | `DELETE /v1/teams/{id}/invitations/{invitation_id}` | 无 | 204 |
| 改角色 | `PATCH /v1/teams/{id}/members/{user_id}` | `{"role":"editor"}` | `member` |
| 移除成员 | `DELETE /v1/teams/{id}/members/{user_id}` | 无 | 204 |

邀请只接受已存在且 active 的 Vessel `user_id`。重复 pending 邀请返回 409；同一团队已有 active 成员也返回 409。目标用户接受时，邀请和成员变更在同一事务提交。已移除成员可通过新邀请重新加入。Owner 可授予 Owner，但任何降级或移除都不得留下零位仍能登录的 Owner。

## 授权与并发

服务端先验证 Token，再读取用户当前状态、空间和成员行。非成员或不可见空间返回 404；已入队团队成员但缺少管理能力返回 403。列表查询在 SQL 中限定个人 Owner 或 active 团队成员，避免先取全局数据再过滤。

团队写操作在 PostgreSQL 中锁定团队 `spaces` 行，然后重读 actor 的当前成员角色。邀请接受、角色修改和成员移除都使用这把团队级锁，使撤权与写入按事务顺序生效。移除后旧 JWT 仍可识别用户，但团队读写会立即因成员状态检查而失败。`team_members.user_id` 使用 `ON DELETE RESTRICT`，防止直接删除账号绕过 Owner 保护。

## 当前边界

生产默认禁止公开注册。受控终端可运行 `python -m vessel_service.bootstrap_admin --role user` 创建普通账号。注册邮箱验证正在开发：当前工作区已有验证码 API、Brevo 适配、前端表单和迁移，但未完成生产送达与部署验收。自助密码重置、普通账号生产开通流程、账号停用 API、团队审计表和 CLI 凭据库仍未提供。`PAGES_*` 环境变量名沿用迁入代码；旧 Page MCP capability 仅在显式测试模式注册，正常应用不暴露。部署时须配置 Vessel 专用数据库和密钥。后续账号停用流程必须在同一事务中检查团队 Owner 不变量。

本阶段不提供单资源 ACL、公开分享或跨团队资源访问。Page 与 Apps 每次读写都按持久化空间和当前成员关系检查；文件增量需采取相同方式。
