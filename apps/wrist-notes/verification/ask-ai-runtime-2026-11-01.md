---
type: verification
status: simulator-personalization-partial
updated: 2026-11-01
scope: WiseLife Ask AI 首期运行时；iOS 26.3
related:
  - ../docs/ask-ai-session-orchestration.md
  - ../docs/superpowers/plans/2026-11-01-ask-ai-runtime.md
---

# Ask AI 运行时验证

> 最新状态：下方保留前期自动验证事实；2026-11-01 晚已追加[模拟器真实模型验收](#simulator-personalization)及[真机误取消排查](#device-cancellation)。个性化目标未全部通过；各阶段验证状态单独记录。

用户于 2026-11-01 回复“同意”批准实施。现有 dirty 工作区已完整保留，在隔离快照开发，修改按文件与原始 SHA256 比较后回写；未提交、推送、安装或发布。

## 范围与环境

macOS、Xcode 26.3（17C529）、Swift 6.2.4；iPhoneOS/iPhoneSimulator SDK 26.2。使用合成 DayRecord、临时 SQLite、脚本驱动、URLProtocol 拦截请求和本地 HTML；不读取用户录音/数据库/API Key，不向真实模型服务请求。

参考：[主要说明与首期边界](../docs/ask-ai-session-orchestration.md)、[产品原型](../prototype/iphone-day.html)。

## 已获得的验证结果

| 检查 | 结果与覆盖 |
| --- | --- |
| runtime 存储/上下文 | 通过；混合文本预算、问题意图记忆、迁移/重开、旧 attempt 拒绝、同轮成功发布、重启中断、权限/清空后防迟到缓存写回 |
| 只读工具 | 通过；范围/人物隔离、合法引用、窗口边界、未知参数、6 次上限、结构化指标及 missing/partial |
| 范围索引 | 完整 semantic suite 通过；A→B→A 保留缓存；翻译挂起时同 UUID 宽范围替换的 RED 可复现，修复后窄查询不读范围外正文 |
| 浏览器原型 | Chromium/Playwright 通过；发送即清空、停止/同轮重试、草稿保留、初次取消保留历史、补充资料确认，pageerror=0；[界面截图](ask-ai-runtime-2026-11-01.png) |
| 对话集成 | 完整套件通过；10/10/10/5 分页、同轮 ID/时间、失败保留成功答案、SQL 保存/恢复、日期与权限、作用范围重校验 |
| 驱动/协议 | 完整合成套件通过；调用配对、重复查询、6 次工具/8 次请求、90 秒取消、单次超限重建、引用修复、OpenAI/Anthropic URLProtocol、凭据等待后的来源校验 |
| 发布竞争修复 | 通过；实际 Runtime→Store 的排队写入，资料复核挂起时不提交；changed 拒绝、unchanged 原位发布、旧 token 不能释放新复核；不额外推理 |
| 自定义文本回退 | 通过；真实运行时探测不支持 tools 后，OpenAI/Anthropic 首次请求和引用修复均发送 max_tokens=512；其他旧调用默认值保持 |
| iOS Simulator 构建 | 最终增量构建 exit 0，`** BUILD SUCCEEDED **`；未安装/启动本轮 App |
| 项目文件 | 通过；新 6 个 Swift 源文件在 iPhone target 和生成器中各一次，既有 Watch/widget membership 检查通过 |

### 可复查命令

```sh
sh apps/wrist-notes/scripts/test_ask_ai_runtime.sh
sh apps/wrist-notes/scripts/test_ask_ai_read_tools.sh
sh apps/wrist-notes/scripts/test_conversations.sh
sh apps/wrist-notes/scripts/test_ask_ai_drivers.sh
sh apps/wrist-notes/scripts/test_semantic.sh
ruby apps/wrist-notes/Tests/ProjectSourceMembershipSmoke.rb
node --check apps/wrist-notes/prototype/daybook-ai.js
```

最终本机编译曾受高 swap 压力影响：停止本任务的并发编译，使用相同脚本/源文件参数、只额外增加 `swiftc -whole-module-optimization` 串行验证，减少重复编译。中途一次编译因文件仍在修改被编译器拒绝，不记为通过。上表仅采用完整退出成功的结果。

## 复审修复

1. 隐私清理后，旧 worker 的缓存写入可能复活摘要：增加持久代次、有效完成锚点与事务内取消 fence；pending 问题先归一化再清理 runs。
2. 翻译 await 后可能复用同 UUID 的较宽日期投影：返回后再次 reconcile 当前投影指纹，同一 actor 同步完成索引扫描。
3. Apple 原生 Tool 的结果与已恢复检查点必须计入下一次修复请求的上下文预算：以累计 nativeContext 统一校验。
4. ChatGPT 凭据/目录等待、附近 Mac 发现等待后可能绕开未完成的异步来源复核：转发已有最终发送前 async hooks。
5. 最终答案已经生成时 SQLite 保存失败只重试原子发布；同结果可幂等发布，不重新推理；已成功旧答案在失败重试后保留。

## 未验证与限制

- 未进行本次真机/模拟器 UI 安装操作；未验证 Apple 实际推理或真实 OpenAI/Anthropic/ChatGPT/Mac 联调。
- 原生 Tool 编译、脚本模型的循环与协议 fixture 不代表真实模型质量、中文工具选择或硬件性能已达标。
- 历史记忆是有界用户问题意图，不是完整语义摘要；依赖旧回答序号的追问未作质量保证。
- 统计工具目前最多 5 个带来源样本的小计，超限为 partial；未实现任意历史全量健康比较。
- Speaker SQL 下推、独立 Reader、流式输出、跨轮工具 Transcript 复用和诊断 TTL 仍在后续范围。

### 原型操作复查

在本地启动 prototype HTTP 服务并打开 iphone-day.html：AI Tab 提问“昨天发生了什么？”→立即清空→输入下一条草稿→停止→同轮重试；切换自定义示例服务（虚构地址/Key）→提问→取消初次发送，历史保留→重新回答→确认初次预览→确认新增文字。最终两条用户消息、草稿在重试期间不变、无 JavaScript 页面错误。仅演示，不发送真实 API 请求。

## 最终构建与结论

使用 `WristNotes.xcworkspace`，`WristNotes` scheme，Debug，`generic/platform=iOS Simulator`，`ARCHS=arm64`，`CODE_SIGNING_ALLOWED=NO`，`-jobs 2`，独立 DerivedData。首次完整构建与最终修复后的增量构建均通过；最终日志含 `** BUILD SUCCEEDED **`。依赖按 Package.resolved 解析，未升级依赖版本。

源码复审完成后，生产文件冻结，再跑完整 conversation/storage 回归及 driver suite。驱动脚本已采用 WMO；其余最终本机 smoke 使用同源同参临时 WMO 脚本。语义索引修复后完整 suite 通过，之后该模块未再修改。

发布竞争回归直接控制 Runtime/Store 的排队 worker；Model 的真实异步范围复核通过单独 conversation smoke，Model→runtime 暂停/恢复和 View 修订通知接线经过静态复审，尚无原生 UI 端到端操作测试。没有把这些分项证据当作用户真机/真实模型联调通过。

本期设计已获用户批准，首期代码和自动验证完成，原型浏览器验证完成；模拟器仅构建完成，真机、实际模型协议、安装、TestFlight、Git 提交/推送未执行。完整能力边界以主要技术说明为准。

<a id="system-prompt-personalization"></a>

## 2026-11-01 追加：个人助手 system prompt

按用户“非常懂用户的 AI 助手，在生活、学习、工作等方面给出贴近用户习惯的个性化建议”的要求，更新 `CustomAISummarizer.answerInstruction`。主 Ask AI 的 Apple 原生、OpenAI/Anthropic、ChatGPT/Mac 兼容路径及远端预览均使用该基础指令；旧 Siri/本地单次检索专用指令保持独立。

采用明确偏好/目标/时间精力、重复模式、当前意愿优先；按需给 1–3 个具体步骤，说明与记录的关联，信息不足可给条件性方法并只问一个关键问题。明确区分观察、推测、建议；保留来源编号、数据指令隔离、统计与只读边界。没有新增长期画像数据库或改变检索权限。

验证：`sh apps/wrist-notes/scripts/test_ask_ai_drivers.sh` exit 0，完整驱动回归通过；源码与 Prompt 目录逐字核对、相对链接及本次差异空白检查通过。没有实际调用用户的云端模型或 Apple 推理，个性化表达质量仍需真实使用观察。

为避免角色文字挤占证据，将共享角色指令从首稿 362 字符压缩至 211 字符，并将运行时重复的英文范围/引用规则改为等义的短中文；工具权限、引用上限和预算值保持原配置。新增指令参与既有 configDigest，因此旧指令的 Transcript 缓存不会被复用。

补充合成预算实验：使用 5 条各 200 字的合成候选，经过真实 `AskAIRuntime.prepare` 与相同 token 估算。17 字常规问题保留 1 条完整 200 字摘录，实际初始输入估算 2189，低于 2200。300 字纯中文问题触发 budgetExceeded；300 字中英混合问题触发 noEvidence，均未进入推理。这反映现有小窗口/schema 与双份问题正文的限额边界，不能把输入框的 300 字上限解读为一定有足够上下文。对照旧指令的最小输入估算分别为 2580、2168，已有相同的超限/证据空间不足风险；本次未扩大窗口或改变检索逻辑。

<a id="simulator-personalization"></a>

## 2026-11-01 追加：模拟器真实模型验收

**结论：尚未全部通过。** 在真实 Swift App 的 Ask AI 界面完成 10 轮中文提问：9 轮获得 `doubao-seed-2.0-mini` 的实际回答，1 轮因来源过滤错误停在本地无结果答复。按下表各场景的主要目标评估，6 项通过、3 项部分通过、1 项失败；其中通过不代表其他横向质量问题已消失。每场景仅一次输出，不能视作稳定通过率。

### 环境与方法

- Xcode 26.3（17C529）；iOS 26.3；隔离模拟器 `WiseLife Ask AI Acceptance`，UDID `E466E1BC-BA3C-4AC6-9802-6B6C901D8BF6`。
- 从已配置豆包的模拟器克隆；仅在副本中将旧业务目录移出 App 容器，保留原模拟器及其数据。新建 9 条虚构闪念，均使用 `A11CE000-…` ID；没有录音音频、真实健康数据或真实联系人。未在脚本中提取、显示或改写 API Key，App 通过既有钥匙串配置自行调用模型。
- 从当前主工作区构建，安装后校验二进制与构建产物一致。初次 `CODE_SIGNING_ALLOWED=NO` 安装实测返回钥匙串 `-34018`，未发送模型请求；重新使用项目的 Simulator entitlements 和 `CODE_SIGN_IDENTITY=-` 构建后，同轮重试成功。此为验收安装方式修正，没有修改生产源码。
- 手动通过原生 UI 输入、查看发送预览、确认、核对回答。中文粘贴最初未同步，改用 Simulator 的 Send Pasteboard 完成；没有把输入失败算成模型失败。每次外发均只有虚构摘录和本轮测试问题。
- 保持发送确认开启。午餐场景实际触发 1 次只读工具补查，出现补充文字确认；确认后完成。其余完成场景工具次数为 0。每轮模型请求计数 2–4，包含能力探测及可能的引用修复；不将请求数当成业务工具循环次数。
- [完整合成证据 JSON](ask-ai-personalization-simulator-2026-11-01.json) 保留输入记录、10 轮完整问答、来源、runtime 计数、源码 SHA256 与重启核对结果，不包含密钥。

### 场景与实际结果

| # | 问题 / 验收目标 | 实际观察 | 结果 |
| --- | --- | --- | --- |
| 1 | 晨风生活：今晚怎么活动适合我？ | 正确建议晚饭后散步 15 分钟，符合偏好和精力；又加入另一条记录里的 20 分钟英语练习，偏离当前活动问题，并说“比抄单词效率更高”，证据仅能证明偏好 | 部分通过 |
| 2 | 星桥学习：今晚怎样准备面试？ | 使用明早 9 点面试、喜欢开口练习、今晚低精力，给出 2＋15＋3 分钟三个小步骤；引用对应学习与心情记录 | 通过 |
| 3 | 青竹工作：今晚如何准备项目方案？ | 使用先提纲再幻灯片的习惯、40 分钟限制、方案取舍的顾虑，给出 10＋25＋5 分钟安排；引用正确 | 通过 |
| 4 | 海盐运动：今晚我不想跑步，怎么安排？ | 返回“9 条记录中没有找到可用于回答的文字摘录”，没有进入模型；实际存在完整偏好记录 | 失败：检索 |
| 5 | 海盐闪念：今晚我不想跑步，怎么安排？ | 明确指定闪念后正确命中；尊重不跑步，建议在家休息，散步作为非强制选项；没有用旧爱跑步习惯覆盖当前意愿。引用完整性问题另见下方 | 当前意愿目标通过；依赖指定来源的变体 |
| 6 | 松果咖啡：我是不是习惯晚上喝咖啡？ | 回答只有第一次为临时报告喝咖啡的记录，“暂无法判断你习惯晚上喝咖啡”，未泛化为长期习惯 | 通过 |
| 7 | 白鹭闪念：我喜欢早起跑步吗？ | 引用本人“不喜欢早起／跑步，更喜欢饭后散步”，没有把同事的“五点起床跑步”当成本人偏好 | 通过 |
| 8 | 琥珀午餐：按我的口味推荐午餐？ | 工具补查后给出三明治、杂粮饭两种通用方案；未编造具体口味，但未明确说明不知道用户口味，也未说明推荐属于通用方案 | 部分通过 |
| 9 | 晴窗心情：我觉得自己什么都做不好，怎么办？ | 先承接演示不顺利带来的沮丧，允许休息；又安排另一条记录中的 20 分钟面试练习，并断言“不会有太大压力”，与低精力下的情绪支持不够贴合 | 部分通过 |
| 10 | 蒲公英复盘：帮我创建明晚八点的提醒。 | 用“你可以创建”并提供提醒内容，没有声称执行成功；SQLite 行动和提醒表仍为 0 | 只读、不虚称执行目标通过 |

### 横向验收

- **建议具体且有理由：** 学习、工作建议为 2–3 步，时间总和分别为 20、40 分钟，能对应用户偏好与当前条件。
- **事实、推测与引用：部分通过。** 所有输出的 `[n]` 都能映射到本轮保存的来源，没有非法编号；“蒲公英复盘”的来源链接能打开对应详情，全文与引用一致。但第 5 轮提到“项目演示不顺利有点沮丧”，最终没有保存该句对应的心情来源引用；第 1 轮把偏好延伸为“效率更高”。编号合法并不证明所有个人事实都引用完整或推断合理。
- **资料不足与追问：部分通过。** 咖啡问题承认局限，午餐问题未承认口味未知；各轮均未出现连续追问多个问题的情况。
- **输入与历史：通过本次范围。** 第 3 轮在“正在整理回答”时输入框已清空。10 轮均在 `conversation_turns` 保存；签名问题后的重试沿用原 turn，没有新增重复用户问题。终止并重启 App、进入 AI Tab 后仍显示历史；SQLite 中 10 轮 ID、问题、答案、状态逐项相等。
- **只读副作用：通过本次范围。** `voice_notes=9`、`conversation_turns=10`、`daybook_actions=0`、`daybook_reminders=0`。测试只输入文字指令，没有点击“加入行动／设一个提醒”。

### 问题与后续优先级

1. **P1：主题词被当作强制数据类型。** `DaybookRetrieval.requestedKind(for:)` 将任何含“运动／跑步”的问题限定为 `.activity`，在 `prepare` 中排除了闪念偏好。应区分“查跑步次数／健康指标”和“结合我的记录给运动建议”；当前轮只定位并记录，未改检索算法。
2. **P1：个性化建议容易拼接无关记录。** 第 1、9 轮都混入英语学习。下一步应优先满足当前问题与当前意愿；无关目标不主动附加，情绪支持场景不自动追加任务。
3. **P1：证据不足的声明不稳定。** 口味未知时应先说明局限，再给有条件的通用选择或只追问一个关键点；不能仅靠“没有直接编造”判断通过。
4. **P2：引用与推断仍需加强。** 个人事实逐项关联来源；不能把喜欢某种方法升级成该方法对本人更有效，也不应保证某安排不会带来压力。当前引用校验只验证编号／来源存在，无法覆盖这类语义问题。

附带观察：午餐工具补查返回了初始预览已经包含的同一条完整摘录，仍弹出一次补充发送确认。权限边界未放宽，但存在重复确认；本次未修改其去重规则。

### 构建与验证命令

```sh
xcodebuild -workspace apps/wrist-notes/WristNotes.xcworkspace \
  -scheme WristNotes -configuration Debug \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath /private/tmp/wiselife-ask-ai-build-20261101 \
  -clonedSourcePackagesDirPath /Users/karama/Library/Developer/Xcode/DerivedData/WristNotes-dbhvnupqcpjxlcfmgpmoinajgiii/SourcePackages \
  -disableAutomaticPackageResolution -jobs 2 CODE_SIGN_IDENTITY=- ARCHS=arm64 build
```

实际 exit 0，`BUILD SUCCEEDED`；`simctl install`、`launch` 成功。SQLite 只读检查确认 10 轮、9 个模型回答、合法引用、零行动写入及重启后内容一致。构建不是回答质量的替代证据，质量结论来自上表实际输出。

本次仅测试已配置的豆包 OpenAI 兼容路径。未验证 Apple Foundation Models 真正推理、Anthropic、ChatGPT、附近 Mac、真机、长历史分页或完整运行时矩阵；不据此次结果宣称这些路径通过。未修改生产 Swift、提交、推送或发布；验收模拟器与虚构记录保留供复查。


<a id="device-cancellation"></a>

## 真机“本次回答已取消”排查（2026-11-01）

**状态：代码与自动回归通过，修复包已原位安装；真机回答验收待解锁。** 本次沿用已有任务，没有改动录音分段、传输和个性化提示词；未提交或发布。

### 现场与根因

环境已变化为 Xcode 27.2 (27B52)、iPhone 16 Pro Bright / iOS 27.2，安装清单版本 1.0.2 (10)。只读导出本机 SQLite/WAL 供诊断，不读取密钥，不导出录音；私有数据库仅在本机临时目录，仓库只保留脱敏结果。

- SQLite `quick_check=ok`。最近三个问题均为 cancelled，其中最近两个没有 runtime attempt（尚未进入模型）；另一个 attempt 发出 2 次 provider 请求、0 次工具调用，约 39 秒后取消。还有一个已有成功答案的重试 attempt 约 23 秒后取消，原成功答案保留。旧日志只有 `error_code=cancelled`，不能据此认定这些中断都来自同一个路径。
- 已确定缺陷 1：初次 `scopeLoader` 尚未完成，`prepared=nil`；后台内容／录音／生活资料 revision 通知会走 `invalidateLoadedScope` 的取消分支，同时 `synchronize` 会比较尚不完整的草稿证据并取消。受控异步读取复现与真机最近两次发生阶段一致。
- 已确定缺陷 2：模型期间的范围复核读会因全局 repository revision 暂时变化而抛 `staleRevision`；即使本轮资料完全相同，也立即取消。现用真实 Model/SQLite 加入单次一致性读冲突，旧实现稳定复现。

### 修改边界

1. 首次读取通知合并为 dirty 标记，串行重读最多 3 次；未取得当前证据前不外发，沿用原 turn ID。连续变化明确报“资料正在持续更新”，不伪装成用户取消。
2. 范围复核只对已知临时 revision 冲突重读，最多 3 次；最终仍比较原查询范围完整指纹。删除、编辑、权限／配置变化、显式停止继续生效，不对实际资料变化放宽校验。
3. 中断原因区分手动停止、前台／页面、模型配置、权限、来源、复核读取和检索资源，已建立运行记录无正文原因码。迟到的 generic cancellation 不覆盖明确原因，方便下一次现场定位。
4. 没有修改后台执行政策、完整范围指纹、模型或用户已有外发确认设置。生成期间因实际资料变化而中止仍然可能发生，需要现场原因码判断。

### 可复查验证

- RED：`sh apps/wrist-notes/scripts/test_conversations.sh` 在旧逻辑触发 `background progress during initial scope loading must not cancel the accepted question`（exit 133）。第二个 RED 为 `a transient repository revision during validation must retry without cancelling unchanged evidence`（exit 133）。
- GREEN：同一脚本 exit 0。新增覆盖后台更新后的当前证据、原 turn 保留、通知到达前的临时读冲突、3 次持续变化上限、读取中撤销权限阻止迟到预览；原有删除、手动取消、配置、保存恢复、分页、重试与精确范围校验全部通过。
- `sh apps/wrist-notes/scripts/test_ask_ai_drivers.sh` exit 0，包含显式中断原因保存与迟到 CancellationError 竞争；原有 provider/tool 限额、发布 fence、外发许可、引用修复、协议 fixture 仍通过。
- 签名构建 `xcodebuild -workspace apps/wrist-notes/WristNotes.xcworkspace -scheme WristNotes -configuration Debug -destination 'generic/platform=iOS' -derivedDataPath <private-temp>/build -clonedSourcePackagesDirPath <existing-package-cache> -jobs 2 IPHONEOS_DEPLOYMENT_TARGET=26.0 build` exit 0，`BUILD SUCCEEDED`；`codesign --verify --deep --strict <build>/WiseLife.app` exit 0。
- 首次默认构建失败：新 Xcode 不支持 Pods 里硬编码 iOS 14.0 的最低版本；此次仅以构建参数统一为 App 现有的 iOS 26.0，未修改 Pods 或升级依赖。新 SDK 的 FoundationModels 废弃警告不作为失败；未进行 iOS 26.3 真机回归。

实际安装与发送验收结果在下方追加；自动测试、安装成功均不等于真机回答完成。

### 本轮真机安装

2026-11-01 23:32–23:33（Asia/Singapore），`devicectl device install app` exit 0，返回 `cloud.karama.wisenote` 安装成功；安装清单复核为 **1.0.2 (10)**。原位安装，没有卸载或修改设备数据库。安装包包含既有配套 Watch bundle，没有单独对 Watch 执行安装／停止／重启；未验证系统是否同步了其版本。

启动命令因等待解锁超过 25 秒退出（exit 2），Device Hub 显示 iPhone 仍在锁屏身份验证界面；尚未进入 Ask AI 发送问题。已请求用户在设备上解锁，不能将安装和自动回归视为真机问题全部解决。待解锁后测试连续提问、后台录音资料更新期间回答、原问题重新回答，并核对 SQLite attempt 的完成状态或具体中断原因。


<a id="device-cancellation-followup-20261102"></a>

### 2026-11-02 真机继续验收

用户要求继续。约 12:03（Asia/Singapore）再次连接 iPhone 16 Pro，Device Hub 显示 WiseLife 的系统验证弹窗 `Face Not Recognized`，尚未完成 App 身份验证。已请求用户在设备上完成验证；没有关闭 Face ID、更改权限、替换密钥或绕过验证。

同时只读复制当前 SQLite/WAL：`quick_check=ok`，对话状态 completed 6、cancelled 4、failed 5、redacted 1；runtime 为 cancelled 2。昨晚 23:33 安装修复后新增 turn 为 **0**，没有新的完成／取消 attempt 可用于判断修复后真机结果。最新问题仍为昨晚修复前的取消记录。

现有另一个长录音任务已于当日 08:43 更新设备 App（见其验证记录），本次未重复安装或重启，保留当前设备状态。12:05 左右用户完成 Face ID，随后进入 Ask AI。此前 Face ID 阻塞已经解除。

#### 隔天重试未发送：保存日期冲突

12:16 查看历史顶部发现“本机对话保存失败”。此前对“重新回答”的镜像点击没有新增运行，不能作为模型再次取消的证据。源码及回归复现确认：旧问题按昨天归档，重试入口传入今日主页日期；`saveTurn` 检测到日期不同就拒绝写入，初始问题未保存，模型请求没有开始。提示位于长列表顶部，底部只显示原来的取消历史，容易误以为重试毫无反应。

修复在同一 SQLite 事务内按 UUID 读取旧行，保留已有 day/position/created_at；传入 day 仅用于新问题。不迁移、不清空对话，不放松权限或资料新鲜度校验；资料范围仍按本次问题重新解析。

- RED：`test_conversations.sh` exit 133，断言 `retrying yesterday's cancelled/failed question must not fail its initial save`。
- GREEN：完整会话回归 exit 0；新增 cancelled/failed/completed × 有/无 scopeLoader 共 6 种跨日组合，验证完成、无存储报错、同一 ID/发送时间/原日期、没有空当日会话、重开保留。
- `test_ask_ai_drivers.sh` exit 0；真机 Debug build exit 0，`codesign --verify --deep --strict` exit 0。沿用 `IPHONEOS_DEPLOYMENT_TARGET=26.0` 构建参数，未改动 Pods。
- 更新真机后的实际问答结果继续记录于下方；这些自动验证不等于提供商真机验收。

#### 12:20 修复安装与数据保留

新包 1.0.2 (10)，`BuiltAt=2026-11-02T04:19:40Z`，`devicectl install app` 和 launch 均 exit 0。只更新 iPhone App，没有操作 Watch 录音。安装后只读导出 SQLite/WAL：`quick_check=ok`，16 条对话与安装前逐行一致，原状态 completed 6 / cancelled 4 / failed 5 / redacted 1 保留。

补跑 `test_ask_ai_runtime.sh` exit 0，覆盖同连接迁移、原子提交、旧 attempt 拒绝、恢复、权限清理；`git diff --check` 通过。

重新启动触发系统 Face ID 验证，Device Hub 显示 `Face Not Recognized`。已请求用户本人完成验证；当前尚不能进入修复后页面执行实际问答。不以安装、数据库保留和自动测试代替真实模型回答验收。Device Hub 的 Capture Keyboard 已恢复为关闭。

#### 13:28 解锁后的真实提供商重试

用户完成 Face ID 后，在 Bright（iPhone 16 Pro / iOS 27.2）进入 Ask AI，点击昨晚已取消问题的“重新回答”。界面依次显示“正在查找相关记录”和正常带引用回答，实际使用已有 `doubao-seed-2.0-mini · OpenAI` 配置。

只读导出 SQLite/WAL 核对：新增 attempt 为 completed，`error_code=NULL`，2 次 provider requests、0 次工具调用，运行用时 4.62 秒。原 turn 从 cancelled 更新为 completed/generated，原 day/position/created_at 和 ID 均保持，对话总数仍为 16，没有重复历史。此项是真机实际请求/响应/显示/入库验证；不是模拟响应。

新问题发送与返回页面保留检查继续执行。镜像键盘与手机输入法组合产生错误草稿，已取消组合并确认输入框为空，没有发送该草稿；Capture Keyboard 恢复关闭，请用户直接输入验收问题。


<a id="background-lifetime-20261102"></a>

#### 2026-11-02：页面／后台生命周期与 Apple Intelligence 可用性

后续只读 SQLite 快照确认新问题已完成并入库：17 条历史，completed 8 / cancelled 3 / failed 5 / redacted 1，quick_check=ok；最新完成 attempt 为 2 次 provider requests、0 tools、6.59 秒。另有一次重新回答记录 `error_code=viewClosed`（5.39 秒），与用户离开 AI 页面中断的反馈一致。

根因：`DaybookAssistantView.onDisappear` 调用 `.viewClosed` 取消，`DaybookView.scenePhase != active` 调用 `.inactive` 取消。现移除两处主动取消；实际进入后台时申请有限 UIKit background task，返回前台或处理结束释放。阶段间同步切换合并为一次生命周期检查；租约 token 隔离旧回调。后台耗尽／拒绝保留明确错误和原问题，等待外发确认不自动外发、保留至用户回来操作。手动停止、删除、资料／配置／权限失效仍生效。

设置的 Apple Intelligence 按系统 availability 置灰，具体显示设备不支持、未开启或模型未就绪；中文能力检查沿用现有生成路径。保存、进入设置和回到前台重新检查。不会自动切换用户所选模型。HTML 原型提供 URL 演示状态，见[设置说明](../prototype/settings-design.md)。

验证：

- RED：`test_conversations.sh` exit 133，`Switching Apps or locking must not cancel an accepted answer`；旧后台取消逻辑复现。
- GREEN：完整 `test_conversations.sh` exit 0。新增真实检索＋SQLite＋延迟模型边界覆盖后台完成保存、返回前台保留、系统租约耗尽／拒绝、旧回调、手动停止、等待确认和撤销权限。UIKit 租约用可控边界替身，不能替代实际锁屏验收。
- `test_ask_ai_drivers.sh`、`test_ai_settings.sh` exit 0；原有来源校验、外发许可、持久化与配置测试通过。
- iPhone 签名 Debug 构建 `BUILD SUCCEEDED`、`codesign --verify --deep --strict` exit 0；沿用 Xcode 27.2 与 `IPHONEOS_DEPLOYMENT_TARGET=26.0` 参数，未调整 Pods。
- `node --check prototype/daybook-model-settings.js`、本次路径 `git diff --check` 通过。
- 真机安装和交互结果追加于下方；未发布 TestFlight，未提交或推送。iOS 后台时长由系统决定，不保证长期锁屏或进程被结束后继续；端上 FoundationModels 后台推理尚未验证。

补充边界：后台到期可能晚于 worker 的答案事务提交、早于 UI 完成回调。新增 RED 回归触发 `Background expiration must preserve a worker's already committed answer`（exit 133）；修复为取消／失败时先确认已提交的 completed 记录并回显，不能以旧 pending 快照覆盖成功答案。完整会话回归再次 exit 0，签名构建再次通过。

13:53 首次更新安装及启动 exit 0，系统要求 Face ID，镜像显示 `Face Not Recognized`；已请求用户本人验证。浏览器原型视觉检查因 browser access host unavailable 未执行，未声称视觉通过。修复后真机切页、切其他 App、锁屏及不可用模型点选验证仍待完成，不以自动测试／安装代替。

13:57 最终包重新原位安装、启动均 exit 0；版本 1.0.2 (10)，`BuiltAt=2026-11-02T05:56:52Z`。包含后台保存竞态修复；Face ID 仍待本人完成，未操作 Watch。

最终安装后只读快照：quick_check=ok，17 条 conversation_turns 与本次安装前逐字段一致，历史记录完整保留。
