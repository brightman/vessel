---
type: verification
status: installed-live-incremental-timeline-verified
updated: 2026-11-02
scope: WiseLife iPhone 持续接收 Watch 小时文件时的增量主题处理
related:
  - ../docs/watch-to-iphone-hourly-recording-sequence.md
  - ../docs/superpowers/specs/2026-10-23-content-segmentation-v2-review.md
---

# 10 小时录音未提前生成时间轴片段

## 现场证据

用户报告 Watch 仍在连续录音，iPhone 已收到 10 个小时文件。连接真机只读导出 SQLite/WAL 及偏好用于诊断；没有导出音频，没有读取或记录模型密钥，没有修改设备数据库。原始快照仅保存在本机私有临时目录，不纳入仓库。

- iPhone 16 Pro，安装版本 1.0.2 (9)；当前工作区版本 1.0.2 (10)，有大量既有未提交变更。
- 22:17 快照：10 个文件，序号 0–9，无 final ordinal；录音来源 `complete=false`。119 个窗口中完成 70、失败 6、等待 42、运行 1。70 个窗口 ASR/VAD 均成功。
- 目标录音只有 20 个未定稿占位段，均无标题、分类；主题检查点为 0。SQLite `quick_check=ok`。
- 22:32 再次快照：完成 70、失败 6、等待 42、`missingResource` 1；仍无主题检查点或定稿段。`missingResource` 可由运行时暂停／资源不可用引起，不能仅凭此状态认定模型未安装。
- 在私有数据库副本用实际生产仓库与 V2 planner 重放：24,171 条可用转写、239 个 block、14 章（5 章暂定）、6 个失败边界。仅增加进度 revision，原授权 scope 与 V2 输入均失效。
- 尝试获取 ContentV2 真机日志时，系统要求 root，非交互 sudo 不可用；未取得现场推理日志，不能据此断言所有失败都来自同一个原因。

## 已复现并修正的缺陷

1. 整个录音的 revision／所有窗口变化参与授权和发布比较；后续 ASR 使仍在生成的旧内容结果被丢弃。V2 改为冻结窗口成员、结果身份、音频前缀与末尾状态，模型仅使用该快照；追加不能扩大本轮外发范围。
2. 同源主题 worker 未排除已运行来源，队列可覆盖任务句柄并重复推理。调度只取没有活动 worker 的来源，其余更新合并等待。
3. V2 发布的内容签名与 reconcile 使用的语义签名不同；下次 ASR 唤醒会清掉已生成标题、摘要与分类。统一使用实际片段范围／转写的签名。
4. 已收到的音频处理完成不代表 Watch 录音结束。未结束来源的末尾章、首个未完成窗口之后的区域保持暂定，已确定前段可发布。

无需更改数据库结构、音频、成功 ASR、Watch 采集和文件传输。源删除、既有证据修改、配置变更、人工编辑保护与显式外发确认继续有效。

## 验证

- RED：新增真实 SQLite 回归，旧实现报 `progress-only updates must not invalidate a topic snapshot`。
- RED：补充发布后再次提交 ASR 的回归，报 `later ASR must preserve finalized titles, summary and classification`。
- GREEN：`sh apps/wrist-notes/scripts/test_content_segments.sh` 通过；覆盖进度变动、后续 ASR、小时文件追加、冻结输入不扩大、已有结果散列变化拒绝、进行中发布、开放尾段、定稿字段保留、删除后撤销，以及已有持久化／编辑／撤销用例。
- `sh apps/wrist-notes/scripts/test_content_authorization.sh` 通过；原有确认预览、GPS／地址变化撤销、删除保护保持。
- `sh apps/wrist-notes/scripts/test_content_v2.sh` 通过；引擎 84 项及生产入口的发布校验、检查点恢复、失败原子性；新增完整覆盖但仍在录音的尾段、结束后尾段闭合、未完成核心之后不能提前定稿。
- 使用真机数据库的私有副本（没有调用 AI）运行修复后的生产读取／planner／publisher：24,171 条转写、14 章；占位测试标题仅写入本地副本，发布 14 段、其中定稿 9 段；reconcile 后 9 段均保留标题和分类。仅证明已有真实数据能通过发布与保留路径，不是 9 个真实模型结果或真机 UI 验收。
- iPhone 签名构建通过（exit 0，`BUILD SUCCEEDED`），`codesign --verify --deep --strict` 通过。命令：`xcodebuild -workspace apps/wrist-notes/WristNotes.xcworkspace -scheme WristNotes -configuration Debug -destination 'generic/platform=iOS' -derivedDataPath <private-temp>/build -jobs 3 build`。
- 构建含配套 Watch App；安装可能影响仍在进行的 Watch 录音，因此在修复包构建通过后向用户确认录音是否已正常结束，未擅自停止录音或安装。

## 设备与发布状态

首次修复完成时未安装；用户随后明确要求“安装到真机上”。2026-11-01 22:52（Asia/Singapore）使用已验证签名包在 iPhone 16 Pro Bright 上原位安装 `cloud.karama.wisenote`，设备返回安装成功；重新查询确认版本 **1.0.2 (10)**，随后启动成功。安装前再次保存了私有数据库快照，未卸载 App、未修改录音或设备数据库，也未对 Watch 单独执行安装／停止／重启命令。安装包含配套 Watch bundle，未验证系统是否自动同步其版本。

安装命令：`xcrun devicectl device install app --device <Bright device ID> <verified-build>/WiseLife.app`；启动命令：`xcrun devicectl device process launch --device <Bright device ID> cloud.karama.wisenote`。两者均 exit 0；安装清单查询确认 bundle version 10。

安装后只读快照：SQLite `quick_check=ok`，目标来源仍有 10 个音频范围、`complete=false`；原有 70 个成功窗口保留，另有失败 7、等待 41、运行 1。目标录音首次出现 **1 个 `content-v2` 检查点**（安装前为 0），说明真实主题推理已开始保存中间结果，语音处理队列也已恢复。该时刻仍为 20 个草稿、0 个定稿，不能宣称时间轴已出现新片段。未重新上传或重跑已成功窗口。

安装成功和主题检查点恢复不等于内容分段真机端到端验收。持续录音过程中提前显示时间轴片段仍须单独确认。未提交或发布。

<a id="2026-11-02-followup"></a>

## 2026-11-02：再次打开进入主题分析、时间轴未显示

### 现场与根因

- 本次初始快照：录音已正常结束，11 个音频范围、38,762.5 秒；130 个窗口中成功 115、失败 15，无等待或运行窗口。因此“语音窗口全部结束”不等于“全部成功”或“主题分类完成”。SQLite 完整性正常。
- 初始仅有 22 个草稿、0 个定稿、0 个标题；123 个 V2 检查点含 58 个 chapter、54 个 merge、11 个 final，其中 final 分类 meaningful 7、lowInformation 4；整轮完成标记为 0。
- 私有数据库副本离线重放 33,419 条真实转写、342 个 block、23 章，复用 87 个检查点后遇到缺失 final 响应。原入口只在整个 engine 成功返回后统一发布，已有结果因其他片段未完成而无法展示。没有读取密钥或向模型另行发送录音内容。
- 检查期间，设备原版本在前台继续处理并完成批量发布；随后快照为 62 个段、43 个定稿，其中 23 个 meaningful final，并有 1 个整轮完成标记。使用 Device Hub 查看 Bright 实际画面，关闭原始录音详情并切到 **11 月 1 日 → 全部** 后，看到了该长录音的标题、摘要和时长。此 UI 验证发生在本次新包安装前，不能算作新增逐段发布代码的真机验收。

### 修复与自动验证

- 生产入口支持逐段发布：每个 final 的完整所有权和证据校验通过后写入，失败不撤销其他已完成结果；未完成轮次不写完成标记。
- 冻结输入以现有 `content_enrichment_checkpoints` 表的 `content-v2-run` 单元保存；模型身份和源证据校验不变，重开保留原章节／合并／分类检查点身份。精确排除已完成范围，支持后段先完成、前段仍待重试。
- RED：旧实现以 `an earlier completed segment must publish before a later classification fails` 失败。GREEN：V2 引擎 84 项及生产入口通过，新增前段成功后段失败、前段失败后段成功、恢复仅调用缺失 final 的测试。
- Repository 全套通过：逐段可见、乱序完成不丢较早内容、部分结果不标全完成、重开恢复同一快照、重复发布幂等、完整完成保留前次结果、真实小数边界容差；既有编辑／删除／撤销保护保持。
- 真实缓存重放发现浮点相邻边界在 6073.45 秒附近被误判为重叠；按现有 1e-6 秒容差修正，真实音频帧重叠仍拒绝。修复后 11 个既有 final 都能写入副本，7 个 meaningful 可展示，后续缺失响应不影响已保存结果。
- 命令：`sh apps/wrist-notes/scripts/test_content_v2.sh`、`sh apps/wrist-notes/scripts/test_content_segments.sh`、`sh apps/wrist-notes/scripts/test_content_authorization.sh`，均通过。
- 当前 Xcode 支持 iOS 15–27.2，Pods 生成项目的旧 14.0 target 导致首轮构建失败。使用项目现行 26.0 目标的构建参数 `IPHONEOS_DEPLOYMENT_TARGET=26.0` 后构建成功；未修改 Pods 或降低 App 支持版本。最终签名检查通过。

### 本次设备更新

2026-11-02 08:43 左右原位安装并启动成功，仍为 1.0.2 (10)，本次 `BuiltAt=2026-11-02T00:41:43Z`。没有点击“重新处理”，没有卸载或改写设备数据库。安装后 Face ID 要求用户本人验证，已请求解锁；新包重开后的 UI 与数据保留检查继续记录于此。

安装后只读快照再次确认 `quick_check=ok`；62 个段、43 个定稿、23 个 meaningful final 均保留；115 个成功窗口和 15 个失败窗口保持。新的持续录音、后台恢复、失败窗口重新识别尚未验收；Face ID 未通过前不宣称新包重开的 UI 已验证。本轮时间轴已有内容的观察发生在旧版本完成批量写入后，新增逐段发布行为由真实缓存离线重放和合成故障回归验证。

### 解锁后的页面与新持续录音验收

2026-11-02 08:53–08:54，用户完成 Face ID 后，直接在 Bright 新安装版本中关闭完整录音详情，切到 **11 月 1 日 → 全部**，实际看到长录音片段的标题、摘要和时长。此前选中的“原始录音”筛选显示源文件，不是内容片段时间轴。

随后退到 iPhone 主屏幕并重新打开 WiseLife，系统再次要求 Face ID；12:05 左右用户完成验证后继续检查。只读数据库比较及后续快照确认：旧录音仍为 62 段、43 定稿、23 meaningful final；115 个成功与 15 个失败窗口保持，174 个主题检查点和 1 个完成标记保持。前后片段内容、标题、摘要、分类未改变，仅同步了 `sourceRevision`。这次观察没有发现旧录音重新生成主题结果；未采集提供商请求日志，不以检查点不变宣称网络请求数为零。

用户补充 Watch 正在进行新的连续录音，首个小时文件已上传。本次没有安装、重启或停止 Watch，没有点击“重新处理”，也没有修改设备数据库。沿用当前构建，在真实录音进行中观察到：

| 观察阶段 | 源文件／结束状态 | 转写 | 主题与发布状态 |
| --- | --- | --- | --- |
| 12:05 左右 | 1 个 3600 秒文件，`complete=false` | 11/11 成功 | 7 个模型检查点、1 个冻结轮次，尚无定稿 |
| 中间快照 | 仍为 1 个文件，`complete=false` | 11/11 成功 | 2 个 meaningful final 已独立保存标题／摘要，当前轮次仍有 `content-v2-run`；其他单位尚未结束 |
| 12:08 左右 | 仍为 1 个文件，`complete=false` | 11/11 成功 | 5 个片段中 3 个 meaningful final、2 个暂定；20 个模型检查点、2 个已完成快照标记，冻结轮次已清理 |

在 **11 月 2 日 → 全部** 的真机时间轴上实际看到 10:03、10:14、10:17 三个新片段，各有标题、摘要与时长。标题和录音内容不写入验证记录。该结果验证了本次安装版本在“录音仍继续、仅首个小时文件到达、当前轮次尚未全部结束”时逐段持久化，并由页面展示；无需等待整个录音结束。暂定尾段仍不作为完成内容展示。这里的 2 个完成标记对应两份增量证据快照，不表示 Watch 录音结束。

所有导出均使用 `xcrun devicectl device copy from --device Bright --domain-type appDataContainer --domain-identifier cloud.karama.wisenote --source 'Library/Application Support/WristNotes/Database' --destination <private-temp>`；只在本机副本执行 SQLite 只读查询与字段比较，`quick_check=ok`。本轮仅补充验证记录，未再次改动或安装代码。

**验收边界：**已验证旧内容在新版解锁后可见、跨重新打开保留，以及新持续录音首文件的提前发布和真机时间轴展示。后续小时文件追加、长时间后台推理、旧录音 15 个失败 ASR 窗口恢复仍未验收。

<a id="second-file-receipt-20261102"></a>

### 2026-11-02 14:21：第二个小时文件未收到

用户反馈第二个文件接收失败。仅进行真机界面与只读诊断，未安装／停止／重启 Watch，未点击重新处理或删除音频。

**后续恢复（14:33–14:39）：**用户确认 Watch 已安装最新 App，随后明确确认“已经传输成功了”。14:36 观察录音列表已显示 5 个文件，14:39 顶部状态更新为最近同步 14:39。未执行手动重传或修改 Watch；安装状态恢复与传输恢复的时间相关不能单独证明因果。下方保留此前缺失证据。

- 当前录音组开始于 10:03。iPhone SQLite 有 ordinal 0、2、3（界面第 1、3、4 个），各 3600 秒；ordinal 1 对应 11:03–12:03，稳定短 ID `06F8EDC0`，录音库、普通收件箱和保存回执表均无此 ID，音频目录精确搜索为 0 个文件。
- UI 第 2 个为“缺失 · 等待接收”；第 1 个已转写，第 3、4 个已存音频待转写。诊断记录第 3 个在 13:32:23 收到、第 4 个在 14:19:24 收到，随后本地保存并排队 ACK。最近 20 条日志和本会话较早快照未找到第二个文件接收／校验失败事件；滚动日志不能排除已经覆盖的旧事件。
- 从手机 WatchConnectivity 收到的 context 只读提取内嵌 `wiseLifeWatchSyncV1` JSON：Watch 报告时间 14:02:57，pending IDs 为第 2、3、4 个，`failures=[]`。第二个仍在待确认清单；这不能证明其当前字节或系统队列状态。
- 系统安装状态异常：09:24 报告 Watch App 已安装，12:12 配对状态事件变为 App 未安装；12:20 iPhone 更新后及后续激活仍为未安装，但之后第 3、4 个文件持续到达。`refreshStatus` 仅在 `isInstalled` 为真时读取同步快照，导致同步统计保留旧快照；手机重试入口也依赖该标志。不能把它直接解释为手表确实没有 App。
- 展示问题：头部使用已收到的文件数作为分母，显示绿色“3/3 已保存”，但已知序号 0...3 中缺少 ordinal 1。应按已知范围显示 3/4，并区分录音尚未结束。此轮先记录，未修改 UI。
- 当前安装包：iPhone 与嵌入的 Watch App 均为 1.0.2 (10)，Watch 最低系统 10.0、含 arm64_32 架构、companion bundle 正确，满足用户 watchOS 10.6.2 的声明兼容要求。手机安装成功不能证明 Watch 已同步更新；尚未读取手表实际安装版本。
- Watch 读取受阻：devicectl 返回 CoreDeviceError 4000，底层 NSPOSIXErrorDomain 60（超时）；Device Hub 同样 Connection timed out，并提示 Watch 必须在 Mac 附近。已请用户将手表靠近手机、唤醒 WiseLife，保持正在进行的录音。

**当前结论：**缺口发生在文件持久接收之前，不是 ASR／主题拆分隐藏了已收到的文件。存在配套 App 安装状态识别异常，但尚不能确认它导致第二个文件未送达。该文件在 12:20 更新前已经列入待确认，后续文件仍可接收；版本不同不是已证明的根因。需进一步读取 Watch 当前版本、文件存在性、outstanding transfer 和 didFinish 诊断。
