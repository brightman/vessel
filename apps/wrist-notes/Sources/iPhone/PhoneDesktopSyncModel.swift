import Foundation
import Combine
import Network
import UIKit

private final class PhoneDesktopSyncWorker: @unchecked Sendable {
    private let queue = DispatchQueue(label: "WiseLife.Phone.DesktopSync", qos: .utility)
    private var repository: PhoneDesktopSyncRepository?
    private let url: URL
    init(url: URL) { self.url = url }
    func perform<T>(_ body: @escaping (PhoneDesktopSyncRepository) throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    let repository = try self.repository ?? PhoneDesktopSyncRepository(database: DaybookDatabase(url: self.url))
                    self.repository = repository; continuation.resume(returning: try body(repository))
                } catch { continuation.resume(throwing: error) }
            }
        }
    }
}

@MainActor final class PhoneDesktopSyncModel: ObservableObject {
    @Published private(set) var peerName: String?
    @Published private(set) var isSyncing = false
    @Published private(set) var pendingCount = 0
    @Published private(set) var lastSynced: Date?
    @Published private(set) var summaries: [String: DesktopSummary] = [:]
    @Published var message: String?
    @Published var automatic: Bool {
        didSet { defaults.set(automatic, forKey: "desktop-sync-auto"); if automatic { schedule() } }
    }
    private let defaults: UserDefaults
    private let keychain: SyncKeychain
    private let worker: PhoneDesktopSyncWorker
    private var pairingStorageUnavailable = false
    private var peer: DesktopPairedPeer?
    private var browser: NWBrowser?
    private var endpoint: NWEndpoint?
    private var task: Task<Void, Never>?
    private var polling: Task<Void, Never>?
    private var observers: [AnyCancellable] = []
    private var foreground = true
    private var retryCount = 0
    private var needsSync = false
    private var sourceEpoch = 0
    init(notes: NotesModel, defaults: UserDefaults = .standard, databaseURL: URL = DaybookDatabase.applicationURL,
         keychainService: String = "cloud.karama.wisenote.desktop-sync") {
        self.defaults = defaults; automatic = defaults.object(forKey: "desktop-sync-auto") as? Bool ?? true
        keychain = SyncKeychain(service: keychainService); worker = PhoneDesktopSyncWorker(url: databaseURL)
        foreground = UIApplication.shared.applicationState == .active
        do {
            if let data = try keychain.read("peer") {
                peer = try DesktopSyncCodec.decode(DesktopPairedPeer.self, data); peerName = peer?.code.name
            }
        } catch { message = error.localizedDescription; pairingStorageUnavailable = true }
        observers.append(notes.$notes.dropFirst().sink { [weak self] _ in self?.sourceChanged() })
        for name in [AudioProcessingModel.contentDidChange, RecordingChunkReceiver.didChange] {
            observers.append(NotificationCenter.default.publisher(for: name).sink { [weak self] _ in Task { @MainActor in self?.sourceChanged() } })
        }
        observers.append(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification).sink { [weak self] _ in
            Task { @MainActor in self?.foreground = true; self?.startDiscovery(); self?.startPolling(); self?.schedule() }
        })
        observers.append(NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification).sink { [weak self] _ in
            Task { @MainActor in self?.foreground = false; self?.task?.cancel(); self?.polling?.cancel(); self?.browser?.cancel(); self?.browser = nil }
        })
        Task { await refresh(); startDiscovery(); startPolling(); schedule() }
    }
    func pair(_ text: String) {
        guard !isSyncing else { return }
        guard !pairingStorageUnavailable else { message = "请先重新读取配对状态，避免覆盖暂不可读的配对。"; return }
        task?.cancel()
        task = Task {
            isSyncing = true; message = nil
            defer { isSyncing = false }
            do {
                let code = try DesktopPairingCode.parse(text)
                let deviceID = try await worker.perform { try $0.deviceID() }
                let request = DesktopSyncRequest(operation: "pair", serverID: code.serverID, deviceID: deviceID,
                    deviceName: UIDevice.current.name, credential: code.secret)
                let response = try await SyncConnection.exchange(request, code: code)
                guard let token = response.deviceToken, !token.isEmpty else { throw DesktopSyncError.unauthorized }
                let peer = DesktopPairedPeer(code: code, deviceID: deviceID, token: token)
                try keychain.write(DesktopSyncCodec.encode(peer), account: "peer")
                try await worker.perform { try $0.resetPeer(code.serverID) }
                sourceEpoch += 1
                self.peer = peer; peerName = code.name; retryCount = 0
                startDiscovery(); startPolling(); needsSync = true
                message = "已配对，准备同步录音转写。"
            } catch is CancellationError { }
            catch { message = error.localizedDescription }
            task = nil
            if needsSync { needsSync = false; Task { await Task.yield(); self.syncNow() } }
        }
    }
    func syncNow() {
        guard foreground, peer != nil else { return }
        if isSyncing { needsSync = true; return }
        task?.cancel(); task = Task { await exchange() }
    }
    private func exchange() async {
        guard let peer else { return }
        isSyncing = true; message = nil; needsSync = false
        var failed = false
        defer {
            isSyncing = false; task = nil
            if failed && automatic && foreground {
                retryCount += 1
                let delay = min(60, 5 * (1 << min(retryCount, 4)))
                schedule(delay: UInt64(delay))
            } else if needsSync && automatic { schedule() }
        }
        do {
            try await worker.perform { try $0.reconcile() }
            while true {
                try Task.checkCancellation()
                let outgoing = try await worker.perform { repository in
                    let state = try repository.state(serverID: peer.code.serverID)
                    return (state, try repository.events(after: state.acknowledged))
                }
                let request = DesktopSyncRequest(operation: "exchange", serverID: peer.code.serverID, deviceID: peer.deviceID,
                    deviceName: UIDevice.current.name, credential: peer.token, events: outgoing.1, summaryCursor: outgoing.0.cursor)
                let response = try await SyncConnection.exchange(request, code: peer.code, endpoint: endpoint)
                let maximum = outgoing.1.last?.sequence ?? outgoing.0.acknowledged
                try await worker.perform { try $0.accept(response, serverID: peer.code.serverID, maximumSent: maximum) }
                await refresh()
                if pendingCount == 0 && !response.hasMoreSummaries { break }
                await Task.yield()
            }
            retryCount = 0; message = "文字已同步；Mac 生成的总结会在下次连接时回传。"
        } catch is CancellationError { }
        catch { message = error.localizedDescription; failed = true }
        await refresh()
    }
    func unpair(removeLocalOnly: Bool = false) async -> Bool {
        guard let peer, !isSyncing else { return false }
        task?.cancel(); isSyncing = true; defer { isSyncing = false }
        do {
            if !removeLocalOnly {
                let request = DesktopSyncRequest(operation: "unpair", serverID: peer.code.serverID, deviceID: peer.deviceID,
                    deviceName: UIDevice.current.name, credential: peer.token)
                _ = try await SyncConnection.exchange(request, code: peer.code, endpoint: endpoint)
            }
            try keychain.remove("peer"); try await worker.perform { try $0.resetPeer(peer.code.serverID) }
            self.peer = nil; peerName = nil; summaries = [:]; lastSynced = nil; pendingCount = 0
            browser?.cancel(); browser = nil; endpoint = nil; polling?.cancel()
            message = removeLocalOnly ? "已移除手机配对。请在原 Mac 的“同步与配对”中移除手机，清除其副本。" : "已解除配对，并清除 Mac 上这台手机的文字与总结副本。"
            return true
        } catch { message = error.localizedDescription; return false }
    }
    func retryLoad() {
        if peer == nil {
            do {
                if let data = try keychain.read("peer") { peer = try DesktopSyncCodec.decode(DesktopPairedPeer.self, data); peerName = peer?.code.name }
                pairingStorageUnavailable = false
            }
            catch { message = error.localizedDescription }
        }
        Task { await refresh(); startDiscovery(); startPolling() }
    }
    private func sourceChanged() {
        guard peer != nil else { return }
        sourceEpoch += 1
        // Hide old results before asynchronous storage checks, including protected-data failures.
        summaries = [:]
        Task { await refresh() }
        schedule()
    }
    private func schedule(delay: UInt64 = 2) {
        guard automatic, foreground, peer != nil else { return }
        if isSyncing { needsSync = true; return }
        task?.cancel()
        task = Task { do { try await Task.sleep(nanoseconds: delay * 1_000_000_000); syncNow() } catch { } }
    }
    private func refresh() async {
        guard let peer else { return }
        let openingEpoch = sourceEpoch
        do {
            let snapshot = try await worker.perform { repository in
                let summaries = try repository.summaries(), state = try repository.state(serverID: peer.code.serverID)
                return (summaries, state)
            }
            guard self.peer?.code.serverID == peer.code.serverID, sourceEpoch == openingEpoch else { return }
            summaries = snapshot.0; pendingCount = snapshot.1.pending; lastSynced = snapshot.1.lastSynced
        } catch { message = error.localizedDescription }
    }
    private func startPolling() {
        polling?.cancel(); guard peer != nil, foreground else { return }
        polling = Task {
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: 20_000_000_000) } catch { return }
                if automatic { syncNow() }
            }
        }
    }
    private func startDiscovery() {
        guard browser == nil, foreground, let serverID = peer?.code.serverID else { return }
        let browser = NWBrowser(for: .bonjour(type: "_wiselife-sync._tcp", domain: nil), using: .tcp)
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            let endpoint = results.first { result in
                if case .service(let name, _, _, _) = result.endpoint { return name == serverID }; return false
            }?.endpoint
            Task { @MainActor in self?.endpoint = endpoint }
        }
        browser.start(queue: DispatchQueue(label: "WiseLife.Phone.DesktopDiscovery")); self.browser = browser
    }
}
