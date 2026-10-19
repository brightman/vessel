# 每日记录原生升级验证

日期：2026-10-19。现有 WiseNote App 升级；用户正在讨论 WiseLife 名称，本轮未更改安装标识或显示名称。

## 实现范围

| 模块 | 原生实现 | 本轮验证 |
| --- | --- | --- |
| 一天首页 | 日期选择、真实统计、24 小时发生时刻、录音／闪念／图片列表、当天搜索筛选、详情与确认删除 | iOS 编译；未完成界面实测 |
| iPhone 录音 | 麦克风授权、AAC 录音、开始／停止／取消、系统中断保留草稿、保存后转写；跨午夜保存后展示开始日期 | 编译；保存失败重试测试通过；真实录音待测 |
| 图片 | 拍照、PhotosPicker、最多 6 张、预览／移除／说明、端上 Vision OCR、失败重试、本地 JPEG、详情缩放 | 持久化／回滚／路径测试通过；相机、相册、OCR 质量待测 |
| AI 问答 | 一天范围检索、中文关键词、有限原文摘录、Apple 本地生成、原记录引用、取消与来源失效、按次远端确认 | 检索与异步状态测试通过；真实模型生成待测 |
| 本地回顾线索 | 实际原文卡片、来源回看、每日不同卡片上限、免打扰、稍后、今天收起 | 纯逻辑和重启持久化测试通过 |
| 提醒 | 标题／时间确认、系统通知、来源 ID、编辑／取消／完成／删除、权限失败与安排失败、前台展示 | 持久化及模拟通知接口测试通过；系统实际送达待测 |
| 设置 | 复用 Apple／Whisper 语言资源与 AI 协议配置，增加 AI 数据范围／频率／安静时段／提醒 | 原有设置、资源下载状态测试回归通过 |

首页线索是根据真实原文生成的回顾入口，不是后台模型自动分析。用户进入 AI 并提交问题后，才运行模型整理重点、提出有来源的建议。没有添加示例生活数据、健康或情绪推断。

## 兼容性与数据边界

- 使用现有 `cloud.karama.wisenote` 和配套 Watch 标识。与任务开始时快照比较，所有既有 target build settings、签名配置、Watch 源码、共享 VoiceNote 和 PhoneConnectivity 均未改动。
- 旧音频继续留在 `Documents/VoiceNotes`，不迁移 UUID、音频文件名或传输元数据。新图片存放 `PhotoMoments`，提醒存放 `DaybookReminders`。
- `NoteRepository.importRecording` 改为先复制音频、原子保存索引、成功后删除输入临时文件。索引保存失败会回滚新副本、保留输入供重试；旧录音接收与去重测试通过。
- 图片以最长边 2800 像素 JPEG 副本存储并移除元数据，系统相册原文件不变。没有原始全分辨率图片备份。OCR 无文字与 OCR 失败分别呈现。
- AI 只读取用户允许的文字，不发送原始音频或图片。自定义问答在确认前不读取 Key、不调用模型；确认时重新验证配置、日期、记录和来源权限。本轮没有向真实外部模型发送个人记录或测试数据。
- 引用校验保证编号来自检索材料，不能证明模型每一句话的语义都正确；界面提供原文核对入口。
- 一次查询一天、最多 5 段原文、每段最多 200 字、总上下文 1400 字；每次问题独立检索。向量索引、跨天记忆、HealthKit、日历和持续后台分析属于后续阶段。

## 已执行验证

### 完整离线测试：通过

```sh
sh apps/wrist-notes/scripts/test_local.sh
```

输出见 [local-tests.log](daybook-native/local-tests.log)。覆盖既有仓库、Watch 状态／手势、工程源文件、编辑、AI 配置／协议、转写配置、Apple 语言资源预留和 Whisper 缓存，以及新增：

- 录音索引写入失败后草稿仍存在，重试后可重开；回归用例先触发失败再修复通过。
- 图片保存／重开／删除、空批次与超限、路径与符号链接验证、部分写入回滚、失败删除保留文件。
- 检索日期边界、夏令时、真实今天／昨天、中文匹配、长文本尾部命中、摘录上限、全文统计、无数据／无文字、照片条数与张数区别。
- AI 异步取消、忽略取消的旧结果不能覆盖新问题、记录删除／改动／来源权限撤销、远端按次确认；生成边界采用受控替身，未验证真实模型质量。
- 提醒创建／编辑／取消／完成／删除、权限拒绝和中途撤销、系统安排失败、磁盘失败、取消回滚、并发串行化、重启协调与损坏文件保护。
- 回顾线索每日上限、降低上限、开关／安静时段、来源撤销、正文变化、删除、午夜重置、稍后、当天收起、重启持久化；偏好不保存原文。

### 完整构建：通过

环境：Xcode 26.3，iOS 最低 26，watchOS 最低 10。

```sh
xcodebuild -project apps/wrist-notes/WristNotes.xcodeproj \
  -scheme WristNotes -configuration Debug \
  -destination 'platform=iOS Simulator,id=D9857EEA-8E8C-4788-BBC0-4EB3B10EE506' \
  -derivedDataPath /private/tmp/wisenote-daybook-derived \
  -clonedSourcePackagesDirPath /private/tmp/wristnotes-model-packages \
  CODE_SIGNING_ALLOWED=NO build

xcodebuild -project apps/wrist-notes/WristNotes.xcodeproj \
  -scheme WristNotes -configuration Debug \
  -destination 'generic/platform=iOS' \
  -derivedDataPath /private/tmp/wisenote-daybook-derived \
  -clonedSourcePackagesDirPath /private/tmp/wristnotes-model-packages \
  CODE_SIGNING_ALLOWED=NO build

sh apps/wrist-notes/Tests/EmbeddedWatchSmoke.sh \
  /private/tmp/wisenote-daybook-derived/Build/Products/Debug-iphonesimulator/WiseNote.app
```

两种构建退出码均为 0，嵌入 Watch 路径检查通过。[模拟器构建摘要](daybook-native/simulator-build-summary.log) / [通用设备构建摘要](daybook-native/device-build-summary.log)。仍有 AppIntents 未链接而跳过元数据提取的构建警告；首次完整构建还报告了原有 Watch AccentColor 资源缺失。无新增 Swift 编译警告。

`git diff --check` 与 iPhone plist 检查通过。独立代码审查发现的提醒来源丢失、建议频率未接入、跨午夜保存展示日期、文件 URL 缩略图问题均已修复，并复核集成。

## 界面与真机验收边界

初次集成构建已安装并启动到现有模拟器，没有卸载或清空数据。随后 Simulator 界面控制被拒绝，停止了界面操作；没有通过截图、其他输入工具等方式绕过限制。之后的修正已重新编译，但没有再次操控模拟器安装和验收。因此本轮不能声称视觉、触摸和端到端采集已验收。

以下仍需在用户 iPhone 16 Pro 与 Apple Watch SE 上运行当前工程核对：

1. 已有录音和设置仍可访问，日期、筛选、来源链接、深浅色、小屏与大字体布局正确。
2. iPhone 麦克风拒绝／授权、录音停止与取消、来电中断、锁屏后台录音、跨午夜保存、保存后 ASR 和播放。未保存草稿在临时目录，系统终止 App 后不保证恢复。
3. 相机权限、相册／iCloud 图片加载、HEIC 转换、OCR 中文／英文、取消、保存／重开和图片缩放。进程被强制终止在图片文件写入与索引提交之间时，可能留下未引用文件；当前不实现崩溃后的照片孤立文件回收。
4. Apple Intelligence 实际中文回答、引用、耗时和取消。当前主机报告 `deviceNotEligible`；编译和替身测试不代表真机模型可用。
5. 按次外部模型发送确认、编辑期间来源失效、通知授权拒绝／重新授权、通知前后台实际送达、提醒编辑与取消。
6. 既有 Watch 传输用户此前已反馈真机修复并通过 ASR；本次未重做传输端到端测试，也未改动该通道。

本轮没有 Git 提交、推送或发布。
