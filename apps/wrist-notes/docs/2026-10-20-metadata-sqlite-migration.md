# WiseLife 第一阶段：业务元数据迁移记录

日期：2026-10-20。范围：`apps/wrist-notes` 本地开发代码；不代表已发布到 TestFlight。

## 实现

- 录音、图片和提醒元数据迁入现有共享 SQLite 数据库。音频、图片仍是独立文件，路径与 UUID 保持不变。
- schema v2 新增 `voice_notes`、`photo_moments`、`photo_attachments`、`daybook_reminders`、`media_tombstones`，保留已有生活、对话、洞察与语义索引表。
- 录音保留完整转写、说话人、来源、处理状态及版本字段；照片保留附件顺序、每图 OCR 和错误；提醒保留通知 ID。
- 旧 JSON 按领域一次迁移，数据与完成标记共同提交。失败回滚并报错，可以重试。旧文件原字节保留；迁移后业务写入不再修改这些文件。
- 数据库写入成功后才发布新内存状态。定点更新与冲突检测防止多个实例覆盖彼此的数据。
- 媒体删除标记支持失败重试，防止启动时把已删除音频恢复。失败导入的文件清理会重新检查数据库归属，避免删除另一连接已成功采用的媒体。
- 提醒核对系统通知队列时会重新读取持久状态，并保护其他协调器正在调度的通知。
- 解锁可用通知和回到前台会重试打开录音、图片和提醒数据库。首次打开失败不阻止 Watch 接收初始化；数据库恢复后重放 Inbox，导入成功才确认。暂时失败保留界面已有记录，处理中断按数据库状态恢复。

## 验证证据

### 本地回归

在集成工作区运行：

```sh
sh apps/wrist-notes/scripts/test_local.sh
```

迁移与提醒修复版本 `2c6bd93`：退出码 0。覆盖现有录音、Watch 状态与手势、项目源文件成员、编辑、说话人、声纹、AI 配置、ASR 资源、照片、提醒、问 AI、对话事务、检索、建议、生活数据、每日洞察、SQLite 和 SQLite Vector 套件。

新增元数据套件使用真实临时 SQLite、合成媒体和 SQL 触发器，验证迁移完整性、重复导入、失败回滚、重试、删除不复活、并发实例、日期索引查询计划、v1 升级和未来版本拒绝。没有读取实际用户媒体、数据库或密钥。

记录：`/private/tmp/wiselife-sqlite-integrated-tests.log`。此路径为本机临时运行证据，可能被系统清理。

### 集成构建

```sh
xcodebuild \
  -workspace apps/wrist-notes/WristNotes.xcworkspace \
  -scheme WristNotes \
  -configuration Debug \
  -destination 'generic/platform=iOS Simulator' \
  -disableAutomaticPackageResolution \
  CODE_SIGNING_ALLOWED=NO build
```

`2c6bd93` 集成版本退出码 0；补齐生命周期恢复的最终版本 `9aa5fc8` 回填后用同一命令再次构建，退出码 0，iPhone 与内嵌 Watch 目标通过构建。最终记录：`/private/tmp/wiselife-sqlite-final-build.log`。未重新生成 App 的 Xcode 工程，Ring 编译开关保持关闭。

### 最终恢复路径

最终审查发现并修复了完整文件保护下数据库暂不可用时缺少重试入口的问题。在主工作区生成独立验证 App，运行实际生产模型、仓库、SQLite、Inbox 和提醒协调器；测试数据仅位于验证 App 的临时目录。推理、通知队列和 Watch 确认发送使用可控边界替身。

```sh
ruby apps/wrist-notes/scripts/test_storage_lifecycle_ios.rb /private/tmp/wiselife-storage-lifecycle-integrated
xcodebuild test \
  -project /private/tmp/wiselife-storage-lifecycle-integrated/StorageLifecycle.xcodeproj \
  -scheme StorageLifecycle \
  -destination 'platform=iOS Simulator,id=D9857EEA-8E8C-4788-BBC0-4EB3B10EE506' \
  -derivedDataPath /private/tmp/wiselife-storage-lifecycle-integrated/DerivedData \
  -resultBundlePath /private/tmp/wiselife-storage-lifecycle-integrated.xcresult \
  CODE_SIGNING_ALLOWED=NO
```

运行设备为 iPhone 17 Pro / iOS 26.3 模拟器；再次运行需选取本机可用模拟器，并为结果包使用不存在的新路径。最终退出码 0：**5 tests, 0 failures; TEST SUCCEEDED**。

覆盖：

1. 录音库首次打开失败仍初始化接收；恢复后重放 Inbox、继续待处理录音，重复通知不重复启动已完成处理。
2. SQL 触发器强制导入失败时保留音频与 sidecar，不发成功确认；前台重试落库后才确认。
3. 处理中状态写入失败后保留错误提示；存储恢复后继续转写并持久保存结果。
4. 图片库暂时打开失败保留已发布列表，恢复后可继续保存。
5. 提醒库首次打开失败后，无需重启 App 即可恢复、保存提醒并保留系统通知。

回归测试先在修复前复现提醒恢复失败（1 个测试、4 个断言失败），并复现错误提示掩盖持久处理状态（5 个测试、2 个断言失败），再验证修复通过。模拟器通过目录占用及 SQL 触发器模拟存储失败，不等同于实际锁屏文件保护验证。

最终日志：`/private/tmp/wiselife-storage-lifecycle-integrated.log`；结果包同上。构建仅出现既有 AppIntents 元数据提取跳过提示。全量审查及修复后的针对性复审均已完成，无遗留 Critical / Important / Minor 发现。

## 边界与后续

- SQLite 使用原有 complete 文件保护。模拟器测试不能替代真机锁屏、解锁、后台接收和配对 Watch 的端到端验证。
- 旧 JSON 是保留的恢复副本；后续删除数据库记录不会自动擦除该副本。备份清理、导出和同步属于后续数据生命周期工作。
- 当前上层仍使用内存数组；本阶段没有引入分页、FTS5、完整转写分段向量覆盖或跨日问答。
- 后续按已确认顺序开展全文检索与完整分段索引，再开展昨日回顾与跨日记忆。

存储说明见 [local-storage-and-retrieval.md](local-storage-and-retrieval.md)。
