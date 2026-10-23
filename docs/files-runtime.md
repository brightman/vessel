# Vessel 文件服务运行与验收

日期：2026-10-15。文件 HTTP API 已实现；尚未部署生产。

## 已交付

- 个人/团队空间文件根目录、嵌套文件夹、名称规范化、搜索和游标分页。
- 个人文件/文件夹 Viewer/Editor 共享、递归继承、共享给我、当前权限查询与撤销。
- 复用团队 Owner/Admin/Editor/Viewer，无单项团队 ACL 或对外分享。
- Aliyun OSS 单段/分段直传、流式 SHA-256 校验、私有最终对象发布与下载。
- 乐观版本切换、历史版本恢复、配额预约、幂等回执、文件审计。
- 移动/恢复权限变化预览、回收站批次、递归永久清理。
- PostgreSQL outbox worker、租约 fencing、故障重试、上传过期处理、延迟暂存清理、孤立复制对象对账。

公共契约见 [api-contract-files.md](api-contract-files.md)；目录/权限语义见 [shared-files-design.md](shared-files-design.md)。文件夹不是 Note directory，文件共享不授予 Note 或 App 权限。本轮只增加文件路由注册与模型注册，不改写 Notes/Apps 行为。

## 数据库与依赖

从 `apps/api` 运行 `uv sync` 安装锁定依赖。使用 Vessel 专用 PostgreSQL，然后设置 NOTES_DATABASE_URL 并执行 `.venv/bin/alembic upgrade head`。新增迁移为 `0009_shared_files`，依赖现有 `0008_space_resources`。

迁移包含文件域表、同空间父子外键、有效名称/个人根目录唯一索引，以及文件当前版本的复合延迟外键。禁止用回退迁移删除生产文件元数据，恢复使用备份。旧 Notes 基线的空库约束仍由 `0008` 执行，文件增量不改变它。

## OSS 配置

默认推荐独立文件服务 RAM Role 和 Bucket；不向客户端返回长期密钥。当前按用户授权复用 baizhi-agent OSS，以**只读配置文件**形式读取已有 OSS_ENDPOINT、OSS_REGION、OSS_BUCKET、OSS_ACCESS_KEY_ID、OSS_ACCESS_KEY_SECRET 等必要字段，不复制密钥到仓库、不修改原配置或进程全局环境。

```sh
export VESSEL_FILES_OSS_CONFIG_FILE=/path/to/baizhi-agent/.baizhi-agent/config/.env
export VESSEL_FILES_OSS_PREFIX=vessel-files
# 只有明确复用未开启版本控制的 Bucket 时启用：
export VESSEL_FILES_OSS_ALLOW_UNVERSIONED=true
```

也可通过 VESSEL_FILES_OSS_ENDPOINT（HTTPS）、VESSEL_FILES_OSS_REGION、VESSEL_FILES_OSS_TEMP_BUCKET、VESSEL_FILES_OSS_FINAL_BUCKET 显式覆盖位置，凭据由 OSS_ACCESS_KEY_ID/OSS_ACCESS_KEY_SECRET/OSS_SESSION_TOKEN 或 VESSEL_FILES_OSS_RAM_ROLE 提供。显式 Vessel 位置优先于读取的 Baizhi 位置；RAM Role 优先于静态凭据。配置路径与 Bucket 可以写配置，密钥不要写入聊天、命令参数或源码。

版本化模式绑定源/最终 versionId，允许同一个已开启版本控制的 Bucket。未版本化模式必须显式允许，客户端只能签名写 uploads 暂存键，服务端条件复制至独立 files 最终键、禁止覆盖并校验最终字节；不调用 Bucket 设置写 API。暂停版本控制不支持。最终私有对象的新写入使用 SSE-OSS AES256，下载默认 attachment。

默认：单文件 512 MiB、空间 10 GiB、超过 16 MiB 分段、part 8 MiB、上传 URL 600 秒、下载 URL 60 秒、上传意图 24 小时。可向下调整 VESSEL_FILES_MAX_FILE_BYTES、VESSEL_FILES_SPACE_QUOTA_BYTES 等对应 FilesSettings 配置。所有保留的物理版本和回收文件计入容量；恢复历史引用不重复计费。

## 启动

根目录运行 `bash scripts/dev/start-api.sh`。脚本从 `apps/api/.env` 读取 `NOTES_DATABASE_URL` 等配置，进程环境变量可覆盖；可用 `NOTES_CONFIG_FILE` 指定另一份配置。没有文件 OSS 配置时，文件目录功能仍可用，签发上传/下载返回明确的文件存储不可用错误；Note/Apps 继续独立工作。

**必须另运行文件 worker**，HTTP complete/cancel/purge 的后台调度只是低延迟触发；进程重启后的恢复、延迟清理和上传到期都依赖 worker。与 API 使用同一数据库及 OSS 配置：

```sh
bash scripts/dev/start-files-worker.sh
# 单批运维检查：
bash scripts/dev/start-files-worker.sh --once
```

worker 每 2 秒轮询，按 Space → outbox 的锁顺序执行状态变更；网络请求不持有 Space 锁。任务失败保留 failure_code、attempts 和下次执行时间，采用退避重试；租约过期可接管，旧 attempt 不得覆盖新 attempt 的业务状态或完成标记。

对每个完成/取消/失败上传立即清理暂存，并在意图到期后一小时再次清扫能力 URL 的晚到对象。每次复制返回的对象身份独立登记，失去租约也不丢弃；删除前查引用。永久清理任务只处理已登记批次中的对象；不按整个共享 Bucket 扫描或删除。

## 验收方式

专项测试使用真实 SQLAlchemy/账号/权限与 HTTP，只替换 OSS 网络边界；SDK 签名测试直接使用已安装 oss2。测试脚本 `scripts/dev/files_http_e2e.py <base_url>` 使用真实 HTTP 与真实 OSS，不打印 Token、密钥或签名 URL。必须配独立测试数据库和随机专用 OSS 前缀，不能对生产用户资源运行。

本轮验证使用隔离 PostgreSQL，复用 `baizhi-agent-data` 的未版本化配置及专用 `vessel-files/e2e-20261015-01/` 前缀。验证包括 23 字节文件、17 MiB 三段文件、SHA-256 回读、私有根目录隔离、角色拒写、旧 Token 撤权、上传链接重放不改最终对象、共享文件夹回收恢复、永久清理及请求幂等。

最终验收记录：

| 验证 | 结果 |
| --- | --- |
| 文件专项 + 账号、团队、Note、Apps 受影响核心测试 | 95 passed；1 条上游 oss2 datetime 弃用提示 |
| 全新隔离 PostgreSQL 的 Alembic 迁移 | 0001 至 0009 全部成功，包含当前版本复合延迟外键 |
| 真实 HTTP + OSS E2E，run `8fc9348a` | 通过上述链路，另含 PostgreSQL 并发交叉移动：一个提交成功、另一个冲突；文件三个逻辑版本与历史恢复 |
| PostgreSQL 递归可见性与分页 | 共享给我、继承搜索、连续游标分页通过 |
| 独立 worker | `--once` 正常运行；永久删除失败重试、旧租约 fencing、取消后晚到对象、配额不重复扣减有回归覆盖 |
| 独立代码评审 | 已报告阻塞项全部修复并复核 |
| 代码语法/关键静态检查、文档链接、diff 空白检查 | 通过 |
| 测试清理 | 专用 OSS 前缀内残留对象及分段会话均为 0；本次 API 和 PostgreSQL 进程已停止；Bucket 设置未变 |

## 已知边界

- 默认下载 URL 撤权后仍可能在剩余 60 秒内可用；已下载副本无法撤回。
- 未版本化模式依赖 Vessel 服务端不覆盖最终键；具有 Bucket 广泛写权限的其他系统仍可能改写对象。生产宜用独立 Bucket/RAM 前缀权限并启用版本控制。
- 历史版本自动过期、回收站自动永久清理、匿名/邮箱邀请、跨空间复制、在线预览、独立 CLI/MCP 均未开放。30 天是记录的回收保留策略，本轮永久清理由 Owner/Admin 显式发起。
- 本轮完成开发与隔离环境验收，未执行生产发布、故障域切换、容量压力测试或真实 OSS 版本化模式验收；版本化调用由 SDK 边界测试覆盖。
