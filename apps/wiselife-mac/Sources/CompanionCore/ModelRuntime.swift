import Foundation
import IOKit.pwr_mgt

public protocol TextEngine: Sendable {
    func load(directory: URL) async throws
    func unload() async
    func generate(_ request: TextRequest, contextLimit: Int) async throws -> GenerationResult
}

public enum RuntimeState: String, Codable, Sendable {
    case unloaded, loading, ready, unloading, failed
    public var title: String {
        switch self {
        case .unloaded: "模型未加载"
        case .loading: "正在加载模型"
        case .ready: "模型已就绪"
        case .unloading: "正在释放内存"
        case .failed: "模型加载失败"
        }
    }
}

public struct RuntimeSnapshot: Sendable {
    public let state: RuntimeState
    public let modelID: String?
    public let queued: Int
    public let active: Bool
    public let loadSeconds: Double?
    public let lastMetrics: GenerationMetrics?
}

/// Deliberately contains no prompt, generated text, token credential, or device name.
public struct GenerationMetrics: Codable, Sendable {
    public let promptTokens: Int
    public let generatedTokens: Int
    public let firstTokenSeconds: Double
    public let totalSeconds: Double
}

/// Actor reentrancy alone does not serialize an async engine. This explicit FIFO owns
/// exactly one engine task until it has actually exited, including after cancellation.
public actor ModelRuntime {
    private struct Job {
        let id: UUID
        let device: UUID
        let request: TextRequest
        let continuation: CheckedContinuation<GenerationResult, Error>
        let deadline: Task<Void, Never>
    }
    private let engine: any TextEngine
    private let queueLimit: Int
    private let timeout: Duration
    private let contextLimit: Int
    private var state: RuntimeState = .unloaded
    private var selectedModel: String?
    private var queue: [Job] = []
    private var active: (job: Job, task: Task<Void, Never>)?
    private var activeCancellation: ServiceError?
    private var loadTask: Task<Void, Error>?
    private var unloadTask: Task<Void, Never>?
    private var accepting = true
    private var lastUsed = Date()
    private var loadSeconds: Double?
    private var metrics: GenerationMetrics?
    private var revokedDevices: Set<UUID> = []

    public init(engine: any TextEngine, queueLimit: Int = 2, timeout: Duration = .seconds(120), contextLimit: Int = 8192) {
        self.engine = engine; self.queueLimit = max(0, queueLimit); self.timeout = timeout
        self.contextLimit = min(8192, max(512, contextLimit))
    }
    public func snapshot() -> RuntimeSnapshot {
        .init(state: state, modelID: selectedModel, queued: queue.count, active: active != nil, loadSeconds: loadSeconds, lastMetrics: metrics)
    }
    public func load(_ modelID: String, directory: URL) async throws {
        guard active == nil, queue.isEmpty, state != .loading, state != .unloading, accepting else { throw ServiceError.busy }
        state = .loading; selectedModel = modelID; metrics = nil; loadSeconds = nil
        let start = Date(), engine = self.engine
        let task = Task { await engine.unload(); try Task.checkCancellation(); try await engine.load(directory: directory) }
        loadTask = task
        do {
            try await task.value
            guard state == .loading, !task.isCancelled else { throw ServiceError.cancelled }
            state = .ready; lastUsed = Date(); loadSeconds = Date().timeIntervalSince(start); loadTask = nil
        } catch {
            if state == .loading { state = .failed; loadTask = nil }
            throw (error as? ServiceError) ?? ServiceError(503, "model_load_failed", "模型加载失败，请检查文件或选择较小的模型。")
        }
    }
    public func generate(_ request: TextRequest, device: UUID) async throws -> GenerationResult {
        try Task.checkCancellation()
        guard accepting, state == .ready else { throw ServiceError.notReady }
        guard !revokedDevices.contains(device) else { throw ServiceError.unauthorized }
        guard request.model == selectedModel else { throw ServiceError(404, "unknown_model", "请使用 /v1/models 返回的 Mac 模型。") }
        guard active == nil || queue.count < queueLimit else { throw ServiceError.busy }
        let id = UUID()
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                let deadline = Task { [timeout] in
                    do { try await Task.sleep(for: timeout); self.cancel(id: id, reason: .timeout) } catch { }
                }
                let job = Job(id: id, device: device, request: request, continuation: continuation, deadline: deadline)
                if Task.isCancelled { deadline.cancel(); continuation.resume(throwing: ServiceError.cancelled) }
                else if active == nil { start(job) } else { queue.append(job) }
            }
        }, onCancel: { Task { await self.cancel(id: id, reason: .cancelled) } })
    }
    private func start(_ job: Job) {
        let engine = self.engine, contextLimit = self.contextLimit
        let task = Task {
            let lease = PowerLease(); defer { lease.release() }
            let result: Result<GenerationResult, Error>
            do { try Task.checkCancellation(); result = .success(try await engine.generate(job.request, contextLimit: contextLimit)) }
            catch { result = .failure(error) }
            finish(id: job.id, result: result)
        }
        active = (job, task)
    }
    private func finish(id: UUID, result: Result<GenerationResult, Error>) {
        guard let active, active.job.id == id else { return }
        active.job.deadline.cancel()
        if let cancellation = activeCancellation { active.job.continuation.resume(throwing: cancellation) }
        else {
            switch result {
            case .success(let result):
                metrics = .init(promptTokens: result.promptTokens, generatedTokens: result.generatedTokens, firstTokenSeconds: result.firstTokenSeconds, totalSeconds: result.totalSeconds)
                active.job.continuation.resume(returning: result)
            case .failure(let error):
                active.job.continuation.resume(throwing: (error as? ServiceError) ?? (error is CancellationError ? .cancelled : .inference))
            }
        }
        self.active = nil; activeCancellation = nil; lastUsed = Date()
        if state == .ready, accepting, !queue.isEmpty { start(queue.removeFirst()) }
    }
    private func cancel(id: UUID, reason: ServiceError) {
        if active?.job.id == id { activeCancellation = reason; active?.task.cancel() }
        else if let index = queue.firstIndex(where: { $0.id == id }) {
            let job = queue.remove(at: index); job.deadline.cancel(); job.continuation.resume(throwing: reason)
        }
    }
    public func cancel(device: UUID) {
        let ids = queue.filter { $0.device == device }.map(\.id) + (active?.job.device == device ? [active!.job.id] : [])
        for id in ids { cancel(id: id, reason: .cancelled) }
    }
    public func revoke(device: UUID) { revokedDevices.insert(device); cancel(device: device) }
    public func allow(device: UUID) { revokedDevices.remove(device) }
    public func suspend() { accepting = false; cancelAll() }
    public func cancelAll() {
        for id in queue.map(\.id) { cancel(id: id, reason: .cancelled) }
        if let id = active?.job.id { cancel(id: id, reason: .cancelled) }
    }
    public func unload() async {
        if let task = unloadTask { await task.value; return }
        state = .unloading; cancelAll()
        let loading = loadTask; loading?.cancel()
        let generation = active?.task, engine = self.engine
        let task = Task {
            if let loading { _ = await loading.result }
            if let generation { await generation.value }
            await engine.unload()
        }
        unloadTask = task
        await task.value
        loadTask = nil; state = .unloaded; unloadTask = nil
    }
    public func unloadIfIdle(now: Date = Date(), interval: TimeInterval = 600) async {
        if state == .ready, active == nil, queue.isEmpty, now.timeIntervalSince(lastUsed) >= interval { await unload() }
    }
    public func shutdown() async { accepting = false; await unload() }
    public func resume() { accepting = true }
}

private final class PowerLease {
    private var id: IOPMAssertionID = 0
    init() {
        _ = IOPMAssertionCreateWithDescription(kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
            "WiseLife text generation" as CFString, nil, nil, nil, 125, kIOPMAssertionTimeoutActionRelease as CFString, &id)
    }
    func release() { if id != 0 { IOPMAssertionRelease(id); id = 0 } }
    deinit { release() }
}
