import AppKit
import SwiftUI
import Network
import CompanionCore
import CompanionMLX

@MainActor final class CompanionModel: ObservableObject {
    enum Page: String, CaseIterable, Identifiable {
        case overview = "概览", models = "模型库", devices = "已配对设备", privacy = "隐私与说明"
        var id: String { rawValue }
        var icon: String {
            switch self { case .overview: "square.grid.2x2"; case .models: "cpu"; case .devices: "iphone.and.arrow.forward"; case .privacy: "lock.shield" }
        }
    }
    @Published var page: Page = .overview
    @Published var models: [CatalogModel] = []
    @Published var selectedID = "mlx-community/Qwen3-4B-4bit"
    @Published var installed: Set<String> = []
    @Published var state: RuntimeState = .unloaded
    @Published var currentModelID: String?
    @Published var devices: [PairedDevice] = []
    @Published var available = false
    @Published var advertising = false
    @Published var serviceMessage = "服务已暂停"
    @Published var pairing: PairingCode?
    @Published var showPairing = false
    @Published var pendingRevoke: PairedDevice?
    @Published var operationID: String?
    @Published var operationLabel = ""
    @Published var progress: Double?
    @Published var downloadBytes: Int64 = 0
    @Published var downloadTotal: Int64 = 0
    @Published var downloadSpeed: Double = 0
    @Published var downloadPhase: DownloadProgress.Phase?
    @Published var notice: String?
    @Published var retryDownloadID: String?
    @Published var error: String?
    @Published var active = false
    @Published var queued = 0
    @Published var loadSeconds: Double?
    @Published var metrics: GenerationMetrics?
    @Published var sample = SystemSample.current()
    @Published var freeBytes: Int64 = 0
    @Published var initialized = false
    @Published var pairingAccessPending = false
    @Published var networkNames: [String] = []
    @Published var selectedNetwork = ""
    let hardware = MacHardware.current()
    let runtime = ModelRuntime(engine: MLXTextEngine())
    private let server = LocalHTTPServer()
    private let bonjour = BonjourAdvertiser()
    private var store: ModelStore?
    private var registry: PairingRegistry?
    private var router: APIRouter?
    private var identity: TLSIdentity?
    private var pairingPreparation: Task<(PairingRegistry, TLSIdentity), Error>?
    private var port: Int?
    private var boundAddress: String?
    private var operation: Task<Void, Never>?
    private var poller: Task<Void, Never>?
    private var pressure: DispatchSourceMemoryPressure?
    private var reconciling = false
    private var sleeping = false
    private var lastStartAttempt = Date.distantPast
    private var observers: [NSObjectProtocol] = []
    private let preview: Bool
    private var speedSampleTime = Date()
    private var speedSampleBytes: Int64 = 0
    private var downloadFileName = ""
    var selectedModel: CatalogModel? { models.first { $0.id == selectedID } }
    var currentModel: CatalogModel? { models.first { $0.id == currentModelID } }
    var recommendedModel: CatalogModel? {
        guard let id = ModelRecommendation.preferredID(hardware: hardware, catalog: models) else { return nil }
        return models.first { $0.id == id }
    }
    var orderedModels: [CatalogModel] {
        guard let preferred = recommendedModel else { return models }
        return [preferred] + models.filter { $0.id != preferred.id }
    }
    func fits(_ model: CatalogModel) -> Bool { ModelRecommendation.fits(model.id, hardware: hardware) }
    var ready: Bool { state == .ready }
    var pairingRegistryLoaded: Bool { registry != nil || preview }
    var busy: Bool { operationID != nil || state == .loading || state == .unloading }

    init(preview: Bool = false) {
        self.preview = preview
        if preview {
            models = (try? CatalogModel.bundled()) ?? []; initialized = true
            serviceMessage = "连接局域网后，即可为 iPhone 提供本地 AI"
            freeBytes = 57 * 1024 * 1024 * 1024
            #if DEBUG
            if CommandLine.arguments.contains("--download-preview"), let item = recommendedModel {
                page = .models; operationID = item.id; operationLabel = "正在从 Hugging Face 下载"
                progress = 0.38; downloadBytes = Int64(Double(item.bytes) * 0.38); downloadTotal = item.bytes
                downloadSpeed = 12 * 1024 * 1024; downloadPhase = .downloading
            }
            #endif
        } else { Task { await bootstrap() } }
    }
    private func bootstrap() async {
        do {
            models = try CatalogModel.bundled()
            self.store = try ModelStore()
            available = UserDefaults.standard.bool(forKey: "companion.available")
            selectedID = UserDefaults.standard.string(forKey: "companion.selected-model") ?? selectedID
            if !models.contains(where: { $0.id == selectedID }) { selectedID = models[0].id }
            let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
            source.setEventHandler { [weak self] in
                Task { @MainActor in
                    guard let self else { return }
                    let snapshot = await self.runtime.snapshot()
                    guard snapshot.state == .ready || snapshot.state == .loading else { return }
                    self.error = "系统内存紧张，已取消生成并卸载模型。可选择较小模型后重新加载。"
                    await self.runtime.unload()
                }
            }
            source.resume(); pressure = source
            let center = NSWorkspace.shared.notificationCenter
            observers.append(center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in guard let self else { return }; self.sleeping = true; await self.reconcile(); await self.runtime.unload() }
            })
            observers.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in guard let self else { return }; self.sleeping = false; await self.reconcile() }
            })
            initialized = true
            if available {
                do { try await preparePairing() }
                catch { available = false; UserDefaults.standard.set(false, forKey: "companion.available"); self.error = message(error) }
            }
            await refresh(); await reconcile()
            poller = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(1))
                    guard let self, !Task.isCancelled else { break }
                    await self.refresh(); await self.runtime.unloadIfIdle(); await self.reconcile()
                }
            }
        } catch { self.error = message(error); serviceMessage = "初始化失败，请重新打开 App" }
    }
    func refresh() async {
        let value = await runtime.snapshot()
        state = value.state; currentModelID = value.modelID; active = value.active; queued = value.queued
        loadSeconds = value.loadSeconds; metrics = value.lastMetrics; sample = .current()
        if let registry {
            devices = await registry.devices
            if pairing != nil, !(await registry.isPairing()) { pairing = nil }
        }
        if let store {
            var found: Set<String> = []
            for model in models where await store.isInstalled(model) { found.insert(model.id) }
            installed = found; freeBytes = await store.availableBytes()
        }
        networkNames = Array(Set(LocalInterface.all().map(\.name))).sorted()
        if !networkNames.contains(selectedNetwork) { selectedNetwork = networkNames.first ?? "" }
        advertising = bonjour.published
    }
    func changeAvailability(_ value: Bool) {
        available = value; UserDefaults.standard.set(value, forKey: "companion.available")
        lastStartAttempt = .distantPast
        Task {
            if value {
                do { try await preparePairing() }
                catch { available = false; UserDefaults.standard.set(false, forKey: "companion.available"); self.error = message(error) }
            }
            await reconcile()
        }
    }
    /// Keychain authorization is needed only for pairing and serving iPhones.
    /// A changed local development signature must not block the main thread or
    /// prevent the independent model library / downloader from opening.
    private func preparePairing() async throws {
        if router != nil { return }
        pairingAccessPending = true
        let task: Task<(PairingRegistry, TLSIdentity), Error>
        if let existing = pairingPreparation { task = existing }
        else {
            task = Task.detached(priority: .utility) {
                let secret = KeychainStore()
                let registry = try PairingRegistry(store: secret)
                let identity = try TLSIdentity.load(store: secret, serviceID: await registry.serviceID)
                return (registry, identity)
            }
            pairingPreparation = task
        }
        defer { pairingAccessPending = false; pairingPreparation = nil }
        let (registry, identity) = try await task.value
        if router == nil {
            self.registry = registry; self.identity = identity
            router = APIRouter(registry: registry, runtime: runtime)
        }
    }
    func loadPairingDevices() {
        guard initialized, !preview else { return }
        Task {
            do { try await preparePairing(); await refresh() }
            catch { self.error = message(error) }
        }
    }
    func changeNetwork(_ name: String) { selectedNetwork = name; lastStartAttempt = .distantPast; Task { await reconcile() } }
    func retryService() {
        Task {
            guard !reconciling else { return }
            reconciling = true
            bonjour.stop(); await router?.setAvailable(false); await server.stop()
            port = nil; boundAddress = nil; lastStartAttempt = .distantPast
            reconciling = false; await reconcile()
        }
    }
    private func reconcile() async {
        guard !preview, !reconciling, let router, let registry, let identity else { return }
        reconciling = true; defer { reconciling = false }
        let pairingOpen = await registry.isPairing()
        let wanted = !sleeping && (available || pairingOpen)
        let network = LocalInterface.all().first { $0.name == selectedNetwork }
        if port != nil, !wanted || network?.address != boundAddress {
            bonjour.stop(); await router.stop(); await server.stop(); port = nil; boundAddress = nil
        }
        if !wanted {
            await router.setAvailable(false); await runtime.suspend()
            serviceMessage = sleeping ? "Mac 休眠中，服务已暂停" : "服务已暂停"; advertising = false; return
        }
        guard let network else {
            serviceMessage = "未找到局域网，请连接 Wi-Fi 后重试"; advertising = false; return
        }
        if port == nil {
            guard Date().timeIntervalSince(lastStartAttempt) >= 10 else { return }
            lastStartAttempt = Date()
            do {
                let port = try await server.start(address: network.address, identity: identity, router: router)
                self.port = port; boundAddress = network.address
                bonjour.publish(serviceID: await registry.serviceID, port: port)
            } catch { serviceMessage = message(error); return }
        }
        await router.setAvailable(available)
        advertising = bonjour.published
        serviceMessage = bonjour.failed ? "设备发现失败，请检查局域网权限后重试" : advertising ? (available ? "可被附近的 iPhone 发现" : "等待 iPhone 扫码配对") : "正在发布局域网服务…"
    }
    func openPairing() {
        guard initialized, !preview else { return }
        Task {
            do {
                try await preparePairing()
                guard let registry, let identity else { throw ServiceError.notReady }
                pairing = try await registry.open(fingerprint: identity.fingerprint)
                showPairing = true; await reconcile()
            } catch { self.error = message(error) }
        }
    }
    func closePairing() {
        pairing = nil; showPairing = false
        Task { await registry?.close(); await reconcile() }
    }
    func revoke(_ device: PairedDevice) {
        Task { do { try await router?.revoke(device.id); await refresh() } catch { self.error = message(error) } }
    }
    func download(_ model: CatalogModel) {
        guard !busy, let store else { return }
        guard fits(model) else { error = ModelRecommendation.explanation(for: model.id, hardware: hardware); return }
        operationID = model.id; operationLabel = "正在连接 Hugging Face"; progress = 0
        downloadBytes = 0; downloadTotal = model.bytes; downloadSpeed = 0; downloadPhase = .downloading
        speedSampleTime = Date(); speedSampleBytes = 0; downloadFileName = ""; notice = nil; error = nil; retryDownloadID = nil
        let operationToken = UUID()
        downloadToken = operationToken
        operation = Task {
            defer {
                downloadToken = nil; operationID = nil; operationLabel = ""; progress = nil
                downloadPhase = nil; operation = nil
            }
            do {
                try await store.install(model) { [weak self] value in
                    Task { @MainActor in
                        guard let self, self.downloadToken == operationToken else { return }
                        self.updateDownload(value)
                    }
                }
                await refresh()
                notice = "\(model.name) 下载并校验完成，可以加载模型了。"
            } catch is CancellationError { notice = "下载已取消，需要时可重新下载。"; retryDownloadID = model.id }
            catch let error as URLError where error.code == .cancelled { notice = "下载已取消，需要时可重新下载。"; retryDownloadID = model.id }
            catch { self.error = message(error); retryDownloadID = model.id }
        }
    }
    private var downloadToken: UUID?
    private func updateDownload(_ value: DownloadProgress) {
        guard value.bytes >= downloadBytes, downloadPhase != .complete else { return }
        if value.bytes == downloadBytes, downloadPhase == .verifying, value.phase == .downloading, value.fileName == downloadFileName { return }
        progress = value.fraction; downloadBytes = value.bytes; downloadTotal = value.total; downloadPhase = value.phase
        downloadFileName = value.fileName
        switch value.phase {
        case .downloading: operationLabel = value.bytes == 0 ? "正在连接 Hugging Face" : "正在从 Hugging Face 下载"
        case .verifying: operationLabel = "正在校验模型文件"
        case .complete: operationLabel = "下载与校验完成"
        }
        let now = Date(), elapsed = now.timeIntervalSince(speedSampleTime)
        if elapsed >= 0.5, value.phase == .downloading {
            let speed = Double(max(0, value.bytes - speedSampleBytes)) / elapsed
            downloadSpeed = downloadSpeed == 0 ? speed : 0.7 * downloadSpeed + 0.3 * speed
            speedSampleTime = now; speedSampleBytes = value.bytes
        }
    }
    func load(_ model: CatalogModel) {
        guard !busy, let store else { return }
        selectedID = model.id; UserDefaults.standard.set(model.id, forKey: "companion.selected-model")
        operationID = model.id; operationLabel = "正在校验并加载"; progress = nil
        operation = Task {
            defer { operationID = nil; operationLabel = ""; operation = nil }
            do {
                let directory = try await store.verifiedDirectory(model)
                try Task.checkCancellation(); await runtime.resume()
                try await runtime.load(model.id, directory: directory)
                if !available { await runtime.suspend() }
                await refresh()
            } catch is CancellationError { }
            catch { self.error = message(error) }
        }
    }
    func cancelOperation() {
        operation?.cancel()
        if state == .loading { Task { await runtime.unload() } }
    }
    func unload() { Task { await runtime.unload(); await refresh() } }
    func cancelGeneration() { Task { await runtime.cancelAll(); await refresh() } }
    func remove(_ model: CatalogModel) {
        guard !busy else { return }
        Task {
            do {
                if currentModelID == model.id { await runtime.unload() }
                try await store?.remove(model); await refresh()
            } catch { self.error = message(error) }
        }
    }
    func shutdown() async {
        sleeping = true; poller?.cancel(); operation?.cancel(); pairingPreparation?.cancel(); pressure?.cancel(); bonjour.stop()
        await router?.stop(); await server.stop(); await runtime.shutdown()
    }
    private func message(_ error: Error) -> String {
        if let error = error as? URLError {
            switch error.code {
            case .notConnectedToInternet, .networkConnectionLost, .cannotFindHost, .cannotConnectToHost:
                return "暂时无法连接 Hugging Face，请检查网络后重新下载。"
            case .timedOut: return "Hugging Face 下载超时，请稍后重试。"
            default: break
            }
        }
        return (error as? ServiceError)?.message ?? "操作未完成，请检查网络或模型文件后重试。"
    }
}
