# Ask AI：Kate Bell 关联发言检索修复

## 复现与原因

- 环境：iOS 26.3 模拟器 `332DEB86-4843-4543-8C73-4719B38DA704`，现有 WiseLife 数据和已保存的 `doubao-seed-2.0-mini` 配置。
- 原问题：`What’s Kate Bell’s opinion in today’s recording?`
- 修复前回答引用 10 月 30 日的 Apple 语音识别测试记录，检索范围是“全部获准记录”。
- 本机 SQLite 已有 Kate Bell 与 10 月 31 日 10:04 录音的说话人关联，活动转写包含该说话人的 85 条时间标记。关联并未丢失。
- 说话人路由原先只识别中文发言意图；日期解析也只识别中文相对日期。英文问题因此进入通用关键词检索，并丢失 `today` 的日期限制。
- 当时向量状态确实为 0/3、3 段 pending；索引空间是 `apple-sentence|1|640|zh-Hans|sentence-v1`。英文查询触发“查询语言或资源不可用”，在向量生成前退回关键词路径。联系人关联查询不应依赖该索引。

## 修改

- 英文发言、观点、录音等提问，以及仅输入联系人姓名，进入 SQLite 关联说话人查询；保留同名消歧、未关联提示和过期关联检查。
- 姓名识别支持英文大小写与所有格，避免把 Kate Bella 误当作 Kate Bell。
- 通用检索和说话人检索共用中英文相对日期解析，支持 today/yesterday/tomorrow/day before yesterday 及直、弯引号所有格。显式日期没有结果时仍保留原日期范围。
- 连续的词级 ASR 合并为有时间定位的短发言段，减少重复时间戳和姓名占用上下文；保留持久化转写、说话人归属和音频偏移。
- 录音整体标题保留在可点击引用中，模型的发言证据仅包含该联系人的关联转写，避免将其他说话人的标题摘要归因给该联系人。
- 联系人电话、邮箱等字段不进入模型上下文。

## 验证

1. `sh apps/wrist-notes/scripts/test_speaker_ask.sh` 通过。修复前原始英文问题、词级上下文截断、整段标题混入证据的回归分别失败；修复后通过。覆盖日期边界、同名联系人、姓名部分匹配、未关联、说话人隔离、过期版本、隐私字段及数字拼接。
2. 签名开启的 iPhone Simulator Debug 构建成功；Keychain entitlement 检查与 `codesign --verify --deep --strict` 通过。更新安装保留原 App 数据和模型配置。
3. XCTest 点击 Ask AI，发送原问题，通过现有豆包模型完成真实请求。最终 UI 测试 1 项、0 失败。
4. 10:33 的最新回答已持久化为 `completed`、`generated=1`，范围为 `2026-10-31`，携带正确的 `speakerContactID`，只有 1 个引用：31 日 10:04 的录音及其绑定 speaker。已截图人工检查引用日期与范围。

## 限制与证据

本次修复验证的是联系人/日期检索及发言上下文。原录音 ASR 存在明显不连贯和疑似错字，最终回答如实说明证据质量不足；未重新转写，也未完成跨语言向量检索优化。仅安装到模拟器。

本机验证目录：`/tmp/wiselife-speaker-ask-20261031/`。包含回归日志、`build-final.log`、`ui-final.xcresult`、`final-answer.json` 和 `final.png`。原始转写及联系人数据库快照留在该临时目录，未加入代码仓库；未读取或输出 API Key。
