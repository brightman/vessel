# Apple 端上翻译与语义检索：正式 App 接入

日期：2026-10-31。用户要求「完成开发，我在真机上测试」。

## 已完成

- Ask AI 与资料库共用的 `DaybookSemanticIndex` 接入 Apple Translation。简体中文/英文索引可接受另一语言或中英混合问题；译文只作为语义查询输入。
- 使用实验中效果更好的 Apple `NLContextualEmbedding`，不再优先选句向量。缺少上下文资源时使用关键词，设置页可显式下载。
- 关键词、日期/来源过滤、姓名、聊天历史、回答提示与引用均继续使用原问题/原文。已关联说话人的直接 SQLite 检索保持不变。
- 译文只保留最近一次成功结果于内存，绑定问题、目标语言、资源 revision 和检索 generation。源变化、清除或资源变更后不能回写迟到结果。取消请求传播并在写入前复核。
- 设置 → AI 检索 → 本地语义检索：选择记录主要语言，查看上下文资源和翻译语言包状态，主动准备中英语言包、刷新、重建或清除索引。
- 语言包准备使用 SwiftUI `.translationTask` 和系统前台下载流程。提问只使用 `installedSource` 会话，不触发下载，不调用云翻译；下载取消/失败可重试。
- 旧句向量和新上下文向量由 `model_key` 隔离；下次检索自动按新模型逐批建立派生索引，保留业务记录。

## 验证结果

| 检查 | 结果 |
| --- | --- |
| 新增回归先红后绿 | 接入前失败于 `translated query must drive semantic ranking while original kind/date bound the candidates`；接入后通过 |
| `scripts/test_query_translation.sh` | 通过：原问题保留、混合语言、缺资源、无效输出、同语言跳过、取消 |
| `scripts/test_semantic.sh --apple-live` | 通过：译文排序、原问题 FTS、日期/类型限制、引用不混入译文、失败回退、缓存复用、清除/取消并发、上下文模型选择 |
| SQLite Vector 原有回归 | 通过：完整文本、断点续建、4,097 候选扫描、真实 tokenizer 不可用与恢复、迁移、资源重试、资料删除和过期结果隔离 |
| Mac 真实 Apple 链路 | 通过：英文预算问题 → 本机 Apple Translation → 中文上下文向量 → SQLite Vector，第一名为正确中文预算记录，返回原文不变。使用 3 条合成记录，未读取个人资料 |
| `scripts/test_speaker_ask.sh` | 通过：中英文说话人意图、姓名边界、日期、SQLite 关联、说话人隔离、权限与过期版本 |
| iOS Simulator Debug 签名构建 | `BUILD SUCCEEDED`；iPhone Simulator `332DEB86-4843-4543-8C73-4719B38DA704` |
| generic/platform=iOS Debug 构建 | `BUILD SUCCEEDED`，包含非模拟器 Apple Translation 分支 |
| 真机产物签名校验 | `codesign --verify --deep --strict` 通过 |
| 修改差异空白检查 | `git diff --check` 通过 |

环境：Xcode 26.3 (17C529)，iPhone 部署目标 iOS 26.0。构建和测试日志位于 `/tmp/wiselife-translation-production-20261031/`。真机产物位于 `/tmp/wiselife-publish-20261028/build/Build/Products/Debug-iphoneos/WiseLife.app`。

本次没有覆盖安装到用户 iPhone，也没有在真机上点击系统下载界面。Simulator 不支持 Apple Translation 实际推理，不能代替真机验收。未提交或推送 Git。

## 真机验收

1. Xcode 打开 `WristNotes.xcworkspace`，选择 `WristNotes` scheme 与 iPhone，覆盖运行最新版本，保留现有数据。
2. 打开「设置 → AI 检索 → 本地语义检索」。中文资料选择「简体中文」；英文资料选择「English」。
3. 如未就绪，分别点击「下载 Apple 上下文向量资源」和「准备中英翻译语言包」，完成系统提示。回来后点击「刷新资源状态」，确认两类资源都已就绪。语言包下载需要网络，后续查询翻译在端上执行。
4. 在「我的记录」选有文本的日期并搜索，让索引进度推进。模型升级会逐步重建向量，不需要重新转写录音。Ask AI 每次使用当前批次与完整关键词结果；它不等待整个范围的向量全部完成。
5. 对已有中文资料，用英文和中英混合提问，并写明 `YYYY-MM-DD`，核对回答引用的日期和原文。可使用相同主题的中文问题对比。翻译信息会进入检索范围说明。
6. 回归 Kate Bell 已绑定说话人的中英文提问：直接关联检索仍按原姓名与日期工作，不依赖向量或翻译包。
7. 取消一次语言包下载，确认仍可用原问题搜索，并能重新点击准备。快速切换搜索、退出页面、清除索引，确认没有旧结果回填。

## 范围与限制

- 当前跨语言查询范围是简体中文与英文，繁体中文/日语索引保留原问题检索，不宣称所有语言共享向量空间。
- 不翻译或复制整库资料；非所选语言资料主要通过原文关键词匹配。Apple 翻译和向量相似度仍可能误解措辞，不承诺每次命中。
- 本次 Mac 三条记录的生产链路验证证明接线有效，不等同于此前 72 问题实验的完整 App 命中率，更不能推算 iPhone 耗时。
- Ask AI 回答仍使用用户配置的 AI 模型；使用端上翻译不代表远端回答模型也变为本地。
- 沿用现有按范围维护与每批 64 块索引的生命周期，未改造成常驻全库后台索引。
