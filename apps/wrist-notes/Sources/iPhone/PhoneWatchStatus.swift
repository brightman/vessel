import Foundation

struct PhoneWatchStatus: Equatable {
    var isSupported = true
    var isPaired = false
    var isInstalled = false
    var isActivated = false
    var isReachable = false

    var isConnected: Bool { isSupported && isPaired && isInstalled && isActivated && isReachable }
    var title: String {
        if !isSupported { return "Watch 通信不可用" }
        if !isPaired { return "尚未配对 Apple Watch" }
        if !isInstalled { return "手表 App 尚未安装" }
        return isConnected ? "Apple Watch 已连接" : "Apple Watch 未连接"
    }
    var message: String {
        if !isSupported { return "当前设备不支持 Apple Watch 通信。" }
        if !isPaired { return "请先在 iPhone 的 Watch App 中配对手表。" }
        if !isInstalled { return "请在 Apple Watch 上安装“语音笔记”，录音会自动传到这里。" }
        if isConnected { return "当前可以与手表 App 即时通信。每条录音的上传状态请在手表列表中查看。" }
        return "当前无法与手表 App 即时通信，后台传输仍由系统安排。录音保留在手表上；可打开手表 App，确认蓝牙已开启。"
    }
}
