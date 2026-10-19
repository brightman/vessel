# iPhone 设置原型 · 2026-10-18

> **2026-10-19 原生接入更新：** 下文记录的是 HTML 原型制作时的范围。SwiftUI 已接入真实 Watch 状态、外观、转写语言、导入、Keychain 与自定义 AI 总结，详见 [原生验证记录](../verification/settings.md)。Whisper 仍未接入；用户反馈传输和真机 ASR 已通过。

入口：[iphone-notes.html](iphone-notes.html)。本次改动范围为 HTML 原型。

## 2026-10-19 转写模型、语言与下载（纠正）

- 先选择“iPhone端上转写”或 Whisper，再显示对应配置。iPhone 模型名称和设置首页摘要已统一；描述为“iPhone系统语音模型，无需API Key，支持单语言转写，按需下载系统语言包”。
- **iPhone端上转写：** 与 Whisper 使用相同的卡片字段与语言下拉选择，取代原先展开的语言单选列表；选择语言后，在共用资源区域检查状态、按需下载、查看进度或重试，资源就绪后保存。已有或共享的系统资源可复用，不代表每个地区都对应独立语言包。
- Apple 列表完整展示上次开发机查询到的 30 个 locale，含地区差异：中文 3 项、粤语 1 项、英语 9 项、日语 1 项、韩语 1 项、德语 3 项、法语 4 项、西班牙语 4 项、意大利语 2 项、葡萄牙语 2 项。正式 App 必须读取实际 iPhone 的 `SpeechTranscriber.supportedLocales`，这个快照不代表所有设备上的最终列表。
- **Whisper：** 保留 Tiny / Base / Small 多语言模型，单独选择“自动检测”或指定一种语言；使用原始多语言模型的 99 个语言代码，不复用 Apple 的语言地区列表。原型不提供仅英语的 `.en` 版本，也不为这三个模型列出后来新增的粤语 token。
- Whisper 下载项为“下载多语言模型”，同一模型供所有支持的语言共用，无需逐语言下载。切换语言保留下载进度；切换模型大小重新检查对应资源。
- 模拟下载有进度、失败重试和保存门槛。切换 Apple 语言、转写模型、Whisper 大小或返回会取消未完成的模拟下载；旧回调不能覆盖当前状态。
- 下载完成不自动保存语言选择；点击“保存”后更新设置首页。返回放弃未保存的语言草稿，已完成的资源下载仍可复用。
- Apple 语言和 Whisper 语言分别保存；切换模型不会将 Apple locale 当作 Whisper 语言代码使用。
- 原型没有网络下载；初始普通话（中国大陆）和英语（美国）资源标记为已就绪，其他项演示下载流程。页面底部“演示控制”可选择下载成功或失败。
- 本次仅更新 HTML 原型，未修改 Swift。沿用此前浏览器来源未获授权的限制，本次未做视觉复核。
- 本次检查：JS 语法和 HTML ID 引用通过；Node VM / DOM 检查通过模型优先的页面顺序、Apple 30 个地区、Whisper 99 种语言及自动检测、独立保存、缺失资源提示、下载进度、失败重试、语言切换复用模型并保留进度、模型切换取消过期回调、保存与返回恢复。检查不代表浏览器视觉验收或真实下载。

### 语言能力核实依据

- [SpeechTranscriber.supportedLocales](https://developer.apple.com/documentation/speech/speechtranscriber/supportedlocales)：返回可识别的语言地区，包含尚未安装但可下载的资源；设备不支持时返回空列表。
- [SpeechTranscriber.installedLocales](https://developer.apple.com/documentation/speech/speechtranscriber/installedlocales)：返回本机已安装的语言地区。
- [AssetInventory](https://developer.apple.com/documentation/speech/assetinventory)：资源来自 Apple，系统预装、其他 App 下载或已有配置共用时无需重复下载；系统管理更新与回收。
- [maximumReservedLocales](https://developer.apple.com/documentation/speech/assetinventory/maximumreservedlocales)：App 可保留语言数量可能随设备存储空间不同。
- [SpeechTranscriber.init(locale:preset:)](https://developer.apple.com/documentation/speech/speechtranscriber/init(locale:preset:))：当前初始化需要指定一种 locale。
- 本轮开发机 macOS 26.5.1 实际查询：30 个 locale，归纳为 10 类语言，可保留数量为 5；这些不是用户 iPhone 16 Pro 的实测结果。iOS 26.3 模拟器本次查询 `isAvailable == false` 且列表为空，没有据此推断真机不支持。
- [Whisper 官方说明](https://github.com/openai/whisper#available-models-and-languages)：Tiny / Base / Small 分为仅英语版和多语言版；多语言模型可指定语言或自动检测。
- [Whisper 语言代码](https://github.com/openai/whisper/blob/main/whisper/tokenizer.py)：语言 token 列表由实际模型支持数量截取；接入运行时时应依据所选模型的语言能力生成选项。

## 2026-10-19 API 接口兼容选项

- 自定义模型的“连接配置”第一项新增“API 接口兼容”：默认 OpenAI，可选 Anthropic。
- OpenAI 对应 Chat Completions，Anthropic 对应 Messages。两者统一填写 API 版本级 Base URL，例如 `https://api.example.com/v1` 或 `https://api.anthropic.com/v1`，分别拼接 `/chat/completions` 和 `/messages`；完整端点地址会提示去掉后缀。
- 切换协议更新地址示例及协议说明，保留已输入字段，并使上次模拟测试失效。测试进行中切换协议，旧结果不会恢复保存权限。
- 保存包括协议选择；返回后重新进入恢复已保存值，设置首页显示“模型名称 · 协议”。返回放弃未保存的协议草稿。
- 此次协议扩展仅修改 HTML 原型；原生 App 目前仍是 OpenAI 兼容调用。HTML 仍无网络请求，不会连接真实 OpenAI 或 Anthropic 服务。
- 检查：JS 语法、HTML ID 引用，以及协议提示、切换后测试失效、旧结果隔离、保存/恢复、返回放弃草稿、完整端点地址校验均通过。Chrome 本地预览被浏览器安全策略拒绝（用户未授权该来源），未进行本次视觉复核。

## 页面与交互

- 首页右上角第一个圆形图标为 Watch 状态：灰色未连接，绿色已连接。点击展示文字说明，不通过点击切换真实连接状态。连接成功不等于某一条录音已传输完成。
- 第二个圆形图标为设置入口。
- 外观支持深色、浅色和跟随系统，应用于列表、详情、播放器及所有设置页面；选择跟随系统后会响应系统外观变化。
- 转写设置先选择 iPhone端上转写或 Whisper 多语言 Tiny / Base / Small；两者使用相同的语言下拉选择与资源下载流程。iPhone 单选语言并按需下载语言包，Whisper 自动检测或指定语言并按需下载多语言模型。保存后更新设置首页摘要，返回放弃未保存的草稿。
- AI 设置支持 Apple 本地模型和自定义服务。自定义项选择 OpenAI / Anthropic API 接口，并填写模型名称、Base URL、API Key。
- 自定义项需先模拟测试成功再保存。包括必填项、地址格式校验、测试中、成功、Key 错误和网络失败状态；修改字段使之前的测试结果失效，旧的异步结果不会覆盖新的配置状态。
- 音频导入入口已移至设置页，选择文件后返回笔记列表。详情页继续使用播放器下方的“总结 / 全文”标签。

页面下方的“演示控制”可切换 Watch 状态和模拟连接测试结果。它属于原型展示工具，不属于 App 设置。

## 转写模型选择

| 方案 | 处理位置 | 当前实现 | 取舍 |
| --- | --- | --- | --- |
| Apple SpeechAnalyzer / SpeechTranscriber | iPhone | Swift 已接入 | 默认推荐；系统管理语言资源。首次可能下载模型，设备与语言支持需运行时检查。 |
| Whisper 多语言 Tiny / Base / Small | iPhone | 原型选项，尚未接入 | 可考虑 WhisperKit 或 whisper.cpp；先下载模型，再离线使用。质量、内存、速度和耗电需用 iPhone 16 Pro 验证。 |
| 自定义语音转写 API | 用户指定服务 | 未加入此次原型，也未接入 | 后续可选，但会发送音频。需要独立的语音转写协议，普通聊天模型接口不能直接代替。 |

Whisper 的多语言版本用于中文，不能选仅英语的 `.en` 版本。原型暂不承诺模型大小、下载耗时或处理速度，具体取决于运行时和模型格式。

## AI 模型与后续原生接入

- **已接入的本地模型：** Apple Foundation Models。需要 Apple Intelligence 在该设备、系统、语言和地区上实际可用。不可用时保留原始笔记，并提示用户；不自动切换远程服务。
- **自定义模型：** 原型可选 OpenAI 兼容 Chat Completions 或 Anthropic 兼容 Messages 接口；Base URL 不包含 `/chat/completions` 或 `/messages`，模型名称必须是服务接受的模型 ID。原生 Anthropic 适配需后续实现，包括 Messages 请求/响应与 `x-api-key`、`anthropic-version` 请求头。
- 真实接入时，连接测试只发送固定测试文本；生成总结才发送用户选择的笔记文本，原始音频不发送。
- 原生 App 应将 Key 存入 iOS Keychain，将普通偏好独立保存。HTML 中 Key 为密码输入框，配置仅保留当前页面内存；刷新即重置，无网络请求、localStorage 或 sessionStorage。
- 当前 HTML 的“测试通过”只代表演示状态，不证明真实地址、凭据或模型可用。Swift 自定义服务调用、Keychain 和 Whisper 下载管理尚未实现。

## 本次检查

- `node --check`：脚本语法通过。
- HTML 检查：58 个 ID 无重复，脚本固定 ID 引用均存在；无网络调用和浏览器持久化接口。
- Node VM + DOM 替身的 12 组逻辑检查通过：导航、三种外观及系统变化、Watch 状态、转写设置保存/放弃草稿、AI 保存门槛、地址校验、测试成功、修改后失效、过期异步结果、失败重试、切回本地、总结/全文切换。
- 自动浏览器预览被本地 `file:` URL 安全策略拒绝；未绕过该限制。本次未验证浏览器渲染、实际滚动和点击效果，逻辑检查不能替代视觉验收。
- 未修改或重新编译 Swift。Watch → iPhone 传输故障不属于本次原型变更，仍未完成端到端验证。
