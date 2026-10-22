# WiseLife 原型与原生 App 功能核对

日期：2026-10-19。产品依据：`prototype/iphone-day.html`、`daybook-design.md`、`watch-recorder.html`。本次只修改 Apple 原生项目，不修改独立 Huawei 项目或官网原型。

## 开发前差异

| 原型能力 | 开发前原生状态 | 本轮处理 |
| --- | --- | --- |
| Watch 点按录音、长按闪念、传输状态、左滑删除 | 已有原生实现；用户此前反馈真机传输与 ASR 通过 | 保留协议与既有功能，回归测试 |
| iPhone 录音、导入、播放、总结/全文 | 已实现 | 保留并回归 |
| 拍照/相册、最多 6 张、图片详情、本地 OCR | 已实现 | 保留并回归 |
| 系统转写与 Whisper 下载/语言选择 | 已实现 | 保留并回归 |
| Apple 本地 AI、OpenAI/Anthropic 兼容配置 | 已实现 | 保留每次外发确认 |
| 日期、搜索、语音/图片/闪念筛选 | 已实现；缺生活筛选 | 补生活记录与来源详情 |
| 健康步数/睡眠及首页回退统计 | 健康为“未接入”；已有闪念/图片回退 | 实现可选 HealthKit 读取 |
| 日历、地点、采集暂停 | 占位页 | 实现可选本地接入 |
| 问 AI 与来源引用 | 每次独立问题，视图退出丢失回答 | 补有界本地对话与追问 |
| 每日多来源洞察、查看依据、不符合 | 单条笔记总结卡片；反馈不持久 | 补真正本地综合分析及缓存 |
| 主动建议、免打扰、提醒草稿与本地通知 | 已实现原文回顾线索与本地提醒 | 保留并连接新洞察 |
| SQLite 本地数据层 | 原有数据以文件和偏好存储为主 | 新生活/会话/洞察数据统一到带事务与索引的逐行表 |
| SQLite Vector 本地检索 | 仅关键词检索 | 已接入端上向量、混合检索及资源管理 |
| WiseLife 显示名 | Native 仍有 WiseNote | 同步可见名称，保留安装标识 |
| EurekaRing | 未接入；官网标记即将支持 | 等待 SDK/设备协议 |
| 用户自己的云存储 | 未实现；官网标记即将支持 | 待明确存储协议、备份/恢复与冲突规则 |

## 本轮验证

开发前完整本地 smoke suite 通过。完成实现后的验证基线为 `7a42d3b`（隔离分支）：

| 检查 | 结果与记录 |
| --- | --- |
| 完整本地 smoke suite | 退出 0，25 条通过结果；`/private/tmp/wiselife-final-local-after-fix.log` |
| 合回主目录后的完整回归 | 退出 0，25 条通过结果，与隔离工作区一致；`/private/tmp/wiselife-main-local.log` |
| iPhone Simulator（arm64 / x86_64） | `BUILD SUCCEEDED`；`/private/tmp/wiselife-final-fix-simulator.log` |
| iOS 真机目标，关闭签名 | `BUILD SUCCEEDED`；`/private/tmp/wiselife-final-fix-device.log` |
| 模拟器与真机目标内嵌 Watch 包 | 两者 `EmbeddedWatchSmoke.sh` 通过 |
| Target / 产品内部名 / Bundle ID / 签名 / 最低系统 | 与原始构建配置逐项比较，一致 |
| 固定版本 SQLite Vector | 19 个上游文件 SHA-256 一致；真实 C 扩展测试通过 |
| 源码归属与差异 | 项目 source membership、`git diff --check` 通过 |
| 审查 | 6 个任务专项审查通过；整组审查及修复复查通过 |

构建并非零警告：本轮设备首次构建出现过 Watch AccentColor 资源缺失提示，以及未使用 AppIntents.framework 导致的元数据提取跳过提示；未影响本次编译。原新增 Text 拼接弃用警告已修正。未把无签名编译当作实际安装或真机功能验收。

### 生活来源

已完成健康步数/睡眠、只读日历及前台保存时的一次定位，并接入设置、来源详情、生活筛选、首页指标和独立 AI 读取范围。新来源默认关闭。步数汇总不会绘制成连续行走轨迹；睡眠按自然日裁剪、重叠区间去重，支持夏令时。

本地存储测试覆盖原子写入、重启、重复导入、删除抑制、读取失败保留旧快照与空结果清理。生命周期测试覆盖暂停/后台/切日后的迟到结果，以及定位等待/允许/拒绝的变化。完整本地测试与 iOS 模拟器 CLI 构建通过，独立审查通过。

日历的 iOS 权限名称为“完全访问”，App 仅进行读取。采集暂停保留已有本地快照；AI 数据开关单独控制这些快照是否可用于回答。物理设备权限和数据准确性待验收。

### 连续对话

已实现按日保存、切页/重启恢复、追问上下文、原始来源入口和清空。每个日期最多 20 轮，保留最近更新的 30 个日期，编码后最多 12 MB；超限裁剪最早的线程。本轮继续加入 SQLite 持久化和当前日期内的 SQLite Vector 检索；跨天语义记忆不在当前范围。旧 JSON 存储会原子迁移并保留原文件。

来源修改、删除或 AI 读取范围改变后，相关回答和依赖它的后续回答失效。外发确认显示完整系统指令和实际用户内容，包括有限前文；确认前不读取 Key、不调用服务。保存相同配置但更换 Key 也会使旧确认失效。

持久化、日期隔离、引用重编号、清空与迟到回答、来源撤销、损坏文件保护、存储上限及外发内容一致性测试通过；完整回归和模拟器构建通过。

整组审查补充修复了数据库提交与界面状态的一致性：会话追加、清空及重置在 SQLite 成功提交后才发布新的已保存历史；失败保留已提交内容，并可在当前会话中重试。未提交回答不会成为追问依据，退出 App 后恢复已保存历史。真实 SQLite 触发器回滚测试覆盖失败、重试、重启和追问上下文；读取权限撤销时，即使 SQL 清理失败也立即阻止旧内容用于显示或 AI。

### 每日洞察与显示名称

每日洞察已改为由至少两条不同来源支持的本地综合观察，并生成带依据的下一步建议。只使用 Apple 本地模型，支持手动生成/重试、来源查看、按证据修订缓存及“不相关”反馈。自动生成仅在前台、今天、主动建议开启、非免打扰时段、每日额度允许且录音流程空闲时进行。提醒只创建草稿，确认后才安排通知。

每日洞察的引用校验、空白/错误输出、模型不可用、日期/权限/来源变化、取消和预算控制通过本地测试；任务代码审查通过。可见产品名已同步 WiseLife，Watch 主界面功能标题仍为“录音”；内部 bundle ID、目标名、存储位置保持兼容。

### SQLite 与 SQLite Vector

生活快照/删除抑制、按日会话/逐轮内容、洞察缓存/次数预算已保存到同一个系统 SQLite 数据库：`Application Support/WristNotes/Database/daybook.sqlite3`。使用逐行表、外键、查询索引、WAL、完整同步写入及事务；普通生活数据修改只更新变化的来源/日期。音频、图片和现有记录 ID 保持原有仓库。

旧 JSON/UserDefaults 归档按领域原子迁移并保留原文件，迁移标记与数据一起提交。日期按 Swift 参考时间存储，避免精度变化导致旧证据指纹失效。数据库及其 WAL/SHM 使用独立目录和 complete 文件保护，不改动媒体目录策略。

完整本地测试及模拟器构建通过；专项审查发现的存储错误恢复后旧权限范围残留问题已修复。新增回归覆盖权限撤销、删除、切日/语言变化后的重置与重试，以及模型调用前的再次检查。真实用户旧归档、锁屏保护和权限交互仍需真机验收。

SQLite Vector 已静态编译进 iPhone App，并使用系统 SQLite。向量由 Apple NaturalLanguage 在本机生成；实际 cosine scan 前先按当天、来源权限和模型筛选候选。资料库保留全部关键词命中，再补充语义命中；问 AI 引用当前原文，不索引生成总结。缺资源、语言不匹配或索引失败会回退关键词，资源仅在显式操作时下载。

原文截取、分段、每次索引量与全局缓存均有上限。模型版本、编辑、删除及权限撤销会使旧向量失效，清空索引保留原始资料。详见 [本地存储与检索](local-storage-and-retrieval.md)。

真实 C 扩展、过滤后排序、向量持久化、维度变更、编辑/删除/撤权、关键词回退和迟到任务测试通过。审查复现的同输入取消后不能恢复问题已修复，新增测试覆盖前台恢复、下载/刷新/切语言及清空后不立即重建；修复专项测试和模拟器构建通过，专项复查已通过。

### 最新硬件原型

实施期间主工作区新增硬件选择器（commit `8be638c`）。它的 EurekaRing 连接、电量、同步属于明确标注的演示数据。原生首页及设置已补齐硬件选择器。Apple Watch 使用真实 WCSession 的配对、安装和当前可达状态，保留后台传输说明和刷新；配对管理仍由 Apple Watch App 完成。EurekaRing 保持“计划支持”，不显示虚构连接、电量和同步数据。中/英/日文目录及模拟器编译检查通过，界面与 VoiceOver 尚待验收。


## 明确的产品边界

- 24 小时是按天组织记录；不表示全天后台录音或持续定位。
- 健康数据读取授权状态不能由 HealthKit 可靠探测；没有结果可能是未授权或确无数据，界面不能宣称授权成功或补造零值。
- Apple Watch SE 本身没有部分高级健康传感器；App 只读取 Apple 健康中实际已有并可访问的数据。
- 系统 AI 仍受 Apple Intelligence 设备、系统地区/语言及模型下载状态限制；模拟器构建成功不能证明真机模型质量。
- 自定义模型问答会在用户确认后发送预览文字至其配置的服务。纯端上模式不需要 WiseLife 服务器。
- 当前一次检索一天；SQLite Vector 用于该日期内的本地语义检索，跨天比较和长期语义记忆未实现。不宣称跨语言检索质量或将距离当作可信度。
- 模拟器界面操作被自动审批拒绝，本轮不绕过限制。真实权限、界面点击和物理设备模型/传感器路径需单独验收。

## 真机验收清单

以下项目尚未由本轮工具完成，建议在 iPhone 16 Pro 与 Apple Watch SE 上逐项验收：

1. 更新安装后检查旧录音、图片、UUID、转写及自定义模型设置仍可用；Watch 正常传输一条新录音。
2. 分别开启健康、日历和地点：授权前不读取；日历只读；保存记录时地点为一次定位。暂停后不继续采集，旧快照仍可查看。
3. 查看当天健康统计与 Apple 健康的一致性；无可读数据时显示闪念/图片回退，不显示虚构步数/睡眠。
4. 发起带引用的问答、追问、切页、退出重进；删除原资料或撤销 AI 数据开关后，旧回答/引用失效。
5. 在语义检索设置检查当前语言资源；缺失时显式下载；同义表达可以补充原文命中。中英混合、长文本与无关查询需人工评估。
6. 检索中切日期、切后台再回来、切语言、清除索引，确认无旧结果出现，关键词结果仍可用，后续合法检索能恢复。
7. 开启 Apple Intelligence 后手动生成多来源每日洞察；查看依据、忽略、重新进入；建议只生成可编辑提醒草稿。
8. 原有本地录音、系统/Whisper 转写、图片 OCR、总结/全文切换以及本地通知保持可用。
9. 检查中文/英文/日文布局、动态字体、深浅色、VoiceOver、硬件选择器和 Watch 状态详情。
10. 锁屏/解锁后验证数据库恢复；在真实历史数据量下测量首次建索引延迟、内存与耗电。

## 可重复的验证命令

在仓库根目录执行：

```sh
sh apps/wrist-notes/scripts/test_local.sh
xcodebuild -project apps/wrist-notes/WristNotes.xcodeproj \
  -scheme WristNotes -destination 'generic/platform=iOS Simulator' \
  -clonedSourcePackagesDirPath /private/tmp/wristnotes-model-packages \
  -derivedDataPath /private/tmp/wiselife-task1-build CODE_SIGNING_ALLOWED=NO build
xcodebuild -project apps/wrist-notes/WristNotes.xcodeproj \
  -scheme WristNotes -destination 'generic/platform=iOS' \
  -clonedSourcePackagesDirPath /private/tmp/wristnotes-model-packages \
  -derivedDataPath /private/tmp/wiselife-final-device CODE_SIGNING_ALLOWED=NO build
sh apps/wrist-notes/Tests/EmbeddedWatchSmoke.sh \
  /private/tmp/wiselife-task1-build/Build/Products/Debug-iphonesimulator/WiseNote.app
sh apps/wrist-notes/Tests/EmbeddedWatchSmoke.sh \
  /private/tmp/wiselife-final-device/Build/Products/Debug-iphoneos/WiseNote.app
```

项目 source membership 检查已包含在 `test_local.sh` 中。SQLite Vector 单独验证可执行 `sh apps/wrist-notes/scripts/test_semantic.sh`。

## 本地交付

原生改动已合回 `/Users/karama/Documents/Vessel/apps/wrist-notes`。74 个原生项目文件及 README、三份任务文档已逐字节核对；全部 266 个非原型跟踪文件与已验证工作区一致。合回前逐项确认目标原生文件没有并发修改，原型/官网及其他工作保持各自修改。主目录未暂存、提交或推送。
