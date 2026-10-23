# GT 6 → iPhone 设计与兼容性 · 2026-10-19

## 已确定范围

用户要求新目录开发，与 Apple 版功能一致。设备为 HUAWEI WATCH GT 6；先接 iPhone 16 Pro，普通 Android 后续支持。沿用之前确认的单红色按钮、长按闪念、录音列表以及手机笔记详情“总结 / 全文”。本轮不改原 Apple 版文件。

用户于 2026-10-19 确认手表系统为 **HarmonyOS 6.1.0**。这是用户提供的版本，未通过真机读取；完整构建号尚未提供，不能据此判断是否已达到 `6.1.0.117(SP4C00M04)`。

## 目标版本的兼容性结论

| 项目 | 当前证据与结论 |
| --- | --- |
| GT 6 配对 iPhone | 官方功能兼容表列出 iOS 13 及以上；系统配对支持不等于自研 App 的传输链路已可用。 |
| GT 6 开发类型 | 华为开发者论坛针对 GT 6 / HarmonyOS 6.1.0 的答复为 Lite Wearable JS；不能因系统版本为 6.1 就选用标准穿戴 ArkTS API。 |
| 系统录音机 | 官方要求固件 `6.1.0.117(SP4C00M04)` 及以上。 |
| 系统录音同步至手机 | 官方要求华为手机 HarmonyOS `6.1.0.120 SP8` 及以上，并要求运动健康及运动健康服务达到 `16.1.4.171`。该路径不满足 iPhone 或普通 Android 目标。 |
| 自研 App 在手表采集麦克风 | 尚无已核实的 GT 6 第三方 JS 录音 API、权限和后台运行约束；这是实现手表录音的首要阻塞项。 |
| 自研 App 向 iPhone 传音频 | Wear Engine 是候选方案；目标设备支持、SDK、应用配置及真机文件收发仍待验证。 |

当前不建议仅为本项目升级固件或更换手机：尚无证据表明这样能开放所需第三方录音接口。系统录音机的固件条件仅用于核对系统功能。

## 架构决策

- GT 6：使用 Lite Wearable JS 平台。按压状态机、录音元数据、发送队列与系统录音适配分离。取得真实录音接口前不模拟本机录音成功。
- iPhone：独立 SwiftUI App，复用已经实现的文件存储、播放器、SpeechAnalyzer 和 Foundation Models；保留音频导入以便独立验证手机能力。
- 传输：Wear Engine SDK 是计划中的设备通信层，不能用 WatchConnectivity 替代；也不假定存在可直接读取录音的 BLE 服务。
- 文件协议：数据分片顺序传输，手机逐片落盘、最终校验；只有手机持久化完成后的应用级确认才能标记“已上传”。底层发送成功不能代替该确认。
- 不实现“手表遥控手机录音”来代替用户要求的手表本机录音。

## 方案取舍

1. **GT 6 JS + Wear Engine + 原生 iPhone（选定方向）**：保留已有端上能力；需确认 GT 6 录音 API 及获得 SDK 接入配置。
2. 标准 HarmonyOS ArkTS 手表方案：官方区分 Wearable 和 Lite Wearable，不能直接用于 GT 6。
3. 系统录音机导出方案：需要官方提供导出或共享路径，不能直接访问其他应用沙盒。暂不作为自定义 App 的录音实现。

## 官方证据

初次查阅：2026-10-18。2026-10-19 通过公开搜索结果复核目标版本问答、系统录音机和手机兼容表；未访问此前被拒绝的开发者文档浏览器页面。下列 SDK 文档仍沿用初次取得的证据，未获得新的 SDK。

- [GT 6 开发问答](https://forums.developer.huawei.com/forumPortal/en/topic/0201227110981528048)：提问设备同为 GT 6 / HarmonyOS 6.1.0。2026-10-12 论坛答复称其为 Lite Wearable，使用 JS，不支持 ArkTS；测试安装通过 DevEco Assistant 与华为运动健康，可使用非华为 Android 手机。该答复不证明录音 API 可用，也未确认仅用 iPhone 的私测安装路径。
- [华为穿戴开发入口](https://developer.huawei.com/consumer/en/multidevice/wearables/get-started/)：分别列出标准穿戴与轻量级穿戴开发路线。
- [Lite Wearable 能力](https://developer.huawei.com/consumer/en/multidevice/wearables/lite/)：列出设备通信及本地音频播放，但不足以确认第三方麦克风录音能力。
- [华为手表录音机](https://consumer.huawei.com/cn/support/content/zh-cn16093758/)：列出上表中的录音机固件及华为手机同步条件。系统录音功能不能推导第三方可调用。
- [GT 6 手机功能兼容表](https://consumer.huawei.com/cn/support/content/zh-cn16066413/)：列出配对 iOS 的支持范围和手表录音机功能；“手表能录音”这一项不能解读为“录音能同步至 iPhone”。
- [Wear Engine](https://developer.huawei.com/consumer/cn/hms/huawei-wearengine)：官方列出 iOS 平台和 SDK 接入流程，需申请服务。
- [穿戴 JS 消息/文件通信](https://developer.huawei.com/consumer/cn/doc/connectivity-guides/send-message-0000001052460491)：消息上限 1KB，文件需小于 4MB，轻量级设备不应并行传输同类型文件。该页不足以独立证明目标固件与 iOS 的完整链路。
- [iOS SDK 集成](https://developer.huawei.com/consumer/cn/doc/connectivity-guides/integrated-sdk-ios-0000001921071177)与[iOS 消息通信](https://developer.huawei.com/consumer/cn/doc/connectivity-guides/phone-send-message-ios-0000001875158886)：入口存在，但本次自动提取正文失败；不能据此虚构方法签名。

公开资料未能确认不代表官方明确禁止。当前结论是“GT 6 第三方录音接口未确认”，不是“GT 6 不能录音”。

本次针对 GT 6、Lite Wearable、麦克风录音和 iOS Wear Engine 的开发者论坛检索，没有取得可用于实现录音驱动的新接口资料。

## 外部接入条件

- 在华为开发者平台核实 GT 6 第三方麦克风采集与后台录音接口，获得目标固件所需 SDK、权限和样例。
- 已准备[接入咨询草稿](huawei-integration-inquiry.md)，包含录音、后台运行、iOS 文件通信和私测安装问题；仅保存在本地，尚未发送。
- 获得 Wear Engine iOS/JS SDK 和对应应用开通配置。开发者身份、协议接受、证书私钥由用户在官方工具中处理，不在聊天中提交。
- 安装配套 DevEco 工具后，先做真实 10 秒录音 → 文件检查 → iPhone 接收 → 持久化确认，再做 30 分钟以上和熄屏测试。
- 手机转写/摘要不可用时保留原始录音，允许重试；绝不自动向外部模型上传。

## 验收层级

1. Node 单元测试可确认手势和队列规则，不能证明手表运行。
2. iPhone 编译可确认独立工程可构建，不能证明 Wear Engine 或端上模型可用。
3. GT 6 真机录音和 iPhone 文件接收通过后，才能宣称华为版本的录音链路已完成。
