import Foundation

private func expect(_ value: @autoclosure () -> Bool, _ message: String) {
    guard value() else { fatalError(message) }
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
        for url in ["http://example.com/v1", "https://user:password@example.com/v1", "https://example.com/v1?key=x", "https://example.com/v1#x", "https://example.com/v1/chat/completions", "file:///tmp/model", "https://"] {
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
        expect(settings.ai.mode == .local && settings.appearance == .dark, "local-first defaults")
        expect(settings.localeIdentifier == "en-US", "preserve existing locale")
        settings.appearance = .system
        try settings.saveAI(normalized, apiKey: "fake-key")
        let reloaded = AppSettings(defaults: defaults, secrets: secrets)
        expect(reloaded.appearance == .system && reloaded.ai == normalized, "preferences survive relaunch")
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
            let data: Data
            if let body = request.httpBody { data = body }
            else {
                let stream = request.httpBodyStream!
                stream.open(); defer { stream.close() }
                var body = Data(), buffer = [UInt8](repeating: 0, count: 2048)
                while stream.hasBytesAvailable {
                    let count = stream.read(&buffer, maxLength: buffer.count)
                    if count <= 0 { break }
                    body.append(contentsOf: buffer.prefix(count))
                }
                data = body
            }
            let payload = try JSONSerialization.jsonObject(with: data) as! [String: Any]
            expect(payload["model"] as? String == "demo-model", "selected model")
            let messages = payload["messages"] as! [[String: String]]
            expect(messages.first?["role"] == "system", "summary instructions separate from note")
            requests.append(messages.last!["content"]!)
            return (200, Data(#"{"choices":[{"message":{"content":"总结结果"},"finish_reason":"stop"}]}"#.utf8))
        }
        try await client.testConnection(configuration: normalized, apiKey: "fake-key")
        expect(requests == [CustomAISummarizer.testPrompt], "test sends only fixed probe text")
        requests = []
        let transcript = String(repeating: "这是一条语音笔记。", count: 850) + "最后的行动项：周五确认。"
        let summary = try await client.summarize(transcript, configuration: normalized, apiKey: "fake-key")
        expect(summary == "总结结果", "extract chat content")
        expect(requests.dropLast().joined() == transcript, "all source text reaches chunk requests without truncation")
        for (code, expected) in [(401, AIServiceError.authentication), (429, .rateLimited), (500, .http(500))] {
            StubProtocol.handler = { _ in (code, Data("secret error body".utf8)) }
            do { try await client.testConnection(configuration: normalized, apiKey: "fake-key"); fatalError("accepted failed HTTP") }
            catch let error as AIServiceError { expect(error == expected, "classify HTTP error without body") }
        }
        for body in [#"{"choices":[]}"#, #"{"choices":[{"message":{"content":" "}}]}"#, #"{"choices":[{"message":{"content":"partial"},"finish_reason":"length"}]}"#] {
            StubProtocol.handler = { _ in (200, Data(body.utf8)) }
            do { try await client.testConnection(configuration: normalized, apiKey: "fake-key"); fatalError("accepted incomplete response") }
            catch is AIServiceError {}
        }
        StubProtocol.handler = { _ in throw URLError(.notConnectedToInternet) }
        do { try await client.testConnection(configuration: normalized, apiKey: "fake-key"); fatalError("accepted offline") }
        catch let error as AIServiceError { expect(error == .network, "safe offline message") }

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
        editor.apiKey = "different-key"
        expect(!editor.canSave, "key change invalidates successful test")
        editor.configuration.mode = .local
        expect(editor.canSave, "local mode needs no remote test")
        try editor.save()
        expect(settings.ai.mode == .local && secrets.value == "fake-key", "returning local retains saved custom credentials")

        expect(PhoneWatchStatus(isSupported: false).title.contains("不可用"), "unsupported device")
        expect(!PhoneWatchStatus(isPaired: true, isInstalled: true, isActivated: true, isReachable: false).isConnected, "paired is not reachable")
        expect(PhoneWatchStatus(isPaired: true, isInstalled: true, isActivated: true, isReachable: true).isConnected, "live reachability")
        print("AI settings: validation, persistence, request/response, errors, long text, test races and Watch status passed")
    }
}
