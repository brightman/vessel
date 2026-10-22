import Foundation
import Security
import CryptoKit

private func check(_ value: @autoclosure () -> Bool, _ message: String) throws {
    if !value() { throw TestFailure.failed(message) }
}
private enum TestFailure: Error { case failed(String) }
private func rejects(_ expected: ChatGPTError, _ action: () async throws -> Void) async throws {
    do { try await action(); throw TestFailure.failed("Expected rejection: \(expected)") }
    catch let error as ChatGPTError { try check(error == expected, "Unexpected typed error") }
}

private final class FixtureProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (Int, [String: String], Data))!
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (status, headers, data) = try Self.handler(request)
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { FileHandle.standardError.write(Data("Fixture rejected request: \(error)\n".utf8)); client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}
private func requestBody(_ request: URLRequest) -> Data {
    if let body = request.httpBody { return body }
    guard let stream = request.httpBodyStream else { return Data() }
    stream.open(); defer { stream.close() }
    var output = Data(); var buffer = [UInt8](repeating: 0, count: 1024)
    while stream.hasBytesAvailable { let count = stream.read(&buffer, maxLength: buffer.count); if count <= 0 { break }; output.append(contentsOf: buffer.prefix(count)) }
    return output
}
private func json(_ object: Any) -> Data { try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) }
private func b64(_ data: Data) -> String { data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "") }
private func query(_ url: URL) -> [String: String] { Dictionary(uniqueKeysWithValues: URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!.map { ($0.name, $0.value ?? "") }) }
private func callback(_ attempt: ChatGPTAuthorizationAttempt, client: String? = "oaiapp_test", state: String? = nil) -> URL {
    var c = URLComponents(url: attempt.callbackURL, resolvingAgainstBaseURL: false)!
    c.queryItems = [.init(name: "code", value: "fixture-code"), .init(name: "state", value: state ?? attempt.state)]
    if let client { c.queryItems!.append(.init(name: "client_id", value: client)) }
    return c.url!
}
private struct SigningFixture {
    let key: SecKey
    let jwk: [String: Any]
    init() {
        key = SecKeyCreateRandomKey([kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeySizeInBits: 2048] as CFDictionary, nil)!
        let bytes = [UInt8](SecKeyCopyExternalRepresentation(SecKeyCopyPublicKey(key)!, nil)! as Data)
        var index = 0
        func take() -> [UInt8] {
            index += 1
            var count = Int(bytes[index]); index += 1
            if count & 128 != 0 { let n = count & 127; count = 0; for _ in 0..<n { count = count * 256 + Int(bytes[index]); index += 1 } }
            let result = Array(bytes[index..<(index + count)]); index += count; return result
        }
        // Skip sequence header, then consume modulus/exponent INTEGERs.
        index = 1; let length = bytes[index]; index += 1
        if length & 128 != 0 { index += Int(length & 127) }
        let n = take().drop(while: { $0 == 0 }); let e = take().drop(while: { $0 == 0 })
        jwk = ["kty": "RSA", "kid": "fixture", "use": "sig", "alg": "RS256", "n": b64(Data(n)), "e": b64(Data(e))]
    }
    func token(nonce: String?, subject: String = "user-fixture", audience: Any = "oaiapp_test", issuer: String = "https://auth.openai.com", expiry: TimeInterval = 4_000_000_000) -> String {
        var claims: [String: Any] = ["iss": issuer, "aud": audience, "sub": subject, "exp": expiry, "email": "fixture@example.test"]
        if let nonce { claims["nonce"] = nonce }
        let signing = b64(json(["alg": "RS256", "kid": "fixture"])) + "." + b64(json(claims))
        let signature = SecKeyCreateSignature(key, .rsaSignatureMessagePKCS1v15SHA256, Data(signing.utf8) as CFData, nil)! as Data
        return signing + "." + b64(signature)
    }
}

@main struct ChatGPTProtocolSmoke {
    static func main() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FixtureProtocol.self]
        let api = ChatGPTAPI(session: URLSession(configuration: configuration), now: { Date(timeIntervalSince1970: 2_000_000_000) })
        let attempt = try ChatGPTAuthorizationAttempt(callbackURL: URL(string: "http://127.0.0.1:54321/auth/callback")!, clientID: nil, hostID: "urn:uuid:fixture")
        let auth = query(try api.authorizationURL(attempt: attempt))
        try check(auth["client_id"] == "dynamic_agent_client" && auth["agent_name_hint"] == "WiseLife", "Initial dynamic registration")
        try check(auth["resource"] == "https://api.openai.com/v1" && auth["code_challenge_method"] == "S256", "Resource and PKCE")
        try check(auth["code_challenge"] == b64(Data(SHA256.hash(data: Data(attempt.verifier.utf8)))), "PKCE digest")
        try check(auth["scope"] == "openid profile email offline_access resource.invoke chatgpt.tokens.use.direct", "Complete requested scopes")
        let other = try ChatGPTAuthorizationAttempt(callbackURL: attempt.callbackURL, clientID: nil, hostID: attempt.hostID)
        try check(attempt.state != other.state && attempt.nonce != other.nonce && attempt.verifier != other.verifier, "Fresh random secrets")
        do { _ = try ChatGPTAuthorizationAttempt(callbackURL: URL(string: "http://localhost:54321/auth/callback")!, clientID: nil, hostID: attempt.hostID); throw TestFailure.failed("localhost accepted") } catch ChatGPTError.invalidCallback {}
        FixtureProtocol.handler = { _ in throw TestFailure.failed("Invalid callback reached network") }
        try await rejects(.invalidCallback) { _ = try await api.exchange(callbackURL: callback(attempt, state: "wrong"), attempt: attempt) }
        try await rejects(.invalidCallback) { _ = try await api.exchange(callbackURL: callback(attempt, client: nil), attempt: attempt) }
        let returning = try ChatGPTAuthorizationAttempt(callbackURL: attempt.callbackURL, clientID: "oaiapp_test", hostID: attempt.hostID, idTokenHint: "retained-id", loginHint: "fixture@example.test", expectedSubject: "user-fixture")
        let returningAuth = query(try api.authorizationURL(attempt: returning))
        try check(returningAuth["agent_name_hint"] == nil, "Returning omits agent name")
        try await rejects(.invalidCallback) { _ = try await api.exchange(callbackURL: callback(returning, client: "other-client"), attempt: returning) }
        let fixture = SigningFixture()
        var issued = fixture.token(nonce: attempt.nonce)
        var granted = "openid profile email offline_access resource.invoke chatgpt.tokens.use.direct"
        var refreshMode = false
        FixtureProtocol.handler = { request in
            switch request.url!.path {
            case "/api/accounts/oauth/token":
                let body = String(data: requestBody(request), encoding: .utf8) ?? ""
                try check(body.contains("client_id=oaiapp_test") && !body.contains("dynamic_agent_client"), "Issued client used for token exchange")
                if refreshMode { try check(!body.contains("scope="), "Refresh retains granted scope") }
                var object: [String: Any] = ["access_token": "opaque-access", "token_type": "Bearer", "refresh_token": "rotated-refresh", "expires_in": 3600, "scope": granted]
                if !issued.isEmpty { object["id_token"] = issued }
                return (200, [:], json(object))
            case "/.well-known/openid-configuration": return (200, [:], json(["issuer": "https://auth.openai.com", "jwks_uri": "https://auth.openai.com/.well-known/jwks.json", "revocation_endpoint": "https://auth.openai.com/oauth/revoke"]))
            case "/.well-known/jwks.json": return (200, [:], json(["keys": [fixture.jwk]]))
            default: throw TestFailure.failed("Unexpected endpoint")
            }
        }
        let credential = try await api.exchange(callbackURL: callback(attempt), attempt: attempt)
        try check(credential.canUsePlan && credential.subject == "user-fixture" && credential.refreshToken == "rotated-refresh", "Validated identity and granted plan")
        granted = "openid profile email"
        let identityOnly = try await api.exchange(callbackURL: callback(attempt), attempt: attempt)
        try check(!identityOnly.canUsePlan, "Identity-only grant retained without inference permission")
        issued = fixture.token(nonce: "wrong")
        try await rejects(.invalidIdentity) { _ = try await api.exchange(callbackURL: callback(attempt), attempt: attempt) }
        issued = fixture.token(nonce: returning.nonce, subject: "other-user")
        try await rejects(.invalidIdentity) { _ = try await api.exchange(callbackURL: callback(returning), attempt: returning) }
        for bad in [fixture.token(nonce: attempt.nonce, audience: "other"), fixture.token(nonce: attempt.nonce, issuer: "https://evil.example"), fixture.token(nonce: attempt.nonce, expiry: 1)] {
            issued = bad
            try await rejects(.invalidIdentity) { _ = try await api.exchange(callbackURL: callback(attempt), attempt: attempt) }
        }
        let valid = fixture.token(nonce: attempt.nonce)
        var pieces = valid.split(separator: ".").map(String.init); pieces[2] = b64(Data(repeating: 0, count: 256)); issued = pieces.joined(separator: ".")
        try await rejects(.invalidIdentity) { _ = try await api.exchange(callbackURL: callback(attempt), attempt: attempt) }
        issued = ""; refreshMode = true; granted = "openid profile email offline_access resource.invoke chatgpt.tokens.use.direct"
        let renewed = try await api.refresh(credential)
        try check(renewed.idToken == credential.idToken && renewed.subject == credential.subject && renewed.expiresAt == Date(timeIntervalSince1970: 2_000_003_600), "Refresh without ID token retains validated identity")
        issued = fixture.token(nonce: nil, subject: "other-user")
        try await rejects(.invalidIdentity) { _ = try await api.refresh(credential) }
        FixtureProtocol.handler = { _ in (200, [:], json(["models": [["slug": "hidden", "display_name": "Hidden", "visibility": "hide"], ["slug": "model-z", "display_name": "Z", "visibility": "list"], ["slug": "model-a", "display_name": "A", "visibility": "list"]]])) }
        let models = try await api.models(accessToken: "fixture")
        try check(models == [ChatGPTModel(id: "model-z", displayName: "Z"), ChatGPTModel(id: "model-a", displayName: "A")], "Models filter preserving order")
        func stream(_ events: [[String: Any]]) -> Data { Data(events.map { "data: " + String(data: json($0), encoding: .utf8)! + "\n\n" }.joined().utf8) }
        var events: [[String: Any]] = [["type": "response.output_text.delta", "delta": "Hello"], ["type": "response.completed", "response": ["status": "completed", "output": [["type": "message", "role": "assistant", "content": [["type": "output_text", "text": "Hello"]]]]]]]
        FixtureProtocol.handler = { request in
            try check(request.url!.absoluteString == "https://api.openai.com/v1/responses" && request.httpMethod == "POST", "Public Responses route")
            let body = try JSONSerialization.jsonObject(with: requestBody(request)) as! [String: Any]
            try check(body["store"] as? Bool == false && body["stream"] as? Bool == true, "Required privacy/stream flags")
            return (200, ["Content-Type": "text/event-stream"], stream(events))
        }
        let answer = try await api.complete(instruction: "Instruction", content: "Fixture content", model: "model-a", accessToken: "fixture")
        try check(answer == "Hello", "Completed text")
        events = [["type": "response.output_text.delta", "delta": "Partial"]]
        try await rejects(.incompleteResponse) { _ = try await api.complete(instruction: "i", content: "c", model: "m", accessToken: "t") }
        events += [["type": "response.incomplete"]]
        try await rejects(.incompleteResponse) { _ = try await api.complete(instruction: "i", content: "c", model: "m", accessToken: "t") }
        events = [["type": "response.failed", "response": ["error": ["code": "subscription_sharing_usage_limit_exceeded", "message": "SECRET BODY"]]]]
        try await rejects(.usageLimit) { _ = try await api.complete(instruction: "i", content: "c", model: "m", accessToken: "t") }
        FixtureProtocol.handler = { _ in (503, [:], json(["detail": "SECRET BODY"])) }
        try await rejects(.temporarilyUnavailable) { _ = try await api.models(accessToken: "t") }
        FixtureProtocol.handler = { _ in (400, [:], json(["error": "invalid_grant", "error_description": "SECRET BODY"])) }
        try await rejects(.expired) { _ = try await api.refresh(credential) }
        // Returning callback may omit client_id, but must still validate the original registration.
        let returningToken = fixture.token(nonce: returning.nonce)
        FixtureProtocol.handler = { request in
            switch request.url!.path {
            case "/api/accounts/oauth/token": return (200, [:], json(["access_token": "opaque", "token_type": "Bearer", "expires_in": 60, "id_token": returningToken, "scope": "openid profile email"]))
            case "/.well-known/openid-configuration": return (200, [:], json(["issuer": "https://auth.openai.com", "jwks_uri": "https://auth.openai.com/keys"]))
            case "/keys": return (200, [:], json(["keys": [fixture.jwk]]))
            default: throw TestFailure.failed("Unexpected returning endpoint")
            }
        }
        let returned = try await api.exchange(callbackURL: callback(returning, client: nil), attempt: returning)
        try check(returned.clientID == "oaiapp_test" && returned.subject == "user-fixture", "Returning callback retains issued client")
        var wrongPath = URLComponents(url: callback(attempt), resolvingAgainstBaseURL: false)!
        wrongPath.path = "/callback"
        try await rejects(.invalidCallback) { _ = try await api.exchange(callbackURL: wrongPath.url!, attempt: attempt) }
        var duplicated = URLComponents(url: callback(attempt), resolvingAgainstBaseURL: false)!
        duplicated.queryItems!.append(.init(name: "state", value: attempt.state))
        try await rejects(.invalidCallback) { _ = try await api.exchange(callbackURL: duplicated.url!, attempt: attempt) }
        var declined = URLComponents(url: attempt.callbackURL, resolvingAgainstBaseURL: false)!
        declined.queryItems = [.init(name: "error", value: "access_denied"), .init(name: "state", value: attempt.state)]
        try await rejects(.cancelled) { _ = try await api.exchange(callbackURL: declined.url!, attempt: attempt) }
        var leakedDiscoveryRequest = false
        FixtureProtocol.handler = { request in
            switch request.url!.path {
            case "/api/accounts/oauth/token": return (200, [:], json(["access_token": "opaque", "token_type": "Bearer", "expires_in": 60, "id_token": returningToken, "scope": "openid"]))
            case "/.well-known/openid-configuration": return (200, [:], json(["issuer": "https://auth.openai.com", "jwks_uri": "https://evil.example/keys"]))
            default: leakedDiscoveryRequest = true; throw TestFailure.failed("Discovery escaped allowlist")
            }
        }
        try await rejects(.invalidIdentity) { _ = try await api.exchange(callbackURL: callback(returning), attempt: returning) }
        try check(!leakedDiscoveryRequest, "Discovery URI must stay on official HTTPS host")
        FixtureProtocol.handler = { _ in (200, [:], json(["access_token": "new-opaque", "token_type": "Bearer", "expires_in": 60])) }
        let minimalRefresh = try await api.refresh(credential)
        try check(minimalRefresh.scopes == credential.scopes && minimalRefresh.refreshToken == credential.refreshToken, "Refresh preserves omitted scope/rotation fields")
        FixtureProtocol.handler = { _ in (200, [:], json(["access_token": "new-opaque", "token_type": "Bearer", "expires_in": 60, "scope": "openid profile email offline_access resource.invoke chatgpt.tokens.use.direct unexpected.scope"])) }
        try await rejects(.invalidResponse) { _ = try await api.refresh(credential) }
        var revoked = false
        FixtureProtocol.handler = { request in
            switch request.url!.path {
            case "/.well-known/openid-configuration": return (200, [:], json(["issuer": "https://auth.openai.com", "jwks_uri": "https://auth.openai.com/keys", "revocation_endpoint": "https://auth.openai.com/oauth/revoke"]))
            case "/oauth/revoke":
                let body = String(data: requestBody(request), encoding: .utf8)!
                try check(body.contains("token_type_hint=refresh_token") && body.contains("client_id=oaiapp_test"), "Revocation form bound to registration")
                revoked = true; return (200, [:], Data())
            default: throw TestFailure.failed("Unexpected revocation endpoint")
            }
        }
        try await api.revoke(credential)
        try check(revoked, "Empty 200 revocation accepted")
        FixtureProtocol.handler = { _ in (200, [:], Data(repeating: 65, count: 1_048_577)) }
        try await rejects(.invalidResponse) { _ = try await api.models(accessToken: "fixture") }
        let terminal: [String: Any] = [
            "type": "response.completed",
            "response": ["status": "completed", "output": [
                ["type": "message", "role": "assistant", "content": [["type": "output_text", "text": "Full answer"]]]
            ]]
        ]
        FixtureProtocol.handler = { _ in
            let crOnly = String(data: stream([terminal]), encoding: .utf8)!.replacingOccurrences(of: "\n", with: "\r")
            return (200, ["Content-Type": "text/event-stream"], Data(crOnly.utf8))
        }
        let crAnswer = try await api.complete(instruction: "i", content: "c", model: "m", accessToken: "t")
        try check(crAnswer == "Full answer", "SSE accepts CR as a standard line terminator")
        FixtureProtocol.handler = { _ in (200, ["Content-Type": "text/event-stream"], stream([terminal, ["type": "response.failed", "response": ["error": ["code": "subscription_sharing_usage_limit_exceeded"]]]])) }
        try await rejects(.invalidResponse) { _ = try await api.complete(instruction: "i", content: "c", model: "m", accessToken: "t") }
        FixtureProtocol.handler = { _ in (200, ["Content-Type": "text/event-stream"], Data(("data: " + String(data: json(terminal), encoding: .utf8)! + "\n").utf8)) }
        try await rejects(.incompleteResponse) { _ = try await api.complete(instruction: "i", content: "c", model: "m", accessToken: "t") }
        FixtureProtocol.handler = { _ in (200, ["Content-Type": "text/event-stream"], stream([["type": "response.completed", "response": ["status": "completed", "output": []]]])) }
        try await rejects(.invalidResponse) { _ = try await api.complete(instruction: "i", content: "c", model: "m", accessToken: "t") }
        try check(ChatGPTAPI.failure(status: 403, code: "subscription_sharing_route_not_supported", requestID: "req-fixture") == .http(status: 403, code: "subscription_sharing_route_not_supported", requestID: "req-fixture"), "Route errors retain exact safe diagnosis")
        try check(ChatGPTAPI.failure(status: 401, body: json(["detail": "admission denied"]), requestID: nil) == .permissionMissing, "Admission 401 retains credential")
        try check(ChatGPTAPI.failure(status: 401, code: "subscription_sharing_invalid_user") == .permissionMissing, "Subscriber admission failure is not confirmed session revocation")
        try check(!(ChatGPTAPI.failure(status: 400, code: "SECRET_BODY", requestID: "SECRET BODY").localizedDescription.contains("SECRET")), "Unknown diagnostics never echoed")
        print("ChatGPT protocol smoke passed: OAuth, RSA identity, refresh, account models, terminal SSE and safe recovery")
    }
}
