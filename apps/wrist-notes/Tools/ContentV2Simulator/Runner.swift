import Foundation
import Security
import CryptoKit
import SQLite3

/// Explicit development runner. It never runs on application launch. Credentials
/// are read inside the cloned simulator and never leave the authorization header.
private final class NoRedirect: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}
private enum LabError: Error { case arguments, configurationMismatch, keychainUnavailable, incompleteResponse, http(Int), checkpoint }

private actor LabTransport {
    let configuration: [String:Any]
    let directory: URL
    private var count = 0
    init(configuration: [String:Any], directory: URL) { self.configuration=configuration; self.directory=directory }
    func respond(instruction: String, content: String) async throws -> String {
        guard let model=configuration["model"] as? String, let base=configuration["baseURL"] as? String,
              let components=URLComponents(string:base), components.scheme == "https",
              components.host == "ark.cn-beijing.volces.com", components.user == nil,
              components.password == nil, components.query == nil, components.fragment == nil,
              model.lowercased() == "doubao-seed-2.0-mini",
              (configuration["apiProtocol"] as? String ?? "openai") == "openai" else { throw LabError.configurationMismatch }
        let query: [String:Any] = [kSecClass as String:kSecClassGenericPassword,
            kSecAttrService as String:"com.vessel.wristnotes.ai", kSecAttrAccount as String:"custom-model-api-key",
            kSecReturnData as String:true, kSecMatchLimit as String:kSecMatchLimitOne]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary,&item) == errSecSuccess,
              let bytes=item as? Data, let raw=String(data:bytes,encoding:.utf8) else { throw LabError.keychainUnavailable }
        let key=raw.trimmingCharacters(in:.whitespacesAndNewlines)
        guard !key.isEmpty, !key.unicodeScalars.contains(where:CharacterSet.controlCharacters.contains) else { throw LabError.keychainUnavailable }
        let identity=Data((instruction+"\n"+content).utf8)
        let requestID=SHA256.hash(data:identity).map { String(format:"%02x",$0) }.joined()
        let savedURL=directory.appendingPathComponent(requestID+".json")
        // Transport cache reuses only the exact complete prompt and model configuration.
        if let data=try? Data(contentsOf:savedURL),
           let saved=try? JSONSerialization.jsonObject(with:data) as? [String:Any],
           saved["instruction"] as? String == instruction, saved["content"] as? String == content,
           saved["model"] as? String == model, saved["baseURL"] as? String == base,
           let reply=saved["reply"] as? String { return reply }
        let body: [String:Any] = ["model":model,"messages":[["role":"system","content":instruction],["role":"user","content":content]],
                                "stream":false,"temperature":0.1,"max_tokens":9000]
        var request=URLRequest(url:components.url!.appendingPathComponent("chat/completions"))
        request.httpMethod="POST"; request.httpBody=try JSONSerialization.data(withJSONObject:body)
        request.setValue("application/json",forHTTPHeaderField:"Content-Type")
        request.setValue("Bearer \(key)",forHTTPHeaderField:"Authorization")
        request.timeoutInterval=180
        let settings=URLSessionConfiguration.ephemeral
        settings.urlCache=nil; settings.httpCookieStorage=nil; settings.httpShouldSetCookies=false
        settings.urlCredentialStorage=nil; settings.requestCachePolicy = .reloadIgnoringLocalCacheData
        settings.timeoutIntervalForRequest=180; settings.timeoutIntervalForResource=240
        let session=URLSession(configuration:settings,delegate:NoRedirect(),delegateQueue:nil)
        defer { session.invalidateAndCancel() }
        count += 1; let sequence=count, start=Date()
        print("model_request \(sequence) input_chars=\(instruction.count+content.count)")
        let (data,response)=try await session.data(for:request)
        guard let http=response as? HTTPURLResponse else { throw LabError.incompleteResponse }
        guard (200...299).contains(http.statusCode) else { throw LabError.http(http.statusCode) }
        guard data.count <= 2_000_000,
              let object=try JSONSerialization.jsonObject(with:data) as? [String:Any],
              let choice=(object["choices"] as? [[String:Any]])?.first,
              choice["finish_reason"] as? String == "stop",
              let message=choice["message"] as? [String:Any], let reply=message["content"] as? String,
              !reply.isEmpty, !reply.contains(key) else { throw LabError.incompleteResponse }
        let evidence: [String:Any] = ["instruction":instruction,"content":content,"reply":reply,"model":model,"baseURL":base,
                                     "usage":object["usage"] ?? [:],"seconds":Date().timeIntervalSince(start),"http_status":http.statusCode]
        try JSONSerialization.data(withJSONObject:evidence,options:[.prettyPrinted,.sortedKeys]).write(to:savedURL,options:.atomic)
        print("model_response \(sequence) seconds=\(Int(Date().timeIntervalSince(start)))")
        return reply
    }
}

private final class LabCheckpoints: @unchecked Sendable {
    let db: DaybookDatabase
    init(url:URL) throws {
        db=try DaybookDatabase(url:url)
        try db.execute("CREATE TABLE IF NOT EXISTS content_v2_lab_checkpoints(cache_key TEXT PRIMARY KEY,payload BLOB NOT NULL)")
    }
    func load(_ key:String) throws -> Data? { try db.query("SELECT payload FROM content_v2_lab_checkpoints WHERE cache_key=?",[.text(key)]).first?["payload"]?.data }
    func save(_ key:String,_ data:Data) throws {
        try db.execute("INSERT INTO content_v2_lab_checkpoints(cache_key,payload) VALUES (?,?) ON CONFLICT(cache_key) DO UPDATE SET payload=excluded.payload",[.text(key),.blob(data)])
    }
}

@main struct Runner {
    static func main() async {
        do { try await run() }
        catch let error as ContentSegmentationV2.Failure { print("FAILED \(error.description)"); exit(1) }
        catch let error as LabError { print("FAILED \(error)"); exit(1) }
        catch { print("FAILED local_or_transport_error"); exit(1) }
    }
    static func run() async throws {
        let args=CommandLine.arguments
        guard args.count == 4 else { throw LabError.arguments }
        let report=URL(fileURLWithPath:args[3],isDirectory:true)
        try FileManager.default.createDirectory(at:report,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        let raw=try PropertyListSerialization.propertyList(from:Data(contentsOf:URL(fileURLWithPath:args[1])),format:nil) as? [String:Any]
        guard let configData=raw?["aiConfiguration"] as? Data,
              let config=try JSONSerialization.jsonObject(with:configData) as? [String:Any],
              config["mode"] as? String == "custom", let model=config["model"] as? String,
              let base=config["baseURL"] as? String else { throw LabError.configurationMismatch }
        let input=try JSONDecoder().decode(ContentSegmentationV2.Input.self,from:Data(contentsOf:URL(fileURLWithPath:args[2])))
        let plan=try ContentSegmentationV2.prepare(input)
        let encoder=JSONEncoder(); encoder.outputFormatting=[.prettyPrinted,.sortedKeys]
        try encoder.encode(plan).write(to:report.appendingPathComponent("plan.json"),options:.atomic)
        print("prepared rows=\(input.spans.count) blocks=\(plan.blocks.count) chapters=\(plan.chapters.count) verified_gaps=\(plan.gaps.filter { $0.status == .verified }.count)")
        let responseDirectory=report.appendingPathComponent("responses",isDirectory:true)
        try FileManager.default.createDirectory(at:responseDirectory,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        let transport=LabTransport(configuration:config,directory:responseDirectory)
        let checkpoints=try LabCheckpoints(url:report.appendingPathComponent("checkpoints.sqlite3"))
        let engine=ContentSegmentationV2.Engine(configuration:.init(modelIdentity:base+"|"+model),
            model:{ instruction,content in try await transport.respond(instruction:instruction,content:content) },
            loadCheckpoint:{ try checkpoints.load($0) }, saveCheckpoint:{ try checkpoints.save($0,$1) })
        let result=try await engine.run(input)
        try encoder.encode(result).write(to:report.appendingPathComponent("output.json"),options:.atomic)
        print("complete segments=\(result.segments.count) meaningful=\(result.segments.filter { $0.classification == .meaningful }.count) model_requests=\(result.metrics.modelRequests) checkpoints=\(result.metrics.checkpointHits)")
    }
}
