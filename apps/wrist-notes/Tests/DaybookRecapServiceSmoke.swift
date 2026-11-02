import Foundation

private final class RecapTransport: URLProtocol {
    static var content: [String] = []
    static var invalid = false
    static var queuedResponses: [String] = []
    static var instructions: [String] = []
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
            precondition(body["model"] as? String == "recap-fixture")
            precondition(body["max_tokens"] as? Int == 750, "provider output limit must match reserved context")
            let messages = body["messages"] as! [[String: String]]
            let text = messages.last!["content"]!
            Self.instructions.append(messages.first!["content"]!)
            Self.content.append(text)
            let regex = try NSRegularExpression(pattern: #"\[(\d+)\]"#)
            let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text))!
            let number = text[Range(match.range(at: 1), in: text)!]
            let result = Self.invalid ? "无效引用 [99999]" : (Self.queuedResponses.isEmpty ? "记录了园艺的想法。[\(number)]" : Self.queuedResponses.removeFirst())
            let data = try JSONSerialization.data(withJSONObject: ["choices": [["message": ["content": result], "finish_reason": "stop"]]])
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

@main struct DaybookRecapServiceSmoke {
    @MainActor static func main() async throws {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [RecapTransport.self]
        let service = DaybookRecapService(custom: CustomAISummarizer(session: URLSession(configuration: config)))
        let day = Calendar.current.startOfDay(for: .now)
        let records = (0..<14).map { index in
            DayRecord(id: UUID(), capturedAt: day.addingTimeInterval(Double(index * 60)), kind: .thought, title: "园艺",
                text: "开头\(index)" + String(repeating: "罗勒", count: 800) + "结尾\(index)")
        }
        let input = DaybookRecapInput.prepare(records: records, day: day, allowedKinds: [.thought])
        precondition(input.sources.count == 14 && input.excerptedCount == 14)
        // A full day on a configured large-context model must not inherit Apple's
        // small, character-based chunks. All sources still reach the actual request.
        let fullDayRecords = (0..<90).map { index in
            DayRecord(id: UUID(), capturedAt: day.addingTimeInterval(Double(index * 60)), kind: .voice,
                title: "测试片段", text: "BEGIN\(index) " + String(repeating: "测试证据 abc ", count: 90) + " END\(index)")
        }
        let fullDay = DaybookRecapInput.prepare(records: fullDayRecords, day: day, allowedKinds: [.voice])
        let large = AIConfiguration(mode: .custom, model: "recap-fixture", baseURL: "https://example.invalid/v1", contextWindowTokens: 262_000)
        _ = try await service.generate(fullDay, configuration: large, apiKey: "fixture-only", language: "zh-Hans", isCurrent: { true })
        precondition(RecapTransport.content.count == 1, "configured large window must process this 90-source day in one request")
        for index in 0..<90 {
            precondition(RecapTransport.content[0].contains("BEGIN\(index) ") && RecapTransport.content[0].contains(" END\(index)"), "large-window generation must retain every source excerpt")
        }
        precondition(!RecapTransport.instructions[0].contains("Produce compact evidence notes"), "one request must produce the final recap")
        RecapTransport.content = []; RecapTransport.instructions = []
        let provider = AIConfiguration(mode: .custom, model: "recap-fixture", baseURL: "https://example.invalid/v1")
        let result = try await service.generate(input, configuration: provider, apiKey: "fixture-only", language: "zh-Hans", isCurrent: { true })
        precondition(result.contains("[1]"))
        precondition(RecapTransport.content.count > 1, "multiple bounded chunks must be merged")
        precondition(RecapTransport.instructions.allSatisfy { $0.contains("life, work and learning") && $0.contains("background audio") && $0.contains("intent") }, "authority rules must reach every provider call")
        precondition(RecapTransport.instructions.first!.contains("evidence notes") && RecapTransport.instructions.last!.contains("next steps"), "intermediate evidence extraction must be distinct from final synthesis")
        precondition(RecapTransport.content.contains { $0.contains("主动闪念") && $0.contains("同源组") }, "actual source payload carries provenance")
        precondition(RecapTransport.content.allSatisfy { $0.count < 2700 }, "every actual outgoing request must be bounded")
        for index in 0..<14 {
            precondition(RecapTransport.content.contains { $0.contains("开头\(index)") && $0.contains("结尾\(index)") }, "every record's excerpts must reach the provider")
        }
        let single = DaybookRecapInput.prepare(records: [records[0]], day: day, allowedKinds: [.thought])
        let beforeSingle = RecapTransport.content.count
        _ = try await service.generate(single, configuration: provider, apiKey: "fixture-only", language: "zh-Hans", isCurrent: { true })
        precondition(RecapTransport.content.count == beforeSingle + 1 && RecapTransport.instructions.last!.contains("next steps") && !RecapTransport.instructions.last!.contains("Produce compact evidence notes"),
                     "a single source batch must directly produce a user-facing recap, not intermediate notes")
        RecapTransport.queuedResponses = ["今天整理了花园，并想种罗勒。", "今天整理了花园，并想种罗勒。[1]"]
        let beforeCitationRepair = RecapTransport.content.count
        let repaired = try await service.generate(single, configuration: provider, apiKey: "fixture-only", language: "zh-Hans", isCurrent: { true })
        precondition(repaired == "今天整理了花园，并想种罗勒。[1]", "a recap draft missing citations is repaired from the same source before being rejected")
        precondition(RecapTransport.content.count == beforeCitationRepair + 2, "citation repair makes exactly one bounded correction request")
        precondition(RecapTransport.instructions.last!.contains("source markers") || RecapTransport.instructions.last!.contains("来源编号"),
                     "the correction request explicitly constrains citations to source markers")
        RecapTransport.queuedResponses = ["You spent the morning working in the garden and discussed a plan for planting herbs tomorrow.[1]", "昨天你整理了花园，也聊到了接下来种罗勒的想法。[1]"]
        let languageCalls = RecapTransport.content.count
        let localized = try await service.generate(single,configuration:provider,apiKey:"fixture-only",language:"zh-Hans",isCurrent:{true})
        precondition(localized.hasPrefix("昨天") && RecapTransport.content.count == languageCalls+2,
                     "an English response to the Chinese UI must be repaired before saving")
        RecapTransport.queuedResponses = ["Yesterday you worked in the garden and discussed planting herbs.[1]"]
        let english = try await service.generate(single,configuration:provider,apiKey:"fixture-only",language:"en",isCurrent:{true})
        precondition(english.hasPrefix("Yesterday"), "English interface must accept an English recap")
        RecapTransport.queuedResponses = ["昨日は庭の手入れをして、これからバジルを育てることについて話しました。[1]"]
        let japanese = try await service.generate(single,configuration:provider,apiKey:"fixture-only",language:"ja",isCurrent:{true})
        precondition(japanese.hasPrefix("昨日"), "Japanese interface must accept a Japanese recap")
        RecapTransport.queuedResponses = Array(repeating:"Yesterday you worked in the garden and discussed planting herbs.[1]",count:2)
        do { _ = try await service.generate(single,configuration:provider,apiKey:"fixture-only",language:"zh-Hans",isCurrent:{true}); fatalError("wrong-language repair accepted") }
        catch DaybookRecapFailure.languageMismatch {}
        RecapTransport.invalid = true
        do { _ = try await service.generate(input, configuration: provider, apiKey: "fixture-only", language: "zh-Hans", isCurrent: { true }); fatalError("invalid provider citation accepted") }
        catch DaybookRecapFailure.invalid {}
        let calls = RecapTransport.content.count
        let tooSmall = AIConfiguration(mode: .custom, model: "recap-fixture", baseURL: "https://example.invalid/v1", contextWindowTokens: 1024)
        do { _ = try await service.generate(single, configuration: tooSmall, apiKey: "fixture-only", language: "zh-Hans", isCurrent: { true }); fatalError("impossible context accepted") }
        catch DaybookRecapFailure.contextBudget {}
        precondition(RecapTransport.content.count == calls, "insufficient configured context must fail before sending or dropping sources")
        do { _ = try await service.generate(input, configuration: provider, apiKey: "fixture-only", language: "zh-Hans", isCurrent: { false }); fatalError("stale send accepted") }
        catch is CancellationError {}
        precondition(RecapTransport.content.count == calls, "stale request must stop before network transport")
        print("Daily recap service bounded batching and citation checks passed (stub transport, no network)")
    }
}
