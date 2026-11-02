import CryptoKit
import Foundation

/// Shared pure mixed-language estimate; Ask AI applies its own safety margin in the budget.
enum AskAITokenEstimator {
    static func estimate(_ text: String) -> Int { ContentModelBudget.estimateTokens(text) }
}

struct AskAIContextBudget: Sendable {
    var windowTokens: Int = 4096
    var inputLimit: Int = 2200
    var outputReserve: Int = 512
    func fits(instruction: String, content: String, tools: String = "") -> Bool {
        let input = estimatedInput(instruction: instruction, content: content, tools: tools)
        return inputLimit > 0 && outputReserve >= 0 && input <= inputLimit && input <= windowTokens - outputReserve
    }
    func estimatedInput(instruction: String, content: String, tools: String = "") -> Int {
        // Framing margin covers role boundaries and the answer/citation wrapper.
        let raw = 64 + AskAITokenEstimator.estimate(instruction) + AskAITokenEstimator.estimate(content) + AskAITokenEstimator.estimate(tools)
        return raw + (raw + 3) / 4
    }
}

/// Intent only: assistant assertions and record bodies never enter rolling memory.
struct AskAIRollingMemory: Codable, Equatable, Sendable {
    let questions: [String]
    let coveredCursor: String?
    let dependencyDigest: String
    let inputDigest: String
    var promptVersion = "ask-ai-memory-v1"
    static func build(turns: [DaybookConversationTurn], dependencyDigest: String) -> Self {
        let ordered = turns.filter { $0.completionState == .completed }.sorted {
            let a = $0.createdAt ?? .distantPast, b = $1.createdAt ?? .distantPast
            return a == b ? $0.id.uuidString < $1.id.uuidString : a < b
        }
        let recent = ordered.suffix(12)
        let questions = recent.map { String($0.question.prefix(120)) }
        let digestText = recent.map { $0.id.uuidString + ":" + $0.question }.joined(separator: "\n")
        let digest = SHA256.hash(data: Data((dependencyDigest + "\n" + digestText).utf8)).map { String(format: "%02x", $0) }.joined()
        return Self(questions: questions, coveredCursor: ordered.last.map { "\(($0.createdAt ?? .distantPast).timeIntervalSinceReferenceDate):\($0.id.uuidString)" }, dependencyDigest: dependencyDigest, inputDigest: digest)
    }
}

struct AskAIBoundedContext: Sendable {
    let content: String
    let sources: [DaybookRetrieval.Source]
    let estimatedInputTokens: Int
    let historyTurnIDs: [UUID]
}

enum AskAIContextBuilder {
    enum Failure: Error { case invalidQuestion, budgetExceeded, noEvidence }
    static func build(question: String, history: [DaybookConversationTurn], evidence: [DaybookRetrieval.Source], instruction: String, tools: String = "", memory: AskAIRollingMemory? = nil, budget: AskAIContextBudget = .init()) throws -> AskAIBoundedContext {
        guard !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, question.count <= 300 else { throw Failure.invalidQuestion }
        var content = "CURRENT QUESTION:\n" + question + "\nCURRENT VERIFIED EVIDENCE:\n"
        guard budget.fits(instruction: instruction, content: content, tools: tools) else { throw Failure.budgetExceeded }
        var sources: [DaybookRetrieval.Source] = []
        for source in evidence.prefix(5) {
            var excerpt = String(source.snippet.prefix(200))
            let title = String(source.title.prefix(48))
            while !excerpt.isEmpty {
                let block = "[\(source.number)] id=\(source.id.uuidString) capturedAt=\(ISO8601DateFormatter().string(from: source.capturedAt)) kind=\(source.kind.rawValue) \(title)\n\(excerpt)\n"
                if budget.fits(instruction: instruction, content: content + block, tools: tools) {
                    content += block
                    sources.append(.init(id: source.id, number: source.number, title: title, capturedAt: source.capturedAt, kind: source.kind, snippet: excerpt, truncated: source.truncated || excerpt != source.snippet, provenance: source.provenance, sourceKey: source.sourceKey, speakerID: source.speakerID, speakerOffset: source.speakerOffset, speakerEndOffset: source.speakerEndOffset))
                    break
                }
                excerpt = String(excerpt.dropLast())
            }
        }
        if !evidence.isEmpty && sources.isEmpty { throw Failure.noEvidence }
        // Recent user questions resolve intent. Re-read sources to establish every personal fact.
        var historyIDs: [UUID] = []
        for turn in history.filter({ $0.completionState == .completed }).suffix(3).reversed() {
            let block = "\nCONVERSATION BACKGROUND (user question only, not evidence):\n" + turn.question + "\n"
            if budget.fits(instruction: instruction, content: content + block, tools: tools) { content += block; historyIDs.append(turn.id) }
        }
        if let memory {
            for question in memory.questions.reversed() {
                let block = "\nEARLIER USER INTENT (not evidence): " + question + "\n"
                if budget.fits(instruction: instruction, content: content + block, tools: tools) { content += block }
            }
        }
        return AskAIBoundedContext(content: content, sources: sources, estimatedInputTokens: budget.estimatedInput(instruction: instruction, content: content, tools: tools), historyTurnIDs: historyIDs)
    }
}
