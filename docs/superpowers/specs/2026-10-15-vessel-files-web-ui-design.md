# Vessel Files Web UI 设计

状态：设计已获确认，待实施。日期：2026-10-15。

## 目标与边界

在现有 `/console` 中增加完整的 Files 管理界面，让 Vessel 用户通过浏览器管理个人和团队空间的通用文件。首版覆盖目录浏览、名称搜索、文件上传下载、版本、个人共享、移动、回收、恢复、永久清理及有权限的审计查看。沿用独立账号、空间选择和现有 `/v1` 文件 API；Files 的文件夹与 Page 目录、Page 图片、Apps 表格保持分离。

本界面不增加匿名链接、邮箱邀请、团队文件单项 ACL、跨空间移动或复制、文件正文搜索、在线预览和批量结构操作。API 只提供单项 mutation；多文件上传由浏览器逐个创建意图并展示队列。文件 HTTP API 已实现但尚未发布生产，浏览器直传 OSS 的 CORS 仍须单独验证。

## 产品结构与布局

现有主导航加入 **Files**，保留 Pages、Apps、团队和当前空间选择。Files 默认打开当前空间的根文件夹。桌面采用三层：现有 Vessel 侧栏、Files 目录栏、文件列表；选中项目时右侧打开详情抽屉。窄屏时目录栏改为抽屉，详情以全屏面板打开，上传队列以可展开的底部状态条呈现。

```text
Vessel 侧栏       Files 目录栏              文件列表 / 搜索                 详情抽屉
当前空间           我的文件                  面包屑                         基本信息
Files             共享给我                  搜索名称 · 类型筛选             历史版本
Pages             回收站                    上传 · 新建文件夹               共享权限
Apps              当前空间的文件夹树          名称 · 大小 · 修改时间 · 操作     当前能力
团队                                       下一页
```

“我的文件”始终使用选中空间的 root。切换空间、视图或文件夹时清除上一个列表的选择和游标。“共享给我”是跨空间的虚拟入口，不改变当前空间，也不把源空间加入空间选择器。被直接共享的单个文件只显示该文件；被共享的文件夹可从共享入口向下浏览，不显示无权访问的父级、兄弟项或空间根目录。面包屑在共享入口截断。分享者和空间名称若 API 未返回，不通过其他空间接口猜测或拼接。

文件列表默认显示名称、类型、大小、最近修改时间；文件夹大小显示“—”。行单击选中并打开详情，双击文件夹进入目录，文件双击下载。操作菜单包括下载、上传新版本、重命名、移动、共享、移入回收站；各项按该 item 的有效能力显示。搜索仅针对当前选中空间的文件域，使用服务端名称包含匹配与 file/folder 类型过滤；共享入口只有服务端分页列表，不把当前页前端过滤伪装成全局搜索。游标分页显示“加载更多”，筛选或位置变化重置游标。

详情抽屉的基本信息显示文件名、大小、MIME、SHA-256、修改时间、创建/更新用户 ID 和当前权限来源。文件历史按版本倒序分页，可下载指定版本；有 `can_write` 时可恢复历史为新逻辑版本，确认框说明不会删旧版本。个人 Owner 可在“共享”页按已有 Vessel 用户 ID 添加 Viewer/Editor 授权和到期时间，查看直接与继承来源；继承授权指向来源文件夹，不能在子项直接修改。团队文件显示“团队成员按角色可见”，不出现个人共享表单。Owner/Admin 可在独立审计视图读取文件操作事件；不把审计入口误显示给无权者。

## 能力与操作映射

页面可先使用当前空间的团队角色布置入口，但具体按钮必须依赖 `GET /v1/file-items/{id}/permissions`。共享给我的资源可能不属于当前用户列出的任何空间，不能用 `/v1/spaces/{id}/permissions` 推断其文件权限。服务端每次 mutation 仍独立判权。

| 界面操作 | 主要 API / 条件 |
| --- | --- |
| 根目录、子目录、搜索 | `GET /spaces/{id}/folders/root`、`GET /spaces/{id}/file-items`、`GET /folders/{id}/children`、`POST /spaces/{id}/file-items/search` |
| 共享给我 | `GET /shared-files`；共享文件夹后续用 `GET /folders/{id}/children` |
| 新建文件夹、重命名 | `POST /spaces/{id}/folders` 需要目标目录 `can_create_children`；`PATCH /file-items/{id}` 需要 item `can_write` 和 `expected_metadata_version` |
| 上传、下载、版本 | 上传意图、签名、complete、状态端点；`POST /files/{id}/download`；`GET /files/{id}/versions`；历史恢复需要 `can_write` 和 `expected_current_version_id` |
| 个人共享 | `GET/POST/PATCH/DELETE /file-items/{id}/grants`；仅 `can_manage_sharing`，变更传 `expected_acl_revision` |
| 移动、回收、恢复 | move prepare/commit、`POST /file-items/{id}/trash`、restore prepare/commit；活动 item 的移动/回收按 `can_move`、`can_trash` 展示，回收批次按空间角色与回收 API 判权 |
| 永久清理、审计 | `POST /file-trash/{batch}/purge`、`GET /file-purges/{id}`、`GET /spaces/{id}/file-audit`；仅 Owner/Admin |

文件夹目标选择器懒加载可浏览子目录，并读取目标目录的 `can_create_children`；不允许选文件、当前文件夹自身、后代或其他空间。真正的无环、同空间和权限检查仍由 API 完成。移动先调用 prepare，显示 `permission_changes` 中将新增或失去的访问来源，再提交 preview ID/hash、metadata version、ACL revision。恢复回收批次也先预览原位置、名称冲突与将重新生效的访问来源，再确认。预览过期或 409 必须重新生成，不使用旧预览盲重试。

回收站按批次展示名称、原位置、回收时间、保留截止和状态。恢复只恢复该批次，不表示恢复此前单独回收的子项。永久清理要二次确认并说明历史版本也将物理删除；提交 202 后轮询 purge job 的 `pending/running/succeeded/failed`，不可在 job 尚未完成时显示“已删除”。文件及历史版本在物理清理完成前仍可能计入容量。当前 API 没有配额读取端点，因此界面不展示推测的容量条，只在 413 时提示实际超限错误。

## 上传与下载交互

上传按钮和拖放区域支持多文件队列。每个文件是独立上传意图；目录上传暂不提供，因为 API 不接收相对路径树。浏览器先以 Web Worker 按块读取 `File`，增量计算 SHA-256，避免一次把最多 512 MiB 文件放进内存。计算完成后创建 `mode=create` 意图；“上传新版本”使用 `mode=new_version`，明确传当前 file/version/metadata 预期值。大小和 MIME 从选取的本地文件取得，不把浏览器提供的 MIME 当成安全预览依据。

按服务端返回的 `transfer_mode`、`part_size_bytes` 和 `part_count` 切片。每次 `parts/sign` 最多申请 20 段；OSS PUT 必须携带指令中的精确 headers 和 body，不附加 Vessel Bearer Token。分段收集 OSS 返回的 ETag 后调用 complete；接受 202 后轮询上传状态，直到 `ready` 或 `failed/expired/cancelled/conflict`。进度分为“计算校验值”“传输”“服务端校验与发布”，最后一个阶段不伪装成字节百分比。队列限制并发文件与分段数，避免浏览器、网络和 OSS 过载；可取消未发布意图。

刷新页面会丢失浏览器 `File` 对象和内存中的签名指令。只允许在 `sessionStorage` 按用户 ID 保存本次会话的 upload ID，以便重新打开时查询结果或取消未完成意图；恢复后的队列仅显示 upload ID 和服务端状态。文件名、文件字节、预签名 URL、Token 和 OSS headers 都不持久化。登出时清除队列索引；账号切换时不读取其他账号的索引，过期项在恢复查询后清理。首版不承诺刷新后继续传输：用户重新选文件，旧意图先取消或等待过期，再以新意图开始。对失败和 `conflict` 不执行覆盖式重试；重读目标版本后由用户发起新上传。

下载时当次调用 `POST /files/{id}/download` 获取短期附件 URL，并立即触发浏览器下载；历史版本传 `version_id`。不缓存或记录 URL，不把 HTML/SVG 作为可信页面内嵌。签名到期或授权被撤销时重新调用 API；已经签发的 URL 在剩余有效期内可能仍可用，界面不承诺即时撤回。

## 客户端结构、状态与错误

在 `apps/web/src/App.tsx` 增加 Files 导航；新的 Files 视图复用现有登录、刷新 cookie 和同源 Bearer API 客户端。建议拆为文件 API 适配层、目录/列表视图、详情/版本/共享视图、上传任务控制器、回收站视图。页面状态用 `space_id + view + folder_id + filter` 定位；游标、选中项和已加载详情只保存在内存。当前空间 ID 继续是 `localStorage` 中唯一的持久用户偏好；上传 ID 只在 `sessionStorage` 中暂存。

所有文件 mutation 生成独立 `Idempotency-Key`，同一请求的网络重试使用相同 key；新用户意图才生成新 key。`REQUEST_IN_PROGRESS` 按 `Retry-After` 延后读取或同 key 重试。成功后刷新受影响目录/详情与权限，不在客户端猜测最终 ACL 或版本。409 按错误类型提供“重新载入并再次预览”，保留重命名文本或共享表单内容直到用户明确丢弃；403/404 清除已失权的详情和签名能力，不继续展示缓存的共享子项；503 `FILE_STORAGE_UNAVAILABLE` 明确说明目录仍可浏览、传输暂不可用。错误信息展示安全业务 code 和 `X-Request-ID`，不展示签名 URL 或内部对象键。

名称和分享对象按文本渲染，不插入原始 HTML。所有 destructive 操作都需明确确认。键盘可到达目录树、列表行、详情标签和对话框；焦点在抽屉/对话框关闭后返回触发按钮。上传进度与终态使用可读状态文字和 `aria-live`，不只靠颜色。移动/恢复权限变化预览既显示增加也显示失去的来源；来源不包含无权查看的祖先名称。

## 实施门槛与验收

浏览器直传前需在专用测试 Bucket/前缀验证 OSS CORS：允许控制台实际 Origin、PUT 和签名要求的 headers，并在分段响应中暴露 ETag。配置修改由 Bucket 管理者实施；前端不提供 Bucket 设置权限。开发环境需同时运行文件 worker，才能验证 complete 后的异步发布与清理。真实浏览器上传验收使用隔离 PostgreSQL、专用 OSS 前缀和测试账号，不操作现有用户文件。

先做 API 客户端和只读目录/共享视图，再做上传下载与状态队列，之后完成版本、共享、移动和回收。测试按项目 `AGENTS.md`：先专项、再受影响核心测试，合计不超过 100 个用例，最后真实浏览器 E2E。E2E 至少覆盖个人上传下载及 SHA-256、团队 Viewer 拒写与 Editor 写入、个人 Viewer/Editor 共享和撤权、分段上传 CORS/ETag、历史版本恢复、移动/恢复预览、回收与清理 job，以及服务端 409/503 的用户可见处理。未通过浏览器直传与 worker 路径前，不宣称 Files Web UI 已完成。

设计依据：[文件 API 契约](../../api-contract-files.md)、[文件运行说明](../../files-runtime.md)、[文件共享设计](../../shared-files-design.md) 和 [现有控制台设计](2026-10-15-vessel-web-console-design.md)。
