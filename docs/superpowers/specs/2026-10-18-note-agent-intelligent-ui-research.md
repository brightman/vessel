# Note Agent Intelligent UI 技术调研与应用设计

日期：2026-10-18。状态：官方资料调研与本地代码核对完成；尚未实现或完成 E2E。

## 目标

将 Intelligent UI 理解为 Agent 根据任务选择合适的交互界面：回答、澄清选择、资料展示、编辑预览。与统一 Ask/Edit 输入配套，让用户通过自然语言描述任务，必要时通过卡片补充信息或审核变更。

## 当前代码事实

- React NoteAgent.tsx 使用本地 conversation/history、运行流、状态查询、取消与恢复，并提供独立提案接受/拒绝操作。
- agent_platform.py 当前按 ask/edit 设置指令和 use_output_schema；edit 完成后由服务端转成提案。
- proposals/agent_output.py 严格解析 base_revision、operations、summary，复用 ProposalService 校验。
- 当前不能把自由文本澄清作为合法 edit 输出。统一输入应同时解决回答、澄清和编辑的响应分支。
- 现有事件名包含 TEXT_MESSAGE_CONTENT、RUN_ERROR；这些命名不能证明完整符合 AG-UI 协议。

## 技术方案比较

| 方案 | 官方能力 | Vessel 适配评估 |
| --- | --- | --- |
| 受控 Generative UI：结构化数据映射现有 React 组件 | AI SDK 官方示例将工具状态/结果映射到 React 组件 | 推荐作为首版模式；无需为了该模式强制迁移 SDK。复用现有 Python 网关、运行流、提案服务 |
| CopilotKit + AG-UI | CopilotKit 支持只读、交互、工具、状态与 A2UI 等渲染；AG-UI 规定双向事件交互 | 可作为未来标准化入口；当前需评估网关事件、鉴权、运行恢复、提案状态与 SDK 的适配，不能直接替换聊天框即宣称完成 |
| A2UI | 以 JSON 描述组件、数据绑定与用户动作，客户端 renderer 更新界面 | 适合多个 Agent/多端共享组件协议。首版需求只有有限卡片，引入通用 surface/data binding 生命周期成本较高 |
| AI SDK UI | React hooks、消息 parts、工具状态渲染、流式消息 | 能力适合聊天，但当前后端已有自定义网关与持久运行协议；采用 SDK 前需写传输适配并验证取消/恢复 |

以上适配结论为基于当前代码的工程判断，未做依赖安装或集成试验。A2UI 官方 renderer 文档与仓库存在多协议版本；若后续引入必须锁定 renderer 和协议版本，不能混用 v0.9 与 v1.0 schema。

## 推荐首版：现有运行协议 + 类型化消息卡片

保留现有 React 页面与服务端。Agent 输出带版本的响应：answer、clarification 或 edit。模型选择语义分支与数据；前端组件目录控制布局、按钮与可执行动作。卡片不是任意 HTML/JS，也不携带由模型指定的 API 地址。

### 对话界面

1. 统一输入框：Ask a question or describe changes…，移除 Ask/Edit 按钮。
2. 回答：Markdown、列表/简单表格及来源链接。仅有可核对 URL 才展示来源。
3. 澄清：问题、2–5 个选项与自由输入；选择后提交下一轮，保留原任务上下文。不能把选择当成同意写入。
4. 运行状态：展示真实状态与可用的工具事件、耗时、停止/重连。没有事件时只显示处理中与已用时间，不虚构搜索/核实进度，不展示私有推理。
5. 编辑提案：摘要、变更前后预览、来源、接受/拒绝。展示基于服务端已校验的 proposal_id 获取的数据，不能直接渲染 Agent 自称可提交的提案。
6. 长表格/比赛清单：对话中显示有限行预览，完整内容在 Note 提案预览里查看，避免右侧栏过宽。

### 数据与权限

- 响应契约引入明确 schema_version 和 type；answer/clarification 不带可执行 Note operations，edit 必须经过已有提案解析与校验。
- 只读用户保留回答/澄清；服务端禁止其创建或接受修改，前端隐藏/禁用按钮只是辅助。
- 新交互必须绑定已鉴权的 Note、Run、response/action 标识；客户端提交选项 ID，服务端检查归属与选项存在性。重复提交不能产生重复运行或重复修改。
- 保存结构化最终响应及用户选择，刷新后可以恢复；旧澄清卡片标记已回答，旧提案状态从服务端重取。
- 建议首版采用“澄清回答开启下一 Run”，沿用当前单 Note 活跃运行约束，不引入挂起执行的完整工作流。每次新 Run 读取最新 revision，防止继续使用陈旧文档。
- action 无效、来源 URL 不合规、响应不符合 schema：显示可理解错误或纯文本安全回退，不执行操作。
- 外部 Agent output_schema 需与服务端新契约协调；确认当前网关是否允许按请求覆盖 schema，若只能修改共享 Agent 配置，应使用兼容 schema 或专用配置，避免影响已有调用者。

## 比赛记录任务的具体体验

用户输入完整比赛记录要求。如果“每一场”范围明确，直接查询并提出带来源的记录；存在实质歧义时，澄清卡片只询问必要范围（如正式单打/含表演赛）。处理中显示真实检索事件，完成后呈现记录条数、日期范围、来源和提案预览。没有核实的数据明确标注缺失；空白模板不能算完成。

## 验收与 E2E

- 无模式选择即可完成普通问答，Note revision 不变且无提案。
- 模糊任务出现澄清卡片；点击选项或自由输入后继续原任务，重复点击不能重复提交；刷新能恢复已回答状态。
- 明确编辑请求生成预览；接受后刷新保留正文，拒绝后正文不变。
- 只读权限、过期 revision、无效选项、失败/停止/重连均有覆盖。
- 未识别组件或错误响应不导致整个侧栏崩溃。
- 自动化 E2E 使用可控 Agent 响应验证交互与权限；另用本地真实 Agent 验证问答、澄清、编辑三类响应。两种验证分别报告，不以 mock 通过代替真实运行通过。

## 官方资料

- AI SDK Generative UI：https://ai-sdk.dev/docs/ai-sdk-ui/generative-user-interfaces
- AI SDK UI reference：https://ai-sdk.dev/docs/reference/ai-sdk-ui
- CopilotKit Generative UI：https://docs.copilotkit.ai/ag2/generative-ui
- AG-UI introduction：https://docs.ag-ui.com/introduction
- A2UI renderers：https://a2ui.org/reference/renderers/
- A2UI React renderer：https://github.com/a2ui-project/a2ui/blob/main/renderers/react/README.md
- A2UI v1 protocol：https://github.com/a2ui-project/a2ui/blob/main/specification/v1_0/docs/a2ui_protocol.md
