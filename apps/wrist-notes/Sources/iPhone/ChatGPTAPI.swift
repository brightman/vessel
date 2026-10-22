import Foundation
import CryptoKit

private final class ChatGPTNoRedirect: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

/// This public-client API never sends data to a WiseLife service.
final class ChatGPTAPI {
    private let session: URLSession
    private let now: () -> Date
    private let noRedirect = ChatGPTNoRedirect()
    private static let resource = "https://api.openai.com/v1"
    private static let tokenURL = URL(string: "https://auth.openai.com/api/accounts/oauth/token")!
    private static let discoveryURL = URL(string: "https://auth.openai.com/.well-known/openid-configuration")!
    private static let scopes = "openid profile email offline_access resource.invoke chatgpt.tokens.use.direct"

    init(session: URLSession? = nil, now: @escaping () -> Date = Date.init) {
        if let session { self.session = session }
        else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.httpCookieStorage = nil
            configuration.urlCredentialStorage = nil
            configuration.httpShouldSetCookies = false
            configuration.urlCache = nil
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            configuration.timeoutIntervalForRequest = 60
            configuration.timeoutIntervalForResource = 120
            self.session = URLSession(configuration: configuration)
        }
        self.now = now
    }

    func authorizationURL(attempt: ChatGPTAuthorizationAttempt) throws -> URL {
        var components = URLComponents(string: "https://auth.openai.com/api/accounts/authorize")!
        var values: [(String, String)] = [
            ("client_id", attempt.clientID ?? "dynamic_agent_client"), ("ext_agent_host_id", attempt.hostID),
            ("response_type", "code"), ("redirect_uri", attempt.callbackURL.absoluteString),
            ("scope", Self.scopes), ("resource", Self.resource), ("state", attempt.state), ("nonce", attempt.nonce),
            ("code_challenge_method", "S256"), ("code_challenge", Data(SHA256.hash(data: Data(attempt.verifier.utf8))).chatGPTBase64URL)
        ]
        if attempt.clientID == nil { values.append(("agent_name_hint", "WiseLife")) }
        if let hint = attempt.idTokenHint { values.append(("id_token_hint", hint)) }
        if let hint = attempt.loginHint { values.append(("login_hint", hint)) }
        components.queryItems = values.map { URLQueryItem(name: $0.0, value: $0.1) }
        guard let url = components.url else { throw ChatGPTError.invalidCallback }
        return url
    }

    func exchange(callbackURL: URL, attempt: ChatGPTAuthorizationAttempt) async throws -> ChatGPTCredential {
        let callback = try parseCallback(callbackURL, attempt: attempt)
        let body = try await request(formRequest(Self.tokenURL, [
            ("grant_type", "authorization_code"), ("client_id", callback.clientID), ("code", callback.code),
            ("code_verifier", attempt.verifier), ("redirect_uri", attempt.callbackURL.absoluteString), ("resource", Self.resource)
        ]), limit: 262_144)
        let tokens = try decodeTokens(body)
        guard let idToken = tokens.id_token else { throw ChatGPTError.invalidIdentity }
        let identity = try await identity(idToken, clientID: callback.clientID, nonce: attempt.nonce, subject: attempt.expectedSubject)
        guard let scope = tokens.scope else { throw ChatGPTError.invalidResponse }
        return ChatGPTCredential(clientID: callback.clientID, subject: identity.subject, email: identity.email,
                                 hostID: attempt.hostID, idToken: idToken, accessToken: tokens.access_token,
                                 refreshToken: tokens.refresh_token, expiresAt: now().addingTimeInterval(tokens.expires_in), scopes: try parseScopes(scope))
    }

    func refresh(_ credential: ChatGPTCredential) async throws -> ChatGPTCredential {
        guard let refreshToken = credential.refreshToken, !refreshToken.isEmpty, credential.clientID != "dynamic_agent_client" else { throw ChatGPTError.expired }
        let body = try await request(formRequest(Self.tokenURL, [
            ("grant_type", "refresh_token"), ("client_id", credential.clientID), ("refresh_token", refreshToken), ("resource", Self.resource)
        ]), limit: 262_144)
        let tokens = try decodeTokens(body)
        var subject = credential.subject
        var email = credential.email
        if let idToken = tokens.id_token {
            let validated = try await identity(idToken, clientID: credential.clientID, nonce: nil, subject: credential.subject)
            subject = validated.subject; email = validated.email ?? credential.email
        }
        let scopes = try tokens.scope.map(parseScopes) ?? credential.scopes
        // A refresh without scope retains the grant; an explicit response must never expand it.
        guard scopes.isSubset(of: credential.scopes) else { throw ChatGPTError.invalidResponse }
        return ChatGPTCredential(clientID: credential.clientID, subject: subject, email: email, hostID: credential.hostID,
                                 idToken: tokens.id_token ?? credential.idToken, accessToken: tokens.access_token,
                                 refreshToken: tokens.refresh_token ?? refreshToken, expiresAt: now().addingTimeInterval(tokens.expires_in), scopes: scopes)
    }

    func models(accessToken: String) async throws -> [ChatGPTModel] {
        var req = URLRequest(url: URL(string: Self.resource + "/models")!)
        try authorize(&req, token: accessToken)
        let data = try await request(req, limit: 1_048_576)
        struct Catalog: Decodable {
            struct Model: Decodable { let slug: String; let display_name: String; let visibility: String }
            let models: [Model]
        }
        do {
            let catalog = try JSONDecoder().decode(Catalog.self, from: data)
            let models = catalog.models.filter { $0.visibility == "list" }
            guard models.count <= 2000, models.allSatisfy({ !$0.slug.isEmpty && !$0.display_name.isEmpty && $0.slug.utf8.count <= 512 && $0.display_name.utf8.count <= 1024 }), Set(models.map(\.slug)).count == models.count else { throw ChatGPTError.invalidResponse }
            return models.map { ChatGPTModel(id: $0.slug, displayName: $0.display_name) }
        } catch { throw ChatGPTError.invalidResponse }
    }

    func complete(instruction: String, content: String, model: String, accessToken: String) async throws -> String {
        guard !model.isEmpty, model.utf8.count <= 512, instruction.utf8.count + content.utf8.count <= 1_048_576 else { throw ChatGPTError.invalidResponse }
        var req = URLRequest(url: URL(string: Self.resource + "/responses")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        try authorize(&req, token: accessToken)
        req.httpBody = try JSONSerialization.data(withJSONObject: ["model": model, "instructions": instruction,
            "input": [["role": "user", "content": content]], "store": false, "stream": true])
        let (bytes, response) = try await open(req)
        guard (200..<300).contains(response.statusCode) else {
            let body = try await collect(bytes, limit: 262_144)
            throw Self.failure(status: response.statusCode, body: body, requestID: response.value(forHTTPHeaderField: "x-request-id"))
        }
        guard response.value(forHTTPHeaderField: "Content-Type")?.lowercased().split(separator: ";").first?.trimmingCharacters(in: .whitespaces) == "text/event-stream" else { throw ChatGPTError.invalidResponse }
        var parser = ChatGPTEventStream()
        var total = 0
        do {
            for try await byte in bytes {
                try Task.checkCancellation()
                total += 1
                guard total <= 4_194_304 else { throw ChatGPTError.invalidResponse }
                try parser.accept(byte)
            }
        } catch is CancellationError { throw ChatGPTError.cancelled }
        catch let error as ChatGPTError { throw error }
        catch { throw ChatGPTError.network }
        return try parser.finish()
    }

    func revoke(_ credential: ChatGPTCredential) async throws {
        guard let token = credential.refreshToken, !token.isEmpty else { return }
        let discovery = try await discovery()
        guard let url = discovery.revocation_endpoint.flatMap(Self.officialAuthURL) else { throw ChatGPTError.invalidResponse }
        _ = try await request(formRequest(url, [("token", token), ("token_type_hint", "refresh_token"), ("client_id", credential.clientID)]), limit: 262_144)
    }

    private func parseCallback(_ url: URL, attempt: ChatGPTAuthorizationAttempt) throws -> (code: String, clientID: String) {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false), var base = URLComponents(url: url, resolvingAgainstBaseURL: false), components.fragment == nil else { throw ChatGPTError.invalidCallback }
        base.query = nil
        guard base.url == attempt.callbackURL, let items = components.queryItems, items.count <= 32,
              Set(items.map(\.name)).count == items.count else { throw ChatGPTError.invalidCallback }
        let values = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
        guard values["state"] == attempt.state else { throw ChatGPTError.invalidCallback }
        if let error = values["error"] {
            if error == "access_denied" { throw ChatGPTError.cancelled }
            throw ChatGPTError.invalidCallback
        }
        guard let code = values["code"], !code.isEmpty, code.utf8.count <= 8192 else { throw ChatGPTError.invalidCallback }
        let issued = values["client_id"] ?? attempt.clientID
        guard let clientID = issued, ChatGPTAuthorizationAttempt.validIdentifier(clientID), clientID != "dynamic_agent_client",
              attempt.clientID == nil || attempt.clientID == clientID else { throw ChatGPTError.invalidCallback }
        return (code, clientID)
    }

    private struct Tokens: Decodable {
        let access_token: String; let token_type: String; let expires_in: Double
        let refresh_token: String?; let id_token: String?; let scope: String?
    }
    private func decodeTokens(_ data: Data) throws -> Tokens {
        do {
            let tokens = try JSONDecoder().decode(Tokens.self, from: data)
            guard Self.safeToken(tokens.access_token), tokens.token_type.lowercased() == "bearer", tokens.expires_in.isFinite,
                  tokens.expires_in > 0, tokens.expires_in <= 31_536_000,
                  tokens.refresh_token.map(Self.safeToken) ?? true,
                  tokens.id_token.map({ !$0.isEmpty && $0.utf8.count <= 32_768 }) ?? true else { throw ChatGPTError.invalidResponse }
            return tokens
        } catch { throw ChatGPTError.invalidResponse }
    }
    private func parseScopes(_ value: String) throws -> Set<String> {
        guard value.utf8.count <= 8192, value.utf8.allSatisfy({ $0 == 32 || ($0 >= 33 && $0 <= 126 && $0 != 34 && $0 != 92) }) else { throw ChatGPTError.invalidResponse }
        return Set(value.split(separator: " ").map(String.init))
    }
    private struct Discovery: Decodable { let issuer: String; let jwks_uri: String; let revocation_endpoint: String? }
    private func discovery() async throws -> Discovery {
        let data = try await request(URLRequest(url: Self.discoveryURL), limit: 262_144)
        guard let value = try? JSONDecoder().decode(Discovery.self, from: data), value.issuer == "https://auth.openai.com", Self.officialAuthURL(value.jwks_uri) != nil else { throw ChatGPTError.invalidIdentity }
        return value
    }
    private func identity(_ token: String, clientID: String, nonce: String?, subject: String?) async throws -> ChatGPTIDToken.Identity {
        let metadata = try await discovery()
        guard let url = Self.officialAuthURL(metadata.jwks_uri) else { throw ChatGPTError.invalidIdentity }
        let jwks = try await request(URLRequest(url: url), limit: 262_144)
        return try ChatGPTIDToken.validate(token, jwks: jwks, clientID: clientID, nonce: nonce, expectedSubject: subject, now: now())
    }
    private static func officialAuthURL(_ value: String) -> URL? {
        guard let c = URLComponents(string: value), c.scheme == "https", c.host == "auth.openai.com", c.port == nil || c.port == 443,
              c.user == nil, c.password == nil, c.fragment == nil, c.query == nil, !c.path.isEmpty else { return nil }
        return c.url
    }
    private func authorize(_ request: inout URLRequest, token: String) throws {
        guard Self.safeToken(token) else { throw ChatGPTError.expired }
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
    }
    private static func safeToken(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 65_536 && value.utf8.allSatisfy { $0 >= 33 && $0 <= 126 }
    }
    private func formRequest(_ url: URL, _ values: [(String, String)]) -> URLRequest {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        let encoded = values.map { $0.0.addingPercentEncoding(withAllowedCharacters: allowed)! + "=" + $0.1.addingPercentEncoding(withAllowedCharacters: allowed)! }.joined(separator: "&")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(encoded.utf8)
        return request
    }
    private func open(_ request: URLRequest) async throws -> (URLSession.AsyncBytes, HTTPURLResponse) {
        do {
            try Task.checkCancellation()
            var clean = request
            clean.httpShouldHandleCookies = false
            clean.cachePolicy = .reloadIgnoringLocalCacheData
            let (bytes, response) = try await session.bytes(for: clean, delegate: noRedirect)
            guard let http = response as? HTTPURLResponse, http.url == request.url else { throw ChatGPTError.invalidResponse }
            return (bytes, http)
        } catch is CancellationError { throw ChatGPTError.cancelled }
        catch let error as ChatGPTError { throw error }
        catch let error as URLError where error.code == .cancelled { throw ChatGPTError.cancelled }
        catch { throw ChatGPTError.network }
    }
    private func collect(_ bytes: URLSession.AsyncBytes, limit: Int) async throws -> Data {
        var data = Data()
        do {
            for try await byte in bytes {
                try Task.checkCancellation()
                guard data.count < limit else { throw ChatGPTError.invalidResponse }
                data.append(byte)
            }
        } catch is CancellationError { throw ChatGPTError.cancelled }
        catch let error as ChatGPTError { throw error }
        catch { throw ChatGPTError.network }
        return data
    }
    private func request(_ req: URLRequest, limit: Int) async throws -> Data {
        let (bytes, response) = try await open(req)
        let body = try await collect(bytes, limit: limit)
        guard (200..<300).contains(response.statusCode) else { throw Self.failure(status: response.statusCode, body: body, requestID: response.value(forHTTPHeaderField: "x-request-id")) }
        return body
    }

    static func failure(status: Int, body: Data, requestID: String?) -> ChatGPTError {
        let object = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
        let error = object?["error"]
        let code = ((error as? [String: Any])?["code"] as? String) ?? (error as? String)
        return failure(status: status, code: code, requestID: requestID)
    }
    static func failure(status: Int, code: String?, requestID: String? = nil) -> ChatGPTError {
        switch code {
        case "invalid_grant", "invalid_refresh_token", "token_expired", "refresh_token_expired", "refresh_token_invalidated", "refresh_token_reused": return .expired
        case "subscription_sharing_usage_limit_exceeded": return .usageLimit
        case "subscription_sharing_user_not_eligible": return .notEligible
        case "subscription_sharing_usage_unavailable", "subscription_sharing_user_unavailable": return .temporarilyUnavailable
        case "subscription_sharing_invalid_user", "chatpass_v2_scope_not_authorized", "chatpass_v2_invalid_authorization_context": return .permissionMissing
        case "invalid_client": return .unavailableConfiguration
        default: break
        }
        let diagnosticCodes: Set<String> = ["subscription_sharing_unsupported_capability", "subscription_sharing_route_not_supported"]
        let safeID = requestID.flatMap { value in value.utf8.count <= 128 && value.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95 }) ? value : nil }
        if let code, diagnosticCodes.contains(code) { return .http(status: status, code: code, requestID: safeID) }
        if status == 401 { return .permissionMissing }
        if status == 403 { return .permissionMissing }
        if status == 429 { return .usageLimit }
        if (500...599).contains(status) { return .temporarilyUnavailable }
        // Never display arbitrary server fields. Only documented identifiers are safe diagnostic codes.
        return .http(status: status, code: nil, requestID: safeID)
    }
}

/// Incremental, bounded SSE decoder. Deltas never constitute success on their own.
private struct ChatGPTEventStream {
    private var line = Data()
    private var eventData: [String] = []
    private var previousCR = false
    private var eventName: String?
    private var completed = false
    private var output = ""
    private var delta = ""

    mutating func accept(_ byte: UInt8) throws {
        if byte == 10 && previousCR { previousCR = false; return }
        if byte == 10 || byte == 13 {
            previousCR = byte == 13
            guard let text = String(data: line, encoding: .utf8) else { throw ChatGPTError.invalidResponse }
            line.removeAll(keepingCapacity: true)
            try acceptLine(text)
        } else {
            previousCR = false
            guard line.count < 262_144 else { throw ChatGPTError.invalidResponse }
            line.append(byte)
        }
    }
    private mutating func acceptLine(_ line: String) throws {
        if line.isEmpty { try dispatch(); return }
        if line.hasPrefix(":") { return }
        let parts = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        let value = parts.count == 2 ? String(parts[1].hasPrefix(" ") ? parts[1].dropFirst() : parts[1][...]) : ""
        if parts[0] == "data" {
            guard eventData.reduce(0, { $0 + $1.utf8.count }) + value.utf8.count <= 262_144 else { throw ChatGPTError.invalidResponse }
            eventData.append(value)
        } else if parts[0] == "event" { eventName = value }
    }
    private mutating func dispatch() throws {
        defer { eventData.removeAll(keepingCapacity: true); eventName = nil }
        guard !eventData.isEmpty else { return }
        let string = eventData.joined(separator: "\n")
        if string == "[DONE]" { guard completed else { throw ChatGPTError.incompleteResponse }; return }
        guard let object = try? JSONSerialization.jsonObject(with: Data(string.utf8)) as? [String: Any], let type = object["type"] as? String,
              eventName == nil || eventName == type else { throw ChatGPTError.invalidResponse }
        if completed { throw ChatGPTError.invalidResponse }
        switch type {
        case "response.output_text.delta":
            guard let part = object["delta"] as? String, delta.utf8.count + part.utf8.count <= 262_144 else { throw ChatGPTError.invalidResponse }
            delta += part
        case "response.failed", "error":
            let response = object["response"] as? [String: Any]
            let error = (response?["error"] as? [String: Any]) ?? (object["error"] as? [String: Any])
            let code = (error?["code"] as? String) ?? (object["code"] as? String)
            if code == nil { throw ChatGPTError.invalidResponse }
            throw ChatGPTAPI.failure(status: 400, code: code)
        case "response.incomplete": throw ChatGPTError.incompleteResponse
        case "response.completed":
            guard let response = object["response"] as? [String: Any], response["status"] as? String == "completed",
                  response["error"] == nil || response["error"] is NSNull else { throw ChatGPTError.invalidResponse }
            var texts: [String] = []
            if let items = response["output"] as? [[String: Any]] {
                for item in items where item["type"] as? String == "message" && item["role"] as? String == "assistant" {
                    if let content = item["content"] as? [[String: Any]] {
                        for piece in content where piece["type"] as? String == "output_text" {
                            guard let text = piece["text"] as? String else { throw ChatGPTError.invalidResponse }
                            texts.append(text)
                        }
                    }
                }
            }
            let text = texts.joined(separator: "\n")
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, text.utf8.count <= 262_144 else { throw ChatGPTError.invalidResponse }
            output = text; completed = true
        default: break
        }
    }
    mutating func finish() throws -> String {
        // An unfinished SSE event is a truncated response, even after valid earlier deltas.
        guard line.isEmpty, eventData.isEmpty, completed else { throw ChatGPTError.incompleteResponse }
        return output
    }
}
