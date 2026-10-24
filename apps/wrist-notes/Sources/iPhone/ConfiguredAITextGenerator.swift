import Foundation

/// All external text providers have explicit routing. Nearby Mac never falls back to a cloud or Apple model.
@MainActor
enum ConfiguredAITextGenerator {
    static func generate(_ content: String, instruction: String, configuration: AIConfiguration, apiKey: String = "",
                         custom: CustomAISummarizer = CustomAISummarizer(), chatGPT: ChatGPTAccountModel? = nil,
                         isCurrent: @escaping @MainActor () -> Bool = { true }) async throws -> String {
        try Task.checkCancellation()
        guard isCurrent() else { throw CancellationError() }
        let value: String
        switch configuration.mode {
        case .nearbyMac:
            value = try await NearbyMacClient.shared.generate(content: content, instruction: instruction,
                configuration: configuration, isCurrent: isCurrent)
        case .custom:
            value = try await custom.sendCustomRequest(content, instruction: instruction, configuration: configuration, apiKey: apiKey)
        case .chatgpt:
            value = try await (chatGPT ?? .shared).complete(instruction: instruction, content: content,
                modelID: configuration.chatGPTModel, accountID: configuration.chatGPTAccountID, isCurrent: isCurrent)
        case .local:
            throw AIServiceError.invalidConfiguration("Apple 本地模型应在 iPhone 上运行。")
        }
        try Task.checkCancellation()
        guard isCurrent() else { throw CancellationError() }
        return value
    }
}
