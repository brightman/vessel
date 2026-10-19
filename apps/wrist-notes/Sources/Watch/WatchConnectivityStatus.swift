import Foundation

struct PendingRecording: Codable, Identifiable {
    let id: UUID
    let kind: RecordingKind
    let capturedAt: Date
    let duration: TimeInterval
    var uploaded: Bool
    var recordingClock: RecordingClock?

    init(id: UUID, kind: RecordingKind, capturedAt: Date, duration: TimeInterval, uploaded: Bool = false) {
        self.id = id
        self.kind = kind
        self.capturedAt = capturedAt
        self.duration = duration
        self.uploaded = uploaded
    }

    private enum CodingKeys: String, CodingKey { case id, kind, capturedAt, duration, uploaded, recordingClock }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        kind = try values.decode(RecordingKind.self, forKey: .kind)
        capturedAt = try values.decode(Date.self, forKey: .capturedAt)
        duration = try values.decode(TimeInterval.self, forKey: .duration)
        uploaded = try values.decodeIfPresent(Bool.self, forKey: .uploaded) ?? false
        recordingClock = try values.decodeIfPresent(RecordingClock.self, forKey: .recordingClock)
    }
}

enum WatchConnectivityStatus {
    static func shouldRetryPendingTransfers(isActivated: Bool, companionAppInstalled: Bool) -> Bool {
        isActivated && companionAppInstalled
    }

    static func message(
        isSupported: Bool,
        isActivated: Bool,
        companionInstalled: Bool,
        pendingCount: Int,
        transferCount: Int,
        missingFileCount: Int
    ) -> String {
        guard isSupported else { return "此设备不支持 Watch Connectivity" }
        guard isActivated else { return "正在连接 iPhone…" }
        guard companionInstalled else { return "请先在配对 iPhone 安装并打开 WristNotes" }
        if missingFileCount > 0 { return "有 \(missingFileCount) 条录音文件缺失，无法发送" }
        if pendingCount > 0 { return "iPhone 已连接，待传 \(pendingCount) 条（传输中 \(transferCount) 条）" }
        if transferCount > 0 { return "录音已传输，等待 iPhone 保存确认" }
        return "已连接 iPhone"
    }
}
