import Foundation

private final class InsightTransport: URLProtocol {
    static var content: [String] = []
    static var paths: [String] = []
    static var output = #"{"observation":"园艺想法 [1] 与种子记录 [2] 相呼应。","nextAction":"看看包装 [2]"}"#
    static var status = 200
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            var bytes = request.httpBody ?? Data()
            if bytes.isEmpty, let stream = request.httpBodyStream {
                stream.open(); defer { stream.close() }
                var buffer = [UInt8](repeating: 0, count: 4096)
                while stream.hasBytesAvailable {
                    let count = stream.read(&buffer, maxLength: buffer.count)
                    if count <= 0 { break }; bytes.append(contentsOf: buffer.prefix(count))
                }
            }
            let body = try JSONSerialization.jsonObject(with: bytes) as! [String: Any]
            precondition(body["model"] as? String == "insight-fixture")
            let messages = body["messages"] as! [[String: String]]
            Self.content.append(messages.last!["content"]!)
            Self.paths.append(request.url!.path)
            let anthropic = request.url!.path.hasSuffix("/messages")
            let instruction = anthropic ? body["system"] as? String : messages.first?["content"]
            precondition(instruction?.contains("untrusted data") == true && instruction?.contains("zh-Hans") == true)
            precondition(request.value(forHTTPHeaderField: anthropic ? "x-api-key" : "Authorization") == (anthropic ? "fixture-only" : "Bearer fixture-only"))
            let response: [String: Any] = anthropic
                ? ["type": "message", "role": "assistant", "stop_reason": "end_turn", "content": [["type": "text", "text": Self.output]]]
                : ["choices": [["message": ["content": Self.output], "finish_reason": "stop"]]]
            let data = try JSONSerialization.data(withJSONObject: response)
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: Self.status, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

@main struct DaybookInsightServiceSmoke {
    @MainActor static func main() async throws {
        let session = URLSessionConfiguration.ephemeral; session.protocolClasses = [InsightTransport.self]
        let service = DaybookInsightService(custom: CustomAISummarizer(session: URLSession(configuration: session)))
        let now = Date.now
        let records = [DayRecord(id: UUID(), capturedAt: now, kind: .thought, title: "园艺", text: "想种罗勒。"),
                       DayRecord(id: UUID(), capturedAt: now, kind: .image, title: "种子", text: "买了一包种子。")]
        let input = try DaybookInsightModel.prepare(records: records, selectedDate: now, allowedKinds: [.thought, .image], now: now)
        var provider = AIConfiguration(mode: .custom, model: "insight-fixture", baseURL: "https://example.invalid/v1")
        for api in AIConfiguration.APIProtocol.allCases {
            provider.apiProtocol = api
            let result = try await service.generate(input, configuration: provider, apiKey: "fixture-only", language: "zh-Hans", now: now, isCurrent: { true })
            precondition(result.observation.contains("[1]") && result.nextAction.contains("[2]"))
            precondition(InsightTransport.content.last == DaybookInsightService.content(input, now: now), "preview must match actual source payload including captured clock")
            precondition(InsightTransport.paths.last == "/v1/" + api.endpointPath)
        }
        for invalid in ["not JSON", #"{"observation":"只有一条 [1]","nextAction":"看看 [1]"}"#,
                        #"{"observation":"虚构引用 [1] [99]","nextAction":"看看 [2]"}"#] {
            InsightTransport.output = invalid
            do { _ = try await service.generate(input, configuration: provider, apiKey: "fixture-only", language: "zh-Hans", now: now, isCurrent: { true }); fatalError("invalid insight accepted") }
            catch DaybookInsightFailure.invalid {}
        }
        InsightTransport.status = 401
        do { _ = try await service.generate(input, configuration: provider, apiKey: "fixture-only", language: "zh-Hans", now: now, isCurrent: { true }); fatalError("authentication failure accepted") }
        catch AIServiceError.authentication {}
        let calls = InsightTransport.content.count
        do { _ = try await service.generate(input, configuration: provider, apiKey: "fixture-only", language: "zh-Hans", now: now, isCurrent: { false }); fatalError("stale send accepted") }
        catch is CancellationError {}
        precondition(InsightTransport.content.count == calls)
        print("Daily insight service OpenAI/Anthropic routing, exact preview and validation passed (stub transport, no network)")
    }
}
