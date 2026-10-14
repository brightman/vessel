# Vessel 身份、团队与权限实施计划

**目标：** 在 Pages API 基础上交付独立用户账号、个人空间、团队成员和按角色控制的团队 API。

**边界：** 本增量只创建空间、成员、邀请和权限查询，不允许将团队角色用于读取现有个人 Page。文件、表格和团队 Page 在各自增量接入统一授权。数据库形状见 `docs/db-schema.md`。

## 任务 1：完成 API 基线迁移

- [x] 保留原始 Pages API 快照提交。
- [x] 将包与启动入口改为 Vessel，并离线锁定依赖。
- [x] 跑 API 测试和隔离 PostgreSQL 的真实 HTTP E2E。

## 任务 2：身份和空间数据

- [ ] 先加测试：注册后有且仅有一个个人空间；团队创建者成为 Owner。
- [ ] 添加 `spaces`、`team_members`、`team_invitations` 模型与 `0007` 迁移；回填旧用户个人空间。
- [ ] 注册和管理员创建账号时在同一事务中创建个人空间。
- [ ] 将新访问 Token audience 改为 `vessel-api`；保持 Pages 专用 MCP capability audience，直至该入口重构。

## 任务 3：团队 API 与权限

- [ ] 先加测试：邀请/接受、角色能力、非成员 404、Viewer 禁写、撤权、最后 Owner 保护、重复邀请冲突。
- [ ] 实现 `GET /v1/spaces`、`GET /v1/spaces/{space_id}/permissions`、`POST /v1/teams`、团队详情/成员列表、邀请列表与接受、成员角色修改与移除。
- [ ] Owner/Admin 管理团队；Admin 不得管理 Owner 或授予 Owner，Owner 不得移除最后一名有效 Owner。
- [ ] 所有团队写入在 PostgreSQL 事务中锁团队行并重新查询成员权限；撤权后的新请求立即失权。

## 任务 4：验证与交付

- [ ] 直接相关测试与受影响核心测试合计不超过 100 例，记录命令、用例数和结果。
- [ ] 在隔离 PostgreSQL 上运行迁移，再经真实 HTTP 完成两用户邀请、接受、角色变更、撤权和非成员拒绝路径。
- [ ] 检查文档、OpenAPI、`git diff --check` 与源 Pages checkout 状态，提交到 Vessel 分支。
