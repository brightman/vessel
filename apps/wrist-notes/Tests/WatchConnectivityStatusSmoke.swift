import Foundation

@main
struct WatchConnectivityStatusSmoke {
    static func main() throws {

let id = UUID(uuidString: "3C29B9A0-1122-4333-8444-555566667777")!
let audio = Data((0..<100_000).map { UInt8($0 % 251) })
let chunks = SimulatorAudioChunks.split(audio)
precondition(chunks.count == 3 && chunks.allSatisfy { $0.count <= SimulatorAudioChunks.maximumChunkSize })
var assembler = SimulatorAudioChunkAssembler()
var reassembled: Data?
for (index, chunk) in chunks.enumerated() {
    reassembled = try assembler.append(chunk, at: index, total: chunks.count)
}
precondition(reassembled == audio)

let legacy = """
[{"id":"3C29B9A0-1122-4333-8444-555566667777","kind":"long","capturedAt":1000,"duration":3.5}]
"""
let restored = try JSONDecoder().decode([PendingRecording].self, from: Data(legacy.utf8))
precondition(restored.count == 1 && restored[0].id == id && !restored[0].uploaded)
var uploaded = restored[0]
uploaded.uploaded = true
uploaded.transferFailed = true
let roundTrip = try JSONDecoder().decode(PendingRecording.self, from: JSONEncoder().encode(uploaded))
precondition(roundTrip.uploaded && roundTrip.transferFailed)
precondition(!WatchConnectivityStatus.shouldRetryPendingTransfers(isActivated: true, companionAppInstalled: false))
precondition(WatchConnectivityStatus.shouldRetryPendingTransfers(isActivated: true, companionAppInstalled: true))
precondition(!WatchConnectivityStatus.shouldRetryPendingTransfers(isActivated: false, companionAppInstalled: true))

precondition(
    WatchConnectivityStatus.message(
        isSupported: true,
        isActivated: true,
        companionInstalled: false,
        pendingCount: 11,
        transferCount: 0,
        missingFileCount: 0
    ) == "请先在配对 iPhone 安装并打开 WiseLife"
)
precondition(
    WatchConnectivityStatus.message(
        isSupported: true,
        isActivated: true,
        companionInstalled: true,
        pendingCount: 11,
        transferCount: 3,
        missingFileCount: 0
    ) == "已配对 · 待同步 11 条"
)
precondition(
    WatchConnectivityStatus.message(
        isSupported: false,
        isActivated: false,
        companionInstalled: false,
        pendingCount: 11,
        transferCount: 0,
        missingFileCount: 0
    ) == "此设备不支持 Watch Connectivity"
)
precondition(
    WatchConnectivityStatus.message(
        isSupported: true,
        isActivated: true,
        companionInstalled: true,
        pendingCount: 11,
        transferCount: 0,
        missingFileCount: 2
    ) == "有 2 条录音文件缺失，无法发送"
)
print("Watch connectivity status smoke passed")

    }
}
