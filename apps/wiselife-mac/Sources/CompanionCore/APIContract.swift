import Foundation
import CoreFoundation

public struct ServiceError: Error, Sendable, Equatable, LocalizedError {
    public let status: Int
    public let code: String
    public let message: String
    public var errorDescription: String? { message }
    public init(_ status: Int, _ code: String, _ message: String) {
        self.status = status; self.code = code; self.message = message
    }
    public static let unauthorized = Self(401, "unauthorized", "配对已失效，请重新配对。")
    public static let notReady = Self(503, "model_not_ready", "模型尚未就绪，请在 Mac 上加载模型后重试。")
    public static let busy = Self(429, "queue_full", "Mac 正在处理其他请求，请稍后重试。")
    public static let cancelled = Self(409, "cancelled", "请求已取消，可以重试。")
    public static let timeout = Self(504, "generation_timeout", "生成超时，请缩短文字后重试。")
    public static let inference = Self(500, "inference_failed", "本机生成失败，请重试或重新加载模型。")
    public static let bodyTooLarge = Self(413, "body_too_large", "请求超出 1 MiB 限制。")
    public static let invalidRequest = Self(400, "invalid_request", "仅支持一条 system 和一条 user 文本消息。")
}

public struct TextRequest: Sendable {
    public let model: String
    public let system: String
    public let user: String
    public let maxTokens: Int
    public let temperature: Float
    public init(model: String, system: String, user: String, maxTokens: Int = 1024, temperature: Float = 0.3) {
        self.model = model; self.system = system; self.user = user
        self.maxTokens = min(2048, max(1, maxTokens)); self.temperature = temperature
    }
    public static let maximumBodyBytes = 1_048_576
    public static func parse(_ data: Data) throws -> Self {
        guard data.count <= maximumBodyBytes else { throw ServiceError.bodyTooLarge }
        guard let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(body.keys).isSubset(of: ["model", "messages", "stream", "max_tokens", "temperature"]),
              let model = body["model"] as? String, !model.isEmpty,
              let messages = body["messages"] as? [[String: Any]], messages.count == 2,
              messages[0]["role"] as? String == "system", messages[1]["role"] as? String == "user",
              messages.allSatisfy({ Set($0.keys) == ["role", "content"] }),
              let system = messages[0]["content"] as? String,
              let user = messages[1]["content"] as? String, !user.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { throw ServiceError.invalidRequest }
        if let stream = body["stream"] {
            guard let value = stream as? NSNumber, CFGetTypeID(value) == CFBooleanGetTypeID(), !value.boolValue else {
                throw ServiceError(400, "unsupported_stream", "首版仅支持 stream: false。")
            }
        }
        var maximum = 1024
        if let raw = body["max_tokens"] {
            guard let n = raw as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(),
                  n.doubleValue.isFinite, n.doubleValue.rounded() == n.doubleValue,
                  n.doubleValue > 0, n.doubleValue <= Double(Int32.max) else { throw ServiceError.invalidRequest }
            maximum = min(2048, n.intValue)
        }
        var temperature: Float = 0.3
        if let raw = body["temperature"] {
            guard let n = raw as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(),
                  n.doubleValue.isFinite, (0...1).contains(n.doubleValue) else { throw ServiceError.invalidRequest }
            temperature = n.floatValue
        }
        return .init(model: model, system: system, user: user, maxTokens: maximum, temperature: temperature)
    }
}

public struct GenerationResult: Sendable, Codable {
    public let text: String
    public let promptTokens: Int
    public let generatedTokens: Int
    public let firstTokenSeconds: Double
    public let totalSeconds: Double
    public let finishReason: String
    public init(text: String, promptTokens: Int, generatedTokens: Int, firstTokenSeconds: Double, totalSeconds: Double, finishReason: String) {
        self.text = text; self.promptTokens = promptTokens; self.generatedTokens = generatedTokens
        self.firstTokenSeconds = firstTokenSeconds; self.totalSeconds = totalSeconds; self.finishReason = finishReason
    }
}

public struct APIResponse: Sendable {
    public let status: Int
    public let body: Data
    public init(status: Int = 200, object: [String: Any]) {
        self.status = status; self.body = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
    }
    public static func error(_ error: ServiceError) -> Self {
        .init(status: error.status, object: ["error": ["code": error.code, "message": error.message, "type": "wiselife_error"]])
    }
}
