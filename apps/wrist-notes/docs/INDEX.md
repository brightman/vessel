# WiseLife 文档总索引

> 整理日期：2026-10-31；更新：2026-11-05。面向产品、开发、测试与交接；链接指向原文，保留现有文件位置。

## 使用与范围

本次收录 **210 份文档与文字资料**：Apple 项目 157 份、仓库根目录的相关规范、设计与计划 45 份、独立 Huawei 项目参考 7 份、官网迁移说明 1 份。本索引自身另计；按不含锚点的唯一文档文件链接计数（不计 JSON 等验证附件；包含独立 Huawei 项目的既有引用）。

- 主体是 `apps/wrist-notes/`，补齐散落于仓库 `docs/` 的 WiseLife / WristNotes / 早期 WiseNote 原生 App 文档。
- 全量收录项目内 Markdown、HTML 原型、TXT 验证附件和许可文本；无扩展名的上游许可证也已包含。
- 代码、截图、音频、构建日志、依赖下载目录与 Git 忽略的本机导出不逐项列为文档；相关附件通过原验证记录查找。Vessel 服务端等其他产品文档不纳入。
- 文档名称保留原文。设计、计划、实验、验收分别阅读；日期较新不自动表示已实现、已发布或覆盖所有旧方案。

### 形式建议

**Markdown 作为维护源，HTML 作为可选阅读层。** GitHub、编辑器及代码审查均可直接阅读本索引，修改随 Git 追踪。以后需要全文搜索、标签筛选或时间线界面时，可从同一份文档元数据生成 HTML，避免维护两套目录。本次交付 Markdown 索引。

### 目录

- [1. 产品设计说明](#product)
- [2. 技术设计说明](#technical)
- [3. 按日期组织的变更索引](#changes)
- [4. 按功能模块查找](#modules)
- [5. 验证、开发与发布](#verification)
- [6. 实施计划、历史与其他资料](#other)

### 建议阅读顺序

1. [项目说明](../README.md) → [产品整体设计](../prototype/daybook-design.md) → [iPhone 主原型](../prototype/iphone-day.html)。
2. [数据生命周期与本地结构](local-data-schema.md) → [存储与检索](local-storage-and-retrieval.md) → 下方对应功能设计。
3. 结合功能的实施计划与验证记录，再检查代码／设备验收状态。

<a id="product"></a>

## 1. 产品设计说明

涵盖整体产品、iPhone／Watch 交互、功能原型、品牌、官网及传播文案。原型可演示不等于原生功能已完成。

| 文档 | 文档标注日期 | 阅读提示 |
| --- | --- | --- |
| [WiseLife icon · 观 / The Witness](../design/brand/wiselife-icon-v1/README.md) | 2026-10-19 | 产品、交互或品牌说明 |
| [iPhone Day 硬件连接原型](2026-10-19-hardware-prototype-plan.md) | 2026-10-19 | 产品、交互或品牌说明 |
| [WiseLife 官网优化：Auday 参考与实施记录](2026-10-19-wiselife-auday-review.md) | 2026-10-19 | 产品、交互或品牌说明 |
| [WiseLife × EurekaRing 众筹传播文案](wiselife-eurekaring-crowdfunding-copy-2026-10-22.md) | 2026-10-22 | 产品、交互或品牌说明 |
| [Ask AI 自动查找记录 · 2026-10-23](../prototype/ai-date-range-design.md) | 2026-10-23 | 产品、交互或品牌说明 |
| [WiseLife website icon](../prototype/assets/brand/README.md) | 未标注 | 产品、交互或品牌说明 |
| [我的一天：24 小时个人记录首页](../prototype/daybook-design.md) | 2026-10-19 | 产品、交互或品牌说明 |
| [WiseLife 闪念：整理、想法、记账与行动](../prototype/flash-assets-design.md) | 2026-10-31 | 整理／全文、明确指令自动创建、想法与账目本地保存、结果时间轴；原型及原生实现状态 |
| [四类记事本交互原型](../prototype/notebook.html) | 2026-11-03 | 灵感、记账、人物、地点；合成数据与模拟 AI；四类原生已授权开发并完成代码，原生验证见日期索引 |
| [WiseLife · 你的生活，你的个人 AI](../prototype/index-next.html) | 未标注 | 官网备选设计，勿与主原型混用 |
| [WiseLife · iPhone 产品原型](../prototype/iphone-day.html) | 2026-11-03 | 纯产品界面；设置中接入四类记事本，查看全部只展示记录，顶部问号提供功能说明 |
| [WristNotes · iPhone 语音笔记界面](../prototype/iphone-notes.html) | 未标注 | 早期语音笔记原型，保留作历史参考 |
| [今天的片段：步数、起床与位置变化](../prototype/life-moments-design.md) | 2026-10-22 | 产品、交互或品牌说明 |
| [说话人关联联系人与 Apple 提醒事项](../prototype/people-reminders-design.md) | 2026-10-21 | 产品、交互或品牌说明 |
| [地点与采集设备：原型评审](../prototype/places-design.md) | 2026-10-20 | 产品、交互或品牌说明 |
| [详情页管理入口原型](../prototype/record-management-design.md) | 2026-10-24 | 产品、交互或品牌说明 |
| [iPhone 设置原型 · 2026-10-18](../prototype/settings-design.md) | 2026-10-18 | 多次追加的历史设置设计；10/31 调整另见日期索引 |
| [WiseLife 首次使用：AI 与数据准备](../prototype/onboarding-design.md) | 2026-11-02 | 原型已获批准并接入原生；转写、AI 能力、数据授权、使用说明四步引导与失败恢复 |
| [首次使用交互原型](../prototype/onboarding.html) | 2026-11-02 | 可演示模型准备、数据授权、iPhone／Watch 使用指引与模拟器截图 |
| [WristNotes · Apple Watch 录音界面](../prototype/watch-recorder.html) | 未标注 | Watch 录音交互原型 |
| [WiseLife alternate homepage](../prototype/wiselife-next-design.md) | 2026-10-24 | 产品、交互或品牌说明 |
| [WiseLife product website](../prototype/wiselife-website.md) | 未标注 | 产品、交互或品牌说明 |
| [WiseLife 每日回顾](../../../docs/superpowers/specs/2026-10-22-daily-recaps-design.md) | 2026-10-22 | 产品、交互或品牌说明 |
| [Watch 表盘快捷录音](../../../docs/superpowers/specs/2026-10-22-watch-recording-complication-design.md) | 2026-10-22 | 产品、交互或品牌说明 |
| [WiseLife Companion prelaunch website section](../../../docs/superpowers/specs/2026-10-23-wiselife-mac-companion-website-design.md) | 2026-10-23 | 产品、交互或品牌说明 |

<a id="technical"></a>

## 2. 技术设计说明

涵盖录音与同步、ASR／VAD、内容分段、SQLite／向量检索、权限与恢复、Siri 和 Mac Companion 等方案。

| 文档 | 文档标注日期 | 阅读提示 |
| --- | --- | --- |
| [WiseLife：iCloud 备份数据范围研究](2026-10-19-icloud-backup-research.md) | 2026-10-19 | 技术方案、研究或实现说明；状态以原文为准 |
| [采集地点地址解析](2026-10-20-capture-addresses.md) | 2026-10-20 | 技术方案、研究或实现说明；状态以原文为准 |
| [地点与采集设备：原生实现](2026-10-20-capture-places.md) | 2026-10-20 | 技术方案、研究或实现说明；状态以原文为准 |
| [WiseLife 对话历史与声音档案恢复](2026-10-20-conversation-history-and-voice-recovery.md) | 2026-10-20 | 技术方案、研究或实现说明；状态以原文为准 |
| [WiseLife 数据、存储、检索与 AI 架构梳理](2026-10-20-data-storage-retrieval-ai-review.md) | 2026-10-20 | 技术方案、研究或实现说明；状态以原文为准 |
| [WiseLife 第二阶段：全文检索与完整分段索引](2026-10-20-fulltext-and-chunk-indexing.md) | 2026-10-20 | 技术方案、研究或实现说明；状态以原文为准 |
| [HealthKit 数据更新（2026-10-20）](2026-10-20-health-background.md) | 2026-10-20 | 技术方案、研究或实现说明；状态以原文为准 |
| [WiseLife 第一阶段：业务元数据迁移记录](2026-10-20-metadata-sqlite-migration.md) | 2026-10-20 | 技术方案、研究或实现说明；状态以原文为准 |
| [Eureka Ring 编译开关](2026-10-20-ring-build-switch.md) | 2026-10-20 | 技术方案、研究或实现说明；状态以原文为准 |
| [Flash Capture 在 WiseLife 闪念语音中的应用研究](2026-10-21-flash-capture-assets-research.md) | 2026-10-21 | 技术方案、研究或实现说明；状态以原文为准 |
| [Watch 配对与同步状态](2026-10-21-watch-sync-status.md) | 2026-10-21 | 技术方案、研究或实现说明；状态以原文为准 |
| [2026-10-22 长录音退出与时长修复](2026-10-22-long-recording-incident.md) | 2026-10-22 | 技术方案、研究或实现说明；状态以原文为准 |
| [WiseLife AI Prompt 目录](ai-prompts.md) | 2026-10-31 | 标题、总结、主题拆分／合并、建议、每日回顾与 Ask AI；源码原文及调用路径 |
| [Ask AI 会话、上下文与工具编排](ask-ai-session-orchestration.md) | 2026-11-01 | 已批准；首期运行时、只读工具、同轮重试、五类附属表与实现边界；验证分项记录 |
| [WiseLife iPhone 与 Apple Watch 数据生命周期及本地结构](local-data-schema.md) | 2026-10-30 | 数据生命周期、SQLite 表、文件与迁移；字段以代码为准 |
| [WiseLife 本地存储与检索](local-storage-and-retrieval.md) | 2026-11-01 | 存储、全文／向量检索、Speaker Ask 的主要阅读入口；数据库保护说明已按代码勘误 |
| [WiseLife 原型与原生 App 功能核对](prototype-completion-audit.md) | 2026-10-19 | 技术方案、研究或实现说明；状态以原文为准 |
| [WiseLife 长录音：分片保存、分段处理与内容时间轴](superpowers/specs/2026-10-22-long-recording-design.md) | 2026-10-22 | 技术方案、研究或实现说明；状态以原文为准 |
| [WiseLife：切片录音、上传、处理与内容分段全流程](superpowers/specs/2026-10-22-streaming-recording-design.md) | 2026-10-22 | 技术方案、研究或实现说明；状态以原文为准 |
| [WiseLife 内容分段策略 v2：统一 preview 与 iPhone](superpowers/specs/2026-10-23-content-segmentation-v2-review.md) | 2026-10-23 | 内容分段策略说明；600 秒门槛另见 10/31 验证 |
| [WiseLife Mac Companion + MLX Local LLM](superpowers/specs/2026-10-23-wiselife-mac-mlx-companion-design.md) | 2026-10-23 | 技术方案、研究或实现说明；状态以原文为准 |
| [Adaptive Content Summary Budget](superpowers/specs/2026-10-24-adaptive-content-summary-budget-design.md) | 2026-10-24 | 技术方案、研究或实现说明；状态以原文为准 |
| [Final 内容片段的时间轴展示与合并设计](superpowers/specs/2026-10-24-content-timeline-readiness-design.md) | 2026-10-24 | 技术方案、研究或实现说明；状态以原文为准 |
| [Watch → iPhone 小时录音文件传输时序](watch-to-iphone-hourly-recording-sequence.md) | 未标注 | 小时文件传输方案；与早期 10 分钟方案分开阅读 |
| [WiseLife local speaker diarization](../../../docs/superpowers/specs/2026-10-19-local-speaker-diarization-design.md) | 2026-10-19 | 技术方案、研究或实现说明；状态以原文为准 |
| [WiseLife AI 对话历史修复](../../../docs/superpowers/specs/2026-10-20-wiselife-conversation-history-design.md) | 2026-10-20 | 技术方案、研究或实现说明；状态以原文为准 |
| [WiseLife 第二阶段：全文检索与完整分段索引](../../../docs/superpowers/specs/2026-10-20-wiselife-fulltext-chunks-design.md) | 2026-10-20 | 技术方案、研究或实现说明；状态以原文为准 |
| [WiseLife 第一阶段：业务元数据 SQLite 迁移](../../../docs/superpowers/specs/2026-10-20-wiselife-metadata-sqlite-design.md) | 2026-10-20 | 技术方案、研究或实现说明；状态以原文为准 |
| [WiseLife Watch 后台传输状态设计](../../../docs/superpowers/specs/2026-10-23-watch-background-transfer-status-design.md) | 2026-10-23 | 技术方案、研究或实现说明；状态以原文为准 |
| [WiseLife Apple ASR 首选与回退方案](../../../docs/superpowers/specs/2026-10-27-wiselife-simulator-apple-asr-design.md) | 2026-10-27 | 技术方案、研究或实现说明；状态以原文为准 |
| [Watch 与 iPhone 文件传输状态和诊断](../../../docs/superpowers/specs/2026-10-28-watch-transfer-diagnostics-design.md) | 2026-10-28 | 技术方案、研究或实现说明；状态以原文为准 |
| [WiseLife Siri 本地查询设计](../../../docs/superpowers/specs/2026-10-29-wiselife-siri-local-query-design.md) | 2026-10-29 | 技术方案、研究或实现说明；状态以原文为准 |

<a id="changes"></a>

## 3. 按日期组织的变更索引

按**文件名、文档标题、文首日期以及明确日期的更新章节**倒序组织设计、实施、修复和验证材料。这里是文档所记载工作的入口，不是 Git 提交日志，也不是 App 版本发布日期。

同一文档有明确的多日更新时会在多天出现；示例录音日期、测试数据日期及文件修改时间不作为变更日期。未标注日期的文档集中列于末尾。

### 2026-11-05

- **GitHub 分支更新** · `codex/wiselife-notebook` 从 `3b9d0e5` 整理联系人五字段、HealthKit 签名与 Xcode 修复，独立模拟器构建 0 warning／0 error，专项回归与集成审查通过；全量旧测试入口的既存失败单独保留。[提交范围与复验](work/2026-11-05-xcode-warnings/README.md#github-分支整理2026-11-05)。

- **Xcode 编译与运行时诊断** · [修复与验证](work/2026-11-05-xcode-warnings/README.md)。通过 computer-use 检查 12 项构建 issue 与 2 项历史运行时诊断；修正 Swift 捕获／登录窗口、Watch 原子操作与资源、项目设置，播放会话与系统定位检查移出主线程。自动检查、完整构建、现场复查与真机状态分项见记录。

- **HealthKit 真机缺少签名权限** · [当前规则与原因](2026-10-20-health-background.md#signing-20261105) · [打包修复与验证](testflight-release-2026-10-19.md#healthkit-signing-20261105)。保留的构建 13 IPA 中 profile 允许健康能力，但 App 签名缺失；新增带签名归档与最终 IPA 权限校验，阻止无能力包通过发布检查。健康刷新回归通过；本次未上传或安装真机，签名产物状态见验证记录。

### 2026-11-04

- **人物联系人五字段表单** · [当前交互说明](../prototype/flash-assets-design.md#contact-form-20261104) · [iPhone 主原型](../prototype/iphone-day.html?preview=notebook) · [原型验证](../verification/flash-assets-prototype/README.md#contact-form-20261104)。添加与编辑共用姓名、公司、邮箱、手机号、关系表单；关系支持多选及新增自定义选项。原型已走查；用户随后要求代码实现，原生已共用五字段控件并补齐 SQLite 邮箱／手机号读写，保留额外资料与录音关联。[原生验证](../verification/flash-assets-prototype/README.md#contact-form-native-20261104)记录存储回归、SwiftUI typecheck 与构建；未进行本次真机安装或发布。

### 2026-11-03

- **记事本 GitHub 分支交付** · 基于 `dev-card-1103` 整理 `codex/wiselife-notebook`，包含本功能代码、原型和文档；隔离分支的 7 组测试、原型静态检查和完整 iOS 模拟器构建通过，原工作区保留。[复验记录](../verification/flash-assets-prototype/README.md#github-分支整理与复验2026-11-03)。

- **四类记事本原生实现** · [当前产品规则](../prototype/flash-assets-design.md#notebook-four-categories) · [同一实施计划](superpowers/plans/2026-10-31-flash-notebook-native.md) · [验证与边界](../verification/flash-assets-prototype/README.md#notebook-native-four-20261103)。灵感新增／编辑、选择 AI 再创作与候选持久化，按月／币种收支，联系人多选／自定义关系，高频地点按日去重；设置入口／返回，查看全部不放记事本快捷入口。增量 SQLite 保留旧数据，新存储与旧回归测试、iPhone 模拟器构建通过；独立模拟器已安装启动，图形应用缺失故未做原生点击／视觉验收，真实模型、真机与发布未验收。

- **iPhone 主原型清理与整合** · [当前说明与验证](../prototype/daybook-design.md#standalone-prototype-20261103) · [产品原型](../prototype/iphone-day.html)。移除外围官网／评审内容；设置与闪念详情接入灵感、记账、人物、地点，原闪念编辑在两处同步；按最新评审移除“查看全部”里的记事本和四分类入口，记事本返回链接统一为“设置”；增加可展开的产品功能说明。仅 HTML 原型变更，原生与发布未改。

- **四类记事本产品原型** · [设计与确认记录](../prototype/flash-assets-design.md#notebook-four-categories) · [交互原型](../prototype/notebook.html) · [验证](../verification/flash-assets-prototype/README.md#notebook-four-categories-20261103)。灵感编辑与 AI 再创作、月度收支、人物多选／自定义关系、地点高频列表均可演示。主动闪念自动保存、长录音想法暂不收录；按用户最新评审移除地点采集状态与生活节奏卡片，同一地点每天最多计 1 次，按去重后的次数排序，并可按日期查看来源。已走查浏览器，原生代码与真机数据未改。

### 2026-11-02

- **GitHub 代码同步前核验** · 11/02 当前 App／原型／文档整理到独立发布目录，逐文件核对与原工作区一致；Xcode source membership、`test_onboarding.sh`、`test_watch_sync.sh`、原型 JavaScript 语法及暂存差异检查通过。沿用同日 `build-final.log` 的 Debug iOS 构建成功记录；本次未另行安装真机或发布新 TestFlight。Vessel 后端／Web 其他工作不纳入本次同步。

- **首次引导入口收敛** · [当前设计](../prototype/onboarding-design.md) · [验证](../verification/onboarding-prototype-2026-11-02.md#first-launch-only) · 原生与 HTML 设置移除「AI 与数据准备」；仅新安装首次引导，完成／跳过后不再出现。后续配置使用各模型及数据来源的独立入口；本次尚未发布到 TestFlight。
- **TestFlight 1.0.2（11）** · [发布记录](testflight-release-2026-10-19.md#build11-20261102) · Release 归档、发布前回归及四组件发布签名通过；20:28 上传成功，Apple 处理完成，内部／外部组已关联，外部组为“正在测试”。
- **每日回顾窗口、表达、发言人与界面语言** · [当前方案](../../../docs/superpowers/specs/2026-10-22-daily-recaps-design.md) · [验证记录](../verification/2026-10-23-persisted-timeline-recap-refresh.md#recap-budget-20261102) · 按 LLM 窗口分批、阶段反馈、300 秒截止，保留每天一次自动尝试；回顾语言跟随界面，错误语言有界修复。中文真机生成已核验；最终日期／归属补丁已安装，真实输出待复核。

- **产品原型：首次使用 AI 引导** · [设计说明](../prototype/onboarding-design.md) · [交互演示](../prototype/onboarding.html) · [验证](../verification/onboarding-prototype-2026-11-02.md) · 语音转写 → AI 能力（理解与检索同页）→ 数据授权 → 使用说明；逐项说明用途、端上处理与未就绪影响，授权可跳过，自定义云端服务单独说明发送范围；完成后进入现有首页，欢迎标题为「懂你的AI，更懂保护你的隐私」，文案增加 7／14 天原始录音留存与 Bring Your Own Model 英文命名。第 4 步使用真实模拟器截图说明 iPhone 录音／拍照、Watch 安装／使用，没有 Watch 也能完成。原型已获批准并接入 Swift；[原生计划](superpowers/plans/2026-11-02-onboarding-native.md)与[原生验收](../verification/onboarding-prototype-2026-11-02.md#native-implementation)记录首次安装、恢复、跳过和旧用户升级边界。

- **Ask AI 语音输入修复** · [采集诊断与验证](../verification/ask-ai-voice-input-2026-10-31.md#voice-capture-20261102) · [脱敏采集对照](../verification/ask-ai-microphone-devicehub-2026-11-02.json) · 资源检查后移，松手收起波形卡，波形刷新与对话页分离；回归通过。真机空音频定位到 Device Hub 屏幕共享干扰：开启 6 次失败、关闭 8 次采集正常。共享与调试器已关闭，实际长按转写／连续草稿输入待用户验收。

- **第二个小时录音未接收诊断** · [真机证据与后续恢复](../verification/progressive-recording-2026-11-01.md#second-file-receipt-20261102) · 曾缺第 2 个小时文件并发现安装状态与计数异常；用户随后确认 Watch 为最新 App、传输已成功，底层排队原因未确认。

- **Ask AI 页面与后台生命周期／模型设置** · [修复与验证](../verification/ask-ai-runtime-2026-11-01.md#background-lifetime-20261102) · 切页不取消、有限后台执行与明确到期原因；Apple Intelligence 不可用时置灰并显示原因。会话、驱动、设置回归和签名构建通过，真机交互状态见验证记录。

- **Ask AI 真机继续验收** · [11/02 现场记录](../verification/ask-ai-runtime-2026-11-01.md#device-cancellation-followup-20261102) · 定位并修复跨日重试的 SQLite 归档日期冲突，6 种跨日组合及会话／运行时回归通过；12:20 已安装，16 条原对话完整保留。13:28 解锁后跨日重试真机成功，豆包正常回答并原位入库（4.62 秒）；新问题也已完成并入库（6.59 秒）。

- **长录音逐段发布与恢复** · [当前分段约定](superpowers/specs/2026-10-23-content-segmentation-v2-review.md#seg-10-按当前片段依赖判断完成) · 分类完成即保存，独立段失败隔离，冻结轮次跨重启恢复；[持续验证记录](../verification/progressive-recording-2026-11-01.md#2026-11-02-followup)。新版真机确认旧录音 23 个可展示片段保留；新持续录音只到达首个小时文件时，3 个片段已显示于时间轴，过程中捕捉到整轮未结束即发布 2 个片段。后续小时追加、长期后台与旧 ASR 失败恢复未验收。

### 2026-11-01

- **Ask AI 真机误取消排查** · [竞态修复与现场验证](../verification/ask-ai-runtime-2026-11-01.md#device-cancellation) · 初次资料读取与范围复核遇到后台进度更新时有界重试；中断原因细分，删除／权限保护保持。真机安装与实际回答状态以验证记录为准。

- **长录音增量处理修复** · [主题分段当前约定](superpowers/specs/2026-10-23-content-segmentation-v2-review.md#seg-10-按当前片段依赖判断完成) · 冻结窗口证据、同源串行、开放尾段与定稿字段保留；[10 小时真机诊断与回归记录](../verification/progressive-recording-2026-11-01.md)。自动测试与签名构建通过；1.0.2 (10) 已安装至 Bright，主题检查点开始写入，时间轴验收待确认。

- **Ask AI 个性化提示词** · [当前 system prompt](ai-prompts.md#92-自定义-ai附近-macchatgpt-基础指令) · 生活／学习／工作建议，明确偏好与习惯证据，当前意愿优先，给出可执行下一步；[验证追加记录](../verification/ask-ai-runtime-2026-11-01.md#system-prompt-personalization)。

- **模拟器真实模型验收** · [10 轮测试与问题清单](../verification/ask-ai-runtime-2026-11-01.md#simulator-personalization) · iOS 26.3＋豆包；9 轮模型回答、1 轮来源过滤失败；建议相关性、资料不足声明与引用仍有缺口，未全部通过。发送清空、来源跳转、SQLite 保存与重启恢复已核对。

- **实现与验证** · [Ask AI 运行时验证](../verification/ask-ai-runtime-2026-11-01.md) · 有界用户问题背景、四类模型执行器、只读工具、同轮重试、范围变更校验、增量外发预览；合成测试、原型、构建与真机状态分开记录。
- **计划** · [Ask AI Runtime 实施计划](superpowers/plans/2026-11-01-ask-ai-runtime.md) · 同一任务持续维护；不自动提交、推送或安装。

- **实施前技术设计评审** · [Ask AI 会话、上下文与工具编排](ask-ai-session-orchestration.md) · 已按当前代码刷新：现有能力与缺口、iOS 26.3 执行器、历史/预算、五类 SQLite 附属表、索引查询隔离、外发许可与迁移。仅更新文档，未修改 Swift 或原型。
- **实施前基线验证** · [本次检查结果](ask-ai-session-orchestration.md#baseline-validation) · Speaker 专项通过；对话专项在旧提示文案断言中止，后续用例未执行；未进行 App 构建、模拟器 UI 或真机推理。
- **当前说明勘误** · [存储与检索](local-storage-and-retrieval.md) · 数据库文件保护按源码修正为 completeUntilFirstUserAuthentication，增加待评审方案入口。

### 2026-10-31

- **原型与原生同步** · [闪念结果时间轴](../prototype/flash-assets-design.md#2-信息结构与入口) · 日程／待办／提醒直接显示标题、时间和状态，同源结果分组；编辑保持完成状态，删除保留来源状态；[浏览器验证](../verification/flash-assets-prototype/README.md#timeline-20261031)、[原生验证](../verification/flash-assets-prototype/README.md#timeline-native-20261031)。8 项行动集成测试、编译、模拟器交互及原模拟器更新安装通过，真机待验收。

- **原生开发** · [闪念整理与记事本实施计划](superpowers/plans/2026-10-31-flash-notebook-native.md) · SQLite 整理项、记事本、明确指令自动执行与故障恢复；[验证](../verification/flash-assets-prototype/README.md#native-20261031)

- **产品** · [闪念整理与自动行动](../prototype/flash-assets-design.md) · 文内更新；想法／记账的 SQLite 设计约定、整理结果卡与异常状态原型；设置新增“记事本”，想法改为正文＋时间的紧凑列表
- **验证** · [Flash assets prototype verification](../verification/flash-assets-prototype/README.md#2026-10-31-update) · 文内追加；HTML 交互历史与后续原生验证分别记录

- **目录** · [WiseLife 官网独立目录](../../wiselife-website/docs/directory-migration.md) · 官网与原生 App 并列，包含现有首页、独立设计版本、对比页、资源、脚本与官网检查；App 原型继续归 App

- **规范** · [项目文档生成与维护规则](../../../docs/documentation-rules.md) · 已写入仓库 AGENTS.md，版本 1.0 生效
- **技术** · [WiseLife AI Prompt 目录](ai-prompts.md) · 提取当前源码模板，核对输入输出、模型路径及现状差异；未调整生成逻辑
- **技术** · [WiseLife：切片录音、上传、处理与内容分段全流程](superpowers/specs/2026-10-22-streaming-recording-design.md) · 文内更新
- **技术** · [WiseLife 内容分段策略 v2：统一 preview 与 iPhone](superpowers/specs/2026-10-23-content-segmentation-v2-review.md) · 文内更新
- **计划** · [Local Query Translation Experiment Plan](superpowers/plans/2026-10-31-local-query-translation-experiment.md)
- **计划** · [Apple local query translation: production integration](superpowers/plans/2026-10-31-local-query-translation-production.md)
- **计划** · [Settings navigation adjustment](superpowers/plans/2026-10-31-settings-navigation.md)
- **计划** · [Ask AI voice input implementation plan](../../../docs/superpowers/plans/2026-10-31-ask-ai-voice-input.md)
- **计划** · [Shared keyboard interaction](../../../docs/superpowers/plans/2026-10-31-shared-keyboard-interaction.md)
- **验证** · [Apple embedding 中英文检索实验](../verification/apple-embedding-bilingual-2026-10-31.md)
- **验证** · [Apple 端上翻译 + 本地语义检索实验](../verification/apple-query-translation-2026-10-31.md)
- **验证** · [Apple 端上翻译与语义检索：正式 App 接入](../verification/apple-query-translation-production-2026-10-31.md)
- **验证** · [Ask AI 输入框发送后清空](../verification/ask-ai-composer-clear-2026-10-31.md)
- **验证** · [Ask AI native voice input — 2026-10-31](../verification/ask-ai-voice-input-2026-10-31.md)
- **验证** · [10 分钟空白候选阈值 · 2026-10-31](../verification/content-gap-600-2026-10-31.md)
- **验证** · [键盘交互与待保存录音验证 · 2026-10-31](../verification/keyboard-and-pending-recording-2026-10-31.md)
- **验证** · [模拟器 API Key 读取恢复 · 2026-10-31](../verification/keychain-installation-2026-10-31.md)
- **验证** · [Settings hierarchy alignment — 2026-10-31](../verification/settings-hierarchy-2026-10-31.md)
- **验证** · [Ask AI：Kate Bell 关联发言检索修复](../verification/speaker-ask-2026-10-31.md)

### 2026-10-30

- **技术** · [WiseLife 对话历史与声音档案恢复](2026-10-20-conversation-history-and-voice-recovery.md) · 文内更新
- **技术** · [WiseLife iPhone 与 Apple Watch 数据生命周期及本地结构](local-data-schema.md)
- **技术** · [WiseLife 本地存储与检索](local-storage-and-retrieval.md) · 文内更新
- **计划** · [Speaker Ask and Contact Records Implementation Plan](superpowers/plans/2026-10-30-speaker-ask-contact-implementation.md)

### 2026-10-29

- **技术** · [WiseLife Siri 本地查询设计](../../../docs/superpowers/specs/2026-10-29-wiselife-siri-local-query-design.md)
- **计划** · [WiseLife Siri 本地查询 Implementation Plan](../../../docs/superpowers/plans/2026-10-29-wiselife-siri-local-query.md)
- **计划** · [WiseLife Sliding Group Audio Processing Implementation Plan](../../../docs/superpowers/plans/2026-10-29-wiselife-sliding-group-processing.md)

### 2026-10-28

- **技术** · [Watch 与 iPhone 文件传输状态和诊断](../../../docs/superpowers/specs/2026-10-28-watch-transfer-diagnostics-design.md)
- **计划** · [Watch M4A Metadata and Recovery Implementation Plan](../../../docs/superpowers/plans/2026-10-28-watch-m4a-metadata-recovery.md)
- **计划** · [Watch 与 iPhone 整文件传输清理计划](../../../docs/superpowers/plans/2026-10-28-watch-transfer-diagnostics.md)
- **验证** · [原始录音重新处理修复验证](../verification/recording-reprocess-2026-10-28.md)

### 2026-10-27

- **技术** · [WiseLife Apple ASR 首选与回退方案](../../../docs/superpowers/specs/2026-10-27-wiselife-simulator-apple-asr-design.md)
- **计划** · [WiseLife Apple ASR Engine Fallback Implementation Plan](../../../docs/superpowers/plans/2026-10-27-wiselife-apple-asr-fallback.md)

### 2026-10-26

- **验证** · [Settings version and release time](../verification/app-release-info-2026-10-26.md)

### 2026-10-25

- **技术** · [2026-10-22 长录音退出与时长修复](2026-10-22-long-recording-incident.md) · 文内更新
- **计划** · [Feature Implementation Plan](superpowers/plans/2026-10-25-long-recording-phone-chunks.md)
- **验证** · [Independent AI provider settings](../verification/ai-provider-configurations-2026-10-25.md)
- **验证** · [HealthKit workout records](../verification/health-workouts-2026-10-25.md)
- **验证** · [原生模型设置与下载验证 · 2026-10-19](../verification/model-downloads.md) · 文内更新
- **验证** · [iPhone nearby Mac LLM integration — 2026-10-25](../verification/nearby-mac-iphone-2026-10-25.md)

### 2026-10-24

- **产品** · [详情页管理入口原型](../prototype/record-management-design.md)
- **产品** · [WiseLife alternate homepage](../prototype/wiselife-next-design.md)
- **技术** · [Adaptive Content Summary Budget](superpowers/specs/2026-10-24-adaptive-content-summary-budget-design.md)
- **技术** · [Final 内容片段的时间轴展示与合并设计](superpowers/specs/2026-10-24-content-timeline-readiness-design.md)
- **计划** · [Adaptive Content Summary Budget Implementation Plan](superpowers/plans/2026-10-24-adaptive-content-summary-budget.md)
- **计划** · [Final content timeline readiness implementation plan](superpowers/plans/2026-10-24-content-timeline-readiness.md)
- **计划** · [Production Content Segmentation V2 Routing Implementation Plan](superpowers/plans/2026-10-24-production-content-v2-routing.md)

### 2026-10-23

- **产品** · [Ask AI 自动查找记录 · 2026-10-23](../prototype/ai-date-range-design.md)
- **产品** · [WiseLife product website](../prototype/wiselife-website.md) · 文内更新
- **产品** · [WiseLife Companion prelaunch website section](../../../docs/superpowers/specs/2026-10-23-wiselife-mac-companion-website-design.md)
- **技术** · [WiseLife：切片录音、上传、处理与内容分段全流程](superpowers/specs/2026-10-22-streaming-recording-design.md) · 文内更新
- **技术** · [WiseLife 内容分段策略 v2：统一 preview 与 iPhone](superpowers/specs/2026-10-23-content-segmentation-v2-review.md)
- **技术** · [WiseLife Mac Companion + MLX Local LLM](superpowers/specs/2026-10-23-wiselife-mac-mlx-companion-design.md)
- **技术** · [WiseLife Watch 后台传输状态设计](../../../docs/superpowers/specs/2026-10-23-watch-background-transfer-status-design.md)
- **计划** · [Action Tab Implementation Plan](superpowers/plans/2026-10-23-actions-native.md)
- **计划** · [Persisted content timeline](superpowers/plans/2026-10-23-persisted-content-timeline.md)
- **计划** · [Long recording locations and content chapters](superpowers/plans/2026-10-23-recording-location-content.md)
- **计划** · [Simulator Content V2 Implementation Plan](superpowers/plans/2026-10-23-simulator-content-v2.md)
- **计划** · [每日回顾证据权重与行动建议](../../../docs/superpowers/plans/2026-10-23-recap-evidence-authority.md)
- **计划** · [WiseLife Watch Background Transfer Status Implementation Plan](../../../docs/superpowers/plans/2026-10-23-watch-background-transfer-status.md)
- **计划** · [WiseLife Companion Website Teaser Implementation Plan](../../../docs/superpowers/plans/2026-10-23-wiselife-companion-teaser.md)
- **验证** · [Content chapters implementation — 2026-10-23](../verification/2026-10-23-content-chapters-implementation.md)
- **验证** · [每日回顾：每天仅自动尝试一次](../verification/2026-10-23-daily-recap-once.md)
- **验证** · [内容片段持久化与回顾刷新修复](../verification/2026-10-23-persisted-timeline-recap-refresh.md)
- **验证** · [6 小时 42 分录音：真机数据与 Mac 分段实测](../verification/2026-10-23-real-recording-mac-audit.md)
- **验证** · [GPS / 内容分段：真机安装与测试](../verification/2026-10-23-recording-location-content-device.md)
- **验证** · [长录音 GPS 与内容分段更新：开发与验证](../verification/2026-10-23-recording-location-content.md)
- **验证** · [Recording locations implementation — 2026-10-23](../verification/2026-10-23-recording-locations-implementation.md)
- **验证** · [内容片段详情与首页摘要修复](../verification/2026-10-23-segment-detail-ui.md)
- **验证** · [真机内容片段处理状态检查](../verification/2026-10-23-segment-processing-ui.md)
- **验证** · [6h42m recording: simulator content v2 pilot](../verification/2026-10-23-simulator-content-v2.md)
- **验证** · [长录音分段引发 SQLite 写锁：修复与真机验证](../verification/2026-10-23-sqlite-content-contention.md)
- **验证** · [首页与我的记录周期性加载修复](../verification/2026-10-23-timeline-refresh.md)
- **验证** · [行动 Tab 原生实现 · 2026-10-23](../verification/actions-native.md)
- **验证** · [昨日 / 每日回顾：证据权重与行动建议](../verification/daily-recap-evidence-authority.md)
- **验证** · [Watch 安装诊断（2026-10-23）](../verification/watch-installation.md)

### 2026-10-22

- **产品** · [WiseLife × EurekaRing 众筹传播文案](wiselife-eurekaring-crowdfunding-copy-2026-10-22.md)
- **产品** · [今天的片段：步数、起床与位置变化](../prototype/life-moments-design.md)
- **产品** · [WiseLife 每日回顾](../../../docs/superpowers/specs/2026-10-22-daily-recaps-design.md)
- **产品** · [Watch 表盘快捷录音](../../../docs/superpowers/specs/2026-10-22-watch-recording-complication-design.md)
- **技术** · [Watch 配对与同步状态](2026-10-21-watch-sync-status.md) · 文内更新
- **技术** · [2026-10-22 长录音退出与时长修复](2026-10-22-long-recording-incident.md)
- **技术** · [WiseLife 长录音：分片保存、分段处理与内容时间轴](superpowers/specs/2026-10-22-long-recording-design.md)
- **技术** · [WiseLife：切片录音、上传、处理与内容分段全流程](superpowers/specs/2026-10-22-streaming-recording-design.md)
- **计划** · [WiseLife 长录音阶段 A Implementation Plan](superpowers/plans/2026-10-22-long-recording-phase-a.md)
- **计划** · [WiseLife 自动 ASR、内容分段与检索 Implementation Plan](superpowers/plans/2026-10-22-long-recording-phase-b-c.md)
- **计划** · [Ten-minute streaming recording Implementation Plan](superpowers/plans/2026-10-22-streaming-recording.md)
- **计划** · [AI recording titles and duration display](../../../docs/superpowers/plans/2026-10-22-ai-recording-titles-duration.md)
- **计划** · [Daily recaps implementation](../../../docs/superpowers/plans/2026-10-22-daily-recaps-native.md)
- **计划** · [每日洞察沿用 AI 配置](../../../docs/superpowers/plans/2026-10-22-insight-ai-providers.md)
- **计划** · [Life Moments Native Implementation Plan](../../../docs/superpowers/plans/2026-10-22-life-moments-native.md)
- **计划** · [External AI confirmation preference](../../../docs/superpowers/plans/2026-10-22-remote-ai-confirmation.md)
- **计划** · [Watch Recording Complication Plan](../../../docs/superpowers/plans/2026-10-22-watch-recording-complication.md)
- **附件** · [build-result.txt](../verification/daily-recaps-native/build-result.txt)
- **验证** · [AI 长录音标题与完整时长](../verification/ai-recording-titles-duration.md)
- **验证** · [每日洞察使用所选 AI](../verification/daily-insights-ai.md)
- **验证** · [今天的片段：原生开发验证](../verification/life-moments-native/README.md)
- **验证** · [今天的片段：原型验证](../verification/life-moments-prototype/README.md)
- **验证** · [录音内容标题：原生实现与验证](../verification/recording-content-titles.md) · 文内更新
- **验证** · [外部 AI 发送确认偏好](../verification/remote-ai-confirmation.md)
- **验证** · [Segmented recording content — software verification](../verification/segmented-asr-content.md)
- **验证** · [长录音分片：阶段 A 验证记录](../verification/segmented-recording.md)
- **验证** · [Watch 表盘快捷录音验证记录](../verification/watch-recording-complication.md)

### 2026-10-21

- **产品** · [WiseLife 闪念资产原型](../prototype/flash-assets-design.md)
- **产品** · [说话人关联联系人与 Apple 提醒事项](../prototype/people-reminders-design.md)
- **开发** · [WiseLife · 我的一天](../README.md) · 文内更新
- **技术** · [Flash Capture 在 WiseLife 闪念语音中的应用研究](2026-10-21-flash-capture-assets-research.md)
- **技术** · [Watch 配对与同步状态](2026-10-21-watch-sync-status.md)
- **计划** · [WiseLife Flash Assets Prototype Plan](../../../docs/superpowers/plans/2026-10-21-flash-assets-prototype.md)
- **计划** · [Native Contacts and Apple Reminders Implementation Plan](../../../docs/superpowers/plans/2026-10-21-people-reminders-native.md)
- **计划** · [Contacts and Apple Reminders Prototype Plan](../../../docs/superpowers/plans/2026-10-21-people-reminders-prototype.md)
- **计划** · [Recording Content Titles Implementation Plan](../../../docs/superpowers/plans/2026-10-21-recording-content-titles.md)
- **验证** · [Flash assets prototype verification](../verification/flash-assets-prototype/README.md)
- **验证** · [说话人联系人与 Apple 提醒事项：实现与验证](../verification/people-reminders-native.md)
- **验证** · [产品原型验证](../verification/people-reminders-prototype/README.md)
- **验证** · [录音内容标题：原生实现与验证](../verification/recording-content-titles.md)

### 2026-10-20

- **产品** · [地点与采集设备：原型评审](../prototype/places-design.md)
- **产品** · [iPhone 设置原型 · 2026-10-18](../prototype/settings-design.md) · 文内更新
- **产品** · [WiseLife product website](../prototype/wiselife-website.md) · 文内更新
- **开发** · [WiseLife · 我的一天](../README.md) · 文内更新
- **技术** · [WiseLife：iCloud 备份数据范围研究](2026-10-19-icloud-backup-research.md) · 文内更新
- **技术** · [采集地点地址解析](2026-10-20-capture-addresses.md)
- **技术** · [地点与采集设备：原生实现](2026-10-20-capture-places.md)
- **技术** · [WiseLife 对话历史与声音档案恢复](2026-10-20-conversation-history-and-voice-recovery.md)
- **技术** · [WiseLife 数据、存储、检索与 AI 架构梳理](2026-10-20-data-storage-retrieval-ai-review.md)
- **技术** · [WiseLife 第二阶段：全文检索与完整分段索引](2026-10-20-fulltext-and-chunk-indexing.md)
- **技术** · [HealthKit 数据更新（2026-10-20）](2026-10-20-health-background.md)
- **技术** · [WiseLife 第一阶段：业务元数据迁移记录](2026-10-20-metadata-sqlite-migration.md)
- **技术** · [Eureka Ring 编译开关](2026-10-20-ring-build-switch.md)
- **技术** · [WiseLife 本地存储与检索](local-storage-and-retrieval.md)
- **技术** · [WiseLife AI 对话历史修复](../../../docs/superpowers/specs/2026-10-20-wiselife-conversation-history-design.md)
- **技术** · [WiseLife 第二阶段：全文检索与完整分段索引](../../../docs/superpowers/specs/2026-10-20-wiselife-fulltext-chunks-design.md)
- **技术** · [WiseLife 第一阶段：业务元数据 SQLite 迁移](../../../docs/superpowers/specs/2026-10-20-wiselife-metadata-sqlite-design.md)
- **计划** · [Sign in with ChatGPT native implementation](../../../docs/superpowers/plans/2026-10-20-chatgpt-native.md)
- **计划** · [Sign in with ChatGPT prototype plan](../../../docs/superpowers/plans/2026-10-20-chatgpt-prototype.md)
- **计划** · [Lock Screen Quick Recording Implementation Plan](../../../docs/superpowers/plans/2026-10-20-lock-screen-recording.md)
- **计划** · [My Voice Native Implementation Plan](../../../docs/superpowers/plans/2026-10-20-my-voice-native.md)
- **计划** · [WiseLife Action button recording](../../../docs/superpowers/plans/2026-10-20-quick-recording.md)
- **计划** · [WiseLife AI Conversation History Implementation Plan](../../../docs/superpowers/plans/2026-10-20-wiselife-conversation-history.md)
- **计划** · [WiseLife Full Text and Complete Chunk Indexing Implementation Plan](../../../docs/superpowers/plans/2026-10-20-wiselife-fulltext-chunks.md)
- **计划** · [WiseLife HealthKit Refresh Implementation Plan](../../../docs/superpowers/plans/2026-10-20-wiselife-health-background.md)
- **计划** · [WiseLife SQLite Metadata Implementation Plan](../../../docs/superpowers/plans/2026-10-20-wiselife-metadata-sqlite.md)
- **计划** · [WiseLife capture places and devices](../../../docs/superpowers/plans/2026-10-20-wiselife-places-native.md)
- **验证** · [ChatGPT browser and loopback verification — 2026-10-20](../verification/chatgpt-loopback.md)
- **验证** · [WiseLife 原生 Sign in with ChatGPT](../verification/chatgpt-native.md)
- **验证** · [ChatGPT OAuth and Responses core verification](../verification/chatgpt-protocol.md)
- **验证** · [Sign in with ChatGPT 原型验证 · 2026-10-20](../verification/chatgpt-prototype/README.md)
- **验证** · [模拟器 AI 设置保存失败](../verification/keychain-simulator.md) · 文内更新
- **验证** · [WiseLife 锁屏快捷录音](../verification/lock-screen-recording.md)
- **验证** · [我的声音：原生实现与验证](../verification/my-voice-native.md)
- **验证** · [“我的声音”原型验证 · 2026-10-20](../verification/my-voice-prototype/README.md)
- **验证** · [WiseLife iPhone 快捷录音](../verification/quick-recording.md)
- **验证** · [Local speaker diarization verification](../verification/speaker-diarization.md)

### 2026-10-19

- **产品** · [WiseLife icon · 观 / The Witness](../design/brand/wiselife-icon-v1/README.md)
- **产品** · [iPhone Day 硬件连接原型](2026-10-19-hardware-prototype-plan.md)
- **产品** · [WiseLife 官网优化：Auday 参考与实施记录](2026-10-19-wiselife-auday-review.md)
- **产品** · [我的一天：24 小时个人记录首页](../prototype/daybook-design.md)
- **产品** · [iPhone 设置原型 · 2026-10-18](../prototype/settings-design.md) · 文内更新
- **发布** · [WiseLife TestFlight 发布记录](testflight-release-2026-10-19.md)
- **开发** · [WiseLife · 我的一天](../README.md) · 文内更新
- **技术** · [WiseLife：iCloud 备份数据范围研究](2026-10-19-icloud-backup-research.md)
- **技术** · [WiseLife 原型与原生 App 功能核对](prototype-completion-audit.md)
- **技术** · [WiseLife local speaker diarization](../../../docs/superpowers/specs/2026-10-19-local-speaker-diarization-design.md)
- **独立项目** · [GT 6 → iPhone 设计与兼容性 · 2026-10-19](../../wrist-notes-huawei/docs/design.md)
- **独立项目** · [GT 6 第三方录音与 iPhone 通信咨询草稿](../../wrist-notes-huawei/docs/huawei-integration-inquiry.md)
- **独立项目** · [本地验证 · 2026-10-19](../../wrist-notes-huawei/docs/verification.md)
- **计划** · [WiseLife prototype completion implementation plan](2026-10-19-prototype-completion-plan.md)
- **计划** · [Local Speaker Diarization Implementation Plan](../../../docs/superpowers/plans/2026-10-19-local-speaker-diarization.md)
- **计划** · [WiseNote native daily companion implementation plan](../../../docs/superpowers/plans/2026-10-19-wisenote-daybook-native.md)
- **计划** · [WiseNote prototype parity correction](../../../docs/superpowers/plans/2026-10-19-wisenote-prototype-parity.md)
- **验证** · [原生界面核对 · 2026-10-18](../verification/README.md) · 文内更新
- **验证** · [每日记录原生升级验证](../verification/daybook-native.md)
- **验证** · [EurekaRing 原生本地接入 · 2026-10-19](../verification/eureka-ring-native.md)
- **验证** · [硬件连接原型验证 · 2026-10-19](../verification/hardware-connection/README.md)
- **验证** · [模拟器 AI 设置保存失败](../verification/keychain-simulator.md)
- **验证** · [原生模型设置与下载验证 · 2026-10-19](../verification/model-downloads.md)
- **验证** · [iPhone 原型对齐与首页统计验证](../verification/prototype-parity.md)
- **验证** · [iPhone 设置与 AI 总结接入 · 2026-10-19](../verification/settings.md)
- **验证** · [WiseLife website refresh verification](../verification/wiselife-website-refresh/README.md)

### 2026-10-18

- **产品** · [iPhone 设置原型 · 2026-10-18](../prototype/settings-design.md)
- **开发** · [WiseLife · 我的一天](../README.md) · 文内更新
- **计划** · [WristNotes Implementation Plan](../IMPLEMENTATION_PLAN.md) · 文内更新
- **验证** · [原生界面核对 · 2026-10-18](../verification/README.md)

### 日期未标注

以下文档保留分类入口，不猜测创建或变更日期。

- **独立项目** · [WristNotes · Huawei](../../wrist-notes-huawei/README.md)
- **独立项目** · [Huawei WristNotes implementation plan](../../wrist-notes-huawei/docs/implementation-plan.md)
- **独立项目** · [设备间录音协议 v1（接入设计）](../../wrist-notes-huawei/docs/transfer-protocol.md)
- **独立项目** · [GT 6 watch core](../../wrist-notes-huawei/watch/README.md)
- **计划** · [Native transcription models and downloads](../MODEL_DOWNLOAD_PLAN.md)
- **计划** · [iPhone 设置与 AI 总结实施计划](../SETTINGS_IMPLEMENTATION_PLAN.md)
- **许可** · [Lucide-LICENSE.txt](../Sources/iPhone/Lucide-LICENSE.txt)
- **许可** · [SpeakerModels-NOTICES.txt](../Sources/iPhone/SpeakerModels-NOTICES.txt)
- **许可** · [VoiceIdentityModels-NOTICES.txt](../Sources/iPhone/VoiceIdentityModels-NOTICES.txt)
- **开发** · [合成音频 fixture](../Tests/Fixtures/README.md)
- **开发** · [Content V2 simulator lab](../Tools/ContentV2Simulator/README.md)
- **许可** · [SQLite Vector Apache 2.0 许可证](../Vendor/SQLiteVector/LICENSE.md)
- **许可** · [SQLite Vector 1.1.2](../Vendor/SQLiteVector/PROVENANCE.md)
- **许可** · [SQLiteVector-NOTICES.txt](../Vendor/SQLiteVector/SQLiteVector-NOTICES.txt)
- **许可** · [FP16 上游 MIT 许可证](../Vendor/SQLiteVector/libs/fp16/LICENSE.upstream)
- **技术** · [Watch → iPhone 小时录音文件传输时序](watch-to-iphone-hourly-recording-sequence.md)
- **产品** · [WiseLife website icon](../prototype/assets/brand/README.md)
- **产品** · [WiseLife · 你的生活，你的个人 AI](../prototype/index-next.html)
- **产品** · [WiseLife · 轻松记录，每天更懂自己](../prototype/iphone-day.html)
- **产品** · [WristNotes · iPhone 语音笔记界面](../prototype/iphone-notes.html)
- **许可** · [lucide-LICENSE.txt](../prototype/lucide-LICENSE.txt)
- **法律** · [隐私政策 · WiseLife](../prototype/privacy/index.html)
- **法律** · [服务条款 · WiseLife](../prototype/terms/index.html)
- **产品** · [WristNotes · Apple Watch 录音界面](../prototype/watch-recorder.html)
- **验证** · [Ask AI 自动范围实施](../verification/ask-ai-auto-scope.md)
- **附件** · [build-result.txt](../verification/daily-insights-ai/build-result.txt)
- **附件** · [build-result.txt](../verification/daily-recap-evidence-authority/build-result.txt)
- **验证** · [每日回顾 / 昨日回顾 — 原生实现验证](../verification/daily-recaps-native.md)
- **附件** · [checks.txt](../verification/life-moments-native/checks.txt)
- **附件** · [local-tests.txt](../verification/model-downloads/local-tests.txt)
- **附件** · [whisper-download.txt](../verification/model-downloads/whisper-download.txt)
- **附件** · [whisper-offline.txt](../verification/model-downloads/whisper-offline.txt)
- **附件** · [daniel-results.txt](../verification/my-voice-native/daniel-results.txt)
- **附件** · [samantha-results.txt](../verification/my-voice-native/samantha-results.txt)
- **验证** · [Streaming long recording verification](../verification/streaming-recording.md)

<a id="modules"></a>

## 4. 按功能模块查找

从一项功能串起“设计 → 技术／计划 → 实施与验证”。这是精选阅读路径；全量文档见其他章节。

| 功能 | 产品／技术入口 | 实施／验证入口 |
| --- | --- | --- |
| 首页、时间轴与详情 | [首页设计](../prototype/daybook-design.md) · [统一管理入口](../prototype/record-management-design.md) | [原型对齐](../verification/prototype-parity.md) · [片段详情](../verification/2026-10-23-segment-detail-ui.md) |
| Watch 录音与传输 | [Watch 原型](../prototype/watch-recorder.html) · [小时文件时序](watch-to-iphone-hourly-recording-sequence.md) · [传输诊断](../../../docs/superpowers/specs/2026-10-28-watch-transfer-diagnostics-design.md) | [分片流水线历史验证](../verification/streaming-recording.md) · [安装诊断](../verification/watch-installation.md) |
| ASR、VAD 与内容分段 | [分段策略](superpowers/specs/2026-10-23-content-segmentation-v2-review.md) · [Apple ASR 回退设计](../../../docs/superpowers/specs/2026-10-27-wiselife-simulator-apple-asr-design.md) | [10 分钟候选阈值](../verification/content-gap-600-2026-10-31.md) · [模型下载](../verification/model-downloads.md) · [重新处理](../verification/recording-reprocess-2026-10-28.md) |
| SQLite、全文与向量 | [数据结构](local-data-schema.md) · [检索架构](local-storage-and-retrieval.md) | [迁移](2026-10-20-metadata-sqlite-migration.md) · [写锁修复](../verification/2026-10-23-sqlite-content-contention.md) · [双语检索实验](../verification/apple-embedding-bilingual-2026-10-31.md) |
| Ask AI、语音输入与历史 | [自动查询范围](../prototype/ai-date-range-design.md) · [历史持久化](../../../docs/superpowers/specs/2026-10-20-wiselife-conversation-history-design.md) · [26.3 会话与工具实现](ask-ai-session-orchestration.md) | [语音输入](../verification/ask-ai-voice-input-2026-10-31.md) · [发送后清空](../verification/ask-ai-composer-clear-2026-10-31.md) · [端上翻译](../verification/apple-query-translation-production-2026-10-31.md) |
| 说话人与我的声音 | [说话人关联](../prototype/people-reminders-design.md) · [分离方案](../../../docs/superpowers/specs/2026-10-19-local-speaker-diarization-design.md) | [Speaker Ask](../verification/speaker-ask-2026-10-31.md) · [声音登记](../verification/my-voice-native.md) |
| 每日回顾、标题与摘要 | [AI Prompt 目录](ai-prompts.md) · [每日回顾](../../../docs/superpowers/specs/2026-10-22-daily-recaps-design.md) · [摘要预算](superpowers/specs/2026-10-24-adaptive-content-summary-budget-design.md) | [一次自动生成](../verification/2026-10-23-daily-recap-once.md) · [证据权重](../verification/daily-recap-evidence-authority.md) · [标题时长](../verification/ai-recording-titles-duration.md) |
| 地点、HealthKit 与生活片段 | [地点与设备](../prototype/places-design.md) · [生活片段](../prototype/life-moments-design.md) · [健康更新](2026-10-20-health-background.md) | [GPS 真机记录](../verification/2026-10-23-recording-location-content-device.md) · [运动记录](../verification/health-workouts-2026-10-25.md) |
| 闪念、联系人与行动 | [闪念资产](../prototype/flash-assets-design.md) · [联系人与提醒](../prototype/people-reminders-design.md) | [联系人与提醒实现](../verification/people-reminders-native.md) · [行动 Tab](../verification/actions-native.md) |
| 设置、模型与隐私 | [设置层级](superpowers/plans/2026-10-31-settings-navigation.md) · [隐私政策](../prototype/privacy/index.html) | [设置验证](../verification/settings-hierarchy-2026-10-31.md) · [模型独立配置](../verification/ai-provider-configurations-2026-10-25.md) · [发送确认](../verification/remote-ai-confirmation.md) |
| 快捷录音、Siri 与锁屏 | [Siri 查询](../../../docs/superpowers/specs/2026-10-29-wiselife-siri-local-query-design.md) · [Watch 表盘](../../../docs/superpowers/specs/2026-10-22-watch-recording-complication-design.md) | [快捷录音](../verification/quick-recording.md) · [锁屏录音](../verification/lock-screen-recording.md) · [表盘验收边界](../verification/watch-recording-complication.md) |
| EurekaRing、Mac 与发布 | [Ring 编译开关](2026-10-20-ring-build-switch.md) · [Mac 方案](superpowers/specs/2026-10-23-wiselife-mac-mlx-companion-design.md) | [Mac 接入](../verification/nearby-mac-iphone-2026-10-25.md) · [Ring 历史验证](../verification/eureka-ring-native.md) · [TestFlight](testflight-release-2026-10-19.md) |

<a id="verification"></a>

## 5. 验证、开发与发布

### 5.1 实施与验证记录

编译、自动测试、模拟器交互、真机和发布各有独立范围；结论以每份记录中的明确证据和未验证项为准。

| 文档 | 文档标注日期 | 阅读提示 |
| --- | --- | --- |
| [Content chapters implementation — 2026-10-23](../verification/2026-10-23-content-chapters-implementation.md) | 2026-10-23 | 当次实施与验证记录；通过范围及限制见原文 |
| [每日回顾：每天仅自动尝试一次](../verification/2026-10-23-daily-recap-once.md) | 2026-10-23 | 当次实施与验证记录；通过范围及限制见原文 |
| [内容片段持久化与回顾刷新修复](../verification/2026-10-23-persisted-timeline-recap-refresh.md) | 2026-10-23 | 当次实施与验证记录；通过范围及限制见原文 |
| [6 小时 42 分录音：真机数据与 Mac 分段实测](../verification/2026-10-23-real-recording-mac-audit.md) | 2026-10-23 | 当次实施与验证记录；通过范围及限制见原文 |
| [GPS / 内容分段：真机安装与测试](../verification/2026-10-23-recording-location-content-device.md) | 2026-10-23 | 当次实施与验证记录；通过范围及限制见原文 |
| [长录音 GPS 与内容分段更新：开发与验证](../verification/2026-10-23-recording-location-content.md) | 2026-10-23 | 当次实施与验证记录；通过范围及限制见原文 |
| [Recording locations implementation — 2026-10-23](../verification/2026-10-23-recording-locations-implementation.md) | 2026-10-23 | 当次实施与验证记录；通过范围及限制见原文 |
| [内容片段详情与首页摘要修复](../verification/2026-10-23-segment-detail-ui.md) | 2026-10-23 | 当次实施与验证记录；通过范围及限制见原文 |
| [真机内容片段处理状态检查](../verification/2026-10-23-segment-processing-ui.md) | 2026-10-23 | 当次实施与验证记录；通过范围及限制见原文 |
| [6h42m recording: simulator content v2 pilot](../verification/2026-10-23-simulator-content-v2.md) | 2026-10-23 | 当次实施与验证记录；通过范围及限制见原文 |
| [长录音分段引发 SQLite 写锁：修复与真机验证](../verification/2026-10-23-sqlite-content-contention.md) | 2026-10-23 | 当次实施与验证记录；通过范围及限制见原文 |
| [首页与我的记录周期性加载修复](../verification/2026-10-23-timeline-refresh.md) | 2026-10-23 | 当次实施与验证记录；通过范围及限制见原文 |
| [原生界面核对 · 2026-10-18](../verification/README.md) | 2026-10-18 | 2026-10-18 界面核对历史；并非全部验证的目录 |
| [行动 Tab 原生实现 · 2026-10-23](../verification/actions-native.md) | 2026-10-23 | 当次实施与验证记录；通过范围及限制见原文 |
| [Independent AI provider settings](../verification/ai-provider-configurations-2026-10-25.md) | 2026-10-25 | 当次实施与验证记录；通过范围及限制见原文 |
| [AI 长录音标题与完整时长](../verification/ai-recording-titles-duration.md) | 2026-10-22 | 当次实施与验证记录；通过范围及限制见原文 |
| [Settings version and release time](../verification/app-release-info-2026-10-26.md) | 2026-10-26 | 当次实施与验证记录；通过范围及限制见原文 |
| [Apple embedding 中英文检索实验](../verification/apple-embedding-bilingual-2026-10-31.md) | 2026-10-31 | 当次实施与验证记录；通过范围及限制见原文 |
| [Apple 端上翻译 + 本地语义检索实验](../verification/apple-query-translation-2026-10-31.md) | 2026-10-31 | 当次实施与验证记录；通过范围及限制见原文 |
| [Apple 端上翻译与语义检索：正式 App 接入](../verification/apple-query-translation-production-2026-10-31.md) | 2026-10-31 | 当次实施与验证记录；通过范围及限制见原文 |
| [Ask AI 自动范围实施](../verification/ask-ai-auto-scope.md) | 未标注 | 当次实施与验证记录；通过范围及限制见原文 |
| [Ask AI 输入框发送后清空](../verification/ask-ai-composer-clear-2026-10-31.md) | 2026-10-31 | 当次实施与验证记录；通过范围及限制见原文 |
| [Ask AI native voice input — 2026-10-31](../verification/ask-ai-voice-input-2026-10-31.md) | 2026-10-31 | 当次实施与验证记录；通过范围及限制见原文 |
| [ChatGPT browser and loopback verification — 2026-10-20](../verification/chatgpt-loopback.md) | 2026-10-20 | 当次实施与验证记录；通过范围及限制见原文 |
| [WiseLife 原生 Sign in with ChatGPT](../verification/chatgpt-native.md) | 2026-10-20 | 当次实施与验证记录；通过范围及限制见原文 |
| [ChatGPT OAuth and Responses core verification](../verification/chatgpt-protocol.md) | 2026-10-20 | 当次实施与验证记录；通过范围及限制见原文 |
| [Sign in with ChatGPT 原型验证 · 2026-10-20](../verification/chatgpt-prototype/README.md) | 2026-10-20 | 当次实施与验证记录；通过范围及限制见原文 |
| [10 分钟空白候选阈值 · 2026-10-31](../verification/content-gap-600-2026-10-31.md) | 2026-10-31 | 当次实施与验证记录；通过范围及限制见原文 |
| [每日洞察使用所选 AI](../verification/daily-insights-ai.md) | 2026-10-22 | 当次实施与验证记录；通过范围及限制见原文 |
| [昨日 / 每日回顾：证据权重与行动建议](../verification/daily-recap-evidence-authority.md) | 2026-10-23 | 当次实施与验证记录；通过范围及限制见原文 |
| [每日回顾 / 昨日回顾 — 原生实现验证](../verification/daily-recaps-native.md) | 未标注 | 当次实施与验证记录；通过范围及限制见原文 |
| [每日记录原生升级验证](../verification/daybook-native.md) | 2026-10-19 | 当次实施与验证记录；通过范围及限制见原文 |
| [EurekaRing 原生本地接入 · 2026-10-19](../verification/eureka-ring-native.md) | 2026-10-19 | 当次实施与验证记录；通过范围及限制见原文 |
| [Flash assets prototype verification](../verification/flash-assets-prototype/README.md) | 2026-10-31 | 当次实施与验证记录；通过范围及限制见原文 |
| [硬件连接原型验证 · 2026-10-19](../verification/hardware-connection/README.md) | 2026-10-19 | 当次实施与验证记录；通过范围及限制见原文 |
| [HealthKit workout records](../verification/health-workouts-2026-10-25.md) | 2026-10-25 | 当次实施与验证记录；通过范围及限制见原文 |
| [键盘交互与待保存录音验证 · 2026-10-31](../verification/keyboard-and-pending-recording-2026-10-31.md) | 2026-10-31 | 当次实施与验证记录；通过范围及限制见原文 |
| [模拟器 API Key 读取恢复 · 2026-10-31](../verification/keychain-installation-2026-10-31.md) | 2026-10-31 | 当次实施与验证记录；通过范围及限制见原文 |
| [模拟器 AI 设置保存失败](../verification/keychain-simulator.md) | 2026-10-19 | 当次实施与验证记录；通过范围及限制见原文 |
| [今天的片段：原生开发验证](../verification/life-moments-native/README.md) | 2026-10-22 | 当次实施与验证记录；通过范围及限制见原文 |
| [今天的片段：原型验证](../verification/life-moments-prototype/README.md) | 2026-10-22 | 当次实施与验证记录；通过范围及限制见原文 |
| [WiseLife 锁屏快捷录音](../verification/lock-screen-recording.md) | 2026-10-20 | 当次实施与验证记录；通过范围及限制见原文 |
| [原生模型设置与下载验证 · 2026-10-19](../verification/model-downloads.md) | 2026-10-19 | 当次实施与验证记录；通过范围及限制见原文 |
| [我的声音：原生实现与验证](../verification/my-voice-native.md) | 2026-10-20 | 当次实施与验证记录；通过范围及限制见原文 |
| [“我的声音”原型验证 · 2026-10-20](../verification/my-voice-prototype/README.md) | 2026-10-20 | 当次实施与验证记录；通过范围及限制见原文 |
| [iPhone nearby Mac LLM integration — 2026-10-25](../verification/nearby-mac-iphone-2026-10-25.md) | 2026-10-25 | 当次实施与验证记录；通过范围及限制见原文 |
| [说话人联系人与 Apple 提醒事项：实现与验证](../verification/people-reminders-native.md) | 2026-10-21 | 当次实施与验证记录；通过范围及限制见原文 |
| [产品原型验证](../verification/people-reminders-prototype/README.md) | 2026-10-21 | 当次实施与验证记录；通过范围及限制见原文 |
| [iPhone 原型对齐与首页统计验证](../verification/prototype-parity.md) | 2026-10-19 | 当次实施与验证记录；通过范围及限制见原文 |
| [WiseLife iPhone 快捷录音](../verification/quick-recording.md) | 2026-10-20 | 当次实施与验证记录；通过范围及限制见原文 |
| [录音内容标题：原生实现与验证](../verification/recording-content-titles.md) | 2026-10-21 | 当次实施与验证记录；通过范围及限制见原文 |
| [原始录音重新处理修复验证](../verification/recording-reprocess-2026-10-28.md) | 2026-10-28 | 当次实施与验证记录；通过范围及限制见原文 |
| [外部 AI 发送确认偏好](../verification/remote-ai-confirmation.md) | 2026-10-22 | 当次实施与验证记录；通过范围及限制见原文 |
| [Segmented recording content — software verification](../verification/segmented-asr-content.md) | 2026-10-22 | 当次实施与验证记录；通过范围及限制见原文 |
| [长录音分片：阶段 A 验证记录](../verification/segmented-recording.md) | 2026-10-22 | 当次实施与验证记录；通过范围及限制见原文 |
| [Settings hierarchy alignment — 2026-10-31](../verification/settings-hierarchy-2026-10-31.md) | 2026-10-31 | 当次实施与验证记录；通过范围及限制见原文 |
| [iPhone 设置与 AI 总结接入 · 2026-10-19](../verification/settings.md) | 2026-10-19 | 当次实施与验证记录；通过范围及限制见原文 |
| [Ask AI：Kate Bell 关联发言检索修复](../verification/speaker-ask-2026-10-31.md) | 2026-10-31 | 当次实施与验证记录；通过范围及限制见原文 |
| [Local speaker diarization verification](../verification/speaker-diarization.md) | 2026-10-20 | 当次实施与验证记录；通过范围及限制见原文 |
| [Streaming long recording verification](../verification/streaming-recording.md) | 未标注 | 当次实施与验证记录；通过范围及限制见原文 |
| [Watch 安装诊断（2026-10-23）](../verification/watch-installation.md) | 2026-10-23 | 当次实施与验证记录；通过范围及限制见原文 |
| [Watch 表盘快捷录音验证记录](../verification/watch-recording-complication.md) | 2026-10-22 | 当次实施与验证记录；通过范围及限制见原文 |
| [WiseLife website refresh verification](../verification/wiselife-website-refresh/README.md) | 2026-10-19 | 当次实施与验证记录；通过范围及限制见原文 |

### 5.2 开发、实验工具与发布

| 文档 | 文档标注日期 | 阅读提示 |
| --- | --- | --- |
| [WiseLife · 我的一天](../README.md) | 未标注 | 开发与使用入口 |
| [合成音频 fixture](../Tests/Fixtures/README.md) | 未标注 | 开发与使用入口 |
| [Content V2 simulator lab](../Tools/ContentV2Simulator/README.md) | 未标注 | 分段实验工具说明；历史接入状态需与后续文档对照 |

| 文档 | 文档标注日期 | 阅读提示 |
| --- | --- | --- |
| [WiseLife TestFlight 发布记录](testflight-release-2026-10-19.md) | 2026-10-19 | 历史发布过程与验收记录 |

### 5.3 文字验证附件

截图、日志和媒体不复制到索引；优先从相邻验证文档进入。以下为项目内已有 TXT 附件。

| 文档 | 文档标注日期 | 阅读提示 |
| --- | --- | --- |
| [build-result.txt](../verification/daily-insights-ai/build-result.txt) | 未标注 | 测试输出附件；配合上级验证说明阅读 |
| [build-result.txt](../verification/daily-recap-evidence-authority/build-result.txt) | 未标注 | 测试输出附件；配合上级验证说明阅读 |
| [build-result.txt](../verification/daily-recaps-native/build-result.txt) | 2026-10-22 | 测试输出附件；配合上级验证说明阅读 |
| [checks.txt](../verification/life-moments-native/checks.txt) | 未标注 | 测试输出附件；配合上级验证说明阅读 |
| [local-tests.txt](../verification/model-downloads/local-tests.txt) | 未标注 | 测试输出附件；配合上级验证说明阅读 |
| [whisper-download.txt](../verification/model-downloads/whisper-download.txt) | 未标注 | 测试输出附件；配合上级验证说明阅读 |
| [whisper-offline.txt](../verification/model-downloads/whisper-offline.txt) | 未标注 | 测试输出附件；配合上级验证说明阅读 |
| [daniel-results.txt](../verification/my-voice-native/daniel-results.txt) | 未标注 | 测试输出附件；配合上级验证说明阅读 |
| [samantha-results.txt](../verification/my-voice-native/samantha-results.txt) | 未标注 | 测试输出附件；配合上级验证说明阅读 |

<a id="other"></a>

## 6. 实施计划、历史与其他资料

项目级规范：[项目文档生成与维护规则](../../../docs/documentation-rules.md)（2026-10-31，版本 1.0，本仓库已采用），涵盖当前说明、任务记录、变更索引与 Superpowers 配合方式。

### 6.1 全部实施计划

计划记录任务拆分与预期验证；完成情况需结合对应验证文档和代码确认。

| 文档 | 文档标注日期 | 阅读提示 |
| --- | --- | --- |
| [WristNotes Implementation Plan](../IMPLEMENTATION_PLAN.md) | 未标注 | 实施计划；不单独作为完成或发布证明 |
| [Native transcription models and downloads](../MODEL_DOWNLOAD_PLAN.md) | 未标注 | 实施计划；不单独作为完成或发布证明 |
| [iPhone 设置与 AI 总结实施计划](../SETTINGS_IMPLEMENTATION_PLAN.md) | 未标注 | 实施计划；不单独作为完成或发布证明 |
| [WiseLife prototype completion implementation plan](2026-10-19-prototype-completion-plan.md) | 2026-10-19 | 实施计划；不单独作为完成或发布证明 |
| [WiseLife 长录音阶段 A Implementation Plan](superpowers/plans/2026-10-22-long-recording-phase-a.md) | 2026-10-22 | 实施计划；不单独作为完成或发布证明 |
| [WiseLife 自动 ASR、内容分段与检索 Implementation Plan](superpowers/plans/2026-10-22-long-recording-phase-b-c.md) | 2026-10-22 | 实施计划；不单独作为完成或发布证明 |
| [Ten-minute streaming recording Implementation Plan](superpowers/plans/2026-10-22-streaming-recording.md) | 2026-10-22 | 实施计划；不单独作为完成或发布证明 |
| [Action Tab Implementation Plan](superpowers/plans/2026-10-23-actions-native.md) | 2026-10-23 | 实施计划；不单独作为完成或发布证明 |
| [Persisted content timeline](superpowers/plans/2026-10-23-persisted-content-timeline.md) | 2026-10-23 | 实施计划；不单独作为完成或发布证明 |
| [Long recording locations and content chapters](superpowers/plans/2026-10-23-recording-location-content.md) | 2026-10-23 | 实施计划；不单独作为完成或发布证明 |
| [Simulator Content V2 Implementation Plan](superpowers/plans/2026-10-23-simulator-content-v2.md) | 2026-10-23 | 实施计划；不单独作为完成或发布证明 |
| [Adaptive Content Summary Budget Implementation Plan](superpowers/plans/2026-10-24-adaptive-content-summary-budget.md) | 2026-10-24 | 实施计划；不单独作为完成或发布证明 |
| [Final content timeline readiness implementation plan](superpowers/plans/2026-10-24-content-timeline-readiness.md) | 2026-10-24 | 实施计划；不单独作为完成或发布证明 |
| [Production Content Segmentation V2 Routing Implementation Plan](superpowers/plans/2026-10-24-production-content-v2-routing.md) | 2026-10-24 | 实施计划；不单独作为完成或发布证明 |
| [Feature Implementation Plan](superpowers/plans/2026-10-25-long-recording-phone-chunks.md) | 2026-10-25 | 实施计划；不单独作为完成或发布证明 |
| [Speaker Ask and Contact Records Implementation Plan](superpowers/plans/2026-10-30-speaker-ask-contact-implementation.md) | 2026-10-30 | 实施计划；不单独作为完成或发布证明 |
| [Local Query Translation Experiment Plan](superpowers/plans/2026-10-31-local-query-translation-experiment.md) | 2026-10-31 | 实施计划；不单独作为完成或发布证明 |
| [Apple local query translation: production integration](superpowers/plans/2026-10-31-local-query-translation-production.md) | 2026-10-31 | 实施计划；不单独作为完成或发布证明 |
| [Settings navigation adjustment](superpowers/plans/2026-10-31-settings-navigation.md) | 2026-10-31 | 实施计划；不单独作为完成或发布证明 |
| [Local Speaker Diarization Implementation Plan](../../../docs/superpowers/plans/2026-10-19-local-speaker-diarization.md) | 2026-10-19 | 实施计划；不单独作为完成或发布证明 |
| [WiseNote native daily companion implementation plan](../../../docs/superpowers/plans/2026-10-19-wisenote-daybook-native.md) | 2026-10-19 | 实施计划；不单独作为完成或发布证明 |
| [WiseNote prototype parity correction](../../../docs/superpowers/plans/2026-10-19-wisenote-prototype-parity.md) | 2026-10-19 | 实施计划；不单独作为完成或发布证明 |
| [Sign in with ChatGPT native implementation](../../../docs/superpowers/plans/2026-10-20-chatgpt-native.md) | 2026-10-20 | 实施计划；不单独作为完成或发布证明 |
| [Sign in with ChatGPT prototype plan](../../../docs/superpowers/plans/2026-10-20-chatgpt-prototype.md) | 2026-10-20 | 实施计划；不单独作为完成或发布证明 |
| [Lock Screen Quick Recording Implementation Plan](../../../docs/superpowers/plans/2026-10-20-lock-screen-recording.md) | 2026-10-20 | 实施计划；不单独作为完成或发布证明 |
| [My Voice Native Implementation Plan](../../../docs/superpowers/plans/2026-10-20-my-voice-native.md) | 2026-10-20 | 实施计划；不单独作为完成或发布证明 |
| [WiseLife Action button recording](../../../docs/superpowers/plans/2026-10-20-quick-recording.md) | 2026-10-20 | 实施计划；不单独作为完成或发布证明 |
| [WiseLife AI Conversation History Implementation Plan](../../../docs/superpowers/plans/2026-10-20-wiselife-conversation-history.md) | 2026-10-20 | 实施计划；不单独作为完成或发布证明 |
| [WiseLife Full Text and Complete Chunk Indexing Implementation Plan](../../../docs/superpowers/plans/2026-10-20-wiselife-fulltext-chunks.md) | 2026-10-20 | 实施计划；不单独作为完成或发布证明 |
| [WiseLife HealthKit Refresh Implementation Plan](../../../docs/superpowers/plans/2026-10-20-wiselife-health-background.md) | 2026-10-20 | 实施计划；不单独作为完成或发布证明 |
| [WiseLife SQLite Metadata Implementation Plan](../../../docs/superpowers/plans/2026-10-20-wiselife-metadata-sqlite.md) | 2026-10-20 | 实施计划；不单独作为完成或发布证明 |
| [WiseLife capture places and devices](../../../docs/superpowers/plans/2026-10-20-wiselife-places-native.md) | 2026-10-20 | 实施计划；不单独作为完成或发布证明 |
| [WiseLife Flash Assets Prototype Plan](../../../docs/superpowers/plans/2026-10-21-flash-assets-prototype.md) | 2026-10-21 | 实施计划；不单独作为完成或发布证明 |
| [Native Contacts and Apple Reminders Implementation Plan](../../../docs/superpowers/plans/2026-10-21-people-reminders-native.md) | 2026-10-21 | 实施计划；不单独作为完成或发布证明 |
| [Contacts and Apple Reminders Prototype Plan](../../../docs/superpowers/plans/2026-10-21-people-reminders-prototype.md) | 2026-10-21 | 实施计划；不单独作为完成或发布证明 |
| [Recording Content Titles Implementation Plan](../../../docs/superpowers/plans/2026-10-21-recording-content-titles.md) | 2026-10-21 | 实施计划；不单独作为完成或发布证明 |
| [AI recording titles and duration display](../../../docs/superpowers/plans/2026-10-22-ai-recording-titles-duration.md) | 2026-10-22 | 实施计划；不单独作为完成或发布证明 |
| [Daily recaps implementation](../../../docs/superpowers/plans/2026-10-22-daily-recaps-native.md) | 2026-10-22 | 实施计划；不单独作为完成或发布证明 |
| [每日洞察沿用 AI 配置](../../../docs/superpowers/plans/2026-10-22-insight-ai-providers.md) | 2026-10-22 | 实施计划；不单独作为完成或发布证明 |
| [Life Moments Native Implementation Plan](../../../docs/superpowers/plans/2026-10-22-life-moments-native.md) | 2026-10-22 | 实施计划；不单独作为完成或发布证明 |
| [External AI confirmation preference](../../../docs/superpowers/plans/2026-10-22-remote-ai-confirmation.md) | 2026-10-22 | 实施计划；不单独作为完成或发布证明 |
| [Watch Recording Complication Plan](../../../docs/superpowers/plans/2026-10-22-watch-recording-complication.md) | 2026-10-22 | 实施计划；不单独作为完成或发布证明 |
| [每日回顾证据权重与行动建议](../../../docs/superpowers/plans/2026-10-23-recap-evidence-authority.md) | 2026-10-23 | 实施计划；不单独作为完成或发布证明 |
| [WiseLife Watch Background Transfer Status Implementation Plan](../../../docs/superpowers/plans/2026-10-23-watch-background-transfer-status.md) | 2026-10-23 | 实施计划；不单独作为完成或发布证明 |
| [WiseLife Companion Website Teaser Implementation Plan](../../../docs/superpowers/plans/2026-10-23-wiselife-companion-teaser.md) | 2026-10-23 | 实施计划；不单独作为完成或发布证明 |
| [WiseLife Apple ASR Engine Fallback Implementation Plan](../../../docs/superpowers/plans/2026-10-27-wiselife-apple-asr-fallback.md) | 2026-10-27 | 实施计划；不单独作为完成或发布证明 |
| [Watch M4A Metadata and Recovery Implementation Plan](../../../docs/superpowers/plans/2026-10-28-watch-m4a-metadata-recovery.md) | 2026-10-28 | 实施计划；不单独作为完成或发布证明 |
| [Watch 与 iPhone 整文件传输清理计划](../../../docs/superpowers/plans/2026-10-28-watch-transfer-diagnostics.md) | 2026-10-28 | 实施计划；不单独作为完成或发布证明 |
| [WiseLife Siri 本地查询 Implementation Plan](../../../docs/superpowers/plans/2026-10-29-wiselife-siri-local-query.md) | 2026-10-29 | 实施计划；不单独作为完成或发布证明 |
| [WiseLife Sliding Group Audio Processing Implementation Plan](../../../docs/superpowers/plans/2026-10-29-wiselife-sliding-group-processing.md) | 2026-10-29 | 实施计划；不单独作为完成或发布证明 |
| [Ask AI voice input implementation plan](../../../docs/superpowers/plans/2026-10-31-ask-ai-voice-input.md) | 2026-10-31 | 实施计划；不单独作为完成或发布证明 |
| [Shared keyboard interaction](../../../docs/superpowers/plans/2026-10-31-shared-keyboard-interaction.md) | 2026-10-31 | 实施计划；不单独作为完成或发布证明 |

### 6.2 第三方来源与许可证

| 文档 | 文档标注日期 | 阅读提示 |
| --- | --- | --- |
| [Lucide-LICENSE.txt](../Sources/iPhone/Lucide-LICENSE.txt) | 未标注 | 来源或许可声明 |
| [SpeakerModels-NOTICES.txt](../Sources/iPhone/SpeakerModels-NOTICES.txt) | 未标注 | 来源或许可声明 |
| [VoiceIdentityModels-NOTICES.txt](../Sources/iPhone/VoiceIdentityModels-NOTICES.txt) | 未标注 | 来源或许可声明 |
| [SQLite Vector Apache 2.0 许可证](../Vendor/SQLiteVector/LICENSE.md) | 未标注 | 来源或许可声明 |
| [SQLite Vector 1.1.2](../Vendor/SQLiteVector/PROVENANCE.md) | 未标注 | 来源或许可声明 |
| [SQLiteVector-NOTICES.txt](../Vendor/SQLiteVector/SQLiteVector-NOTICES.txt) | 未标注 | 来源或许可声明 |
| [FP16 上游 MIT 许可证](../Vendor/SQLiteVector/libs/fp16/LICENSE.upstream) | 未标注 | 来源或许可声明 |
| [lucide-LICENSE.txt](../prototype/lucide-LICENSE.txt) | 未标注 | 来源或许可声明 |

### 6.3 法律页面

| 文档 | 文档标注日期 | 阅读提示 |
| --- | --- | --- |
| [隐私政策 · WiseLife](../prototype/privacy/index.html) | 未标注 | 产品法律页面 |
| [服务条款 · WiseLife](../prototype/terms/index.html) | 未标注 | 产品法律页面 |

### 6.4 独立 Huawei 项目参考

这是独立工程和数据沙盒，仅作同产品方向的扩展参考；其中的设备能力限制不等同于 Apple 版。

| 文档 | 文档标注日期 | 阅读提示 |
| --- | --- | --- |
| [WristNotes · Huawei](../../wrist-notes-huawei/README.md) | 未标注 | 独立 Huawei 项目；能力和验收不等同 Apple 版 |
| [GT 6 → iPhone 设计与兼容性 · 2026-10-19](../../wrist-notes-huawei/docs/design.md) | 2026-10-19 | 独立 Huawei 项目；能力和验收不等同 Apple 版 |
| [GT 6 第三方录音与 iPhone 通信咨询草稿](../../wrist-notes-huawei/docs/huawei-integration-inquiry.md) | 2026-10-19 | 独立 Huawei 项目；能力和验收不等同 Apple 版 |
| [Huawei WristNotes implementation plan](../../wrist-notes-huawei/docs/implementation-plan.md) | 未标注 | 独立 Huawei 项目；能力和验收不等同 Apple 版 |
| [设备间录音协议 v1（接入设计）](../../wrist-notes-huawei/docs/transfer-protocol.md) | 未标注 | 独立 Huawei 项目；能力和验收不等同 Apple 版 |
| [本地验证 · 2026-10-19](../../wrist-notes-huawei/docs/verification.md) | 2026-10-19 | 独立 Huawei 项目；能力和验收不等同 Apple 版 |
| [GT 6 watch core](../../wrist-notes-huawei/watch/README.md) | 未标注 | 独立 Huawei 项目；能力和验收不等同 Apple 版 |

### 6.5 历史方案阅读提醒

- `iphone-notes.html` 是早期语音笔记页面；现在的 WiseLife 主原型入口是 `iphone-day.html`。`index-next.html` 是备选官网。
- `verification/README.md` 是 10 月 18 日的历史验收记录，不是当前验证总目录。
- 录音保存粒度与内容分隔门槛是两个参数。历史资料出现过 5 分钟、10 分钟、小时文件及 3 分钟 ASR 空白候选，查阅时需核对文档阶段。600 秒候选阈值的本轮变更见 [10/31 验证](../verification/content-gap-600-2026-10-31.md)。
- 数据结构和旧实验说明可能保留历史代码位置、接入状态与测试限制；本索引只整理入口，没有重新认证全部文档的当前有效性。

### 6.6 维护约定

1. 新增文档时同步加入对应分类、日期入口及必要的功能阅读路径；跨目录文件保持相对链接。
2. 每份新文档建议注明：日期、所属模块、文档类型（设计／计划／实验／验证／发布）、适用平台、关联设计／验证、被替代关系。
3. 无明确日期填“未标注”；不要用文件修改时间充当变更日期。
4. 更新规则时在旧文档注明后继文档，保留历史实验和验收证据。
5. 定期核对清单覆盖、链接存在和日期来源。若以后增加 HTML，只从同一份目录元数据生成。

### 收录统计

| 类别 | 数量 |
| --- | ---: |
| 产品／原型／品牌 | 22 |
| 技术／研究／架构 | 32 |
| 实施与验证 | 63 |
| 开发入口／工具 | 3 |
| 发布 | 1 |
| TXT 验证附件 | 9 |
| 实施计划 | 53 |
| 第三方许可与来源 | 8 |
| 法律页面 | 2 |
| Huawei 独立项目参考 | 7 |
| 项目文档规范 | 1 |
| 官网迁移说明 | 1 |
| **收录文档合计** | **202** |

本索引为另新增的目录文件，不计入上表。目录间重复引用不重复计数。
