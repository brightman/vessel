# Apple 端上翻译 + 本地语义检索实验

日期：2026-10-31

## 结论

真实的 Apple 端上查询翻译显著改善了本测试集的中英跨语言检索。效果最好的已测组合是 **按记录语言翻译问题 + Apple contextual embedding + SQLite Vector**。

同时，原问题与译文的语义排名做等权 RRF 融合，在本测试集上弱于只使用译文做跨语言语义检索。保留原问题仍有必要，应优先用于人名、日期、来源和关键词约束，而不是强制与低质量跨语言向量排序等权混合。

已加入可复用 Swift 翻译组件和 iPhone 编译目标，在独立实验中调用。正式 Ask AI 的查询策略、索引生命周期和设置界面尚未切换；这份结果用于确定接入方案。没有安装 App 或改写个人数据库。

## 实验实现

- `AppleQueryTranslator`：调用 Apple `TranslationSession(installedSource:target:)`，检查语言包已安装，不在查询时下载资源，不调用云端翻译 API。
- `DaybookQueryExpansion`：保留原问题，生成可选译文；空输出、无效目标文字、缺少资源、调用失败时返回明确状态，保留原查询；取消会传播。
- 中英混合输入：不使用整句主导语言作为否决条件。包含目标语言之外的中文或拉丁字符时，以对应的中英方向翻译整句；原问题始终保留。
- `QueryRankFusion`：预先固定等权 RRF，k=60；每个排名列表去重，按 ID 稳定处理同分，不比较不同模型的原始相似度分数。
- 前台语言包助手：用 SwiftUI `.translationTask` 和 `prepareTranslation()` 运行 Apple 系统准备流程，随后检测中英两个方向都为 `installed`。

模型仍是上一轮的 Apple 句向量和 contextual 模型，revision、维度没有改变。没有引入第三方 embedding，没有翻译或重写原始记录，没有把译文当成回答证据。

## 环境与数据

| 项目 | 实测值 |
| --- | --- |
| 真实翻译环境 | Mac，macOS 26.5.1，25F80 |
| 翻译框架 | Apple Translation，`installedSource` 会话，`canRequestDownloads=false` |
| 语言资源 | en → zh-Hans 和 zh-Hans → en 均为 installed |
| 检索数据库 | 项目内 SQLite Vector，SQLite 3.51.0，FLOAT32 / COSINE |
| 固定测试集 | 与上一轮相同：24 个主题、72 条中英及混合记录、72 个问题 |
| 翻译路由数 | 144：每个问题分别考虑中文和英文目标 |
| 实际翻译 | 96 次完成，48 次同语言跳过，0 次接口失败 |
| 翻译输入 | 只使用合成测试问题；未读取个人录音或对话 |

“96 次完成”表示得到通过基本输出检查的真实译文，不代表语义翻译正确率为 100%。每个单语言检索场景均有 24 条候选，包含 23 个干扰项。

fixture SHA-256：`5956aee9115bf579a044e7116377de1cffe5d29fedaec02cf0a32b027672d90e`。没有按测试结果改动题目、答案、融合参数或人工修正译文。

## 1. contextual 模型：主要对比

所有检索在 Mac 上完成。查询和记录始终使用同一个目标语言模型。Top 1 为正确主题排第一；Top 3 为进入前三。

| 问题 → 记录 | 未翻译 Top 1 | 译文 Top 1 | 未翻译 Top 3 | 译文 Top 3 |
| --- | --- | --- | --- | --- |
| 英文 → 中文 | 3/24，12.5% | **18/24，75%** | 4/24 | **23/24，95.8%** |
| 中文 → 英文 | 1/24，4.2% | **18/24，75%** | 3/24 | **23/24，95.8%** |
| 混合 → 中文 | 6/24，25% | **21/24，87.5%** | 16/24 | **24/24，100%** |
| 混合 → 英文 | 10/24，41.7% | **20/24，83.3%** | 11/24 | **23/24，95.8%** |

同语言输入跳过翻译，结果保持原样：中文 → 中文 Top 1 15/24、Top 3 21/24；英文 → 英文 Top 1 16/24、Top 3 23/24。

## 2. 当前句向量：不能只加翻译就认为完成优化

此表直接调用句向量 API，去掉 App 的主导语言拦截以单独测量模型。

| 问题 → 记录 | 模型 | 未翻译 Top 1 | 译文 Top 1 | 译文 Top 3 |
| --- | --- | --- | --- | --- |
| 英文 → 中文 | zh-Hans 句向量 | 0/24 | 2/24 | 7/24 |
| 中文 → 英文 | en 句向量 | 1/24 | 16/24 | 17/24 |
| 混合 → 中文 | zh-Hans 句向量 | 3/24 | 2/24 | 8/24 |
| 混合 → 英文 | en 句向量 | 1/24 | 17/24 | 20/24 |

中文句向量的同语言检索原本就偏弱，本次翻译没有解决这一点。改善最明显的方案需要同时考虑 contextual 模型，而不是仅把中文查询送入当前的 640 维句向量模型。

保留 App 现有 wrapper 的对照也已运行：中文模式中英文问题由“无法生成查询向量”变为译文 Top 1 2/24；英文模式中中文问题由 0/24 变为 16/24。完整矩阵保留在结果文件中。

## 3. 等权融合不是默认最优方案

以下使用 contextual 模型，融合参数在实验前固定，没有按结果调参。

| 问题 → 记录 | 原问题语义 Top 1 | 译文语义 Top 1 | 两路 RRF Top 1 | 两路 RRF Top 3 |
| --- | --- | --- | --- | --- |
| 英文 → 中文 | 3/24 | 18/24 | 6/24 | 13/24 |
| 中文 → 英文 | 1/24 | 18/24 | 6/24 | 10/24 |
| 混合 → 中文 | 6/24 | 21/24 | 13/24 | 18/24 |
| 混合 → 英文 | 10/24 | 20/24 | 12/24 | 20/24 |

原问题直接进入非对应语言的 embedding 后排名质量偏低，等权融合引入了这些错误候选。因此建议跨语言语义通道以译文为主；原问题的实体与关键词召回应作为独立通道继续保留。后者的完整产品融合策略尚未在本轮实验中测量。

## 4. 真实译文与剩余问题

| 原问题 | Apple 端上译文 |
| --- | --- |
| What was the proposal to cut project spending and halt advertising? | 削减项目支出和停止广告的建议是什么？ |
| Kate Bell 今天对削减 project budget 和广告费用有什么建议？ | Kate Bell 今天对削减项目预算和广告费用有什么建议？ |
| 同一混合问题翻译为英文 | What suggestions does Kate Bell have today to cut project budget and advertising costs? |

本测试中两条包含 Kate Bell 的混合问题，在中英两个方向的四次翻译都保留了姓名原文；这不能推广为任意姓名都不会被改写。

已发现的错误和限制：

- `How did I get to work for a meeting after my flight?` 被译成“飞机起飞后，我是怎么去上班开会的？”。引入了原文没有明确表达的“起飞后”；正确的机场去公司记录仍只排第二。
- 混合餐厅问题的英文译文出现 `When makinding dinner...` 的语法错误。
- 混合预算问题在英文 contextual 检索中，把“增加预算”放在“削减预算”之前；正确记录排第二。否定、方向和细节区分仍需要核对原始证据。
- 中文睡眠问题翻译后在英文 contextual 模型中正确记录仍排第十，说明翻译不能解决所有语义召回问题。

因此日期范围、人物身份和来源权限应由原问题与结构化数据确定；答案和引用仍来自原始记录。译文只扩大或改善检索，不作为事实来源。

## 5. 耗时

本 Mac、已安装资源的 96 次实际翻译：

- 中位数：31.5 ms。
- P95：50.5 ms，采用排序后 floor(0.95 × (n−1)) 位置。
- 最慢：440.3 ms，为本次批处理的首个翻译请求。
- 翻译调用耗时合计：3.76 秒，不包含模型下载和 embedding 检索。

预检此前已运行过两个方向，所以这里的首个批处理请求不等于全新系统的严格冷启动。上述数据不代表 iPhone 真机时延，未测后台、锁屏或低电量场景。

## 6. 验证与交付状态

- 已先运行失败的策略测试，失败点为“translation must augment the original question”，然后实现并通过测试。
- 测试覆盖原问题保留、混合输入路由、缺资源回退、空/未改变/明显错误语言输出、同语言跳过、取消传播、RRF 去重和原查询排序保留。
- 真实 Apple 翻译完成，保存每个问题的原文、译文、状态与耗时。
- 六个模型 / wrapper 实验组均完成原问题、译文、融合对比；原文自检、SQLite 文本读取、FTS 和独立余弦计算断言通过。
- `AppleQueryTranslator.swift` 与 `DaybookQueryExpansion.swift` 已加入 iPhone target；iOS Simulator 全量 App 构建成功，日志：`/tmp/wiselife-translation-20261031/ios-build.log`。
- iOS Simulator 不执行 Apple Translation，真实翻译和 contextual 检索结果来自 Mac。没有声称已在 iPhone 真机验收。
- 没有提交或推送代码，正式 Ask AI 检索调用路径尚未启用新组件。

## 产物

- [翻译组件](../Sources/iPhone/AppleQueryTranslator.swift)
- [查询扩展和融合策略](../Sources/iPhone/DaybookQueryExpansion.swift)
- [策略测试](../Tests/LocalQueryTranslationSmoke.swift)
- [真实译文与耗时](apple-query-translation-2026-10-31-queries.json)
- [全部指标、跨语言样例与哈希](apple-query-translation-2026-10-31-results.json)
- 完整原始输出：`/tmp/wiselife-translation-20261031/run-1/`，其中 `retrieval/results.json` 包含每一项排名结果。

## 复现

在仓库根目录运行：

```sh
# 语言包未准备时，在 Mac 前台使用系统下载流程。
bash apps/wrist-notes/scripts/prepare_translation_resources.sh /tmp/wiselife-translation-resources

# 用新目录保留每次真实翻译，不人工改写测试输出。
bash apps/wrist-notes/scripts/benchmark_apple_translation.sh /tmp/wiselife-translation-rerun

# 不依赖语言包的策略测试。
bash apps/wrist-notes/scripts/test_query_translation.sh
```

本实验是固定的 24 主题合成诊断集，适合验证方案方向。它不等于真实 ASR 语料、完整资料库、人物绑定检索或最终回答准确率；下一步应按原问题解析结构化约束，并在真机与独立真实语料上验证“目标语言译文 + contextual 语义检索 + 原问题关键词”的完整流程。
