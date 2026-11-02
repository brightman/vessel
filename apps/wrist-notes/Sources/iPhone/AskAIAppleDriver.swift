import Foundation
import FoundationModels

@available(iOS 26.3, macOS 26.3, *)
@Generable private struct AskAIAppleArguments {
    @Guide(description:"One of searchRecords, readRecord, aggregateMetrics, searchConversationHistory") var name: String
    @Guide(description:"JSON object matching that tool's parameters") var json: String
}
@available(iOS 26.3, macOS 26.3, *)
private struct AskAIAppleReadTool: Tool {
    let name = "readLocalRecords"
    let description: String
    let execute: @MainActor @Sendable (AskAIToolCall) async throws -> String
    func call(arguments: AskAIAppleArguments) async throws -> String {
        try await execute(.init(id:UUID().uuidString,name:arguments.name,arguments:Data(arguments.json.utf8)))
    }
}

/// Native Tool owns call/result transcript pairing; only a completed response is checkpointed.
@MainActor final class AskAIAppleDriver: AskAIDriving {
    private let execute: @MainActor @Sendable (AskAIToolCall) async throws -> String
    private var session: LanguageModelSession?
    private var instruction = ""
    private var content = ""
    private var completed = false
    private var restored = false
    init(execute:@escaping @MainActor @Sendable (AskAIToolCall) async throws -> String) { self.execute = execute }
    private static var toolDescription: String {
        let schemas = String(data:(try? JSONSerialization.data(withJSONObject:AskAIReadTools.toolDefinitions,options:.sortedKeys)) ?? Data(),encoding:.utf8) ?? ""
        return "Call one of these read-only capabilities using name and a JSON object string matching parameters. Dates and permissions cannot expand. " + schemas
    }
    func start(instruction:String,content:String) throws {
        self.instruction = instruction; self.content = content; completed = false; restored = false
        guard #available(iOS 26.3,macOS 26.3,*) else { throw DaybookAnswerFailure.generation }
        let model = SystemLanguageModel.default
        guard case .available = model.availability else { throw DaybookAnswerFailure.unavailable("Apple Intelligence 当前不可用。") }
        guard model.supportsLocale(Locale(identifier:"zh-CN")) else { throw DaybookAnswerFailure.unsupportedLanguage }
        session = LanguageModelSession(model:model,tools:[AskAIAppleReadTool(description:Self.toolDescription,execute:execute)],instructions:instruction)
    }
    func rebuild() throws { try start(instruction:instruction,content:content) }
    func next(correction:String?) async throws -> AskAIDriverReply {
        guard #available(iOS 26.3,macOS 26.3,*), let session else { throw DaybookAnswerFailure.generation }
        completed = false
        do {
            let prompt = correction ?? (restored ? "Re-answer the current question using the verified evidence above; cite at most five registered sources." : content)
            let result = try await session.respond(to:prompt,options:GenerationOptions(maximumResponseTokens:512))
            try Task.checkCancellation(); completed = true
            return .init(text:result.content,calls:[])
        } catch is CancellationError { throw CancellationError() }
        catch let error as LanguageModelSession.ToolCallError {
            if error.underlyingError is CancellationError { throw CancellationError() }
            if let failure = error.underlyingError as? AskAIRuntime.Failure { throw failure }
            if let failure = error.underlyingError as? AskAIReadTools.Failure { throw failure }
            throw DaybookAnswerFailure.generation
        }
        catch LanguageModelSession.GenerationError.exceededContextWindowSize { throw AskAIRuntime.Failure.contextOverflow }
        catch { try Task.checkCancellation(); throw DaybookAnswerFailure.generation }
    }
    func receive(call:AskAIToolCall,result:String) throws { throw AskAIRuntime.Failure.invalidState }
    @discardableResult func restore(_ payload:Data,newInput:String) -> Bool {
        guard #available(iOS 26.3,macOS 26.3,*), payload.count <= 64 * 1024,
              let transcript = try? JSONDecoder().decode(Transcript.self,from:payload),
              Self.stable(transcript), !transcript.contains(where: { entry in if case .toolCalls = entry { return true }; if case .toolOutput = entry { return true }; return false }),
              AskAITokenEstimator.estimate(String(decoding:payload,as:UTF8.self) + newInput) * 5 / 4 + 64 <= 2200 else { return false }
        session = LanguageModelSession(model:.default,tools:[AskAIAppleReadTool(description:Self.toolDescription,execute:execute)],transcript:transcript)
        restored = true; return true
    }
    func completedCheckpoint() -> Data? {
        guard #available(iOS 26.3,macOS 26.3,*), completed, let transcript = session?.transcript, Self.stable(transcript),
              let data = try? JSONEncoder().encode(transcript), data.count <= 64 * 1024 else { return nil }
        return data
    }
    private static func stable(_ transcript:Transcript) -> Bool {
        guard let last = transcript.last, case .response = last else { return false }
        var pending = Set<String>()
        for entry in transcript {
            switch entry {
            case .toolCalls(let calls):
                for call in calls { guard pending.insert(call.id).inserted else { return false } }
            case .toolOutput(let output): guard pending.remove(output.id) != nil else { return false }
            default: break
            }
        }
        return pending.isEmpty
    }
}
