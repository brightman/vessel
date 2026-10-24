import Foundation

private func expect(_ value: @autoclosure () -> Bool, _ message: String) {
    guard value() else { fatalError(message) }
}

private func requestPayload(_ request: URLRequest) throws -> [String: Any] {
    if let data = request.httpBody { return try JSONSerialization.jsonObject(with: data) as! [String: Any] }
    let stream = request.httpBodyStream!
    stream.open(); defer { stream.close() }
    var body = Data(), buffer = [UInt8](repeating: 0, count: 2048)
    while stream.hasBytesAvailable {
        let count = stream.read(&buffer, maxLength: buffer.count)
        if count <= 0 { break }
        body.append(contentsOf: buffer.prefix(count))
    }
    return try JSONSerialization.jsonObject(with: body) as! [String: Any]
}

private final class MemorySecrets: SecretStore {
    var value = ""
    var failWrites = false
    func read() throws -> String { value }
    func write(_ value: String) throws {
        if failWrites { throw AIServiceError.invalidConfiguration("Keychain unavailable") }
        self.value = value
    }
}

private final class StubProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (Int, Data))!
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (code, data) = try Self.handler(request)
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

@main
struct AISettingsSmoke {
    @MainActor static func main() async throws {
        let good = AIConfiguration(mode: .custom, model: " demo-model ", baseURL: "https://example.com/v1/")
        let normalized = try good.validated(apiKey: "fake-key")
        expect(normalized.model == "demo-model", "trim model")
        expect(normalized.endpoint.absoluteString == "https://example.com/v1/chat/completions", "append endpoint once")
        let legacy = try JSONDecoder().decode(AIConfiguration.self, from: Data(#"{"mode":"custom","model":"legacy-model","baseURL":"https://example.com/v1"}"#.utf8))
        expect(legacy.apiProtocol == .openai, "legacy configuration defaults to OpenAI protocol")
        expect(legacy.endpoint.absoluteString == "https://example.com/v1/chat/completions", "legacy configuration keeps OpenAI endpoint")
        let anthropic = try JSONDecoder().decode(AIConfiguration.self, from: Data(#"{"mode":"custom","model":"claude-test","baseURL":"https://example.com/v1","apiProtocol":"anthropic"}"#.utf8))
        expect(anthropic.endpoint.absoluteString == "https://example.com/v1/messages", "Anthropic configuration uses Messages endpoint")
        let restoredAnthropic = try JSONDecoder().decode(AIConfiguration.self, from: JSONEncoder().encode(anthropic))
        expect(restoredAnthropic == anthropic, "protocol survives configuration encoding")
        for url in ["http://example.com/v1", "https://user:password@example.com/v1", "https://example.com/v1?key=x", "https://example.com/v1#x", "https://example.com/v1/chat/completions", "https://example.com/v1/messages/", "file:///tmp/model", "https://"] {
            do {
                _ = try AIConfiguration(mode: .custom, model: "model", baseURL: url).validated(apiKey: "fake-key")
                fatalError("accepted invalid address")
            } catch is AIServiceError {}
        }
        do { _ = try good.validated(apiKey: ""); fatalError("accepted empty key") } catch is AIServiceError {}
        do { _ = try good.validated(apiKey: "fake\nkey"); fatalError("accepted header injection") } catch is AIServiceError {}
        _ = try AIConfiguration(mode: .custom, model: "model", baseURL: "http://localhost:9000/v1").validated(apiKey: "fake-key")

        let suite = "wristnotes-settings-test-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("en-US", forKey: "transcriptionLocale")
        let secrets = MemorySecrets()
        let settings = AppSettings(defaults: defaults, secrets: secrets)
        expect(settings.ai.mode == .local && settings.appearance == .system, "local-first defaults follow system appearance")
        expect(settings.localeIdentifier == "en-US", "preserve existing locale")
        expect(settings.interfaceLanguage == .chinese, "default interface language stays Chinese")
        settings.interfaceLanguage = .english
        expect(settings.localeIdentifier == "en-US", "interface language does not change transcription language")
        settings.appearance = .dark
        try settings.saveAI(normalized, apiKey: "fake-key")
        let reloaded = AppSettings(defaults: defaults, secrets: secrets)
        expect(reloaded.appearance == .dark && reloaded.ai == normalized, "existing appearance and AI preferences survive relaunch")
        expect(reloaded.interfaceLanguage == .english, "interface language survives relaunch")
        reloaded.interfaceLanguage = .japanese
        let japaneseReloaded = AppSettings(defaults: defaults, secrets: secrets)
        expect(japaneseReloaded.interfaceLanguage == .japanese, "Japanese interface language survives relaunch")
        expect(japaneseReloaded.localeIdentifier == "en-US", "Japanese interface leaves transcription language unchanged")
        let loadedKey = try reloaded.apiKey()
        expect(loadedKey == "fake-key", "secret is stored separately")
        let stored = String(data: defaults.data(forKey: "aiConfiguration")!, encoding: .utf8)!
        expect(!stored.contains("fake-key"), "key excluded from preferences")
        secrets.failWrites = true
        do { try settings.saveAI(good, apiKey: "replacement"); fatalError("ignored keychain failure") } catch {}
        expect(settings.ai == normalized && secrets.value == "fake-key", "failed credential save preserves config")
        secrets.failWrites = false

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProtocol.self]
        let client = CustomAISummarizer(session: URLSession(configuration: config))
        var requests: [String] = []
        StubProtocol.handler = { request in
            expect(request.httpMethod == "POST", "chat request method")
            expect(request.url?.path == "/v1/chat/completions", "chat path")
            expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer fake-key", "credential header")
            expect(request.value(forHTTPHeaderField: "x-api-key") == nil, "OpenAI uses only bearer authentication")
            let payload = try requestPayload(request)
            expect(payload["model"] as? String == "demo-model", "selected model")
            expect(payload["stream"] as? Bool == false, "OpenAI response is not streamed")
            let messages = payload["messages"] as! [[String: String]]
            expect(messages.first?["role"] == "system", "summary instructions separate from note")
            requests.append(messages.last!["content"]!)
            return (200, Data(#"{"choices":[{"message":{"content":"总结结果"},"finish_reason":"stop"}]}"#.utf8))
        }
        try await client.testConnection(configuration: normalized, apiKey: "fake-key")
        expect(requests == [CustomAISummarizer.testPrompt], "test sends only fixed probe text")
        StubProtocol.handler = { request in
            let payload = try requestPayload(request)
            let messages = payload["messages"] as! [[String: String]]
            expect(messages[0]["content"] == CustomAISummarizer.answerInstruction, "previewed instruction reaches provider verbatim")
            expect(messages[1]["content"] == "问题：那接下来呢？\n\n检索到的本地资料：\n[1] 客户需要报价\n先前对话：用户询问客户需求", "previewed question, evidence and history reach provider verbatim")
            return (200, Data(#"{"choices":[{"message":{"content":"整理报价 [1]"},"finish_reason":"stop"}]}"#.utf8))
        }
        _ = try await client.answer(question: "那接下来呢？", context: "[1] 客户需要报价\n先前对话：用户询问客户需求", configuration: normalized, apiKey: "fake-key")
        StubProtocol.handler = { request in
            let payload = try requestPayload(request)
            let messages = payload["messages"] as! [[String: String]]
            requests.append(messages.last!["content"]!)
            return (200, Data(#"{"choices":[{"message":{"content":"总结结果"},"finish_reason":"stop"}]}"#.utf8))
        }
        requests = []
        let transcript = String(repeating: "这是一条语音笔记。", count: 850) + "最后的行动项：周五确认。"
        let summary = try await client.summarize(transcript, configuration: normalized, apiKey: "fake-key")
        expect(summary == "总结结果", "extract chat content")
        expect(requests.dropLast().joined() == transcript, "all source text reaches chunk requests without truncation")
        requests = []
        StubProtocol.handler = { request in
            expect(request.httpMethod == "POST" && request.url?.path == "/v1/messages", "Anthropic Messages request")
            expect(request.value(forHTTPHeaderField: "x-api-key") == "fake-key", "Anthropic key header")
            expect(request.value(forHTTPHeaderField: "anthropic-version") == "2023-06-01", "Anthropic version header")
            expect(request.value(forHTTPHeaderField: "Authorization") == nil, "Anthropic omits bearer authentication")
            let payload = try requestPayload(request)
            expect(payload["model"] as? String == "claude-test", "Anthropic selected model")
            expect((payload["max_tokens"] as? Int ?? 0) > 0, "Anthropic bounds response tokens")
            expect(payload["stream"] as? Bool == false, "Anthropic response is not streamed")
            expect(!(payload["system"] as? String ?? "").isEmpty, "Anthropic instructions use top-level system")
            let messages = payload["messages"] as! [[String: String]]
            expect(messages.count == 1 && messages[0]["role"] == "user", "Anthropic system is not included as a message")
            requests.append(messages[0]["content"]!)
            return (200, Data(#"{"id":"msg_test","type":"message","role":"assistant","model":"claude-test","content":[{"type":"text","text":"第一段"},{"type":"text","text":"第二段"}],"stop_reason":"end_turn","stop_sequence":null,"usage":{"input_tokens":10,"output_tokens":10}}"#.utf8))
        }
        try await client.testConnection(configuration: anthropic, apiKey: " fake-key ")
        expect(requests == [CustomAISummarizer.testPrompt], "Anthropic connection test uses fixed probe")
        requests = []
        let anthropicSummary = try await client.summarize("需要总结的笔记", configuration: anthropic, apiKey: "fake-key")
        expect(anthropicSummary == "第一段\n第二段", "combine Anthropic text blocks in order")
        expect(requests == ["需要总结的笔记"], "Anthropic receives note only on summarize")
        StubProtocol.handler = { _ in (200, Data(#"{"type":"message","role":"assistant","content":[{"type":"thinking","thinking":"private reasoning"},{"type":"text","text":"总结"}],"stop_reason":"stop_sequence"}"#.utf8)) }
        let stoppedSummary = try await client.summarize("笔记", configuration: anthropic, apiKey: "fake-key")
        expect(stoppedSummary == "总结", "Anthropic extracts text without exposing thinking blocks")
        for configuration in [normalized, anthropic] {
            for (code, expected) in [(302, AIServiceError.http(302)), (401, .authentication), (403, .authentication), (429, .rateLimited), (500, .http(500))] {
                StubProtocol.handler = { _ in (code, Data("secret error body".utf8)) }
                do { try await client.testConnection(configuration: configuration, apiKey: "fake-key"); fatalError("accepted failed HTTP") }
                catch let error as AIServiceError { expect(error == expected, "classify HTTP error without body") }
            }
        }
        for body in [#"{"choices":[]}"#, #"{"choices":[{"message":{"content":" "}}]}"#, #"{"choices":[{"message":{"content":"partial"},"finish_reason":"length"}]}"#] {
            StubProtocol.handler = { _ in (200, Data(body.utf8)) }
            do { try await client.testConnection(configuration: normalized, apiKey: "fake-key"); fatalError("accepted incomplete response") }
            catch is AIServiceError {}
        }
        for (body, expected) in [
            (#"{"type":"error","error":{"type":"overloaded_error","message":"secret body"}}"#, AIServiceError.invalidResponse),
            (#"{"type":"error","role":"assistant","content":[{"type":"text","text":"not a message"}],"stop_reason":"end_turn"}"#, .invalidResponse),
            (#"{"type":"message","role":"assistant","content":[],"stop_reason":"end_turn"}"#, .invalidResponse),
            (#"{"type":"message","role":"assistant","content":[{"type":"text","text":" "}],"stop_reason":"end_turn"}"#, .invalidResponse),
            (#"{"type":"message","role":"assistant","content":[{"type":"text"}],"stop_reason":"end_turn"}"#, .invalidResponse),
            (#"{"type":"message","role":"assistant","content":[{"type":"tool_use","id":"tool_1","name":"unknown","input":{}}],"stop_reason":"tool_use"}"#, .incompleteResponse),
            (#"{"type":"message","role":"assistant","content":[{"type":"text","text":"partial"}],"stop_reason":"max_tokens"}"#, .incompleteResponse),
            (#"{"type":"message","role":"assistant","content":[{"type":"text","text":"partial"}],"stop_reason":"pause_turn"}"#, .incompleteResponse),
            (#"{"type":"message","role":"assistant","content":[{"type":"text","text":"partial"}],"stop_reason":null}"#, .invalidResponse)
        ] {
            StubProtocol.handler = { _ in (200, Data(body.utf8)) }
            do { try await client.testConnection(configuration: anthropic, apiKey: "fake-key"); fatalError("accepted invalid Anthropic response") }
            catch let error as AIServiceError { expect(error == expected, "classify Anthropic response failure without body") }
        }
        StubProtocol.handler = { _ in throw URLError(.notConnectedToInternet) }
        do { try await client.testConnection(configuration: normalized, apiKey: "fake-key"); fatalError("accepted offline") }
        catch let error as AIServiceError { expect(error == .network, "safe offline message") }

        // Title generation must send the exact bounded excerpts, to the selected protocol, only while current.
        let titleTranscript = String(repeating: "甲", count: 450) + String(repeating: "乙", count: 450)
            + String(repeating: "丙", count: 450) + String(repeating: "丁", count: 450) + String(repeating: "戊", count: 450)
        let expectedExcerpts = String(repeating: "甲", count: 450) + "\n[…]\n" + String(repeating: "丙", count: 450) + "\n[…]\n" + String(repeating: "戊", count: 450)
        expect(CustomAISummarizer.recordingTitleExcerpts(titleTranscript) == expectedExcerpts, "title input samples beginning, middle and end, with bounded size")
        for configuration in [normalized, anthropic] {
            var titleRequests = 0
            StubProtocol.handler = { request in
                titleRequests += 1
                let payload = try requestPayload(request)
                let messages = payload["messages"] as! [[String: String]]
                expect(messages.last?["content"] == expectedExcerpts, "provider receives exactly the title preview excerpts")
                if configuration.apiProtocol == .openai {
                    expect(messages.first?["role"] == "system" && request.url?.path == "/v1/chat/completions", "OpenAI title protocol")
                    return (200, Data(#"{"choices":[{"message":{"content":"首版发布计划"},"finish_reason":"stop"}]}"#.utf8))
                }
                expect(payload["system"] as? String == CustomAISummarizer.recordingTitleInstruction && request.url?.path == "/v1/messages", "Anthropic title protocol")
                return (200, Data(#"{"type":"message","role":"assistant","content":[{"type":"text","text":"首版发布计划"}],"stop_reason":"end_turn"}"#.utf8))
            }
            let title = try await client.recordingTitle(titleTranscript, configuration: configuration, apiKey: "fake-key", isCurrent: { true })
            expect(title == "首版发布计划" && titleRequests == 1, "one request generates a title")
            do { _ = try await client.recordingTitle(titleTranscript, configuration: configuration, apiKey: "fake-key", isCurrent: { false }); fatalError("sent stale title content") }
            catch is CancellationError {}
            expect(titleRequests == 1, "stale title content must never reach the provider")
        }

        var finish: CheckedContinuation<Void, Error>?
        let editor = AISettingsModel(settings: settings, test: { _, _ in
            try await withCheckedThrowingContinuation { finish = $0 }
        })
        editor.configuration.model = "edited"
        expect(!editor.canSave, "changed custom settings require test")
        editor.startTest()
        while finish == nil { await Task.yield() }
        expect(editor.state == .testing, "show running test")
        editor.configuration.model = "newer"
        finish?.resume(); finish = nil
        await Task.yield()
        expect(editor.state == .idle && !editor.canSave, "stale response must not validate edited config")
        editor.startTest()
        while finish == nil { await Task.yield() }
        finish?.resume(); finish = nil
        while editor.state == .testing { await Task.yield() }
        expect(editor.canSave, "successful matching test permits save")
        try editor.save()
        expect(settings.ai.model == "newer", "saved configuration is used by settings")
        editor.configuration.apiProtocol = .anthropic
        expect(editor.state == .idle && !editor.canSave, "protocol change invalidates successful test")
        editor.startTest()
        while finish == nil { await Task.yield() }
        editor.configuration.apiProtocol = .openai
        finish?.resume(); finish = nil
        await Task.yield()
        expect(editor.state == .idle && !editor.canSave, "stale protocol test cannot validate another protocol")
        editor.startTest()
        while finish == nil { await Task.yield() }
        finish?.resume(); finish = nil
        while editor.state == .testing { await Task.yield() }
        expect(editor.canSave, "test matching selected protocol permits save")
        editor.apiKey = "different-key"
        expect(!editor.canSave, "key change invalidates successful test")
        editor.configuration.mode = .local
        expect(editor.canSave, "local mode needs no remote test")
        try editor.save()
        expect(settings.ai.mode == .local && secrets.value == "fake-key", "returning local retains saved custom credentials")

        var mac = AIConfiguration(); mac.mode = .nearbyMac
        mac.nearbyMacServiceID = UUID().uuidString; mac.nearbyMacName = "合成测试 Mac"
        settings.requiresRemoteAIConfirmation = true
        try settings.saveAI(mac, apiKey: "must-not-store-this")
        let macReloaded = AppSettings(defaults: defaults, secrets: secrets)
        let unusedKey = try macReloaded.apiKey()
        expect(macReloaded.ai == mac && unusedKey.isEmpty, "Mac selection survives relaunch without using a custom API key")
        expect(secrets.value == "fake-key", "Mac pairing does not replace unrelated custom credentials")
        expect(settings.requiresRemoteAIConfirmation, "Mac selection retains send confirmation")
        let beforeMac = requests.count
        do { _ = try await client.summarize("synthetic", configuration: mac, apiKey: "", isCurrent: { false }); fatalError("stale Mac request sent") }
        catch is CancellationError { }
        expect(requests.count == beforeMac, "stale Mac request never falls through to custom cloud transport")
        var invalidMac = mac; invalidMac.nearbyMacServiceID = "not-a-service-id"
        do { _ = try await client.summarize("synthetic", configuration: invalidMac, apiKey: ""); fatalError("invalid Mac routed elsewhere") }
        catch NearbyMacFailure.pairing { }
        expect(requests.count == beforeMac, "unavailable/invalid Mac is an explicit failure, never a cloud fallback")

        expect(PhoneWatchStatus(isSupported: false).title.contains("不可用"), "unsupported device")
        let asleep = PhoneWatchStatus(isPaired: true, isInstalled: true, isActivated: true, isReachable: false)
        let awake = PhoneWatchStatus(isPaired: true, isInstalled: true, isActivated: true, isReachable: true)
        expect(asleep.title == awake.title && asleep.title.contains("已配对"), "wrist wake must not change pairing/sync label")
        expect(!PhoneWatchStatus(isPaired: true, isInstalled: true, isActivated: true, isReachable: false).isConnected, "paired is not reachable")
        expect(PhoneWatchStatus(isPaired: true, isInstalled: true, isActivated: true, isReachable: true).isConnected, "live reachability")
        print("AI settings: validation, persistence, request/response, errors, long text, test races and Watch status passed")
    }
}
