import Foundation
import FoundationModels

@MainActor struct FlashCaptureService {
    func extract(source: ActionSource, settings: AppSettings, configuration: AIConfiguration,
                 isCurrent: @escaping @MainActor () -> Bool) async throws -> FlashExtraction {
        guard source.quote.count <= 6000 else { throw ActionFailure.invalid("这条闪念较长，请先编辑全文到 6000 字以内再整理。") }
        let date = ISO8601DateFormatter().string(from: source.capturedAt)
        let payload = ["transcript": source.quote, "recordedAt": date, "recordedTimeZone": source.timeZoneKnown ? source.timeZoneID : "未知，行动时间须留空"]
        let content = String(decoding: try JSONEncoder().encode(payload), as: UTF8.self)
        guard isCurrent() else { throw CancellationError() }
        let reply: String
        switch configuration.mode {
        case .local:
            guard case .available = SystemLanguageModel.default.availability else { throw SummaryFailure.unavailable }
            let session = LanguageModelSession(instructions: FlashCaptureParser.instruction)
            reply = try await session.respond(to: content, options: GenerationOptions(maximumResponseTokens: 2200)).content
        case .custom:
            reply = try await CustomAISummarizer().insight(content, instruction: FlashCaptureParser.instruction, configuration: configuration, apiKey: settings.apiKey())
        case .nearbyMac:
            reply = try await NearbyMacClient.shared.generate(content: content, instruction: FlashCaptureParser.instruction, configuration: configuration, isCurrent: isCurrent)
        case .chatgpt:
            reply = try await settings.chatGPT.complete(instruction: FlashCaptureParser.instruction, content: content, modelID: configuration.chatGPTModel, accountID: configuration.chatGPTAccountID, isCurrent: isCurrent)
        }
        try Task.checkCancellation(); guard isCurrent() else { throw CancellationError() }
        return try FlashCaptureParser.parse(reply, source: source)
    }
}
