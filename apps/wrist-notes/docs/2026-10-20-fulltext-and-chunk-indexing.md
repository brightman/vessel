# WiseLife 第二阶段：全文检索与完整分段索引

日期：2026-10-20。实施范围为本地开发代码，不代表已发布的 TestFlight 版本。

## 验收目标

- 中文关键词可覆盖完整标题、原文及图片 OCR。资料库可以搜索总结；问 AI 的事实召回使用允许读取的标题与原文。
- 长文本分段不再永久限制于前 1,800 字。索引分批生成、保存进度，恢复后继续，资料库搜索在前台逐批补齐。
- SQLite 先限制日期、来源类型及 AI 权限；全文与向量结果合并，仍以当前原始记录核实引用。
- 索引是可重建缓存。更新、删除、撤销权限、换模型、清空和取消不能重新引入过期内容。

## 平台能力验证

本机 macOS SQLite 内存库确认：FTS5 trigram 能命中连续中文 `设计方`；SQL `instr` 能命中双字词 `预算`。

独立 iOS 测试程序使用系统 SQLite 和内存数据库，验证：

1. `CREATE VIRTUAL TABLE ... USING fts5(body, tokenize='trigram')` 成功。
2. 绑定参数的 FTS MATCH 命中连续中文 `设计方`。
3. SQL 子串匹配覆盖 `预算` 和单字 `五`。
4. 不存在的词返回空结果。

测试设备：iPhone 17 Pro / iOS 26.3 模拟器。结果：**1 XCTest，0 failures，xcodebuild 退出码 0**。

记录：`/private/tmp/wiselife-fulltext-ios-runtime.log`、`/private/tmp/wiselife-fulltext-ios-runtime.xcresult`。测试源码为 `/private/tmp/wiselife-storage-lifecycle-integrated/FTSRuntimeTests.swift`，仅使用独立验证 App 的内存库，没有读取 WiseLife 实际容器或用户资料。

这项验证说明该模拟器运行时支持 tokenizer。

## 生产代码验证

隔离实现提交：`e724cb2`。完整本地回归与最终专项套件均退出 0：

```sh
sh apps/wrist-notes/scripts/test_local.sh
sh apps/wrist-notes/scripts/test_semantic.sh
```

日志：`/private/tmp/wiselife-fulltext-task1-local.log`、`/private/tmp/wiselife-fulltext-task1-semantic.log`。

- 完整原文尾部回归先失败：原代码未索引 1,800 字之后的词句；修复后能持久保存并命中尾段。
- 中文单字、双字和长词，标点、引号、FTS 操作符、大小写及组合 Unicode 均使用实际 SQL 验证。
- SQL 写入触发器验证投影与 FTS 同时回滚，错误时回退当前内存原文。
- 真实连接级 FTS5 API 暂时禁用 trigram，验证 SQL 降级；恢复分词器后验证已有投影回填。回填缺失也经过先失败再修复。
- 超过 64 段的原文跨批次、重新打开数据库后继续，已完成段不重写；不可用内容不阻塞其他记录，资源变化后可重试。
- 4,097 个真实 SQLite Vector 候选中，最后一条的最佳向量能进入结果，全部记录保留；没有旧缓存的总量截断。
- 验证旧派生表升级、模型切换、日期和来源权限、清空/取消期间的迟到拒绝，以及前台续建与无进展停止。
- 原有问 AI、远端发送确认、引用校验、对话事务、ASR、元数据迁移和生活数据回归继续通过。

另在 iPhone 17 Pro / iOS 26.3 模拟器直接编译实际 `DaybookFullTextIndex`、`DaybookRetrieval`、`DaybookDatabase` 等生产源码。使用内存库验证超过旧截断长度的中文原文、短词与 trigram、引号/操作符字面查询、来源权限、摘要仅供资料库、日期边界和删除同步：**1 XCTest，0 failures，退出码 0**。

该测试不替换索引或 SQLite 逻辑，不运行实际语义模型。独立工程与测试位于 `/private/tmp/wiselife-fulltext-ios-production/`；日志和结果为 `/private/tmp/wiselife-fulltext-ios-production.log`、`/private/tmp/wiselife-fulltext-ios-production.xcresult`。临时路径可能被系统清理；核心生产逻辑的回归保留在仓库 `Tests/DaybookFullTextChunksSmoke.swift`。

## 主工作区集成

`c82b22c` 包含首轮审查修复：自动续建期间展示最新已校验进度；首批结果前保留通用等待提示。13 个任务文件经过开发起点内容校验后回填，没有合并隔离快照提交，也没有覆盖其他工作。

在主工作区运行完整 `test_local.sh`，退出码 0；日志 `/private/tmp/wiselife-fulltext-integrated-tests.log`。使用以下命令构建 iPhone 与内嵌 Watch，退出码 0，`BUILD SUCCEEDED`：

```sh
xcodebuild \
  -workspace apps/wrist-notes/WristNotes.xcworkspace \
  -scheme WristNotes \
  -configuration Debug \
  -destination 'generic/platform=iOS Simulator' \
  -disableAutomaticPackageResolution \
  CODE_SIGNING_ALLOWED=NO build
```

构建日志 `/private/tmp/wiselife-fulltext-integrated-build.log`，仅出现既有的 AppIntents 元数据提取跳过提示。工程增加两个源文件的精确引用，并维护生成器静态源文件列表；没有运行工程生成器。

最终审查修复 `42c7bd2` 将续建和资源变更入口都限定为“资料库可见且 App 在前台”。扩展测试覆盖离开页面、在其他页面收到资源事件、拒绝旧结果，以及相同查询返回续建。修复后的针对性复审通过，无遗留发现。

该修复回填后再次运行实际语义/全文专项套件及上述完整 iPhone/Watch 构建，**两项退出码均为 0**。最终日志：`/private/tmp/wiselife-fulltext-final-semantic.log`、`/private/tmp/wiselife-fulltext-final-build.log`。生产全文索引源码与已通过 iOS 测试的实现一致；后续两次修复仅涉及状态展示、页面可见性绑定及相关测试。

## 实现入口

- `DaybookFullTextIndex.swift`：完整归一化投影、FTS5/子串查询、回填与关键词评分。
- `DaybookTextChunks.swift`：完整原文字符范围、句子优先切分及重叠。
- `DaybookSemanticIndex.swift`：事务迁移、进度、分批向量和全范围合并。
- `DaybookRetrieval.swift`：SQL 结果与实时来源核对、关键词回退、事实摘录。
- `DaybookSemanticSearchModel.swift`：前台逐批发布、续建与取消。

完整存储与检索规则见 [local-storage-and-retrieval.md](local-storage-and-retrieval.md)。

## 验证边界

全文/向量测试使用合成数据与确定性向量校验检索和排序；不能替代真机中文语义质量、能耗、大规模耗时及 Apple 资源下载验证。Apple 上下文模型仍可能受模型窗口限制，已处理完分段不等于模型完整理解了每个 token。

针对完整文本同步的锁持有时间做了一次主机内存库探测：10 万字符首次/未变化同步约 10.6/0.86 ms，100 万字符约 74.2/6.43 ms。该结果没有表明测试规模下存在新的阻塞问题，但不能作为 iPhone 响应时间保证；更大资料库与真机性能应继续实测。

跨日问答、昨日回顾、说话人范围查询和时间戳引用属于后续阶段。
