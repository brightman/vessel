# HealthKit 数据更新（2026-10-20）

## 更新方式

- 只读 iPhone HealthKit 的步数和睡眠；Apple Watch 的健康数据需先由系统同步到 iPhone。
- 来源已启用时，在 App 启动阶段安装步数和睡眠的 `HKObserverQuery`；UI 与后台共用 `WiseLifeRuntime.life`，不会重复创建模型或观察查询。
- 步数申请 `.hourly` 后台通知，睡眠申请 `.immediate`。这表示请求的最高频率，不是固定刷新时间，也不保证立即送达。
- 通知到达、回到前台或受保护数据恢复时，刷新**今天、昨天、当前选中日期**，按日期去重。选择其他历史日期或点击“刷新所选日期”，会重新读取该日。
- 本次不保存全量 HealthKit 样本或 anchored query 游标。较早日期的修改/删除在查看或手动刷新该日时才同步，不声称后台实时同步全部历史。
- 没有每分钟健康轮询、服务器、云端备份或新增健康写入权限。

## 本地持久化与权限

继续使用 `LifeSourceStore` → `DaybookDatabase` 的 `life_settings`、`life_snapshots`、`life_records`；无需新增 SQLite 表或升级 schema。

步数仍由 `HKStatisticsQuery(.cumulativeSum)` 查询，避免直接累加来自 Watch/iPhone 的原始样本。睡眠按自然日裁剪并合并重叠区间。成功的空结果会删除该日旧快照中的已删除样本；应用内删除产生的 suppression 继续生效。

数据库仍使用 complete 文件保护，数据仍排除在 iCloud 设备备份之外。锁屏时如果 HealthKit 或 SQLite 无法读取/写入，则保留已有记录；能写入状态时标记旧快照，不能写入时保留错误供界面查看。解锁通知或下一次前台激活重新打开失败的数据库并补刷。

`UserDefaults` 仅镜像一个“健康来源曾启用”的布尔提示，供数据库不可读的冷启动注册观察查询。它不包含健康数据，也不授权读取：只有 SQLite 确认来源仍启用后才执行数据查询。数据库恢复时以 SQLite 为准，关闭过的来源不会因这个提示重新开启。

暂停来源会停止观察查询、请求关闭后台投递、取消当前读取，并保留旧快照。AI 使用健康数据仍需要单独的 AI 偏好授权。应用启动/解锁不会弹出新的健康授权请求；用户开启来源时才请求授权。HealthKit 不向应用披露读取授权结果，空结果也可能是未允许读取。

## 合并、取消和完成回调

- 同一轮通知合并为每个日期一次读取；所有健康读取串行化，避免前台/后台相互覆盖。
- 读取期间收到的新变化进入下一轮，不能用变化发生前已在执行的查询来确认该通知。
- 每个通知 completion 在对应轮处理结束后调用；失败、暂停、过期回调以及 20 秒 watchdog 均会结束处理并确认回调。
- HealthKit 读取 continuation 由 reader 持有；停止查询与结果回调争用同一个标识，避免重复 resume 或挂起等待。
- 观察查询和刷新各有 generation，暂停/重新启用后旧结果不能写入 SQLite。
- 后台 enable/disable API 调用串行执行，以最新开关状态为准。注册失败在来源设置页显示；解锁/回到前台会重新注册，并保留前台补刷。

## 验证

专项生命周期测试已通过，覆盖通知合并、后台持久化、删除同步、暂停/重新启用、超时、数据库恢复、冷启动提示和注册失败重试。本地完整回归与模拟器/通用 iOS 构建均已通过。

回归中发现旧 `SQLitePersistenceSmoke` 断言要求保留迁移后的洞察 UserDefaults，与此前已有的健康数据备份排除逻辑冲突。使用本任务开始时的源文件与测试重现同一失败后，仅更新该断言：成功提交迁移后删除旧 defaults；损坏、未完成迁移仍保留源数据。未更改洞察存储实现。

### 已执行的检查

- `sh apps/wrist-notes/scripts/test_health.sh`：通过。
- `sh apps/wrist-notes/scripts/test_local.sh`：通过，退出码 0；包含 SQLite、对话、检索、SQLite Vector、地点与健康刷新测试。
- `xcodebuild -workspace apps/wrist-notes/WristNotes.xcworkspace -scheme WristNotes -configuration Debug -destination 'generic/platform=iOS Simulator' -disableAutomaticPackageResolution CODE_SIGNING_ALLOWED=NO build`：通过，退出码 0。
- 同上，destination 改为 `generic/platform=iOS`：通过，退出码 0；未签名、未安装真机。最终中/英/日健康说明资源通过模拟器构建验证。
- `plutil -lint apps/wrist-notes/Sources/iPhone/WristNotes.entitlements` 与 `git diff --check -- apps/wrist-notes`：通过。

日志：`/private/tmp/wiselife-health-regression.log`、`/private/tmp/wiselife-health-simulator-build.log`、`/private/tmp/wiselife-health-device-build.log`。构建仍有既有 AppIntents metadata 警告，无新增健康代码编译错误。

### 真机验收（尚未执行）

1. 使用包含 `com.apple.developer.healthkit.background-delivery` entitlement 的有效签名安装 App。开启 Apple 健康来源，允许读取步数和睡眠。
2. 保持 App 前台，在“健康”中新增/删除今天或昨天的一条步数/睡眠测试记录；返回后核对时间轴、当天指标、昨天回顾和上次更新时间。多来源步数以健康系统汇总为准。
3. 将 App 置于后台，产生健康变化，等待系统投递。步数不要求几分钟内更新；睡眠也不能以固定时间判断失败。系统同步 Watch → iPhone 的时间不受本功能控制。
4. 锁屏期间产生变化，解锁/再次进入 App 后检查补刷，确认错误没有清空旧快照。
5. 暂停来源后产生变化，不应导入；重新启用后补刷。强制退出 App 后不要期待后台持续运行。
6. 修改较早日期，进入对应日期确认重新读取；不要将该行为误认为全历史后台增量同步。

Simulator 不支持 HealthKit 后台投递；编译和 mock 生命周期测试不能替代真机验收。

## Apple 依据

- [enableBackgroundDelivery](https://developer.apple.com/documentation/healthkit/hkhealthstore/enablebackgrounddelivery(for:frequency:withcompletion:))：后台 entitlement、步数每小时上限、启动时安装 observer、completion 要求与 Simulator 限制。
- [HKObserverQuery](https://developer.apple.com/documentation/healthkit/hkobserverquery)：数据变化通知；查询本身不返回变化样本。
