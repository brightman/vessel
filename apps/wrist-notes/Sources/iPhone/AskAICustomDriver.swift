import Foundation

struct AskAIToolCall: Sendable {
    let id: String
    let name: String
    let arguments: Data
}
struct AskAIDriverReply: Sendable {
    let text: String
    let calls: [AskAIToolCall]
}
@MainActor protocol AskAIDriving: AnyObject {
    func start(instruction: String, content: String) throws
    func next(correction: String?) async throws -> AskAIDriverReply
    func receive(call: AskAIToolCall, result: String) throws
    func rebuild() throws
}

private final class AskAINoRedirect: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}

/// Per-attempt conversation, never shared cookies, credentials or transcripts across endpoints.
@MainActor final class AskAICustomDriver: AskAIDriving {
    private let configuration: AIConfiguration
    private let key: String
    private let session: URLSession
    private var messages: [[String: Any]] = []
    private var initial: [[String: Any]] = []
    private var instruction = ""
    private var pending = Set<String>()
    private let check: @MainActor () async throws -> Void
    init(configuration: AIConfiguration, apiKey: String, session: URLSession? = nil,
         check: @escaping @MainActor () async throws -> Void = {}) throws {
        self.configuration = try configuration.validated(apiKey: apiKey)
        key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines); self.check = check
        if let session { self.session = session }
        else {
            let settings = URLSessionConfiguration.ephemeral
            settings.httpCookieStorage = nil; settings.urlCredentialStorage = nil; settings.urlCache = nil
            settings.timeoutIntervalForRequest = 30; settings.timeoutIntervalForResource = 90
            self.session = URLSession(configuration: settings, delegate: AskAINoRedirect(), delegateQueue: nil)
        }
    }
    func start(instruction: String, content: String) throws {
        self.instruction = instruction
        initial = [["role":"user", "content":content]]; messages = initial; pending = []
    }
    func rebuild() throws { messages = initial; pending = [] }
    private var toolSchemas: [[String: Any]] {
        AskAIReadTools.toolDefinitions.map { definition in
            if configuration.apiProtocol == .openai { return ["type":"function", "function":definition] }
            return ["name":definition["name"]!,"description":definition["description"]!,"input_schema":definition["parameters"]!]
        }
    }
    /// No user question, record, prior message, contact or system instruction enters this request.
    func probe() async throws -> Bool {
        let schema: [String:Any] = ["type":"object","properties":["value":["type":"string","enum":["ok"]]],"required":["value"],"additionalProperties":false]
        var body: [String:Any] = ["model":configuration.model,"max_tokens":64,"messages":[["role":"user","content":"Call capability_probe with value ok."]]]
        if configuration.apiProtocol == .openai {
            body["tools"] = [["type":"function","function":["name":"capability_probe","description":"Synthetic tool support test", "parameters":schema]]]
            body["tool_choice"] = ["type":"function","function":["name":"capability_probe"]]
        } else {
            body["tools"] = [["name":"capability_probe","description":"Synthetic tool support test","input_schema":schema]]
            body["tool_choice"] = ["type":"tool","name":"capability_probe"]
        }
        let json: [String:Any]
        do { json = try await request(body) }
        catch AIServiceError.http(let code) where [400,404,422,501].contains(code) { return false }
        let reply: AskAIDriverReply
        do { reply = try parse(json) } catch AIServiceError.invalidResponse { return false }
        guard reply.calls.count == 1, let call = reply.calls.first, call.name == "capability_probe",
              let args = try? JSONSerialization.jsonObject(with:call.arguments) as? [String:String], args == ["value":"ok"] else { return false }
        return true
    }
    func next(correction: String?) async throws -> AskAIDriverReply {
        guard pending.isEmpty else { throw AIServiceError.invalidResponse }
        if let correction { messages.append(["role":"user","content":correction]) }
        var body: [String:Any] = ["model":configuration.model,"max_tokens":512,"tools":toolSchemas]
        if configuration.apiProtocol == .openai { body["messages"] = [["role":"system","content":instruction]] + messages }
        else { body["system"] = instruction; body["messages"] = messages }
        let json = try await request(body)
        let reply = try parse(json)
        if configuration.apiProtocol == .openai {
            guard let choices = json["choices"] as? [[String:Any]], let message = choices.first?["message"] as? [String:Any] else { throw AIServiceError.invalidResponse }
            messages.append(message)
        } else {
            messages.append(["role":"assistant","content":json["content"] ?? []])
        }
        pending = Set(reply.calls.map(\.id)); return reply
    }
    func receive(call: AskAIToolCall, result: String) throws {
        guard pending.remove(call.id) != nil else { throw AIServiceError.invalidResponse }
        if configuration.apiProtocol == .openai { messages.append(["role":"tool","tool_call_id":call.id,"content":result]) }
        else {
            let block: [String:Any] = ["type":"tool_result","tool_use_id":call.id,"content":result]
            if messages.last?["role"] as? String == "user", var blocks = messages.last?["content"] as? [[String:Any]] {
                blocks.append(block); messages[messages.count - 1]["content"] = blocks
            } else { messages.append(["role":"user","content":[block]]) }
        }
    }
    private func parse(_ json: [String:Any]) throws -> AskAIDriverReply {
        var calls: [AskAIToolCall] = []; var text = ""
        func add(_ id:String?,_ name:String?,_ arguments:Data?) throws {
            guard let id, !id.isEmpty, id.utf8.count <= 128, let name, !name.isEmpty, name.utf8.count <= 80,
                  let arguments, arguments.count <= 2048, !calls.contains(where: { $0.id == id }), calls.count < 6 else { throw AIServiceError.invalidResponse }
            calls.append(.init(id:id,name:name,arguments:arguments))
        }
        if configuration.apiProtocol == .openai {
            guard let choices = json["choices"] as? [[String:Any]], choices.count == 1,
                  let choice = choices.first, let message = choice["message"] as? [String:Any] else { throw AIServiceError.invalidResponse }
            guard choice["finish_reason"] as? String != "length" else { throw AIServiceError.incompleteResponse }
            text = message["content"] as? String ?? ""
            if let raw = message["tool_calls"] {
                guard let entries = raw as? [[String:Any]] else { throw AIServiceError.invalidResponse }
                for entry in entries {
                    guard entry["type"] as? String == "function", let function = entry["function"] as? [String:Any] else { throw AIServiceError.invalidResponse }
                    try add(entry["id"] as? String,function["name"] as? String,(function["arguments"] as? String).map { Data($0.utf8) })
                }
            }
        } else {
            guard let blocks = json["content"] as? [[String:Any]] else { throw AIServiceError.invalidResponse }
            guard json["stop_reason"] as? String != "max_tokens" else { throw AIServiceError.incompleteResponse }
            for block in blocks {
                switch block["type"] as? String {
                case "text": text += block["text"] as? String ?? ""
                case "tool_use":
                    let args = (block["input"] as? [String:Any]).flatMap { try? JSONSerialization.data(withJSONObject:$0,options:.sortedKeys) }
                    try add(block["id"] as? String,block["name"] as? String,args)
                default: throw AIServiceError.invalidResponse
                }
            }
        }
        guard text.count <= 8000, !text.isEmpty || !calls.isEmpty else { throw AIServiceError.invalidResponse }
        return .init(text:text,calls:calls)
    }
    private func request(_ body:[String:Any]) async throws -> [String:Any] {
        try await check(); try Task.checkCancellation()
        var request = URLRequest(url:configuration.endpoint); request.httpMethod = "POST"
        request.setValue("application/json",forHTTPHeaderField:"Content-Type")
        if configuration.apiProtocol == .openai { request.setValue("Bearer " + key,forHTTPHeaderField:"Authorization") }
        else { request.setValue(key,forHTTPHeaderField:"x-api-key"); request.setValue("2023-06-01",forHTTPHeaderField:"anthropic-version") }
        request.httpBody = try JSONSerialization.data(withJSONObject:body,options:.sortedKeys)
        guard request.httpBody!.count <= 96 * 1024 else { throw AskAIRuntime.Failure.contextOverflow }
        do {
            let (bytes,response) = try await session.bytes(for:request)
            guard let http = response as? HTTPURLResponse else { throw AIServiceError.invalidResponse }
            switch http.statusCode {
            case 200...299: break
            case 401,403: throw AIServiceError.authentication
            case 429: throw AIServiceError.rateLimited
            case 413: throw AskAIRuntime.Failure.contextOverflow
            default: throw AIServiceError.http(http.statusCode)
            }
            if response.expectedContentLength > 256 * 1024 { throw AIServiceError.invalidResponse }
            var data = Data()
            for try await byte in bytes {
                guard data.count < 256 * 1024 else { throw AIServiceError.invalidResponse }; data.append(byte)
            }
            try await check(); try Task.checkCancellation()
            guard let json = try? JSONSerialization.jsonObject(with:data) as? [String:Any] else { throw AIServiceError.invalidResponse }
            return json
        } catch is CancellationError { throw CancellationError() }
        catch let error as AIServiceError { throw error }
        catch let error as AskAIRuntime.Failure { throw error }
        catch let error as URLError {
            if error.code == .cancelled { throw CancellationError() }
            throw error.code == .timedOut ? AIServiceError.timedOut : AIServiceError.network
        } catch { throw AIServiceError.invalidResponse }
    }
}
