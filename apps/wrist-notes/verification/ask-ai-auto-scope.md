# Ask AI 自动范围实施

批准依据：prototype/ai-date-range-design.md 与本轮用户开发指令。

边界：iPhone 原生导航、Ask AI 视图/检索/加载与对应测试。保留其他工作区改动，不提交或推送。

实施顺序：
1. 自动时间解析与权限内检索，保留每日回顾等单日调用兼容。
2. 按解析范围加载持久化资料；软性最近范围无匹配时扩大，明确时间不扩展。
3. 保持连续历史、引用稳定 ID、权限及发送前确认，显示范围和引用日期。
4. 移除 AI 日期入口、隐藏洞察并暂停主动洞察，保留每日回顾。
5. 运行检索/对话回归与 iPhone workspace 模拟器构建。

实现方式：本机时间解析和关键词/语义检索自动选择证据范围，模型基于有限原文摘录回答；不将全部数据发送给模型，不让远程模型绕过授权自行调用资料。

## 已落实

- 原生底部导航隐藏洞察，首页主动建议暂停，洞察自动生成暂停；每日回顾保留。
- AI 日期选择入口移除，推荐问题及说明改为自动查找。
- 支持明确单日、起止日期、上周/本周、上个月/本月、近期与跨时间检索。
- 模糊近期默认 7 天，没有匹配时重新加载更早的本机资料；明确日期及「过去7天」不自动扩大。
- 「只看上周」「再往前找找」等追问沿用前文主题，旧回答只能提供意图背景，事实重新从当前资料取证。
- 引用包含完整日期，范围说明含实际引用日期。原有上下文/摘录上限、语义检索、稳定来源 ID、权限校验与远程确认保留。
- 使用持久化范围加载覆盖全部来源；来源修订、编辑、删除与存储可用性变化使跨日期缓存失效。
- 修复 test_conversations.sh 缺少既有 VoiceNote/NoteRepository 编译依赖的问题。

## 验证结果

- `sh apps/wrist-notes/scripts/test_conversations.sh`：通过；新增自动范围、跨日、权限、软范围二次加载/硬范围不扩展检查，现有持久化、撤权、取消、语义竞争及远程确认回归通过。
- `sh apps/wrist-notes/scripts/test_daily_recaps.sh`：通过；资料/SQLite、协调器授权/过期结果/重试、服务分批/引用检查通过，使用 stub transport，无真实网络调用。
- 原生模拟器 workspace 构建：见本轮执行结果；未进行真机操作或真实 AI 服务端到端验证。

## 实际能力边界

自动选择资料由本机日期解析、关键词及可用的语义索引完成，再由配置的模型回答。不是让远程模型获得数据库访问权限或进行无限制工具调用。复杂或未覆盖的自然语言时间表达仍可能需要用户明确日期。跨时间查询会在本机加载相应记录，但模型仅接收有上限的摘录；大规模资料的加载性能尚未做压力验证。

最终构建：`xcodebuild -workspace apps/wrist-notes/WristNotes.xcworkspace -scheme WristNotes -configuration Debug -destination 'generic/platform=iOS Simulator' -derivedDataPath /private/tmp/wiselife-quick-recording-build CODE_SIGNING_ALLOWED=NO build` 退出码 0，`BUILD SUCCEEDED`。
