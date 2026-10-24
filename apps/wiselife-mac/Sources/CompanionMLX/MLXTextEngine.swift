import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import CompanionCore

/// The app loads only a verified local directory. It never invokes the hub
/// downloader, model-repository code, Python, or a separate inference server.
public actor MLXTextEngine: TextEngine {
    private var container: ModelContainer?
    public init() {}
    /// Small GPU integration check. Does not download or load a language model.
    public func verifyMetal() -> Int {
        let value = sum(MLXArray([Int32(1), 2, 3]))
        return value.item(Int.self)
    }
    public func load(directory: URL) async throws {
        container = nil
        GPU.clearCache()
        // A cache bound is a provisional development setting, not an M3 memory gate.
        GPU.set(cacheLimit: 128 * 1024 * 1024)
        let model = try await LLMModelFactory.shared.loadContainer(configuration: .init(directory: directory))
        try Task.checkCancellation()
        container = model
    }
    public func unload() async { container = nil; GPU.clearCache() }
    public func generate(_ request: TextRequest, contextLimit: Int) async throws -> GenerationResult {
        guard let container else { throw ServiceError.notReady }
        let cancellation = CancellationFlag()
        return try await withTaskCancellationHandler(operation: {
            try await container.perform { context in
                let start = Date()
                let input = try await context.processor.prepare(input: UserInput(
                    chat: [.system(request.system), .user(request.user)], additionalContext: ["enable_thinking": false]))
                let promptTokens = input.text.tokens.size
                guard promptTokens + request.maxTokens <= contextLimit else {
                    throw ServiceError(400, "context_length_exceeded", "输入文字和输出预算超过 Mac 模型上下文限制，请缩短文字后重试。")
                }
                if cancellation.isCancelled { throw CancellationError() }
                let parameters = GenerateParameters(maxTokens: request.maxTokens, temperature: request.temperature, prefillStepSize: 256)
                // Each request owns a fresh iterator and KV cache. Iteration stays in
                // this task until GPU synchronization, so cancellation cannot start
                // a second inference while an AsyncStream producer is still running.
                let iterator = try TokenIterator(input: input, model: context.model, parameters: parameters)
                let eos = Set(context.configuration.extraEOSTokens.compactMap { context.tokenizer.convertTokenToId($0) })
                var tokens: [Int] = [], firstToken: Double?
                defer { Stream().synchronize() }
                for token in iterator {
                    if cancellation.isCancelled || Task.isCancelled { throw CancellationError() }
                    if firstToken == nil { firstToken = Date().timeIntervalSince(start) }
                    if token == context.tokenizer.eosTokenId || token == context.tokenizer.unknownTokenId || eos.contains(token) { break }
                    tokens.append(token)
                    if tokens.count >= request.maxTokens { break }
                }
                try Task.checkCancellation()
                if cancellation.isCancelled { throw CancellationError() }
                let output = context.tokenizer.decode(tokens: tokens)
                Stream().synchronize()
                return GenerationResult(text: output, promptTokens: promptTokens,
                    generatedTokens: tokens.count, firstTokenSeconds: firstToken ?? Date().timeIntervalSince(start),
                    totalSeconds: Date().timeIntervalSince(start), finishReason: tokens.count >= request.maxTokens ? "length" : "stop")
            }
        }, onCancel: { cancellation.cancel() })
    }
}

private final class CancellationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return value }
    func cancel() { lock.lock(); value = true; lock.unlock() }
}
