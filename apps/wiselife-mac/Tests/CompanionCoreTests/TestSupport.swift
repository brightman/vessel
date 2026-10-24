import Foundation
@testable import CompanionCore

final class MemorySecrets: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var data: [String: Data] = [:]
    func read(_ account: String) throws -> Data? { lock.lock(); defer { lock.unlock() }; return data[account] }
    func write(_ data: Data, account: String) throws { lock.lock(); defer { lock.unlock() }; self.data[account] = data }
}

actor StubEngine: TextEngine {
    private(set) var active = 0
    private(set) var maximumActive = 0
    private(set) var calls: [String] = []
    private(set) var unloads = 0
    let delay: Duration
    init(delay: Duration = .milliseconds(10)) { self.delay = delay }
    func load(directory: URL) async throws { }
    func unload() async { unloads += 1 }
    func generate(_ request: TextRequest, contextLimit: Int) async throws -> GenerationResult {
        active += 1; maximumActive = max(active, maximumActive); calls.append(request.user)
        defer { active -= 1 }
        try await Task.sleep(for: delay)
        return .init(text: "中文结果[1]", promptTokens: 20, generatedTokens: 8, firstTokenSeconds: 0.01, totalSeconds: 0.02, finishReason: "stop")
    }
}

func readyRuntime(engine: StubEngine = StubEngine(), timeout: Duration = .seconds(3), queueLimit: Int = 2) async throws -> ModelRuntime {
    let runtime = ModelRuntime(engine: engine, queueLimit: queueLimit, timeout: timeout)
    try await runtime.load("test-model", directory: URL(fileURLWithPath: "/unused-stub"))
    return runtime
}

func requestBody(_ overrides: [String: Any] = [:]) throws -> Data {
    var body: [String: Any] = ["model": "test-model", "messages": [["role": "system", "content": "只按原文回答"], ["role": "user", "content": "只发送本条文字"]], "stream": false]
    body.merge(overrides) { _, new in new }
    return try JSONSerialization.data(withJSONObject: body)
}

func waitUntil(_ condition: () async -> Bool) async throws {
    for _ in 0..<200 { if await condition() { return }; try await Task.sleep(for: .milliseconds(5)) }
    throw ServiceError(500, "test_wait_timeout", "Test condition did not become true")
}
