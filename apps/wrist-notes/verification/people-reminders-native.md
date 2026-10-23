# 说话人联系人与 Apple 提醒事项：实现与验证

日期：2026-10-21。工作目录：`apps/wrist-notes`。本轮完成两项已批准的原型流程，接入原生 SwiftUI／ContactsUI／EventKit。未提交或推送代码。

## 可用入口

### 说话人手动关联联系人

录音详情 → 全文 → 点击说话人名称 → 关联联系人／更换联系人 → 系统联系人选择器 → 确认关联。

- 系统选择器仅返回用户选中的联系人。保存 identifier、显示名称、最多 96 像素／32 KiB JPEG 小头像，不保存电话、邮箱或完整联系人。
- 不申请整个通讯录访问，不修改联系人。部分字段不可用时安全回退到默认名称／头像。
- 支持更换、确认解除及未关联时手动命名。个人名称原样展示，内置说话人标签本地化。
- 关联仅适用于这一条录音，不等同于声纹登记或跨录音自动识别。系统通讯录不会因此显示录音。
- 选择器打开时保留不可变的转写版本与段落快照；重新转写、重新分配说话人、运行中的处理或原记录删除会阻止旧选择保存。
- 使用现有 VoiceNote SQLite payload 持久化。旧数据无需联系人字段；重新转写／说话人分配变化清理旧关联，同一分配及普通段落文字编辑保留关联。

### 可选添加到 Apple 提醒事项

我的提醒 → 新建／编辑 → 开启“同时添加到 Apple 提醒事项” → 主动允许访问 → 选择可写列表 → 确认。

- 新任务默认关闭 Apple 选项；打开 App、刷新或浏览提醒不会触发系统权限申请。
- 使用 EventKit 完整提醒权限。显示真实可写列表及账户名，不假设设备有“本机”列表。
- 仅写任务内容、开始／到期时间、提醒时间、完成状态和随机任务 ID 链接；不附带源录音、全文或来源标识。iCloud 等账户列表按系统账户设置同步。
- 支持修改、完成、确认后成对删除、失败重试。解除 Apple 关联先删除外部任务，再安排 WiseLife 本地通知；删除或通知安排失败均保留可恢复状态。
- 外部修改标题／日期／完成状态在前台刷新时读回。外部删除标记为已移除，不自动重建。读取失败显示可重试状态；恢复权限后点击“重试 Apple 同步”。
- 被关联的任务由 Apple 提醒事项负责通知。即使更新结果不确定，也不另外安排 WiseLife 通知。
- Apple 写入前先保存本机意图；系统保存成功但本机确认失败时，稳定编辑草稿 ID 和随机 URL 标记用于定位同一个任务，防止重试重复创建。
- 缓存系统 ID 必须与标记一致；重复标记或身份不匹配拒绝修改。持久化采用 SQLite v4 的 `reminder_apple_links` 附表与事务。
- 外部删除了日期、改成不支持的内容或撤销访问时保留原本机内容并显示错误，不自动覆盖外部任务。

## 主要源文件

- `Sources/Shared/VoiceNote.swift`：联系人快照、编辑快照与失效策略。
- `Sources/iPhone/NotesModel.swift`、`SpeakerTranscriptView.swift`、`SpeakerContactViews.swift`：持久化入口、系统选择器与说话人管理。
- `Sources/iPhone/DaybookDatabase.swift`、`DaybookReminderPersistence.swift`：v4 迁移、持久意图、失败恢复与同步协调。
- `Sources/iPhone/AppleReminderService.swift`：真实 EventKit 适配器。
- `Sources/iPhone/DaybookReminderStore.swift`、`DaybookReminderViews.swift`：权限入口、列表选择、状态与重试。
- `Sources/iPhone/Info.plist`、`InfoPlist.xcstrings`、`Localizable.xcstrings`：提醒权限说明及中文／英文／日文文案。
- 实际 Xcode 项目与生成脚本均登记新文件；未运行项目生成器。

## 本轮验证结果

| 检查 | 结果与范围 |
| --- | --- |
| `sh scripts/test_speaker_contacts.sh` | 通过：关联／替换／解除、单录音范围、旧数据兼容、真实临时 SQLite 重开、失效快照保护；原 speaker／owner 回归通过 |
| `sh scripts/test_apple_reminders.sh` | 通过：本地行为保留、权限拒绝、更新／完成／删除、失败重试、外部编辑／删除、通知去重、保存后中断、SQLite 回执失败后同草稿重试、v3→v4 迁移 |
| 同脚本中的原 `DaybookReminderSmoke` | 通过：校验、权限、持久化、通知与磁盘回滚、并发、对账、损坏存储和偏好 |
| `sh scripts/test_metadata_sqlite.sh` | 通过：迁移、回滚、重试、payload、旧实例、附件、提醒差异更新、索引与版本兼容 |
| `ruby Tests/ProjectSourceMembershipSmoke.rb` | 通过：iPhone／Watch／录音组件源文件与生成器登记 |
| Xcode workspace 模拟器构建 | 通过：iPhone App、Watch App、录音组件；联系人字段保护最后修改后的增量构建也通过 |
| 独立审查 | 联系人失效快照、草稿重试 ID、结果不确定文案问题已修复并复审；无未解决阻断项 |
| 定向 `git diff --check` | 通过 |

完整构建命令（从仓库根目录）：

```sh
xcodebuild -workspace apps/wrist-notes/WristNotes.xcworkspace \
  -scheme WristNotes -configuration Debug \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath /private/tmp/wiselife-quick-recording-build \
  CODE_SIGNING_ALLOWED=NO build
```

环境：Xcode 26.3，iPhone Simulator SDK 26.2。首次完整构建只有一条 AppIntents 元数据提取跳过警告；最后增量构建日志无警告或错误。

本轮日志位于 `/private/tmp/wiselife-people-native-final-build.log`、`/private/tmp/wiselife-people-contacts-tests.log`、`/private/tmp/wiselife-apple-reminders-tests.log`、`/private/tmp/wiselife-people-metadata-tests.log`。

## 真机验收（尚未执行）

没有进行原生模拟器 UI 自动化，也没有通过工具读取真实通讯录或提醒事项。上面的测试使用临时合成数据和 Apple 服务替身；构建通过不代表系统权限和账户同步已验证。

1. 在 iPhone 安装开发构建。用有多说话人的录音打开联系人选择器；验证取消、确认、更换、解除、重开 App 后保留，以及未命名／无头像联系人。
2. 保持选择器打开时让原转写／说话人分配更新；返回后应阻止旧关联保存。
3. 创建默认本地提醒；再新建 Apple 提醒，分别验证拒绝权限、允许权限、选择 iCloud／其他可写列表和系统中的实际任务。
4. 修改时间／内容、完成任务；在系统提醒事项中修改／完成，再返回 WiseLife 刷新。检查仅由选定通知渠道提醒。
5. 在系统中删除关联任务，再返回 WiseLife；应显示已移除且不重建。恢复权限后重试；确认删除／解除关联时应移除同一 Apple 任务。
6. 验证锁屏通知与所选账户的跨设备同步；它们依赖系统通知、账户及网络设置。

人物资料页和按人限定范围的 Ask AI 不属于本轮交付。
