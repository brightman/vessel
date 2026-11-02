import Foundation
import CryptoKit

@MainActor final class AskAIRuntime {
    enum Failure: LocalizedError {
        case requestLimit, deadline, contextOverflow, invalidState, repeatedCall
        var errorDescription: String? { "本次回答未能在安全范围内完成，请缩小问题范围后重试。" }
    }
    private let original: DaybookRetrieval.Prepared
    private let records: [DayRecord]
    private let configuration: AIConfiguration
    private let configurationRevision: Int
    private let turnID: UUID
    private let store: AskAIRuntimeStore
    private let isCurrent: @MainActor () -> Bool
    private let ensureFresh: @MainActor () async throws -> Void
    private let onStage: @MainActor (String) -> Void
    private let authorizeAdditional: @MainActor (String) async throws -> Void
    private let fence = AskAIPublicationFence()
    private var prepared: DaybookRetrieval.Prepared?
    private var tools: AskAIReadTools?
    private var run: AskAIRuntimeStore.Run?
    private var history: [DaybookConversationTurn] = []
    private var memory: AskAIRollingMemory?
    private var generation: Int64 = 0
    private var requests = 0
    private var activeStart = ProcessInfo.processInfo.systemUptime
    private var consentSeconds: TimeInterval = 0
    private var seenCalls = Set<String>()
    private var usedRepair = false
    private var usedRebuild = false
    private var generated = false
    private var finalResult: AskAIReadTools.Finalized?
    private var generationActive = false
    private var cancellationReason: String?
    private var apple: AskAIAppleDriver?
    private var nativeContext = ""
    private var usesNativeContext = false
    // Synthetic driver injection never affects the production provider choice.
    var testDriver: (any AskAIDriving)?
    var customSession: URLSession?
    var activeDeadline: TimeInterval = 90
    var beforePublicationLease: (@Sendable () -> Void)?

    init(prepared: DaybookRetrieval.Prepared, records: [DayRecord], configuration: AIConfiguration,
         configurationRevision: Int, turnID: UUID, store: AskAIRuntimeStore,
         isCurrent: @escaping @MainActor () -> Bool,
         ensureFresh: @escaping @MainActor () async throws -> Void = {},
         onStage: @escaping @MainActor (String) -> Void,
         authorizeAdditional: @escaping @MainActor (String) async throws -> Void) {
        original = prepared; self.records = records; self.configuration = configuration
        self.configurationRevision = configurationRevision; self.turnID = turnID; self.store = store
        self.isCurrent = isCurrent; self.ensureFresh = ensureFresh; self.onStage = onStage; self.authorizeAdditional = authorizeAdditional
    }
    var instruction: String {
        CustomAISummarizer.answerInstruction + "\n只读工具仅限原始获准范围；工具失败不等于无记录。引用仅用已登记编号，最多5个来源，每条记录一个窗口。\n" +
        (original.evidence.speakerContactID == nil ? "" : "当前资料仅包含关联联系人的说话人发言；直接概括这些发言，以‘关联为该联系人的说话人在录音中提到’限定，不推断现实身份或出席。\n")
    }
    private var windowTokens: Int { configuration.mode == .custom ? max(1024,min(4096,configuration.contextWindowTokens ?? 4096)) : 4096 }
    private var initialBudget: AskAIContextBudget { .init(windowTokens:windowTokens,inputLimit:min(2200,windowTokens - 512)) }
    private var workingBudget: AskAIContextBudget { .init(windowTokens:windowTokens,inputLimit:min(3584,windowTokens - 512)) }
    private var schemaText: String { String(data:(try? JSONSerialization.data(withJSONObject:AskAIReadTools.toolDefinitions,options:.sortedKeys)) ?? Data(),encoding:.utf8) ?? "" }
    private var permissionDigest: String { Self.digest(original.evidence.allowedKinds.map(\.rawValue).sorted().joined(separator:",") + (original.evidence.speakerContactID ?? "")) }
    private var sourceDigest: String { Self.digest(original.evidence.fingerprint + permissionDigest + String(original.dayStart.timeIntervalSinceReferenceDate) + String(original.dayEnd.timeIntervalSinceReferenceDate)) }
    private var configDigest: String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return Self.digest(String(data:(try? encoder.encode(configuration)) ?? Data(),encoding:.utf8)! + ":\(configurationRevision):" + instruction + schemaText + ProcessInfo.processInfo.operatingSystemVersionString)
    }
    static func digest(_ text:String) -> String { SHA256.hash(data:Data(text.utf8)).map { String(format:"%02x",$0) }.joined() }
    private func check() throws {
        try Task.checkCancellation()
        guard fence.check(), isCurrent() else { fence.invalidate(); throw CancellationError() }
        guard !generationActive || ProcessInfo.processInfo.systemUptime - activeStart - consentSeconds < activeDeadline else { throw Failure.deadline }
    }
    private func update(_ state:AskAIRuntimeStore.State) async throws {
        try check(); guard let run else { throw Failure.invalidState }
        try await store.updateAttempt(runID:run.id,state:state,providerRequests:requests,toolCalls:tools?.toolCallCount ?? 0)
        try check()
    }
    func prepare() async throws -> DaybookRetrieval.Prepared {
        try check(); guard run == nil else { throw Failure.invalidState }
        generation = try await store.cacheGeneration()
        run = try await store.startAttempt(turnID:turnID,provider:configuration.mode.rawValue,model:configuration.model,configRevision:String(configurationRevision))
        history = try await store.runtimeHistory(limit:40).filter { $0.id != turnID && $0.evidence.allowedKinds.isSubset(of:original.evidence.allowedKinds) && $0.evidence.speakerContactID == original.evidence.speakerContactID }
        memory = try await store.loadMemory(dependencyDigest:permissionDigest + sourceDigest)
        let readTools = AskAIReadTools(prepared:original,records:records,history:history,scopeIsCurrent:isCurrent)
        tools = readTools
        if memory == nil { memory = AskAIRollingMemory.build(turns:history,dependencyDigest:permissionDigest + sourceDigest) }
        let result = try bounded(readTools.evidence.map(\.source), history:history, memory:memory)
        prepared = result
        try await persistEvidence(); try await update(configuration.isRemote ? .awaitingConsent : .preparing); try check(); return result
    }
    private func bounded(_ sources:[DaybookRetrieval.Source],history:[DaybookConversationTurn],memory:AskAIRollingMemory?) throws -> DaybookRetrieval.Prepared {
        // Wrapper/question are charged as instruction overhead too; this intentionally overestimates.
        var prefix = ""
        if original.evidence.speakerContactID != nil {
            // prepareSpeaker's first line is a controlled contact identity prefix, never transcript text.
            let first = String(original.context.prefix(300).split(separator:"\n",omittingEmptySubsequences:false).first ?? "")
            if first.hasPrefix("当前检索对象是联系人「") || first.hasPrefix("当前关联联系人：") || first.hasPrefix("当前问题") || first.hasPrefix("关联联系人：") || first.hasPrefix("当前联系人：") { prefix = first + "\n" }
        }
        let overhead = CustomAISummarizer.answerContent(question:original.providerQuestion,context:prefix)
        let context = try AskAIContextBuilder.build(question:original.question,history:history,evidence:sources,instruction:instruction + overhead,tools:schemaText,memory:memory,budget:initialBudget)
        let originalHeader = "CURRENT QUESTION:\n" + original.question + "\n"
        let outgoingContent = "CURRENT QUESTION:\n" + original.providerQuestion + "\n" + context.content.dropFirst(originalHeader.count)
        let result = original.projecting(sources:context.sources,context:prefix + outgoingContent)
        guard initialBudget.fits(instruction:instruction,content:CustomAISummarizer.answerContent(question:result.providerQuestion,context:result.context),tools:schemaText) else { throw Failure.contextOverflow }
        return result
    }
    private func persistEvidence() async throws {
        guard let run, let tools else { throw Failure.invalidState }
        for entry in tools.evidence {
            try check()
            try await store.recordEvidence(runID:run.id,id:entry.id,sourceIdentity:entry.source.id.uuidString,sourceVersion:Self.digest(entry.source.snippet),queryScope:sourceDigest,excerpt:String(entry.source.snippet.prefix(200)),permissionDigest:permissionDigest)
        }
    }
    private func countRequest(_ count:Int = 1) async throws {
        try await ensureFresh(); try check(); guard requests + count <= 8 else { throw Failure.requestLimit }; requests += count; try await update(.generating)
    }
    private func consent(_ text:String) async throws {
        try await update(.awaitingConsent)
        let start = ProcessInfo.processInfo.systemUptime
        do { try await authorizeAdditional(text) }
        catch { consentSeconds += ProcessInfo.processInfo.systemUptime - start; throw error }
        consentSeconds += ProcessInfo.processInfo.systemUptime - start
        try check()
    }
    private func execute(_ call:AskAIToolCall, remote:Bool) async throws -> String {
        try check(); guard let run, let tools else { throw Failure.invalidState }
        guard tools.toolCallCount < 6 else { throw AskAIReadTools.Failure.callLimit }
        guard seenCalls.insert(call.id).inserted else { throw Failure.repeatedCall }
        let start = ProcessInfo.processInfo.systemUptime
        try await update(.toolRunning); onStage("正在查阅本地资料…")
        // Persist hashes only: model-supplied arguments can repeat private excerpts or prompt injection.
        try await store.recordToolCall(runID:run.id,callID:Self.digest(call.id),toolName:AskAIReadTools.toolDefinitions.contains(where:{$0["name"] as? String == call.name}) ? call.name : "unknown",argsDigest:Self.digest(String(decoding:call.arguments,as:UTF8.self)),arguments:"{}",state:"running",resultReferences:[],elapsedMilliseconds:0)
        let output:String; let references:[String]; let state:String
        do {
            let result = try await tools.execute(name:call.name,arguments:call.arguments)
            var bounded = result.text
            while AskAITokenEstimator.estimate(bounded) > 400 { bounded = String(bounded.dropLast(max(1,bounded.count / 10))) }
            output = "status=\(result.status)\n" + bounded + (bounded == result.text ? "" : "\n[tool result truncated]"); references = result.evidenceIDs; state = "completed"
        } catch is CancellationError { throw CancellationError() }
        catch AskAIReadTools.Failure.staleEvidence { throw CancellationError() }
        catch AskAIReadTools.Failure.callLimit { throw AskAIReadTools.Failure.callLimit }
        catch {
            // Never reflect raw filesystem/SQL/network/localized errors to a provider.
            output = "status=error\nLocal tool could not complete this request. This is not an empty result."; references = []; state = "failed"
        }
        try check(); try await persistEvidence()
        try await store.recordToolCall(runID:run.id,callID:Self.digest(call.id),toolName:AskAIReadTools.toolDefinitions.contains(where:{$0["name"] as? String == call.name}) ? call.name : "unknown",argsDigest:Self.digest(String(decoding:call.arguments,as:UTF8.self)),arguments:"{}",state:state,resultReferences:references,elapsedMilliseconds:Int((ProcessInfo.processInfo.systemUptime-start)*1000))
        try await update(.generating)
        if remote { try await consent(output) }
        return output
    }
    /// Shared native callback boundary, also exercised without invoking a model in fixtures.
    func executeNative(_ call: AskAIToolCall) async throws -> String {
        usesNativeContext = true
        // Conservative charge for the model continuation after each native tool result.
        try await countRequest()
        let result = try await execute(call, remote: false)
        nativeContext += String(decoding: call.arguments, as: UTF8.self) + result
        guard workingBudget.fits(instruction: instruction, content: nativeContext, tools: schemaText) else { throw Failure.contextOverflow }
        return result
    }

    /// Every explicit next/repair request uses the same budget boundary, including native tool callbacks and restored payload.
    func validateNextContext(correction: String?, conversation: String) throws {
        let actual = usesNativeContext ? nativeContext : conversation
        guard workingBudget.fits(instruction:instruction,content:actual + (correction ?? ""),tools:schemaText) else { throw Failure.contextOverflow }
    }

    /// Timer cancels the in-flight network/native generation, rather than merely checking after it.
    private func timed<T>(_ work:@escaping @MainActor () async throws -> T) async throws -> T {
        let remaining = max(0, activeDeadline - (ProcessInfo.processInfo.systemUptime - activeStart - consentSeconds))
        return try await withThrowingTaskGroup(of:T.self) { group in
            group.addTask { @MainActor in try await work() }
            group.addTask { @MainActor in
                let end = ProcessInfo.processInfo.systemUptime + remaining
                while ProcessInfo.processInfo.systemUptime < end {
                    try await Task.sleep(nanoseconds:50_000_000); try self.check()
                }
                throw Failure.deadline
            }
            defer { group.cancelAll() }; return try await group.next()!
        }
    }
    func generate(apiKey:String?,fallback:any DaybookAnswering) async throws -> AskAIReadTools.Finalized {
        activeStart = ProcessInfo.processInfo.systemUptime; consentSeconds = 0
        generationActive = true; defer { generationActive = false }
        try check(); guard let prepared, let tools, !generated else { throw Failure.invalidState }
        // Time spent reviewing the initial preview does not consume active inference time.
        activeStart = ProcessInfo.processInfo.systemUptime; consentSeconds = 0
        var driver: (any AskAIDriving)? = testDriver
        if driver == nil, configuration.mode == .custom {
            guard let apiKey else { throw AIServiceError.authentication }
            let custom = try AskAICustomDriver(configuration:configuration,apiKey:apiKey,session:customSession,check:{ [weak self] in guard let self else { throw CancellationError() }; try await self.ensureFresh(); try self.check() })
            try await countRequest()
            if try await timed({ try await custom.probe() }) { driver = custom }
        } else if driver == nil, configuration.mode == .local {
            if #available(iOS 26.3, macOS 26.3, *) {
                let native = AskAIAppleDriver(execute:{ [weak self] call in
                    guard let self else { throw CancellationError() }
                    return try await self.executeNative(call)
                })
                apple = native; driver = native; usesNativeContext = true
            }
        }
        guard let driver else {
            try await countRequest(2)
            let text = try await timed {
                if let service = fallback as? DaybookAnswerService {
                    return try await service.answerReviewed(prepared,configuration:self.configuration,apiKey:apiKey,instruction:self.instruction,isCurrent:self.isCurrent,ensureFresh:self.ensureFresh)
                }
                return try await fallback.answer(prepared,configuration:self.configuration,apiKey:apiKey,isCurrent:self.isCurrent)
            }
            try check(); let finalized = try tools.finalize(answer:text); generated = true; finalResult = finalized; return finalized
        }
        nativeContext = CustomAISummarizer.answerContent(question:prepared.providerQuestion,context:prepared.context)
        try driver.start(instruction:instruction,content:nativeContext)
        if let apple {
            let inputDigest = Self.digest(prepared.context + prepared.providerQuestion)
            if let checkpoint = try await store.loadCheckpoint(providerConfigDigest:configDigest,permissionDigest:permissionDigest,sourceDigest:sourceDigest,inputDigest:inputDigest) {
                if apple.restore(checkpoint.payload, newInput:prepared.context + instruction + schemaText) { nativeContext += String(decoding:checkpoint.payload,as:UTF8.self) }
            }
        }
        var correction:String?; var transcript = CustomAISummarizer.answerContent(question:prepared.providerQuestion,context:prepared.context)
        while true {
            try check()
            do {
                try validateNextContext(correction:correction,conversation:transcript)
                try await countRequest(); onStage("正在整理回答…")
                let prompt = correction
                let reply = try await timed { try await driver.next(correction:prompt) }; correction = nil
                transcript += (prompt ?? "") + reply.text
                if usesNativeContext { nativeContext += (prompt ?? "") + reply.text }
                if !reply.calls.isEmpty {
                    for call in reply.calls {
                        let result = try await execute(call,remote:configuration.isRemote)
                        try driver.receive(call:call,result:result)
                        transcript += String(decoding:call.arguments,as:UTF8.self) + result
                    }
                    continue
                }
                try await update(.validating)
                do { let finalized = try tools.finalize(answer:reply.text); generated = true; finalResult = finalized; return finalized }
                catch AskAIReadTools.Failure.invalidCitation {
                    guard !usedRepair else { throw DaybookAnswerFailure.missingCitations }
                    usedRepair = true
                    correction = DaybookAnswerCitationPolicy.repairInstruction(Set(tools.evidence.map { $0.source.number })) + " At most five sources, one window per record."
                }
            } catch Failure.contextOverflow {
                guard !usedRebuild else { throw Failure.contextOverflow }; usedRebuild = true
                let rebuilt = try bounded(Array(tools.evidence.suffix(5)).map(\.source),history:[],memory:nil)
                let content = CustomAISummarizer.answerContent(question:rebuilt.providerQuestion,context:rebuilt.context)
                if configuration.isRemote { try await consent(content) }
                try driver.start(instruction:instruction,content:content); transcript = content; nativeContext = content
            }
        }
    }
    func publish(_ turn:DaybookConversationTurn) async throws {
        guard let run, generated, let finalResult, turn.id == turnID, turn.text == finalResult.text, turn.sources == finalResult.sources, turn.evidence == finalResult.prepared.evidence else { throw Failure.invalidState }
        while true {
            try await ensureFresh(); try check()
            do {
                try await store.completeAttempt(runID:run.id,turn:turn,publicationFence:fence,beforePublicationLease:beforePublicationLease)
                break
            } catch AskAIPublicationFence.Failure.validationPending {
                // Revalidate and retry only this generated publication, never inference.
                try await fence.waitUntilReady()
            }
        }
        guard fence.check(), isCurrent() else { return }
        let derived = AskAIRollingMemory.build(turns:history + [turn],dependencyDigest:permissionDigest + sourceDigest)
        // These are disposable caches; a failed cache save cannot turn an atomic success into a failed answer.
        try? await store.saveMemory(derived,anchorTurnID:turnID,expectedGeneration:generation,publicationFence:fence)
        if tools?.toolCallCount == 0, let payload = apple?.completedCheckpoint(), let prepared {
            let checkpoint = AskAIRuntimeStore.Checkpoint(anchorTurnID:turnID,providerConfigDigest:configDigest,formatVersion:"1",toolVersion:"1",promptVersion:"1",inputDigest:Self.digest(prepared.context + prepared.providerQuestion),permissionDigest:permissionDigest,sourceDigest:sourceDigest,payload:payload)
            if fence.check(), isCurrent() { try? await store.saveCheckpoint(checkpoint,expectedGeneration:generation,publicationFence:fence) }
        }
    }
    func suspendPublication(validation: UUID) { fence.suspend(validation: validation) }
    func resumePublication(validation: UUID) { fence.resume(validation: validation) }
    func cancel(reason: String = "cancelled") {
        cancellationReason = reason
        fence.invalidate()
        if let run { Task { try? await store.interruptAttempt(runID:run.id,state:.cancelled,errorCode:reason) } }
    }
    func fail(_ error:Error) async {
        fence.invalidate(); guard let run else { return }
        try? await store.interruptAttempt(runID:run.id,state:error is CancellationError ? .cancelled : .failed,errorCode:cancellationReason ?? (error is CancellationError ? "cancelled" : "generation_failed"))
    }
}
