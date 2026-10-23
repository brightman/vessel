import Foundation
import FoundationModels

enum SummaryFailure: LocalizedError {
    case unavailable
    case emptyTranscript

    var errorDescription: String? {
        switch self {
        case .unavailable: "此设备上的 Apple Intelligence 模型尚不可用"
        case .emptyTranscript: "请先完成转写或输入文本"
        }
    }
}

struct OnDeviceSummarizer {
    func summarize(_ transcript: String) async throws -> String {
        let content = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty else { throw SummaryFailure.emptyTranscript }
        guard case .available = SystemLanguageModel.default.availability else { throw SummaryFailure.unavailable }
        guard SystemLanguageModel.default.supportsLocale(Locale(identifier: "zh-CN")) else {
            throw SummaryFailure.unavailable
        }

        var layer = chunks(of: content, length: 650)
        while layer.count > 1 {
            var next: [String] = []
            for part in layer {
                let session = LanguageModelSession()
                let reply = try await session.respond(
                    to: "请用不超过100字的中文概括以下语音笔记片段，保留关键事实和行动项，不添加原文没有的内容：\n\(part)",
                    options: GenerationOptions(maximumResponseTokens: 192)
                )
                next.append(String(reply.content.prefix(220)))
            }
            let combined = next.joined(separator: "\n")
            layer = chunks(of: combined, length: 650)
        }
        let session = LanguageModelSession()
        let reply = try await session.respond(
            to: "请用中文为以下语音笔记写简短总结，列出要点和明确提及的行动项，不添加原文没有的内容：\n\(layer[0])",
            options: GenerationOptions(maximumResponseTokens: 384)
        )
        return reply.content
    }

    private func chunks(of value: String, length: Int) -> [String] {
        var result: [String] = []
        var cursor = value.startIndex
        while cursor < value.endIndex {
            let end = value.index(cursor, offsetBy: length, limitedBy: value.endIndex) ?? value.endIndex
            result.append(String(value[cursor..<end]))
            cursor = end
        }
        return result
    }
}
