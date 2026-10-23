# WiseLife：iCloud 备份数据范围研究

日期：2026-10-19。核对范围：本地工作区，Git HEAD `816c1d6`，**包含尚未提交的原生 App 修改**。依据为当前源码和本次实时读取的 Apple 官方资料；没有读取用户录音、数据库或凭据，没有进行真机备份／恢复，没有修改业务代码。

## 1. 结论

WiseLife 的普通录音、转写、总结、照片、提醒和偏好设置可以进入用户自己的 iCloud 设备备份。此路径不需要 WiseLife 服务器、CloudKit 接入或额外的 App 账号；存储占用用户的 iCloud 空间。

当前大部分用户文件已经保存在默认参与系统备份的目录中。因此，当前实现不能把“端上处理”宣传为“数据绝不会进入任何云端”。这取决于用户的系统备份设置和备份是否成功完成。Apple 明确区分周期性设备备份与跨设备同步：[备份包含什么](https://support.apple.com/en-us/108770)、[选择适合 App 的 iCloud 方案](https://developer.apple.com/documentation/cloudkit/deciding-whether-cloudkit-is-right-for-your-app)。

**主要缺口：**

1. HealthKit 步数／睡眠、对话、洞察和语义索引共用一个未排除备份的 SQLite 文件，不能直接把整库当作普通笔记备份。
2. Ring 绑定、处理中任务、完成回执和格式化代次共用一个排除备份的目录。恢复录音库时丢失去重回执，存在再次同步产生重复笔记的风险。
3. 目前没有完成真实 iCloud 备份与换机恢复验收，目录符合备份规则不等于已成功上传。

## 2. 三种能力的区别

| 方案 | 用户得到什么 | App 要做什么 | 是否需要自建服务器 |
| --- | --- | --- | --- |
| iCloud 设备备份 | 换机／设备恢复时带回 App 数据 | 正确安排目录、排除可重建内容、处理恢复后的状态 | 不需要 |
| iCloud Drive 备份文件 | 用户可选中某个归档并在 App 内导入 | 开发导出／导入、版本、完整性校验、文件协调 | 不需要 |
| CloudKit 私有数据库同步 | 多台设备持续同步记录 | 增量上传、冲突、删除、离线队列和账户切换 | 不需要，但要开发同步层 |

系统备份是设备快照，不能作为 App 自有的单条笔记恢复接口；仅删除重装 App 不等同于执行设备备份恢复。官方换机流程是在设备设置过程中选择 iCloud 备份：[通过 iCloud 转移数据](https://support.apple.com/en-us/108344)。

当前 entitlements 只有 HealthKit，没有 iCloud 容器；源码没有 CloudKit 或 ubiquity 文件同步实现。这不妨碍普通沙盒文件参加系统备份。

## 3. 数据清单：技术资格与建议

下表“当前行为”根据代码和系统默认规则判断，不代表已核验某台设备的真实云端备份。适用前提是用户开启 iCloud 备份、没有关闭 WiseLife 的备份、空间足够且备份成功。

| 数据 | 当前存储／行为 | 建议 |
| --- | --- | --- |
| iPhone、Apple Watch、EurekaRing 已保存到手机的录音 | `Documents/VoiceNotes/Audio/*.m4a`；仓库没有主动排除 | 纳入备份；确认从不同来源复制后文件属性没有遗留排除标记 |
| 标题、全文、总结、时间、时长、来源、UUID | `Documents/VoiceNotes/notes.json` | 与音频一起备份，保持 UUID 和关联完整 |
| 已导入 App 的照片、说明、OCR 文本 | `Documents/PhotoMoments/Images` 和 `moments.json` | 纳入备份；这是 App 自己保存的副本，不能因为用户开启“iCloud 照片”就认为它已受照片图库保护 |
| 普通 AI 对话、引用、每日洞察、用户反馈 | `Application Support/WristNotes/Database/daybook.sqlite3` | 可备份非健康内容；先处理与 HealthKit 内容的混存问题 |
| 提醒内容、时间、完成／取消状态 | `Documents/DaybookReminders/reminders.json` | 纳入备份；恢复后重新核对通知权限及系统待触发请求，不直接沿用旧设备调度状态 |
| 外观、语言、模型名称／地址、AI 偏好 | `UserDefaults` | 普通设置可随备份恢复；恢复后重新验证资源和服务可用性，不能沿用“已连接”状态 |
| 日历／位置快照 | 当前与健康数据同库存储 | 技术上可备份；按明确的用户选择保存历史快照，恢复后重查权限、标注旧快照，不能将其当作当前系统数据 |
| HealthKit 步数、睡眠等个人健康信息 | 当前存入同一个 `daybook.sqlite3`，没有排除 | 不纳入 WiseLife 的 iCloud 数据；优先重新从 HealthKit 获取，确需持久化时独立本地存储并设置备份排除 |
| 含 HealthKit 信息的对话、洞察、引用、提醒内容 | 可能随普通领域内容保存 | 同样应纳入健康数据隔离范围；仅排除原始健康表不够 |
| 语义向量、文本分段、原文投影 | 当前与用户数据共用 SQLite | 可重建，建议拆至独立缓存库并排除；其中可能包含健康文字，不能视为匿名数据 |
| Whisper 下载模型及下载缓存 | `Application Support/WristNotes/Models`，下载时显式排除 | 保持排除；恢复后按用户操作重新下载；Apple 管理的模型不由 App 打包备份 |
| 自定义模型 API Key | Keychain，`WhenUnlockedThisDeviceOnly` | 保持设备绑定；换机后重新输入，不写入 JSON／数据库／导出包 |
| Ring 绑定、暂存音频、处理中任务 | `Application Support/WiseNote/Ring`，目录及日志显式排除 | 保留本地处理；恢复后重新连接设备、核对实际状态 |
| Ring 已同步回执、已删除记录防重信息、格式化代次 | 同上，当前一起被排除 | 拆出不含绑定秘密的可恢复映射／回执，解决恢复后重复导入问题；设计恢复时的设备身份核验 |
| 正在录制且尚未提交的手机音频、一般临时文件 | `tmp` | 系统不备份；不能承诺录制中的内容可从 iCloud 恢复 |
| 还只存在 Watch／Ring 的录音 | 不在 iPhone 主录音库 | 不能计入 WiseLife 的 iPhone 备份完成范围，应先成功传到手机；Watch 系统备份单独存在，不能替代传输完成确认 |

Apple 的文件系统规则：`Documents`、`Application Support` 通常参与备份，`tmp`、`Library/Caches` 默认不参与。可重新下载或生成的文件应排除：[文件系统目录用途](https://developer.apple.com/documentation/foundation/using-the-file-system-effectively)、[备份优化](https://developer.apple.com/documentation/foundation/optimizing-your-app-s-data-for-icloud-backup)。

`ThisDeviceOnly` 不应简单解读为“完全不进入任何形式的备份”：官方说明其备份可用于原设备恢复，但不会迁移到另一台设备。当前 API Key 的可靠产品表述是“换机需要重新配置”：[Keychain 可访问性](https://developer.apple.com/documentation/security/restricting-keychain-item-accessibility)。

## 4. 健康数据需要单独处理

Apple App Review Guidelines 5.1.3(ii) 明确要求 App 不得将个人健康信息存入 iCloud。Apple 自己的 Health 数据同步是独立系统能力，不能据此推出第三方 App 可以把读出的健康信息放入自己的 CloudKit 或普通备份数据库：[审核规则](https://developer.apple.com/app-store/review/guidelines/#health-and-health-research)、[HealthKit 隐私要求](https://developer.apple.com/documentation/healthkit/protecting-user-privacy)。

当前源码：`LifeSourceReader` 从 HealthKit 读取步数／睡眠；`LifeSourceStore` 与会话／洞察共用 `daybook.sqlite3`，语义索引也写入此库。文件保护 `FileProtectionType.complete` 是锁屏访问保护，**不等于**排除备份。

建议实现边界：

- 普通用户内容与 HealthKit 数据采用不同物理文件／数据库，按文件设置备份策略。
- 将使用健康来源的对话、洞察、引用、提醒标记来源；无法可靠区分时，相关混合内容保守留在本地。
- 恢复后，在用户允许、系统数据可用时重新读取 HealthKit，不强行恢复旧的读取权限。
- 处理迁移遗留的 `LifeSources/snapshots.json`、会话 JSON、旧洞察 UserDefaults；只修改新库会遗漏旧副本。
- 如采用“排除运行库、导出允许备份的数据快照”的方案，快照必须新建并只写入允许内容；不能只删除旧库的健康行后复制，因为空闲页或 WAL 可能仍保留旧内容。这是实现建议，尚未实施／验收。

## 5. 隐私与可见状态

### iCloud 备份的加密

普通 iCloud 备份有传输和服务器端加密，但默认不是全部端到端加密。用户在支持的地区／账户上开启“高级数据保护”后，iCloud 备份中的第三方 App 数据获得端到端加密；部分元数据仍有不同保护规则。因此不能统一宣传“Apple 永远无法访问备份”。来源：[iCloud 数据安全概览](https://support.apple.com/en-us/102651)。

### 备份排除属性的边界

Apple 将 `isExcludedFromBackup` 定义为系统备份选择的指导，明确不保证文件永远不会出现在任何备份／恢复中；部分文件操作还会重置属性。实现应在相关保存／迁移后校验属性，也不能声称修改该标记会删除历史云端备份：[备份优化](https://developer.apple.com/documentation/foundation/optimizing-your-app-s-data-for-icloud-backup)。

### 产品表述建议

> 录音、转写和 AI 处理优先在你的 iPhone 上完成，WiseLife 不保存你的内容到自建服务器。若你开启系统 iCloud 备份，符合备份范围的记录可随设备备份保存到你的个人 iCloud。使用自选云端 AI 时，仅按你的授权发送所需文本。

系统备份页建议展示“备份范围说明”和查看系统设置的指引。不要把 iCloud 账户可用、文件允许备份、备份已成功三种状态合并成一个绿色“已备份”。本次没有找到可供普通 App 获取整机备份开关、任务成功时间并主动触发整机备份的公开接口；不据此设计可实时核验的 App 内开关／进度。

用户可在“设置 → Apple 账户 → iCloud → 储存空间／管理账户储存空间 → 备份 → 当前设备”管理 App 的备份资格；在 iCloud 备份页查看实际完成时间。系统自动备份通常在充电、锁屏并连接 Wi-Fi 时执行，空间不足会失败：[管理备份范围](https://support.apple.com/en-us/108922)、[执行备份](https://support.apple.com/en-us/108366)。

## 6. 推荐开发顺序

1. **先完成系统备份的数据整理。** 保留普通录音、照片、文字、提醒与偏好；隔离健康数据、派生索引；拆分 Ring 绑定与可恢复回执。
2. **补恢复流程。** 保持 UUID／媒体关联；重新检查模型文件、Keychain、权限、通知调度和硬件状态；不自动重放格式化／解绑／录制等设备动作。
3. **完成真实备份与恢复验收后再发布承诺。** 测试录音可播放、全文／总结一致、照片／OCR 完整、提醒不重复、Ring 再次同步不重复，模型能重新准备。
4. 若用户需要“单独恢复 WiseLife、可选择历史版本”，再增加可导入的 iCloud Drive 归档；若需要 iPad／Mac 持续同步，再评估 CloudKit。现有原生 SQLite 无需为设备备份改成 SwiftData。

如开发自有归档，活跃 WAL 数据库应通过 SQLite 一致性快照机制导出；归档增加格式版本、媒体清单、校验与原子完成标志，恢复采用验证后切换。该要求针对 App 自建归档，不能据此推断 Apple 系统备份需要 App 手动复制 WAL。

## 2026-10-20 上架准备跟进

为避免含 HealthKit 数据的共享 SQLite 以及迁移遗留副本进入 iCloud 设备备份，当前代码在打开主数据库时将整个 `Application Support/WristNotes` 目录、数据库目录、数据库文件和 SQLite sidecar 标记为排除备份；成功迁移旧版 UserDefaults 洞察后删除该备份候选副本。录音与普通记录仍保存在 `Documents`，保持系统备份资格。

验证：先新增 XCTest 并确认 RED（目录标记为 `false`），随后修复后在 iPhone 17 Pro / iOS 26.3.1 模拟器运行 6 项生命周期测试，0 失败；`DaybookInsightSmoke` 同时验证旧洞察数据迁移后清理。测试没有执行真实 iCloud 备份／恢复，也不会清除用户既有的历史设备备份。

影响与边界：Application Support 中的洞察、对话历史和语义索引不会随 iCloud 设备备份恢复；用户需要重新生成洞察，旧对话记录不会自动带回。HealthKit 权限仍由系统管理，恢复后在用户授权时重新读取可用数据。公开隐私页已说明此备份范围。

## 7. 容量估算

按当前录音设置的目标码率粗估，采用十进制 MB／GB，不含容器开销、照片和其他数据，实际 AAC 大小有变化：

| 来源 | 码率 | 每小时 | 每天 1 小时、30 天 | 每天 8 小时、30 天 |
| --- | --- | --- | --- | --- |
| Watch | 32 kbps | 14.4 MB | 0.43 GB | 3.46 GB |
| iPhone | 64 kbps | 28.8 MB | 0.86 GB | 6.91 GB |

这些是累计原始音频体积，不是每次增量备份必定上传的流量。Ring 接入文档记录输出为 32 kbps，仍应以实际文件测量。Whisper 等可下载模型不应增加备份负担。iCloud 免费空间为 5 GB，并与用户其他数据共用；额外容量由用户的 iCloud 套餐承担：[iCloud 储存空间](https://support.apple.com/en-us/108922)。

## 8. 当前代码证据

- [NotesModel.swift](../Sources/iPhone/NotesModel.swift)：`Documents/VoiceNotes` 根目录、Ring 录音导入。
- [NoteRepository.swift](../Sources/iPhone/NoteRepository.swift)：`Audio`、`notes.json` 与原子索引保存。
- [VoiceNote.swift](../Sources/Shared/VoiceNote.swift)：全文、总结、来源和录音元数据。
- [PhotoLibraryModel.swift](../Sources/iPhone/PhotoLibraryModel.swift)、[PhotoRepository.swift](../Sources/iPhone/PhotoRepository.swift)：`PhotoMoments` 图片副本与索引。
- [DaybookDatabase.swift](../Sources/iPhone/DaybookDatabase.swift)：默认库路径、WAL、文件保护与混合领域表。
- [LifeSourceReader.swift](../Sources/iPhone/LifeSourceReader.swift)、[LifeSourceStore.swift](../Sources/iPhone/LifeSourceStore.swift)：HealthKit 读取和持久化。
- [DaybookSemanticIndex.swift](../Sources/iPhone/DaybookSemanticIndex.swift)：同库语义投影、分段和向量。
- [DaybookReminderStore.swift](../Sources/iPhone/DaybookReminderStore.swift)、[DaybookReminderPersistence.swift](../Sources/iPhone/DaybookReminderPersistence.swift)：提醒保存与调度状态核对。
- [AppSettings.swift](../Sources/iPhone/AppSettings.swift)、[KeychainSecretStore.swift](../Sources/iPhone/KeychainSecretStore.swift)：设置和设备绑定 API Key。
- [WhisperModelStore.swift](../Sources/iPhone/WhisperModelStore.swift)：模型根目录排除备份。
- [RingTransferStore.swift](../Sources/iPhone/RingTransferStore.swift)：绑定、任务、回执同目录排除备份。
- [WristNotes.entitlements](../Sources/iPhone/WristNotes.entitlements)：仅 HealthKit capability。

## 9. 尚未验证

- 用户 iPhone 当前是否开启本 App 的系统备份、剩余空间和最近成功时间。
- 当前安装包是否与本工作区一致；不能把源码结论直接当作设备状态。
- 从各来源复制的音频实际备份资源属性、真实备份中媒体和数据库的一致性。
- 换机恢复后的 API Key、硬件重连、Ring 回执缺失影响和健康来源隔离。
- 现有健康混存数据的安全迁移。本文提出的是整改方案，没有宣称现版已完成备份适配。
