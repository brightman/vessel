import Foundation

@MainActor private final class ScriptDriver: AskAIDriving {
    var replies: [Result<AskAIDriverReply,Error>]
    var sent: [String] = []; var results: [String] = []; var starts = 0
    var wait = false
    var onNext: (@MainActor () async throws -> Void)?
    init(_ replies:[Result<AskAIDriverReply,Error>]) { self.replies = replies }
    func start(instruction:String,content:String) throws { starts += 1; sent.append(content) }
    func rebuild() throws { starts += 1 }
    func next(correction:String?) async throws -> AskAIDriverReply {
        if let correction { sent.append(correction) }
        if let onNext { self.onNext = nil; try await onNext() }
        if wait { try await Task.sleep(nanoseconds:5_000_000_000) }
        guard !replies.isEmpty else { throw AIServiceError.invalidResponse }
        return try replies.removeFirst().get()
    }
    func receive(call:AskAIToolCall,result:String) throws { results.append(result) }
}
private final class PublicationGate: @unchecked Sendable {
    private let lock = NSLock()
    private let semaphore = DispatchSemaphore(value:0)
    private var entered = false
    private var first = true
    var didEnter: Bool { lock.lock(); defer { lock.unlock() }; return entered }
    func pauseOnce() {
        lock.lock(); let shouldPause = first; first = false; if shouldPause { entered = true }; lock.unlock()
        if shouldPause { semaphore.wait() }
    }
    func release() { semaphore.signal() }
}
private final class FixtureProtocol: URLProtocol, @unchecked Sendable {
    static var handler: (URLRequest) throws -> (Int,[String:Any]) = { _ in (500,[:]) }
    override class func canInit(with request:URLRequest) -> Bool { true }
    override class func canonicalRequest(for request:URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (status,body) = try Self.handler(request)
            client?.urlProtocol(self,didReceive:HTTPURLResponse(url:request.url!,statusCode:status,httpVersion:nil,headerFields:["Content-Type":"application/json"])!,cacheStoragePolicy:.notAllowed)
            client?.urlProtocol(self,didLoad:try JSONSerialization.data(withJSONObject:body)); client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self,didFailWithError:error) }
    }
    override func stopLoading() {}
}
@MainActor private struct NoFallback: DaybookAnswering {
    func answer(_ prepared:DaybookRetrieval.Prepared,configuration:AIConfiguration,apiKey:String?) async throws -> String { throw AIServiceError.invalidResponse }
}
private final class RuntimeAccountStore: ChatGPTAccountStoring {
    var vault: ChatGPTAccountVault
    init(_ vault: ChatGPTAccountVault) { self.vault = vault }
    func load() throws -> ChatGPTAccountVault? { vault }
    func save(_ vault: ChatGPTAccountVault) throws { self.vault = vault }
}
private actor RuntimeAccountAPI: ChatGPTServing {
    var refreshes = 0, catalogs = 0, requests = 0
    nonisolated func authorizationURL(attempt:ChatGPTAuthorizationAttempt) throws -> URL { URL(string:"https://fixture.invalid/authorize")! }
    func exchange(callbackURL:URL,attempt:ChatGPTAuthorizationAttempt) async throws -> ChatGPTCredential { throw ChatGPTError.invalidCallback }
    func refresh(_ credential:ChatGPTCredential) async throws -> ChatGPTCredential {
        refreshes += 1; try await Task.sleep(nanoseconds:40_000_000)
        return ChatGPTCredential(clientID:credential.clientID,subject:credential.subject,email:nil,hostID:credential.hostID,idToken:"fixture",accessToken:"fixture",refreshToken:"fixture",expiresAt:.now.addingTimeInterval(3600),scopes:credential.scopes)
    }
    func models(accessToken:String) async throws -> [ChatGPTModel] { catalogs += 1; try await Task.sleep(nanoseconds:40_000_000); return [.init(id:"fixture-model",displayName:"Fixture")] }
    func complete(instruction:String,content:String,model:String,accessToken:String) async throws -> String { requests += 1; return "fixture [1]" }
    func revoke(_ credential:ChatGPTCredential) async throws {}
    func counts() -> (Int,Int,Int) { (refreshes,catalogs,requests) }
}
@main struct AskAIDriversSmoke {
    struct Failed: Error { let message:String }
    static func check(_ condition:@autoclosure () throws -> Bool,_ message:String) throws { if try !condition() { throw Failed(message:message) } }
    @MainActor static func main() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ask-ai-drivers-" + UUID().uuidString)
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true); defer { try? FileManager.default.removeItem(at:directory) }
        var calendar = Calendar(identifier:.gregorian); calendar.timeZone = TimeZone(secondsFromGMT:0)!
        let day = calendar.date(from:DateComponents(year:2026,month:11,day:1))!
        let records = [DayRecord(id:UUID(),capturedAt:day,kind:.voice,title:"Synthetic project",text:"project evidence one"), DayRecord(id:UUID(),capturedAt:day.addingTimeInterval(2),kind:.voice,title:"Synthetic second",text:"project evidence two")]
        var retrieval = DaybookRetrieval(); retrieval.calendar = calendar
        let original = try retrieval.prepare(question:"project",records:records,selectedDate:day,allowedKinds:[.voice])
        let fixtureDB = try DaybookDatabase(url:directory.appendingPathComponent("fixture.sqlite"))
        let conversations = DaybookConversationStore(url:directory.appendingPathComponent("history.json"),database:fixtureDB)
        let store = AskAIRuntimeStore(conversationStore:conversations)
        var previews:[String] = []
        func runtime(_ driver:ScriptDriver,remote:Bool = false) throws -> (AskAIRuntime,UUID) {
            let id = UUID()
            let turn = DaybookConversationTurn(id:id,question:original.question,text:"",generated:false,provider:"",evidence:original.evidence,sources:[],scopeDescription:"",state:.pending)
            try conversations.saveTurn(turn,day:day)
            var configuration = AIConfiguration(); configuration.mode = remote ? .custom : .local
            let engine = AskAIRuntime(prepared:original,records:records,configuration:configuration,configurationRevision:1,turnID:id,store:store,isCurrent:{true},onStage:{_ in},authorizeAdditional:{ text in previews.append(text) })
            engine.testDriver = driver; return (engine,id)
        }
        func reply(_ text:String = "",_ calls:[AskAIToolCall] = []) -> Result<AskAIDriverReply,Error> { .success(.init(text:text,calls:calls)) }
        let call = AskAIToolCall(id:"call-1",name:"searchRecords",arguments:Data(#"{"query":"project"}"#.utf8))
        let scripted = ScriptDriver([reply("",[call]),reply("uncited answer"),reply("Evidence [1]")])
        let (engine,id) = try runtime(scripted,remote:true)
        let bounded = try await engine.prepare()
        try check(AskAIContextBudget().fits(instruction:engine.instruction,content:CustomAISummarizer.answerContent(question:bounded.providerQuestion,context:bounded.context),tools:String(data:try JSONSerialization.data(withJSONObject:AskAIReadTools.toolDefinitions,options:.sortedKeys),encoding:.utf8)!),"initial actual input budget")
        let answer = try await engine.generate(apiKey:nil,fallback:NoFallback())
        try check(answer.sources.count == 1 && scripted.results.count == 1 && previews == scripted.results,"exact supplemental outgoing tool result consent")
        try check(scripted.sent.count == 2 && scripted.sent[1].contains("来源编号"),"one citation repair")
        let final = DaybookConversationTurn(id:id,question:original.question,text:answer.text,generated:true,provider:"fixture",evidence:answer.prepared.evidence,sources:answer.sources,scopeDescription:"",state:.completed)
        try await engine.publish(final); try await engine.publish(final)
        let saved = try await store.runtimeTurn(id:id)
        try check(saved?.turn.text == answer.text,"atomic idempotent publication")
        let repeated = ScriptDriver([reply("",[call]),reply("",[call])]); let (repeatEngine,_) = try runtime(repeated)
        _ = try await repeatEngine.prepare()
        do { _ = try await repeatEngine.generate(apiKey:nil,fallback:NoFallback()); throw Failed(message:"duplicate call id accepted") } catch AskAIRuntime.Failure.repeatedCall {}
        let overflow = ScriptDriver([.failure(AskAIRuntime.Failure.contextOverflow),reply("answer [1]")]); let (overflowEngine,_) = try runtime(overflow)
        _ = try await overflowEngine.prepare(); _ = try await overflowEngine.generate(apiKey:nil,fallback:NoFallback())
        try check(overflow.starts == 2,"single overflow rebuild")
        let twice = ScriptDriver([.failure(AskAIRuntime.Failure.contextOverflow),.failure(AskAIRuntime.Failure.contextOverflow)]); let (twiceEngine,_) = try runtime(twice)
        _ = try await twiceEngine.prepare()
        do { _ = try await twiceEngine.generate(apiKey:nil,fallback:NoFallback()); throw Failed(message:"second overflow accepted") } catch AskAIRuntime.Failure.contextOverflow {}
        let bad = ScriptDriver([reply("invented [999]"),reply("invented [999]")]); let (badEngine,_) = try runtime(bad)
        _ = try await badEngine.prepare()
        do { _ = try await badEngine.generate(apiKey:nil,fallback:NoFallback()); throw Failed(message:"out of ledger accepted") } catch DaybookAnswerFailure.missingCitations {}
        let cancelled = ScriptDriver([reply("answer [1]")]); let (cancelEngine,cancelID) = try runtime(cancelled)
        _ = try await cancelEngine.prepare(); let candidate = try await cancelEngine.generate(apiKey:nil,fallback:NoFallback()); cancelEngine.cancel()
        do { try await cancelEngine.publish(.init(id:cancelID,question:original.question,text:candidate.text,generated:true,provider:"fixture",evidence:original.evidence,sources:candidate.sources,scopeDescription:"",state:.completed)); throw Failed(message:"late publish") } catch is CancellationError {}
        let slow = ScriptDriver([reply("answer [1]")]); slow.wait = true; let (deadline,_) = try runtime(slow); deadline.activeDeadline = 0.08
        _ = try await deadline.prepare()
        do { _ = try await deadline.generate(apiKey:nil,fallback:NoFallback()); throw Failed(message:"deadline did not cancel request") } catch AskAIRuntime.Failure.deadline {}
        let manyCalls = (0..<7).map { AskAIToolCall(id:"c\($0)",name:"searchRecords",arguments:call.arguments) }
        let limited = ScriptDriver(manyCalls.map { reply("",[$0]) }); let (limitEngine,_) = try runtime(limited)
        _ = try await limitEngine.prepare()
        do { _ = try await limitEngine.generate(apiKey:nil,fallback:NoFallback()); throw Failed(message:"tool/request limit bypass") } catch AskAIReadTools.Failure.callLimit {} catch AskAIRuntime.Failure.requestLimit {} catch AskAIRuntime.Failure.contextOverflow {}
        let repeatQuery = ScriptDriver([reply("",[call]), reply("",[.init(id:"call-2",name:call.name,arguments:call.arguments)]), reply("verified [1]")])
        let (repeatQueryEngine,_) = try runtime(repeatQuery)
        _ = try await repeatQueryEngine.prepare(); _ = try await repeatQueryEngine.generate(apiKey:nil,fallback:NoFallback())
        try check(repeatQuery.results.count == 2 && repeatQuery.results[0] == repeatQuery.results[1],"same query with distinct ids is legal and stable")
        let errors = (0..<6).map { AskAIToolCall(id:"error-\($0)",name:"unknown",arguments:Data("{}".utf8)) }
        let exhausted = ScriptDriver(errors.map { reply("",[$0]) } + [.failure(AskAIRuntime.Failure.contextOverflow), reply("uncited"), reply("answer [1]")])
        let (exhaustEngine,_) = try runtime(exhausted)
        _ = try await exhaustEngine.prepare()
        do { _ = try await exhaustEngine.generate(apiKey:nil,fallback:NoFallback()); throw Failed(message:"repair request exceeded eight") } catch AskAIRuntime.Failure.requestLimit {}
        try check(exhausted.results.count == 6 && exhausted.results.allSatisfy { $0.contains("status=error") && !$0.contains("status=empty") },"errors consume budget and remain distinguishable")
        let native = ScriptDriver([reply("native verified [1]")]); let (nativeEngine,_) = try runtime(native)
        _ = try await nativeEngine.prepare()
        var nativeResults: [String] = []
        native.onNext = {
            nativeResults.append(try await nativeEngine.executeNative(call))
            nativeResults.append(try await nativeEngine.executeNative(.init(id:"native-two",name:call.name,arguments:call.arguments)))
        }
        _ = try await nativeEngine.generate(apiKey:nil,fallback:NoFallback())
        try check(nativeResults.count == 2 && nativeResults[0] == nativeResults[1],"actual native callback boundary uses shared budgets and tools")
        let nativeConversation = native.sent[0] + "native verified [1]"
        let nativeSchemas = String(data:try JSONSerialization.data(withJSONObject:AskAIReadTools.toolDefinitions,options:.sortedKeys),encoding:.utf8)!
        var foundNativeBoundary = false
        for count in stride(from:0,to:3500,by:5) {
            let correction = String(repeating:"修",count:count)
            guard AskAIContextBudget(inputLimit:3584).fits(instruction:nativeEngine.instruction,content:nativeConversation + correction,tools:nativeSchemas) else { continue }
            do { try nativeEngine.validateNextContext(correction:correction,conversation:nativeConversation) }
            catch AskAIRuntime.Failure.contextOverflow { foundNativeBoundary = true; break }
        }
        try check(foundNativeBoundary,"repair boundary must include actual native callback results rather than the smaller driver conversation")
        try await fallbackFreshness(original)
        let pendingDriver = ScriptDriver([]); let (pendingEngine,pendingID) = try runtime(pendingDriver)
        _ = try await pendingEngine.prepare(); pendingEngine.cancel(reason: "inactive")
        await pendingEngine.fail(CancellationError())
        try await Task.sleep(nanoseconds:50_000_000)
        let pending = try await store.runtimeTurn(id:pendingID)
        try check(pending?.turn.completionState == .cancelled,"initial preview cancellation terminalizes durable pending turn")
        let cancellation = try fixtureDB.query("SELECT error_code FROM ask_ai_runs WHERE turn_id=?", [.text(pendingID.uuidString)])
        try check(cancellation.first?["error_code"]?.string == "inactive", "late generic failure must preserve the explicit interruption cause")
        let fence = AskAIPublicationFence(); fence.invalidate()
        let leasedID = UUID(); let leased = DaybookConversationTurn(id:leasedID,question:original.question,text:"",generated:false,provider:"",evidence:original.evidence,sources:[],scopeDescription:"",state:.pending)
        try conversations.saveTurn(leased,day:day)
        let leasedRun = try await store.startAttempt(turnID:leasedID,provider:"fixture",model:"fixture",configRevision:"1")
        do { try await store.completeAttempt(runID:leasedRun.id,turn:leased.replacing(text:"forbidden",state:.completed),publicationFence:fence); throw Failed(message:"transaction ignored invalid lease") } catch is CancellationError {}
        let leasedStored = try await store.runtimeTurn(id:leasedID)
        try check(leasedStored?.turn.completionState == .pending,"fenced SQL rolled back")
        let cacheGeneration = try await store.cacheGeneration()
        let fencedMemory = AskAIRollingMemory.build(turns:[final],dependencyDigest:"fenced-cache")
        do { try await store.saveMemory(fencedMemory,anchorTurnID:id,expectedGeneration:cacheGeneration,publicationFence:fence); throw Failed(message:"memory cache ignored cancelled fence") } catch is CancellationError {}
        let fencedCheckpoint = AskAIRuntimeStore.Checkpoint(anchorTurnID:id,providerConfigDigest:"fixture",formatVersion:"1",toolVersion:"1",promptVersion:"1",inputDigest:"fixture",permissionDigest:"fixture",sourceDigest:"fixture",payload:Data("fixture".utf8))
        do { try await store.saveCheckpoint(fencedCheckpoint,expectedGeneration:cacheGeneration,publicationFence:fence); throw Failed(message:"checkpoint cache ignored cancelled fence") } catch is CancellationError {}
        for outcome in ["unchanged","changed","superseded"] {
            let once = ScriptDriver([reply("queued evidence [1]")]); let (publicationEngine,publicationID) = try runtime(once)
            _ = try await publicationEngine.prepare(); let publicationAnswer = try await publicationEngine.generate(apiKey:nil,fallback:NoFallback())
            let publication = DaybookConversationTurn(id:publicationID,question:original.question,text:publicationAnswer.text,generated:true,provider:"fixture",evidence:publicationAnswer.prepared.evidence,sources:publicationAnswer.sources,scopeDescription:"",state:.completed)
            let gate = PublicationGate(); publicationEngine.beforePublicationLease = { gate.pauseOnce() }
            let pendingPublication = Task { try await publicationEngine.publish(publication) }
            while !gate.didEnter { await Task.yield() }
            let oldValidation = UUID(); let latestValidation = UUID()
            publicationEngine.suspendPublication(validation:oldValidation)
            if outcome == "superseded" { publicationEngine.suspendPublication(validation:latestValidation); publicationEngine.resumePublication(validation:oldValidation) }
            gate.release()
            let stillPending = try await store.runtimeTurn(id:publicationID)
            try check(stillPending?.turn.completionState == .pending,"queued transaction must not publish while scope validation is pending")
            let runState = try fixtureDB.query("SELECT state FROM ask_ai_runs WHERE turn_id=?",[.text(publicationID.uuidString)]).first?["state"]?.string
            try check(runState != "completed","pending validation keeps run incomplete")
            if outcome == "changed" {
                publicationEngine.cancel()
                do { try await pendingPublication.value; throw Failed(message:"changed validation published old answer") } catch is CancellationError {}
                let changed = try await store.runtimeTurn(id:publicationID)
                try check(changed?.turn.completionState != .completed,"relevant edit prevents stale success")
            } else {
                publicationEngine.resumePublication(validation:outcome == "superseded" ? latestValidation : oldValidation)
                try await pendingPublication.value
                let published = try await store.runtimeTurn(id:publicationID)
                let completedRuns = try fixtureDB.query("SELECT COUNT(*) AS n FROM ask_ai_runs WHERE turn_id=? AND state='completed'",[.text(publicationID.uuidString)]).first?["n"]?.double
                try check(published?.turn.text == publicationAnswer.text && completedRuns == 1 && once.replies.isEmpty && once.starts == 1,"unchanged latest validation publishes exactly once without inference")
            }
        }
        try await unsupportedFallback(original,records:records,day:day,store:store,conversations:conversations)
        try await protocols()
        print("Ask AI drivers: bounded actual runtime, exact consent, call pairing, repair, overflow, limits, deadline, cancellation, atomic publication and synthetic protocol fixtures passed")
    }
    @MainActor static func unsupportedFallback(_ original:DaybookRetrieval.Prepared,records:[DayRecord],day:Date,store:AskAIRuntimeStore,conversations:DaybookConversationStore) async throws {
        let settings = URLSessionConfiguration.ephemeral; settings.protocolClasses = [FixtureProtocol.self]
        let session = URLSession(configuration:settings); defer { session.invalidateAndCancel() }
        for apiProtocol in AIConfiguration.APIProtocol.allCases {
            let configuration: AIConfiguration = { var value = AIConfiguration(); value.mode = .custom; value.model = "fixture"; value.baseURL = "https://fixture.invalid/v1"; value.apiProtocol = apiProtocol; return value }()
            let id = UUID(); try conversations.saveTurn(.init(id:id,question:original.question,text:"",generated:false,provider:"",evidence:original.evidence,sources:[],scopeDescription:"",state:.pending),day:day)
            let engine = AskAIRuntime(prepared:original,records:records,configuration:configuration,configurationRevision:1,turnID:id,store:store,isCurrent:{true},onStage:{_ in},authorizeAdditional:{_ in})
            engine.customSession = session
            var requests = 0
            FixtureProtocol.handler = { request in
                var bytes = request.httpBody
                if bytes == nil, let stream = request.httpBodyStream { stream.open(); defer { stream.close() }; var buffer = [UInt8](repeating:0,count:4096); var data = Data(); while stream.hasBytesAvailable { let count = stream.read(&buffer,maxLength:buffer.count); if count <= 0 { break }; data.append(buffer,count:count) }; bytes = data }
                let body = try JSONSerialization.jsonObject(with:bytes!) as! [String:Any]; requests += 1
                if requests == 1 { try check(body["tools"] != nil && !String(decoding:bytes!,as:UTF8.self).contains("project evidence"),"unsupported probe remains synthetic"); return (400,[:]) }
                try check(body["tools"] == nil && body["max_tokens"] as? Int == 512,"reviewed text fallback and citation repair both request512 output tokens")
                let text = requests == 2 ? "uncited fixture" : "cited fixture [1]"
                if apiProtocol == .openai { return (200,["choices":[["finish_reason":"stop","message":["content":text]]]]) }
                return (200,["type":"message","role":"assistant","content":[["type":"text","text":text]],"stop_reason":"end_turn"])
            }
            _ = try await engine.prepare()
            let answer = try await engine.generate(apiKey:"synthetic-key",fallback:DaybookAnswerService(customSummarizer:CustomAISummarizer(session:session)))
            try check(answer.text == "cited fixture [1]" && requests == 3,"actual runtime unsupported probe reaches capped initial+repair compatibility path")
            // Unrelated legacy callers preserve existing output defaults.
            FixtureProtocol.handler = { request in
                var bytes = request.httpBody
                if bytes == nil, let stream = request.httpBodyStream { stream.open(); defer { stream.close() }; var buffer = [UInt8](repeating:0,count:4096); var data = Data(); while stream.hasBytesAvailable { let count = stream.read(&buffer,maxLength:buffer.count); if count <= 0 { break }; data.append(buffer,count:count) }; bytes = data }
                let body = try JSONSerialization.jsonObject(with:bytes!) as! [String:Any]
                try check(apiProtocol == .openai ? body["max_tokens"] == nil : body["max_tokens"] as? Int == 2048,"legacy output-token defaults retained")
                if apiProtocol == .openai { return (200,["choices":[["finish_reason":"stop","message":["content":"legacy"]]]]) }
                return (200,["type":"message","role":"assistant","content":[["type":"text","text":"legacy"]],"stop_reason":"end_turn"])
            }
            _ = try await CustomAISummarizer(session:session).answer(question:"Fixture",context:"Synthetic",configuration:configuration,apiKey:"synthetic-key")
        }
    }
    @MainActor static func fallbackFreshness(_ prepared:DaybookRetrieval.Prepared) async throws {
        let suite = "ask-ai-fallback-freshness-" + UUID().uuidString
        let defaults = UserDefaults(suiteName:suite)!; defer { defaults.removePersistentDomain(forName:suite) }
        for expired in [true,false] {
            let credential = ChatGPTCredential(clientID:"fixture-client",subject:"fixture",email:nil,hostID:"urn:uuid:fixture",idToken:"fixture",accessToken:"fixture",refreshToken:"fixture",expiresAt:.now.addingTimeInterval(expired ? -60 : 3600),scopes:["chatgpt.tokens.use.direct","resource.invoke"])
            let vault = ChatGPTAccountVault(hostID:credential.hostID,registrations:[.init(clientID:credential.clientID,subject:credential.subject,email:nil,credential:credential,acknowledgedPlan:true)],selectedID:credential.clientID)
            let api = RuntimeAccountAPI()
            let account = ChatGPTAccountModel(storage:RuntimeAccountStore(vault),api:api,defaults:defaults,isEnabled:true)
            let configuration: AIConfiguration = { var value = AIConfiguration(); value.mode = .chatgpt; value.chatGPTModel = "fixture-model"; value.chatGPTAccountID = "fixture-client"; return value }()
            var sourceRevision = 1; var validations = 0
            let service = DaybookAnswerService(chatGPT:account)
            let pending = Task { try await service.answerReviewed(prepared,configuration:configuration,apiKey:nil,instruction:"Fixture",isCurrent:{true},ensureFresh:{ validations += 1; await Task.yield(); guard sourceRevision == 1 else { throw CancellationError() } }) }
            while true {
                let counts = await api.counts()
                if expired ? counts.0 > 0 : counts.1 > 0 { break }; await Task.yield()
            }
            sourceRevision = 2
            do { _ = try await pending.value; throw Failed(message:"reviewed fallback sent stale source after account await") } catch is CancellationError {}
            let counts = await api.counts()
            try check(counts.2 == 0 && validations >= 2,"reviewed fallback forwards async source check through credential/catalog suspension")
        }
        // The Mac transport already invokes authorized after discovery and model load;
        // gate the service integration so future refactors cannot silently drop that hook.
        let source = try String(contentsOfFile:"Sources/iPhone/DaybookAnswerService.swift",encoding:.utf8)
        try check(source.contains("authorized:{ try await ensureFresh(); return isCurrent() }"),"Nearby Mac reviewed-answer async authorization forwarding")
    }
    @MainActor static func protocols() async throws {
        let settings = URLSessionConfiguration.ephemeral; settings.protocolClasses = [FixtureProtocol.self]
        let session = URLSession(configuration:settings); defer { session.invalidateAndCancel() }
        for protocolKind in AIConfiguration.APIProtocol.allCases {
            var configuration = AIConfiguration(); configuration.mode = .custom; configuration.model = "synthetic"; configuration.baseURL = "https://fixture.invalid/v1"; configuration.apiProtocol = protocolKind
            let driver = try AskAICustomDriver(configuration:configuration,apiKey:"synthetic-key",session:session)
            var step = 0
            FixtureProtocol.handler = { request in
                var bytes = request.httpBody
                if bytes == nil, let stream = request.httpBodyStream { stream.open(); defer { stream.close() }; var buffer = [UInt8](repeating:0,count:4096); var data = Data(); while stream.hasBytesAvailable { let count = stream.read(&buffer,maxLength:buffer.count); if count <= 0 { break }; data.append(buffer,count:count) }; bytes = data }
                let body = try JSONSerialization.jsonObject(with:bytes!) as! [String:Any]
                let serialized = String(decoding:bytes!,as:UTF8.self)
                step += 1
                if step == 1 { try check(!serialized.contains("SECRET"),"private probe data") }
                else if step == 3 { try check(serialized.contains("call_fixture") && serialized.contains("status=ok"),"call/result pairing sent") }
                if protocolKind == .openai {
                    if step == 3 { return (200,["choices":[["finish_reason":"stop","message":["role":"assistant","content":"done [1]"]]]]) }
                    let name = step == 1 ? "capability_probe" : "searchRecords"
                    let arguments = step == 1 ? #"{"value":"ok"}"# : #"{"query":"project"}"#
                    return (200,["choices":[["finish_reason":"tool_calls","message":["role":"assistant","tool_calls":[["id":"call_fixture","type":"function","function":["name":name,"arguments":arguments]]]]]]])
                }
                _ = body
                if step == 3 { return (200,["content":[["type":"text","text":"done [1]"]],"stop_reason":"end_turn"]) }
                return (200,["content":[["type":"tool_use","id":"call_fixture","name":step == 1 ? "capability_probe" : "searchRecords","input":step == 1 ? ["value":"ok"] : ["query":"project"]]],"stop_reason":"tool_use"])
            }
            let supported = try await driver.probe(); try check(supported,"capability probe")
            try driver.start(instruction:"synthetic",content:"SECRET initial approved synthetic text")
            let first = try await driver.next(correction:nil); try check(first.calls.count == 1,"protocol call decode")
            do { _ = try await driver.next(correction:nil); throw Failed(message:"unpaired call request") } catch AIServiceError.invalidResponse {}
            try driver.receive(call:first.calls[0],result:"status=ok")
            let second = try await driver.next(correction:nil); try check(second.text == "done [1]","protocol text decode")
            FixtureProtocol.handler = { _ in (200,protocolKind == .openai ? ["choices":[["message":["content":"no tools"]]]] : ["content":[["type":"text","text":"no tools"]]]) }
            let unsupported = try await driver.probe(); try check(!unsupported,"absent capability fallback")
            FixtureProtocol.handler = { _ in (401,[:]) }
            do { _ = try await driver.probe(); throw Failed(message:"auth downgraded to unsupported") } catch AIServiceError.authentication {}
        }
    }
}
