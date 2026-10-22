import Foundation

struct PendingRecording: Codable, Identifiable {
    let id: UUID
    let kind: RecordingKind
    let capturedAt: Date
    var duration: TimeInterval
    var location: CaptureLocation? = nil
    var uploadedAt: Date? = nil
    var transferFailed = false
    var uploaded: Bool

    init(id: UUID, kind: RecordingKind, capturedAt: Date, duration: TimeInterval, location: CaptureLocation? = nil, uploaded: Bool = false) {
        self.id = id
        self.kind = kind
        self.capturedAt = capturedAt
        self.duration = duration
        self.uploaded = uploaded
        self.location = location
    }

    private enum CodingKeys: String, CodingKey { case id, kind, capturedAt, duration, uploaded, location, uploadedAt, transferFailed }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        kind = try values.decode(RecordingKind.self, forKey: .kind)
        capturedAt = try values.decode(Date.self, forKey: .capturedAt)
        duration = try values.decode(TimeInterval.self, forKey: .duration)
        location = try? values.decodeIfPresent(CaptureLocation.self, forKey: .location)
        uploaded = try values.decodeIfPresent(Bool.self, forKey: .uploaded) ?? false
        uploadedAt = try values.decodeIfPresent(Date.self, forKey: .uploadedAt)
        transferFailed = try values.decodeIfPresent(Bool.self, forKey: .transferFailed) ?? false
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
        missingFileCount: Int,
        lastSyncedAt: Date? = nil
    ) -> String {
        guard isSupported else { return "此设备不支持 Watch Connectivity" }
        guard isActivated else { return "正在准备同步…" }
        guard companionInstalled else { return "请先在配对 iPhone 安装并打开 WiseLife" }
        if missingFileCount > 0 { return "有 \(missingFileCount) 条录音文件缺失，无法发送" }
        if pendingCount > 0 { return "已配对 · 待同步 \(pendingCount) 条" }
        if transferCount > 0 { return "录音已传输，等待 iPhone 保存确认" }
        if let lastSyncedAt {
            let time = lastSyncedAt.formatted(date: Calendar.current.isDateInToday(lastSyncedAt) ? .omitted : .abbreviated, time: .shortened)
            return "已配对 · 最近同步 \(time)"
        }
        return "已配对"
    }
}
