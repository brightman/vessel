import SwiftUI
import Combine

@MainActor final class DesktopModel: ObservableObject {
    @Published private(set) var items: [DesktopLibraryItem] = []
    @Published private(set) var devices: [DesktopDevice] = []
    @Published private(set) var configuration: DesktopModelConfiguration
    @Published private(set) var pairing: DesktopPairingCode?
    @Published private(set) var serverStatus = "正在准备本机同步…"
    @Published private(set) var port: UInt16 = 0
    @Published private(set) var generatingID: String?
    @Published private(set) var generationProgress = ""
    @Published var error: String?
    @Published var showPairing = false
    @Published var showModelSettings = false
    @Published var pendingRemoteItem: DesktopLibraryItem?
    @Published var selectedID: String?
    @Published var addresses = DesktopSyncServer.localAddresses()
    @Published var selectedAddress = ""
    private var store: DesktopStore?
    private var server: DesktopSyncServer?
    private var generation: Task<Void, Never>?
    private var attempts = Set<String>()
    private let defaults: UserDefaults
    private let keychain = SyncKeychain(service: "cloud.karama.wiselife.desktop")
    private var preview = false
    init(defaults: UserDefaults = .standard, preview: Bool = false) {
        self.defaults = defaults; self.preview = preview
        configuration = defaults.data(forKey: "model-configuration").flatMap { try? DesktopSyncCodec.decode(DesktopModelConfiguration.self, $0) } ?? .init()
        selectedAddress = addresses.first ?? ""
        if preview {
            items = Self.previewItems(); selectedID = items.first?.id; serverStatus = "已连接 iPhone · 本地加密同步"
        } else { start() }
    }
    private func start() {
        let keychain = self.keychain
        let id = defaults.string(forKey: "server-id") ?? UUID().uuidString
        defaults.set(id, forKey: "server-id")
        Task {
            do {
                let loaded = try await Task.detached(priority: .utility) {
                    let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("WiseLifeDesktop", isDirectory: true)
                    let store = try DesktopStore(url: root.appendingPathComponent("library.sqlite3"))
                    let identity = try DesktopTLSIdentity.load(keychain: keychain)
                    return (store, identity)
                }.value
                store = loaded.0
                let server = DesktopSyncServer(serverID: id, identity: loaded.1, store: loaded.0)
                server.onReady = { [weak self] port in
                    Task { @MainActor in self?.port = port; self?.serverStatus = "等待 iPhone 同步"; self?.renewPairing() }
                }
                server.onChange = { [weak self] in Task { @MainActor in self?.refresh() } }
                server.onFailure = { [weak self] in Task { @MainActor in self?.serverStatus = "局域网同步不可用"; self?.error = "请检查系统设置中的局域网权限，重新打开 WiseLife。" } }
                self.server = server; try server.start(); refresh()
            } catch { serverStatus = "同步尚未启动"; self.error = error.localizedDescription }
        }
    }
    func refresh() {
        guard let store else { return }
        do {
            items = try store.items(); devices = try store.devices()
            if selectedID == nil || !items.contains(where: { $0.id == selectedID }) { selectedID = items.first?.id }
            if !devices.isEmpty { serverStatus = "已配对 \(devices.count) 台 iPhone" }
            autoGenerate()
        } catch { self.error = error.localizedDescription }
    }
    func renewPairing() {
        guard let server, port > 0 else { return }
        addresses = DesktopSyncServer.localAddresses()
        if !addresses.contains(selectedAddress) { selectedAddress = addresses.first ?? "" }
        guard !selectedAddress.isEmpty else { error = "请连接 Wi‑Fi 或有线局域网，再生成配对码。"; pairing = nil; return }
        let host = selectedAddress, port = self.port
        Task { pairing = await server.pairingCode(host: host, port: port) }
    }
    func revoke(_ device: DesktopDevice) {
        do { try store?.revoke(device.id); generation?.cancel(); refresh() }
        catch { self.error = error.localizedDescription }
    }
    func apiKey(configuration: DesktopModelConfiguration? = nil) throws -> String {
        String(data: try keychain.read((configuration ?? self.configuration).credentialAccount) ?? Data(), encoding: .utf8) ?? ""
    }
    func save(configuration supplied: DesktopModelConfiguration, key: String) throws {
        var configuration = supplied
        if !configuration.isLocal { configuration.autoSummarize = false }
        _ = try configuration.endpoint("models")
        guard !configuration.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw DesktopSyncError.model("请填写或选择模型名称。") }
        try keychain.write(Data(key.utf8), account: configuration.credentialAccount)
        generation?.cancel()
        defaults.set(try DesktopSyncCodec.encode(configuration), forKey: "model-configuration")
        self.configuration = configuration; attempts.removeAll(); autoGenerate()
    }
    func generate(_ item: DesktopLibraryItem, allowExternal: Bool = false) {
        guard generatingID == nil, let store else { return }
        if configuration.model.isEmpty { showModelSettings = true; return }
        if !configuration.isLocal && !allowExternal { pendingRemoteItem = item; return }
        let config = configuration
        generatingID = item.id; generationProgress = "准备模型"; error = nil
        attempts.insert(item.id + item.transcript.contentHash + config.cacheKey)
        generation = Task {
            defer { generatingID = nil; generation = nil; autoGenerate() }
            do {
                let key = try apiKey()
                let summary = try await DesktopModelService().summarize(item: item, configuration: config, key: key, store: store) { [weak self] text in
                    Task { @MainActor in self?.generationProgress = text }
                }
                try Task.checkCancellation()
                guard configuration == config else { throw CancellationError() }
                try store.save(summary, item: item); refresh()
            } catch is CancellationError { generationProgress = "已取消，原文和已完成分段保留" }
            catch { self.error = error.localizedDescription }
        }
    }
    func cancelGeneration() { generation?.cancel() }
    func shutdown() { generation?.cancel(); server?.stop() }
    private func autoGenerate() {
        guard configuration.isLocal, configuration.autoSummarize, generatingID == nil, !configuration.model.isEmpty else { return }
        if let next = items.first(where: { $0.summary == nil && $0.transcript.isFinal && !$0.transcript.text.isEmpty && !attempts.contains($0.id + $0.transcript.contentHash + configuration.cacheKey) }) { generate(next) }
    }
    private static func previewItems() -> [DesktopLibraryItem] {
        #if DEBUG
        let record = DesktopTranscript(id: "legacyNote:00000000-0000-0000-0000-000000000001", title: "产品体验与下一步安排", capturedAt: .now, duration: 1680,
            captureDevice: "Apple Watch", kind: "long", text: "我们先把核心的录音体验做好。下周三前完成桌面同步的第一轮测试。总结需要能够回到原文，方便核对。",
            spans: [.init(id: "one", start: 0, end: 18, speaker: "说话人 1", text: "我们先把核心的录音体验做好。"),
                    .init(id: "two", start: 22, end: 40, speaker: "说话人 2", text: "下周三前完成桌面同步的第一轮测试。"),
                    .init(id: "three", start: 45, end: 66, speaker: "说话人 1", text: "总结需要能够回到原文，方便核对。")], isFinal: true)
        let summary = DesktopSummary(id: UUID(), recordID: record.id, inputHash: record.contentHash, model: "本机模型 · 预览", generatedAt: .now,
            markdown: "## 概览\n讨论聚焦录音的核心体验、桌面同步验证和总结的可追溯性。 [S1] [S2] [S3]\n\n## 讨论要点\n- 优先完善核心录音体验。 [S1]\n- 总结应能定位原文，便于核对。 [S3]\n\n## 行动项\n- 下周三前完成桌面同步的第一轮测试；负责人未明确。 [S2]\n\n## 待确认问题\n- 确认测试负责人及验收范围。", references: record.spans.enumerated().map { .init(id: "S\($0.offset + 1)", start: $0.element.start, end: $0.element.end, speaker: $0.element.speaker, text: $0.element.text) })
        return [.init(deviceID: "preview", deviceName: "iPhone Air", transcript: record, summary: summary)]
        #else
        return []
        #endif
    }
}
