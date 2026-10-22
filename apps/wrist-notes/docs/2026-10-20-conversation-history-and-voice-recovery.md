# WiseLife 对话历史与声音档案恢复

日期：2026-10-20。范围：原生 iPhone App 的对话持久化、分页与声音登记恢复。未提交、推送、发布 TestFlight 或安装到用户手机。

## AI 对话

原逻辑会在资料快照变化时丢弃不再匹配当前资料的历史，且存储存在每天 20 轮、30 个日期等裁剪限制。现在将历史保存与当前回答的证据有效性分开处理：

- 所有已发送的问题及回答保存在本机 SQLite；10 是分页大小，不是保存上限。初次显示最近 10 轮，下拉或使用顶部按钮每次加载更早 10 轮。
- 问题先作为 `pending` 持久化，再检索或调用模型；成功、失败、取消更新同一 UUID。重新启动时保留未完成问题并标识中断。存储失败会提示并提供重试，不在问题尚未保存时请求模型。
- 使用 `(created_at, id)` 复合索引和 keyset 游标分页；单轮 UPSERT，不在每次回复时覆盖全部历史。
- 新增录音、转写完成、修改资料、切换日期或暂时缺少来源不会删除对话。旧回答可显示为历史，但过期的回答文本不会成为新回答的事实依据。
- 撤销来源读取权限时保留问题、清除受限回答和引用；显式清空全部历史需要确认。
- 兼容原有 SQLite/JSON 迁移，保留原 JSON 恢复副本。已经被旧版本裁剪且没有备份的聊天无法凭此次代码修复恢复。

独立审查提出的三项问题已修复并复审通过：重启后恢复追问的证据日期；先修复读取错误再重试写入；失败或取消后的本地来源链接绑定正确轮次。

## 我的声音

发现并复现的代码缺陷：声音模型只在初始化读取一次；读取失败后 `profile` 为空，界面误显示“未登记”，解锁或返回前台时也不会重读。

修复内容：

- 区分文件不存在与读取/校验失败；失败显示“声音档案暂时无法读取”，保留最后成功读取的档案。
- 解锁可用通知、回到前台、重进设置入口或登记页时重读；提供“重试读取”。
- 读取失败时不允许覆盖未知的旧登记；取消或退出只清理临时录音，明确删除才删除档案。
- 声纹继续原子保存于本机受保护文件 `Application Support/WristNotes/PrivateVoiceIdentity/profile.json`，排除备份，不上传、不进入检索索引。

完整文件保护可能造成启动时暂时不可读；此次未读取用户真实档案，也未确认用户手机上的具体触发原因。测试通过不意味着确认旧档案一定仍存在。

## 验证记录

| 验证 | 结果与证据 |
| --- | --- |
| 对话旧行为复现 | RED：新增资料不应删除历史的断言失败；`/private/tmp/wiselife-history-red.log` |
| 对话专项与审查回归 | GREEN：真实临时 SQLite 下的 10/10/10/5 分页、时间相同游标、翻页期间新增消息、不裁剪、生命周期、权限及读写错误恢复；`/private/tmp/wiselife-history-review-green.log` |
| 完整本地回归 | 审查修复及声音恢复修改前运行通过；迁移、回滚、现有业务及真实 SQLite Vector 等；`/private/tmp/wiselife-history-local.log`。之后对改动部分运行上述对话专项及下述声音测试 |
| 声音误报复现 | RED：读取失败不得显示未登记的断言失败；`/private/tmp/wiselife-profile-red.log` |
| 声音恢复专项 | GREEN：真实临时档案的保存/重开、读取失败、保留已有身份、重试、取消及删除；`/private/tmp/wiselife-profile-green.log` |
| iOS 生命周期 XCTest | 2 项通过、0 失败；真实生产 Store/Model 与 UIKit 通知，仅推理边界替换；`/private/tmp/wiselife-profile-ios-final.log`，结果包 `/private/tmp/wiselife-profile-recovery-ios-final.xcresult` |
| 完整 App 模拟器构建 | 最终重检通过，exit 0，`BUILD SUCCEEDED`；包含 iPhone 与嵌入式 Watch target，日志 `/private/tmp/wiselife-history-profile-final-build-recheck.log` |

原始最终构建遇到并行开发中的 `StopWiseLifeRecordingIntent.perform` 缺少可推断返回类型错误。该文件已由并行改动修正，本任务没有修改录音快捷指令或重新生成主 Xcode 工程。

### 复现命令

从仓库根目录执行：

```sh
sh apps/wrist-notes/scripts/test_conversations.sh
sh apps/wrist-notes/scripts/test_voice_profile_recovery.sh
ruby apps/wrist-notes/scripts/test_voice_profile_ios.rb /private/tmp/wiselife-profile-recovery-ios
xcodebuild test \
  -project /private/tmp/wiselife-profile-recovery-ios/VoiceProfileRecovery.xcodeproj \
  -scheme VoiceProfileRecovery \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro'
xcodebuild build -workspace apps/wrist-notes/WristNotes.xcworkspace \
  -scheme WristNotes -configuration Debug \
  -destination 'generic/platform=iOS Simulator' \
  -disableAutomaticPackageResolution CODE_SIGNING_ALLOWED=NO
```

## 真机复测

安装包含本次修改的构建后，检查：

1. 登记并成功保存“我的声音”，退出设置后重新进入，确认日期与时长保留；强制退出 App 再打开重复检查。
2. 锁屏后解锁并返回 App，确认档案恢复。若显示读取错误，保留错误文案并使用“重试读取”，不要先删除原登记。
3. AI 连续发送超过 10 轮，重启后检查最近 10 轮；顶部下拉继续加载旧记录。新增录音或更改资料后检查历史仍在。

未验证用户 iPhone 的物理锁屏行为、麦克风登记流程或本次 SwiftUI 分页手势实际点击；未重新执行真实 ASR/声纹推理或远端模型调用。使用合成临时数据，不访问用户对话、声纹或密钥。
