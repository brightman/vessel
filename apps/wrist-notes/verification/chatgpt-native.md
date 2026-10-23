# WiseLife 原生 Sign in with ChatGPT

日期：2026-10-20。范围：`apps/wrist-notes` 的 iPhone 原生客户端。原型已在此前完成；本次实现原生设置、账号管理、Ask AI 和手动摘要。

## 已实现的客户端功能

- AI 模型设置顺序：**Apple 本地模型 → Sign in with ChatGPT → 自定义模型**。Apple 本地仍为默认，失败后不会自动切换到云端。
- 系统浏览器授权、PKCE、state/nonce 和 RSA ID-token 验签；本机临时 HTTP 回调监听；取消、超时、断开和旧回调隔离。
- 账号注册映射、多账号选择、账号可用模型列表、套餐提示、额度错误与管理用量入口。ChatGPT 连接与当前 AI 配置分别保存，配置通过校验后才生效。
- 凭证保存在 `WhenUnlockedThisDeviceOnly` Keychain 中，禁止同步。刷新合并为同一任务，轮换后的凭证必须写入成功后才可使用；不会导入其他 App 的凭证。
- 安全存储失败时暂停账号使用并显示恢复入口。保留尚未写入成功的轮换凭证；读取失败时重试读取，不用空数据覆盖。断开失败标记确保重启或重试不会重新启用已要求删除的凭证。
- Ask AI 在发送前展示实际指令、问题与检索文本；手动摘要展示完整转写和目标服务。原始录音、图片文件和声音档案不会通过此接入上传。Ask AI 历史回答保留其生成时的 provider/model 标签。
- 摘要长文本分段处理；输入、账号或配置变化会使旧确认失效。失败不会自动转用其他服务。
- 中、英、日文设置文案。

## 开启真实登录的前提

当前 `Sources/iPhone/Info.plist` 中 `WiseLifeChatGPTPublicClientEnabled` 为 **false**。设置中展示接入未开通状态，不会发起真实授权。

OpenAI 的官方文档将此公开客户端流程用于符合要求的开源客户端及获准的私有客户端。WiseLife 的发布资格尚未确认。开发中已询问用户该产品属于哪种情况；尚未得到答复。此项是外部接入条件，客户端代码完成不能代替它。

确认发布方式满足官方资格，且 OpenAI 明确允许本应用使用本实现对应的公开客户端和 HTTP loopback 合约后，才能将上述构建配置设为 true。商业应用若收到独立 client ID、回调或其他集成合约，应按获批合约适配，不能仅打开这个开关。

用户拥有 ChatGPT 账号、订阅或安装了 ChatGPT App，本身不代表 WiseLife 获得了接入资格。该流程不需要填写 API Key 或 client secret；自定义模型的 API Key 配置仍独立保留。

## 验证记录

以下命令均由主任务在最终相关代码就绪后执行，退出码为 0。环境：Xcode 26.3（17C529），iPhone Simulator SDK 26.2；模拟器构建不代表物理设备测试。

| 验证 | 命令（仓库根目录） | 结果 |
| --- | --- | --- |
| OAuth / ID token / SSE | `sh apps/wrist-notes/scripts/test_chatgpt_protocol.sh` | 通过 |
| Loopback 真实 HTTP 与浏览器适配器编译 | `sh apps/wrist-notes/scripts/test_chatgpt_loopback.sh` | 通过 |
| 账号、安全存储与摘要确认 | `sh apps/wrist-notes/scripts/test_chatgpt_accounts.sh` | 通过 |
| 既有本地回归 | `sh apps/wrist-notes/scripts/test_local.sh` | 通过 |
| iPhone 模拟器构建 | 下方 `xcodebuild` 命令 | `BUILD SUCCEEDED` |
| 配置与静态检查 | `git diff --check -- apps/wrist-notes`；新文件空白、plist 开关、Ring 配置、恢复文案检查 | 通过 |

```sh
xcodebuild build -workspace apps/wrist-notes/WristNotes.xcworkspace \
  -scheme WristNotes -destination 'generic/platform=iOS Simulator' \
  CODE_SIGNING_ALLOWED=NO
```

账号测试使用隔离 defaults、内存存储和假的网络服务，覆盖并发刷新/模型目录合并、轮换凭证落盘、断开取消、暂时失败与授权过期区别、首次套餐确认、读写失败恢复、同会话清理重试及重启清理。专项断言确认：刷新/模型目录等待期间确认失效时，推理调用次数为零；长摘要第一段后确认失效时，后续段落不发送。

完整本地回归还覆盖既有 AI 配置、转写资源、记录存储、Ask AI 精确预览和配置失效、对话持久化、权限变更、提醒、每日洞察及 SQLite / 语义检索。独立复核确认两个新增边界问题已修复。登录保存失败后释放授权状态的 iOS 路径已编译和源码复核，尚未以真实浏览器交互触发。

最后一次构建仅记录 AppIntents 元数据跳过提示（未链接 AppIntents.framework），没有编译错误。专项测试不使用真实授权或推理。

本机原始完整日志：`/tmp/wiselife-chatgpt-local-final.log`、`/tmp/wiselife-chatgpt-build-final.log`。这些临时日志可能在系统清理后消失；可用上述命令重新验证。

- [OAuth、身份验证与 Responses 核心](chatgpt-protocol.md)：本地 HTTP fixtures 与生成的 RSA 测试身份。
- [浏览器与回调监听](chatgpt-loopback.md)：真实 macOS loopback HTTP 测试与 iOS SDK 编译检查。

## 验证边界与后续真机检查

未进行真实 ChatGPT 登录、模型目录请求、推理、额度、刷新或撤销测试；未操作原生模拟器 UI。需要在具备接入资格的构建上，用物理 iPhone 验证系统授权页面期间的 HTTP 回调可达性，之后验证取消、后台切换、账号切换、首次套餐确认、模型获取、额度错误和断开。

真实 Ask AI/摘要测试应先使用用户同意的无敏感内容，核对确认文本与请求一致，检查切换配置、修改原文或断开后停止后续请求。测试记录不得保存密码、授权 URL、code、token 或 Keychain 内容。

既有笔记摘要仍只保存摘要文本，没有独立的历史 provider/model 字段；这与保留 provider 标签的 Ask AI 历史对话不同。本次不迁移共享笔记数据结构。

Ring SDK 由其他开发任务处理；本次沿用已有 `Config/BuildFeatures.json` 中的 `eurekaRing: false`，编译结果不代表 Ring 硬件验证。

## 官方合约

- [接入概览与资格](https://developers.openai.com/siwc/quickstart)
- [申请商业接入](https://developers.openai.com/siwc/request-client-id)
- [授权与回调](https://developers.openai.com/siwc/token-sharing-open-source/sign-in)
- [账号和会话](https://developers.openai.com/siwc/token-sharing-open-source/profiles-and-sessions)
- [Token 合约](https://developers.openai.com/siwc/token-sharing-open-source/token-reference)
- [模型和推理](https://developers.openai.com/siwc/token-sharing-open-source/models-and-inference)
- [错误与恢复](https://developers.openai.com/siwc/token-sharing-open-source/errors-and-recovery)

实现仅使用公开 `auth.openai.com` OAuth/discovery/JWKS 和 `api.openai.com/v1/models`、`/v1/responses`。Responses 设置 `store:false`、`stream:true`，仅完整成功的终止事件可成为结果；没有使用 ChatGPT 私有接口。
