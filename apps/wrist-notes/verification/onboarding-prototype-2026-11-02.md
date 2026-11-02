# 首次使用 AI 引导原型验证

类型：原型验证记录 · 状态：HTML 已完成，设计待用户评审；Swift 未开发 · 日期：2026-11-02

关联：[产品设计](../prototype/onboarding-design.md) · [原型](../prototype/onboarding.html) · [总索引](../docs/INDEX.md)

## 范围与环境

- 新增独立 `onboarding.html`、CSS、JS；复用现有 WiseLife 样式变量、品牌图标和 Apple／Whisper 语言目录。
- 主原型新增两个链接：新功能体验、设置／语言与 AI／AI 能力准备。其余原型功能未迁移。
- Chrome 实际页面，通过 native CUA 点击检查；本机 HTTP 地址 `http://127.0.0.1:8794/onboarding.html`。浏览器专用 host 不可用，因此使用已授权的 Chrome 原生界面。
- 所有资源、连接检查均模拟；下载、转写、向量生成、网络服务或 Swift 未验证，也未声称实现。

## 已执行与结果

| 检查 | 实际结果 |
| --- | --- |
| `node --check apps/wrist-notes/prototype/onboarding.js` | 通过 |
| HTML ID 唯一、CSS／JS／图片资源存在 | Python HTMLParser 检查通过；本地 HTTP 返回 200 |
| 无 `fetch`、XHR、WebSocket、浏览器持久存储调用 | 源码检查通过；Key 只保留当前页内存，不联网 |
| 正常三步准备 | Chrome 实际点击：Apple 转写检查／下载→已就绪，Apple Intelligence 检查→已就绪，向量资源下载／校验→已就绪，能力检查显示 3 / 3 |
| 翻译增强不阻塞主流程 | 未下载中英翻译语言包，仍可达到 3 / 3；未引入空索引等待 |
| Apple 不可用 | 切换「本机 AI 不可用」场景；本地单选置灰、显示设备不支持；自定义 AI 可主动选择 |
| 自定义 AI | 虚构配置测试成功后出现下一步；把 OpenAI 改为 Anthropic 后回到待准备，需重新测试 |
| 未完成时跳过 | 弹层列出三项受限能力；确认后首页显示 0 / 3、基础记录可用与继续准备入口 |
| 下载失败／恢复 | `?state=failed` 展示网络失败与重新准备；实际点击重试后资源变为已就绪 |
| 深色和窄屏 | 深色浏览器页面可读；Chrome 390 × 844 响应式预览中控件单列、内容可滚动、主操作区保持可见；另观察到 363 px 窄屏适配 |
| 控制台检查 | 所见告警来自浏览器扩展 contentscript，未观察到原型脚本运行异常；不声称检查了所有浏览器扩展的 Issues |
| Git whitespace | 本次编辑路径 `git diff --check` 通过 |

## 实现检查与限制

- 每项资源以独立 key 管理模拟任务，切换资源取消对应未完成任务，回调检查任务身份；完成资源保留。自定义模型变更使测试签名失效。
- 对话框隔离背景焦点，提供 Tab／Shift-Tab 循环和 Escape 返回；动态状态有文字提示，不只靠颜色。
- 此次浏览器手动验证覆盖上表路径，没有自动化穷举所有语言、取消时序或每个失败组合。系统语言资源共享、实际断点续传、存储检查、网络鉴权、Keychain 与原生可用性仍需实现阶段验证。
- 首次引导当前为中文；继承现有视觉与浅深色，不声称完成英文／日文本地化。两个原型页面不共享模型配置；其差异明确记入产品设计。
- 允许先使用基础功能是本轮推荐方案；等待用户评审，不标记为原生产品规则已批准。
- 没有 Git 提交／推送，没有安装 App、操作 Watch 或发布网站。

## 2026-11-02 追加：数据授权与 AI 能力合并

以上表格记录初版（语音转写／理解／检索三个步骤）的验证事实。本轮根据用户反馈更新为 **语音转写 → AI 能力（理解与检索同页）→ 数据授权**，`3 / 3` 现在表示三个引导步骤；数据步骤确认选择即可，不要求全部授权。当前规则见[主要说明](../prototype/onboarding-design.md)。

在 Chrome 原生 CUA 重新实际点击验证：

- 正常路径：转写准备成功 → 合并 AI 页同时检查理解模型及下载检索资源 → 两项均就绪 → 数据授权 → 一项也不开启，点击「按当前选择继续」→ `3 / 3 步完成`，数据项为「暂不使用额外数据」。可选中英翻译未下载，不阻塞。
- 健康权限模拟未选择任何项目：返回显示「已完成权限选择」，明确无数据不代表拒绝，不虚构全部健康读取权限。
- 日历模拟不允许：显示「未授权」和「去设置中开启」，说明具体影响；再次进入模拟系统管理并允许，返回「已允许」。
- 外侧「填入虚构 AI 配置」进入合并页，填充虚构配置；测试通过后理解模型就绪，检索资源保持就绪。切到数据授权后，不再显示全部端上承诺，明确所选服务与另外的外发授权。
- 最新数据授权页实际截图检查：保留三步导航、滚动内容和固定底部按钮，主操作没有被页面说明遮挡。首屏说明随后进一步压缩，便于看到数据卡片。

本轮没有请求真实系统权限、读取健康／位置／日历、发送网络请求或修改 Swift。权限撤销后的真实生命周期、HealthKit 读取范围、系统定位和原生模型安装仍待原生阶段实现与验证。旧版的深色／390 × 844 检查不等于本轮全部新增状态已在手机验证。

最终检查：重新加载最新首页并截图，三项准备清单、端上隐私说明和底部主按钮完整可见。`node --check`、所编辑已跟踪文件的 `git diff --check`、新文件尾随空白、HTML ID 唯一、本地资源／说明链接存在性检查通过。源码未使用联网、持久存储或真实权限采集 API；已确认步骤路由为 `asr → ai → data → review`。

## 2026-11-02 追加：文案与现有首页衔接

用户要求更新转写用途、Apple Intelligence／自定义模型说明，并要求完成引导进入现有界面。本轮移除独立演示空白首页；完成和确认跳过共用跳转到 `iphone-day.html?preview=today#product`。主原型仍明确标注示例数据，两页模型状态未做跨页保存，Key 不通过 URL 传递。

- Chrome 实际点击 `?state=ready` →「开始使用 WiseLife」，地址变为上述主原型地址，显示现有「我的一天」、昨日回顾、片段和「一天／AI／行动／记此刻」导航。
- 在现有设置中切换 English，打开 AI model，实际显示 **Bring Your Own Model**，说明为用户自有 endpoint／Key 和允许的文字外发边界。随后恢复中文。
- 转写「为什么要设置」改为 AI 理解与原始录音保留 7 天／14 天的文案；未开发或启动定时清理，未改任何录音文件。
- 版本暂按用户给定 27.3 显示为 **WiseLife 端上 AI 产品要求**。读取 Apple 支持说明的当前正文为 iOS 27，未将 27.3 定义为 Apple 通用最低版本；实际仍须检查设备、语言、地区和系统模型状态。原生 26.3 适配未修改。
- 引导中文卡片附英文名称；现有设置英文翻译已验证。不声称整套引导已完成英文翻译。
- 静态检查：四个修改的 JS 文件 `node --check` 通过；相关已跟踪文件 `git diff --check`，新原型／设计／验证记录尾随空白、相对链接和跳转目标检查通过。

## 2026-11-02 追加：第 4 步使用说明与模拟器截图

当前流程更新为 **语音转写 → AI 能力 → 数据授权 → 使用说明 → 准备结果**。前三步规则不变；第 4 步按「使用 iPhone／使用 Apple Watch」阅读说明，点击「我知道怎么记录了」后记为已了解，不以硬件安装／配对成功为完成条件。主要说明见 [使用说明与截图](../prototype/onboarding-design.md#5-使用说明与截图)。

### 模拟器采集

- iPhone：`WiseLife Ask AI Acceptance`（iPhone 17 Pro，iOS 26.3 runtime，Device Hub 显示 26.3.1），已有 WiseLife `1.0.2 (10)`，bundle `cloud.karama.wisenote`；没有重装或清空数据。通过 Xcode Device Hub 原生 CUA 操作并以 `xcrun simctl io <simulator> screenshot <path>` 截取实际页面。
- 截图覆盖空日期首页、记此刻菜单、录音中的底部计时条、图片采集入口。实际点击「语音」开始一次短录音，截图后点击「结束并保存」，观察红色录音条消失；这是控件演示，不作为音频质量／转写准确率验收。未删除旧记录，未点击系统真实相机或访问私人照片。
- Watch：`WristNotes Transfer Test Watch`（SE 3 44mm，watchOS 26.2），以 `simctl install` 安装上述构建内嵌的 `Watch/WristNotesWatch.app` 后启动，截取空录音列表／红色按钮。没有录制 Watch 音频，没有修改真机。
- 原生截图压缩为 WebP，4 张 iPhone 全图＋4 张入口裁剪图＋1 张 Watch 全图，总计约 232 KB，保存在 [原型资源](../prototype/assets/onboarding/)。图片没有私人记录正文／凭据；裁剪未修改按钮或页面文字。使用系统 App 的真实消费端安装流程没有在模拟器验收，安装文案核对了 [Apple 官方说明](https://support.apple.com/zh-cn/109023)。
- 本轮找不到旧 `Simulator.app` 路径，改用已安装 Xcode 的 `Contents/Applications/DeviceHub.app` 操作模拟器；没有为此改动 Xcode 安装。

### 浏览器实际验证

Chrome 原生 CUA 操作，`http://127.0.0.1:8794/onboarding.html?state=usage`：

| 项目 | 实际结果 |
| --- | --- |
| iPhone 主题 | 开始录音、结束保存、拍照与相册可切换，文案与实际截图一致 |
| 截图查看 | 录音截图可放大，Escape 关闭后焦点返回原图片按钮 |
| Watch 分支 | 可切换，包含官方安装路径、原生录音图、轻点／按住手势、同步状态解释及返回 iPhone 入口 |
| 无手表路径 | 全部模型就绪、数据全不授权；确认数据进入第 4 步，默认 iPhone；确认了解后显示 `4 / 4 步完成` |
| 完成跳转 | 点「开始使用 WiseLife」进入 `iphone-day.html?preview=today#product`，显示原有「一天」与底部导航 |
| 小屏 | DevTools 390 × 844，截图可读、四步导航不挤出屏幕，内容可滚动、底部按钮固定可达 |
| 深浅色 | 390 × 844 实际切换，文字／按钮可读，截图保留原生浅色，不人为反色 |
| 静态 | `node --check prototype/onboarding.js`、任务文件 `git diff --check`、HTML 本地资源与图片路径／文档链接存在性、ID 唯一和尾随空白检查通过 |

控制台所见告警来自浏览器扩展的 `contentscript.js`，不把扩展 Issues 视作原型验收结果。资源模型、权限、引导完成状态仍为内存演示，没有实现 Swift 引导持久化。未验证真实 Watch 配对／传输、实际相机拍摄、ASR 或新模型下载；本轮没有提交／推送／发布。


<a id="native-implementation"></a>

## 原生实现与验收 · 2026-11-02

类型：原生验收追加记录。状态：代码、自动回归、模拟器构建与主要导航验收完成；真机未安装／未验收，未发布。依据：[当前设计](../prototype/onboarding-design.md#8-原生实现2026-11-02)；[实施计划](../docs/superpowers/plans/2026-11-02-onboarding-native.md)。

### 环境

- Xcode 27.2 / iPhone 17 Pro 模拟器，runtime iOS 26.3（Device Hub 显示 26.3.1）。模拟器构建 1.0.2 (10)，仅本地开发覆盖安装，没有递增发布版本。
- 独立新安装设备 `WiseLife Onboarding Acceptance`：`4AFE1316-3391-4696-86FA-4AD5BDE814EE`，未注入个人资料和示例记录。
- 旧安装设备 `WiseLife Ask AI Acceptance`：`E466E1BC-BA3C-4AC6-9802-6B6C901D8BF6`，原有资料保留。
- Device Hub 初次无响应，退出重开后恢复。其退出会关闭模拟器，随后重新启动，未抹掉设备。

### 自动检查

| 检查 | 实际结果 |
| --- | --- |
| `sh scripts/test_onboarding.sh` | 通过：首次安装、未完成跨重启恢复（运行时创建 DB 后仍 pending）、完成／跳过不再弹出、旧用户迁移、损坏状态保持访问、AI 双资源条件、草稿恢复、凭据型 URL 不进入草稿 |
| `sh scripts/test_ai_settings.sh` | 通过：配置验证、持久化、OpenAI／Anthropic 请求、错误与旧回调隔离；新增引导模式不会把已保存配置当作实时测试成功，原设置复用行为不变 |
| `TranscriptionSettingsSmoke.swift` | 使用 `scripts/test_local.sh` 中的同一 swiftc 源文件集合单独编译运行，通过：迁移、ready/save 门槛、失败重试、共享语言资源、旧回调隔离、持久化 |
| `ruby Tests/ProjectSourceMembershipSmoke.rb` | 通过：项目及 generator 的源文件成员完整，Watch／widget 目标隔离保持 |
| simulator `xcodebuild` | `BUILD SUCCEEDED`，退出码 0 |
| 任务相关 `git diff --check` | 通过 |

构建命令（仓库根目录）：

```sh
xcodebuild -workspace apps/wrist-notes/WristNotes.xcworkspace \
  -scheme WristNotes -configuration Debug \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath /private/tmp/wiselife-onboarding-build-20261102 \
  -clonedSourcePackagesDirPath /Users/karama/Library/Developer/Xcode/DerivedData/WristNotes-dbhvnupqcpjxlcfmgpmoinajgiii/SourcePackages \
  -disableAutomaticPackageResolution -jobs 2 CODE_SIGN_IDENTITY=- ARCHS=arm64 \
  IPHONEOS_DEPLOYMENT_TARGET=26.0 build
```

首次构建受旧 Pods target 的 iOS 14.0 最低版本与新 Xcode 不兼容阻挡；使用命令行 iOS 26.0 覆盖完成，不修改 Pods。过程中一次链接失败来自编译期间继续编辑了 Swift 初始化签名；停止变动后重新构建通过，不是运行时缺失依赖。

### 模拟器实际操作

- 首次安装启动显示欢迎清单，无权限自动弹窗；没有导入假数据。
- 第 1 步读取系统实际语言列表；选择日语，终止并重启 App，恢复语音转写页面与日语选择。Whisper 可切换，显示模型大小／共享多语言说明；缺失资源显示尚未下载。
- 第 2 步理解与检索分开显示。此模拟器的 Foundation Models 实际报告 Apple Intelligence 可用；向量模型缺失时，AI 步骤仍不算完成。
- 点击「检查 AI 能力」调用 Apple 向量资源请求，显示真实“正在请求”状态；本轮未确认资源成功安装，返回后仍显示缺失，没有假报就绪。可选中英翻译显示模拟器限制，不阻止继续。
- 切换自定义模型，展示 Bring Your Own Model、API 接口兼容、模型 ID、Base URL 和安全 Key 输入。空配置测试显示“请填写服务提供的模型名称”，不发送请求、不标记成功。真实云端连接本轮未测试。
- 模型文本框弹出键盘时底部主按钮收起；点击字段标题后键盘消失，主按钮恢复。
- 第 3 步四项均未授权时可确认并进入第 4 步，未出现强制授权链。权限允许／拒绝／前台撤回的系统交互留待真机验收。
- 第 4 步默认 iPhone，开始录音／结束保存／拍照相册可切换；显示实际模拟器截图，完整截图弹层可打开／关闭。发现完整图上方留白后修复为按可用宽度显示，重新安装复查正常。
- Watch 分支显示安装路径、点按持续录音、按住闪念、取消与同步说明；不检查／伪造安装或配对。无需 Watch 可点击“我知道怎么记录了”。
- 两项模型未完整时结果显示 2/4：数据已确认、使用说明已了解。明确列出不可用能力后，选择“先使用基础记录”进入原有首页。
- 跳过后终止重启，直接回到首页；设置 → 语言与AI → AI 与数据准备可回到上次进度，确认标记保持。
- 旧安装覆盖更新后直接显示原有首页，引导状态为 `existingUser`。只比较计数、不导出私人内容：[迁移计数证据](onboarding-native-2026-11-02/upgrade.json)。升级前后对话 10、录音 9、照片 0、录音会话 1、内容片段 1，均不变。

### 可复查截图

- [数据授权](onboarding-native-2026-11-02/data.webp)
- [iPhone 使用说明](onboarding-native-2026-11-02/usage.webp)
- [部分准备结果](onboarding-native-2026-11-02/review.webp)

教程使用的是本文件前文记录的模拟器素材；原生 assets 共 9 张 PNG，约 1.4 MB。截图只用于说明，不能作为真机录音质量／相机／Watch 传输／模型推理可用的证据。

### 尚未验收

本轮未安装到用户真机，未发布 TestFlight。完整 ASR／Whisper／向量资源下载及真实模型推理、云端固定文字连接测试、系统权限允许／拒绝／撤销、相机拍摄、真实 Watch 安装与同步仍需相应设备验收。自动测试覆盖完成状态的持久化，但本模拟器未以全部真实模型就绪跑完 4/4；已验证未完整也可主动跳过并恢复。

<a id="first-launch-only"></a>

## 同日后续：设置不再提供引导入口

用户明确要求「AI 与数据准备」仅用于新安装首次进入，不出现在设置的「语言与 AI」中。本节替代上文设置回看的产品行为；上文保留为当时验收事实。

- 删除原生设置行、弹层路由及 `fromSettings` 分支；首次启动仍由 `OnboardingRootView` 和原有持久化状态控制。未完成首轮可恢复，完成／主动跳过不重复弹出，旧安装升级直达首页。
- 主 HTML 原型删除设置入口，官网区域的独立设计演示链接保留。引导跳过与准备结果文案改为通过「语言与 AI」调整模型、通过「数据来源」管理授权。
- `sh apps/wrist-notes/scripts/test_onboarding.sh`：通过，覆盖首次、恢复、完成／跳过、升级与损坏状态。源码／HTML 静态核对确认设置路由已移除、启动门控保留；`node --check prototype/onboarding.js` 通过。
- iOS Debug 构建 `BUILD SUCCEEDED`，退出码 0（Xcode 27.2，generic iOS，`IPHONEOS_DEPLOYMENT_TARGET=26.0`）。本次未进行新的模拟器 UI 或真机操作，也未发布新的 TestFlight 构建；已发布的 1.0.2 (11) 不包含这次入口移除。
- 本地检查日志：`/Users/karama/Documents/WiseLife-Reports/2026-11-02-onboarding-entry/`。
