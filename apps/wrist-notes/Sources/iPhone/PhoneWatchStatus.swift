import Foundation

struct PhoneWatchStatus: Equatable {
    struct TransferRow: Equatable, Identifiable {
        let sessionID: UUID
        let receivedChunkCount: Int
        let totalChunkCount: Int?
        let phase: WatchTransferPhase?
        let transferringChunkOrdinal: Int?
        let currentChunkFraction: Double?
        let reportedAt: Date
        let isComplete: Bool

        var id: UUID { sessionID }
        var stageLabel: String {
            if isComplete { return String(localized: "iPhone 已完整保存") }
            switch phase {
            case .some(.queued): return String(localized: "系统排队中")
            case .some(.transferring): return String(localized: "后台传输中")
            case .some(.waiting), .none: return String(localized: "等待手表继续传输")
            }
        }
        var segmentLabel: String {
            if let totalChunkCount {
                String(localized: "iPhone 已收到 \(receivedChunkCount)/\(totalChunkCount) 段")
            } else {
                String(localized: "iPhone 已收到 \(receivedChunkCount) 段")
            }
        }
        var currentChunkLabel: String? {
            guard !isComplete, phase == .transferring,
                  let transferringChunkOrdinal,
                  let currentChunkFraction = currentChunkFraction.flatMap(WatchSessionSyncSnapshot.validProgressFraction) else { return nil }
            let percent = Int((currentChunkFraction * 100).rounded())
            return "\(String(localized: "分片 \(transferringChunkOrdinal + 1)")) · \(percent)%"
        }
        var reportedAtLabel: String {
            let formatter = DateFormatter()
            formatter.locale = .current
            formatter.timeZone = .current
            formatter.dateStyle = .none
            formatter.timeStyle = .short
            return String(localized: "状态更新于 \(formatter.string(from: reportedAt))")
        }
    }

    var isSupported = true
    var isPaired = false
    var isInstalled = false
    var isActivated = false
    var isReachable = false
    var pendingCount: Int?
    var recordingTransfers: [TransferRow] = []
    var lastSyncedAt: Date?
    var reportedAt: Date?
    var transferFailureCount = 0
    var missingFileCount = 0
    var phoneSaveFailed = false
    var retryPending = false

    // Transport capability only; never use this as a user-facing connection indicator.
    var isConnected: Bool { isSupported && isPaired && isInstalled && isActivated && isReachable }
    var hasPairedWatch: Bool { isSupported && isActivated && isPaired }
    var canRetrySync: Bool { hasPairedWatch && isInstalled && isActivated }
    static func canRequestSyncRetry(isSupported: Bool, isActivated: Bool, hasPairingID: Bool, isPaired: Bool, isInstalled: Bool) -> Bool {
        isSupported && isActivated && hasPairingID && isPaired && isInstalled
    }
    var issueMessages: [String] {
        guard hasPairedWatch, isInstalled else { return [] }
        var issues: [String] = []
        if transferFailureCount > 0 { issues.append(String(localized: "\(transferFailureCount) 条录音上次传输失败，可重试同步。")) }
        if missingFileCount > 0 { issues.append(String(localized: "\(missingFileCount) 条录音的文件在手表上缺失，请在手表录音列表中检查。重试无法恢复已丢失的文件。")) }
        if phoneSaveFailed { issues.append(String(localized: "iPhone 暂时无法保存录音或同步记录。请解锁手机并检查可用空间，再重试同步。")) }
        return issues
    }
    var title: String {
        if !isSupported { return String(localized: "Watch 通信不可用") }
        if !isActivated { return String(localized: "检查中") }
        if !isPaired { return String(localized: "未配对 Apple Watch") }
        if !isInstalled { return String(localized: "已配对 · 手表 App 未安装") }
        if let pendingCount, pendingCount > 0 { return String(localized: "已配对 · 待同步 \(pendingCount) 条") }
        if let lastSyncedAt { return String(localized: "已配对 · 最近同步 \(Self.format(lastSyncedAt))") }
        return String(localized: "已配对")
    }
    var compactLabel: String {
        if !isSupported { return String(localized: "Watch 不可用") }
        if !isActivated { return String(localized: "检查中") }
        if !isPaired { return String(localized: "未配对") }
        if !isInstalled { return String(localized: "待安装 App") }
        if let pendingCount, pendingCount > 0 { return String(localized: "待同步\(pendingCount)条") }
        if let lastSyncedAt {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = .current
            formatter.dateFormat = Calendar.current.isDateInToday(lastSyncedAt) ? "HH:mm" : "MM/dd HH:mm"
            return String(localized: "最近同步\(formatter.string(from: lastSyncedAt))")
        }
        return String(localized: "已配对")
    }
    var pendingLabel: String {
        guard hasPairedWatch, isInstalled, let pendingCount else { return "—" }
        return String(localized: "\(pendingCount) 条")
    }
    var lastSyncLabel: String {
        guard hasPairedWatch, isInstalled, let lastSyncedAt else { return "—" }
        return Self.format(lastSyncedAt)
    }
    var message: String {
        if !isSupported { return String(localized: "当前设备不支持 Apple Watch 通信。") }
        if !isActivated { return String(localized: "同步服务正在准备，请稍后刷新状态。") }
        if !isPaired { return String(localized: "请先在 iPhone 的 Watch App 中配对手表。") }
        if !isInstalled { return String(localized: "请在 Apple Watch 上安装“WiseLife”，录音会自动传到这里。") }
        return String(localized: "显示最近收到的手表同步状态，后台更新可能延迟。长录音期间，每个已封口的片段会自动交由系统安排同步，结束后继续同步尾段；无需保持手表亮屏。未收到结束状态时，iPhone 仅能确认已保存的部分；最近同步时间以 iPhone 成功保存录音为准。")
    }
    private static func format(_ date: Date) -> String {
        date.formatted(date: Calendar.current.isDateInToday(date) ? .omitted : .abbreviated, time: .shortened)
    }
}
