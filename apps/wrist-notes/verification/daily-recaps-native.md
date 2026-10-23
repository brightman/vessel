# 每日回顾 / 昨日回顾 — 原生实现验证

## 使用入口

- 今天首页的「昨日回顾」；选择历史日期后显示当天回顾。
- 「我的记录 → 回顾」按日期倒序展示，支持日期与回顾文字搜索。历史日尚未生成时可以点开整理。
- 详情包含回顾、较早版本待更新提示、生成时间/模型、资料覆盖说明和原始记录入口。生成中可取消；错误可重试。
- 模型沿用 AI 设置，默认 Apple 本地模型。外部 AI 需确认准确摘录；勾选「下次不再提示」后可自动生成。

## 实现边界

- 与每日洞察独立，只概括已有记录，不生成建议，一条有效来源即可生成。
- 日期资料通过完整 content/session scope 读取，独立于界面分页和 Ask AI 的 top-k。
- 每条长文本取开头、中间、结尾共 600 字摘录；所有允许的记录参与，不将摘录描述为完整原文。单次来源批次不超过 2400 字，分批归纳再合并；验证返回的来源编号。
- 没有转写的音频等待文字就绪；没有文字的图片只说明存在图片记录，不推断画面。原音频、图片、设备坐标不会作为附带元数据发送。
- 新增记录可保留旧版并标记待更新；删除、编辑或撤回读取权限会移除受影响的旧文。读取失败隐藏未验证内容并保留磁盘数据，避免误判为删除。
- 跨日录音的来源按日期和 ID 解析。健康刷新时间、自动标题与无关元数据不算新事实。
- 本机 SQLite 按日期归档，无 30 天裁剪；沿用数据库文件保护及不参与云备份的规则。表中保存回顾、引用信息和指纹，不复制完整原文或凭据。
- 在 App 前台空闲时处理昨日/浏览的历史日，不保证午夜后台执行。失败不自动循环；生命周期中断同一输入最多自动恢复两次，之后可手动重试。

## 验证

命令：

```sh
sh apps/wrist-notes/scripts/test_daily_recaps.sh
sh apps/wrist-notes/scripts/test_local.sh
ruby apps/wrist-notes/Tests/ProjectSourceMembershipSmoke.rb
xcodebuild -workspace apps/wrist-notes/WristNotes.xcworkspace \
  -scheme WristNotes -configuration Debug \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath /private/tmp/wiselife-quick-recording-build \
  CODE_SIGNING_ALLOWED=NO build
```

已验证：日期/DST、超过五条来源、权限过滤、待转写、一条来源、SQLite 跨 41 天重载和回滚、添加/编辑/删除判定、健康刷新去重、确认过期、一次/记住授权、异步过期结果、后台暂停恢复、失败去重及重启、源读取失败不删除归档、跨日引用、模型配置变化。

代码已通过一次独立只读审查及复审。发现并修复了来源存储失败误删、健康时间戳重复生成、中断恢复、跨日引用错位，以及复审中的读取失败处理。

**结果：模拟器 workspace 编译通过；完整 `test_local.sh` 通过；工程源码成员检查通过；任务修改的 `git diff --check` 通过。**

- [完整本地回归输出](daily-recaps-native/local-tests.log)
- [构建结果](daily-recaps-native/build-result.txt)
- 首次完整回归发现已有 Ask AI 测试的编译命令未列入其使用的 `NoteRepository` / `VoiceNote`，已补齐依赖后整套重跑通过。

未执行原生模拟器 UI 自动化；未调用真实外部 AI，未验证真机 Apple Intelligence 输出质量与实际手表/健康数据。网络服务测试使用拦截传输和虚构资料，不发送真实数据。
