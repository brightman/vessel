import Foundation
import Darwin

/// Explicitly invoked credential probe. Reads from an echo-disabled TTY; never stores the key.
@main struct ProviderProbe {
    static func main() async throws {
        guard let input = getpass("API Key (hidden): ") else { throw DesktopSyncError.invalid("No credential supplied") }
        let key = String(cString: input)
        memset(input, 0, strlen(input))
        var configuration = DesktopModelConfiguration()
        configuration.mode = .custom; configuration.baseURL = "https://api.deepseek.com"; configuration.model = "deepseek-flash"
        let service = DesktopModelService()
        do {
            let catalog = try await service.models(configuration: configuration, key: key)
            guard let model = catalog.first(where: { $0 == "deepseek-flash" }) ?? catalog.first else { throw DesktopSyncError.model("No models returned") }
            configuration.model = model
            print("Catalog: OK; selected model: \(model)")
            try await service.test(configuration: configuration, key: key)
            print("Connection test: OK")
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("wiselife-provider-probe-" + UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            let store = try DesktopStore(url: root.appendingPathComponent("probe.sqlite3"))
            let device = UUID().uuidString, token = try store.pair(deviceID: device, name: "Synthetic provider probe")
            let record = DesktopTranscript(id: "legacyNote:" + UUID().uuidString, title: "合成会议测试", capturedAt: .now, duration: 30, captureDevice: "测试数据", kind: "long",
                text: "项目负责人说明：先完成桌面文字同步。测试同学将在下周三完成验证。负责人和具体日历日期未明确。",
                spans: [.init(id: "fixture", start: 0, end: 30, speaker: "说话人 1", text: "项目负责人说明：先完成桌面文字同步。测试同学将在下周三完成验证。负责人和具体日历日期未明确。")], isFinal: true)
            _ = try store.exchange(.init(operation: "exchange", serverID: "probe", deviceID: device, deviceName: "Synthetic", credential: token, events: [.init(sequence: 1, recordID: record.id, record: record)]), serverID: "probe")
            let item = try store.items()[0]
            let summary = try await service.summarize(item: item, configuration: configuration, key: key, store: store, progress: { _ in })
            try store.save(summary, item: item)
            print("Synthetic summary: OK; citations: \(summary.references.count); stored with input hash: OK")
            print("No recording, transcript from the user library, or persistent credential was used.")
        } catch {
            print("Provider probe failed: \(error.localizedDescription)")
            exit(1)
        }
    }
}
