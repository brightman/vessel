# GT 6 第三方录音与 iPhone 通信咨询草稿

日期：2026-10-19。状态：仅本地草稿，尚未发送给华为。

## 主题

HUAWEI WATCH GT 6 / HarmonyOS 6.1.0：第三方 JS 麦克风录音及 Wear Engine iOS 文件传输支持确认

## 项目背景

计划开发独立手表录音应用：点击开始/停止长录音，长按录制短语音，音频先保存在手表，再传至自研 iPhone App，在手机端离线转写和生成摘要。后续支持普通 Android 手机，不使用自建服务器。

目标设备为 HUAWEI WATCH GT 6，用户提供系统版本 HarmonyOS 6.1.0，完整构建号待核对；首个配套手机为 iPhone 16 Pro。

我们查到开发者论坛将该设备归为 Lite Wearable JS；系统录音机资料要求特定固件，并限定其手机同步路径使用华为手机。因此需要单独确认第三方应用能力。

## 请协助确认

1. **麦克风接口**：GT 6 第三方 Lite Wearable JS 应用能否采集麦克风并保存音频文件？如支持，请提供准确的 API 文档、模块导入名、权限名称、最小 SDK/固件版本和可运行示例；是否需企业资质或服务白名单？如不支持，是否有公开授权的系统录音文件导出接口？
2. **持续录音**：第三方录音能否在熄屏、返回表盘后继续？最长时长、存储配额、音频格式，以及来电/低电量中断的回调与保存规则是什么？
3. **iPhone 文件通信**：GT 6 在与 iPhone 的华为运动健康配对时，能否通过 Wear Engine 将自研手表 App 的文件发送给自研 iOS App，并接收保存确认？请提供支持的型号/地区、SDK 下载、最小版本和两端样例。JS 文档中的文件小于 4MB、串行发送限制是否适用于这条链路？
4. **应用身份及后台接收**：两端应用需要怎样的服务开通、签名/身份绑定和用户授权？iOS App 在前台、后台或未运行时，分别支持哪些收发行为？
5. **真机私测**：只有 iPhone 时，如何向 GT 6 安装自签名测试 HAP？如果必须使用 Android 上的 DevEco Assistant，安装后切回 iPhone 配对是否会清除测试 App 或数据，需如何操作？

## 接入后的最小验收

GT 6 真机录制 10 秒可播放音频 → 文件传至 iPhone → 校验并持久化 → iPhone 发回保存确认 → 手表显示“已上传”。随后验证熄屏录音、断线重试和 30 分钟录音。

## 已查阅资料

- [GT 6 / HarmonyOS 6.1.0 开发问答](https://forums.developer.huawei.com/forumPortal/en/topic/0201227110981528048)
- [系统录音机及同步条件](https://consumer.huawei.com/cn/support/content/zh-cn16093758/)
- [GT 6 手机兼容表](https://consumer.huawei.com/cn/support/content/zh-cn16066413/)
- [Wear Engine JS 消息与文件通信](https://developer.huawei.com/consumer/cn/doc/connectivity-guides/send-message-0000001052460491)
- [Wear Engine iOS SDK 集成入口](https://developer.huawei.com/consumer/cn/doc/connectivity-guides/integrated-sdk-ios-0000001921071177)
