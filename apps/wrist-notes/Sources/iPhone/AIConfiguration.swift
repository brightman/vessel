import Foundation

enum AppAppearance: String, CaseIterable {
    case dark, light, system
    var title: String {
        switch self { case .dark: "深色"; case .light: "浅色"; case .system: "跟随系统" }
    }
    var symbol: String {
        switch self { case .dark: "moon"; case .light: "sun.max"; case .system: "circle.lefthalf.filled" }
    }
}

struct AIConfiguration: Codable, Equatable {
    enum Mode: String, Codable { case local, custom }
    var mode: Mode = .local
    var model = ""
    var baseURL = ""

    var label: String { mode == .local ? "Apple 本地模型" : model }
    // Use only after validation, immediately before making a request.
    var endpoint: URL { URL(string: baseURL)!.appendingPathComponent("chat/completions") }

    func validated(apiKey: String) throws -> AIConfiguration {
        var value = self
        value.model = model.trimmingCharacters(in: .whitespacesAndNewlines)
        value.baseURL = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while value.baseURL.hasSuffix("/") { value.baseURL.removeLast() }
        guard !value.model.isEmpty else { throw AIServiceError.invalidConfiguration("请填写服务提供的模型名称。") }
        guard let components = URLComponents(string: value.baseURL),
              let host = components.host, !host.isEmpty,
              components.url != nil else {
            throw AIServiceError.invalidConfiguration("请填写完整的 Base URL，例如 https://api.example.com/v1。")
        }
        let loopback = ["localhost", "127.0.0.1", "[::1]"].contains(host.lowercased())
        guard components.scheme?.lowercased() == "https" || (components.scheme?.lowercased() == "http" && loopback) else {
            throw AIServiceError.invalidConfiguration("请使用 HTTPS 地址；本机 localhost 可以使用 HTTP。")
        }
        guard components.user == nil, components.password == nil, components.query == nil, components.fragment == nil else {
            throw AIServiceError.invalidConfiguration("地址中请勿包含账号、Key、查询参数或锚点。")
        }
        guard !components.path.lowercased().hasSuffix("/chat/completions") else {
            throw AIServiceError.invalidConfiguration("请填写 Base URL，去掉末尾的 /chat/completions。")
        }
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, !key.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw AIServiceError.invalidConfiguration("请填写有效的 API Key。")
        }
        return value
    }
}

enum AIServiceError: LocalizedError, Equatable {
    case invalidConfiguration(String)
    case authentication, rateLimited, network, timedOut, invalidResponse, incompleteResponse, summaryTooLong
    case http(Int)
    var errorDescription: String? {
        switch self {
        case .invalidConfiguration(let message): message
        case .authentication: "API Key 无效或无权使用此模型，请检查配置。"
        case .rateLimited: "服务请求过多或额度不足，请稍后重试。"
        case .network: "无法连接模型服务，请检查网络和服务地址。"
        case .timedOut: "模型服务响应超时，请稍后重试。"
        case .invalidResponse: "服务未返回有效文本，请确认支持 Chat Completions 接口。"
        case .incompleteResponse: "模型未完整返回内容，请重试或更换模型。"
        case .summaryTooLong: "模型未能压缩长文本，请换用擅长总结的模型后重试。"
        case .http(let status): "模型服务返回 HTTP \(status)，请检查地址、模型名称及服务状态。"
        }
    }
}
