import Foundation

private func expect(_ value: Bool, _ message: String) { if !value { fatalError(message) } }
private final class ContentProtocol: URLProtocol {
    static var requests: [URLRequest] = []
    static var bodies: [Data] = []
    static var response = ""
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.requests.append(request)
        var body=request.httpBody ?? Data()
        if let stream=request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var bytes=[UInt8](repeating:0,count:4096)
            while stream.hasBytesAvailable { let count=stream.read(&bytes,maxLength:bytes.count); if count <= 0 { break }; body.append(bytes,count:count) }
        }
        Self.bodies.append(body)
        let reply = HTTPURLResponse(url:request.url!,statusCode:200,httpVersion:nil,headerFields:["Content-Type":"application/json"])!
        client?.urlProtocol(self,didReceive:reply,cacheStoragePolicy:.notAllowed)
        client?.urlProtocol(self,didLoad:Data(Self.response.utf8)); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@main struct ConfiguredContentModelSmoke {
    @MainActor static func main() async throws {
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [ContentProtocol.self]
        let transport = CustomAISummarizer(session:URLSession(configuration:sessionConfiguration))
        var config = AIConfiguration(); config.mode = .custom; config.model = "test-model"; config.baseURL = "https://model.example/v1"
        var authorized = false, keyReads = 0, localCalls = 0, chatCalls = 0
        let router = ConfiguredContentTextModel(configuration:config, transport:transport,
            authorized:{ authorized }, apiKey:{ keyReads += 1; return "test-key" },
            local:{ _ in localCalls += 1; return .init(text:"本机摘要") },
            chat:{ _,_,_ in chatCalls += 1; return "套餐摘要" })
        do { _ = try await router.respond(.init(kind:.summary,text:"讨论需求")); fatalError("unapproved remote request must stop") }
        catch is CancellationError {}
        expect(keyReads == 0 && ContentProtocol.requests.isEmpty,"consent checked before key access or send")
        authorized = true
        ContentProtocol.response = #"{"choices":[{"message":{"content":"讨论产品需求"},"finish_reason":"stop"}]}"#
        let reply = try await router.respond(.init(kind:.summary,text:"讨论需求",context:"13:00；位置精度约100米"))
        expect(reply.text == "讨论产品需求" && keyReads == 1,"custom provider result reaches enrichment")
        let request = ContentProtocol.requests.last!
        expect(request.url?.absoluteString == "https://model.example/v1/chat/completions","OpenAI endpoint selected")
        let body = try JSONSerialization.jsonObject(with:ContentProtocol.bodies.last!) as! [String:Any]
        let messages = body["messages"] as! [[String:String]]
        expect(messages[1]["content"]!.contains("13:00；位置精度约100米"),"actual sampled context sent with excerpt")
        expect(messages[0]["content"]!.contains("untrusted"),"source text remains data, not instructions")

        config.apiProtocol = .anthropic
        ContentProtocol.response = #"{"type":"message","role":"assistant","content":[{"type":"text","text":"{\"decision\":\"sameTopic\",\"timestamp\":1800}"}],"stop_reason":"end_turn"}"#
        let anthropic = ConfiguredContentTextModel(configuration:config,transport:transport,authorized:{ authorized },apiKey:{ "test-key" },local:{ _ in fatalError("wrong route") },chat:{ _,_,_ in fatalError("wrong route") })
        let decision = try await anthropic.respond(.init(kind:.topic,text:"方案讨论",otherText:"继续方案",timestamp:1800))
        expect(decision.decision == .sameTopic && decision.timestamp == 1800,"structured topic reply is parsed")
        expect(ContentProtocol.requests.last!.url?.path == "/v1/messages" && ContentProtocol.requests.last!.value(forHTTPHeaderField:"Authorization") == nil,"Anthropic protocol and credential header selected")
        ContentProtocol.response = #"{"type":"message","role":"assistant","content":[{"type":"text","text":"{\"decision\":\"sameTopic\",\"timestamp\":1700}"}],"stop_reason":"end_turn"}"#
        let invented = try await anthropic.respond(.init(kind:.topic,text:"左",otherText:"右",timestamp:1800))
        expect(invented.decision == .uncertain && invented.timestamp == 1800,"model cannot invent a boundary")

        var localConfig = config; localConfig.mode = .local
        let local = ConfiguredContentTextModel(configuration:localConfig,transport:transport,authorized:{ true },apiKey:{ fatalError("local must not read key") },local:{ _ in localCalls += 1; return .init(text:"本机摘要") },chat:{ _,_,_ in fatalError("wrong route") })
        let localReply = try await local.respond(.init(kind:.summary,text:"本机输入"))
        expect(localReply.text == "本机摘要" && localCalls == 1,"selected local model used without cloud fallback")
        config.mode = .chatgpt
        let chat = ConfiguredContentTextModel(configuration:config,transport:transport,authorized:{ true },apiKey:{ fatalError("chat must not read custom key") },local:{ _ in fatalError("wrong route") },chat:{ _,_,_ in chatCalls += 1; return "套餐摘要" })
        expect(try await chat.respond(.init(kind:.summary,text:"套餐输入")).text == "套餐摘要" && chatCalls == 1,"selected ChatGPT route used")
        let revoked = ConfiguredContentTextModel(configuration:config,transport:transport,authorized:{ authorized },apiKey:{ fatalError("wrong route") },local:{ _ in fatalError("wrong route") },chat:{ _,_,_ in authorized = false; return "过时结果" })
        do { _ = try await revoked.respond(.init(kind:.summary,text:"输入")); fatalError("revoked result must be discarded") }
        catch is CancellationError {}
        print("Configured content model: consent, local/OpenAI/Anthropic/ChatGPT routing, context, topic validation and stale result passed")
    }
}
