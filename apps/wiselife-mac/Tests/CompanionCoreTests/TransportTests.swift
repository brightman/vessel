import XCTest
import Security
@testable import CompanionCore

private final class PinnedSession: NSObject, URLSessionDelegate, URLSessionTaskDelegate, @unchecked Sendable {
    let fingerprint: String
    init(_ fingerprint: String) { self.fingerprint = fingerprint }
    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust,
              let certificate = (SecTrustCopyCertificateChain(trust) as? [SecCertificate])?.first,
              Secrets.equal(Secrets.hash(SecCertificateCopyData(certificate) as Data), fingerprint) else {
            completionHandler(.cancelAuthenticationChallenge, nil); return
        }
        completionHandler(.useCredential, URLCredential(trust: trust))
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}

final class TransportTests: XCTestCase {
    func testActualHTTPSPairGenerateRejectAndRevoke() async throws {
        let secrets = MemorySecrets(), engine = StubEngine(), registry = try PairingRegistry(store: secrets)
        let identity = try TLSIdentity.load(store: secrets, serviceID: await registry.serviceID)
        let runtime = ModelRuntime(engine: engine), router = APIRouter(registry: registry, runtime: runtime)
        let server = LocalHTTPServer()
        let port = try await server.start(address: "127.0.0.1", identity: identity, router: router, allowLoopbackForTests: true)
        let delegate = PinnedSession(identity.fingerprint)
        let session = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        func send(_ path: String, method: String = "GET", body: Data? = nil, token: String? = nil) async throws -> (Int, [String: Any]) {
            var request = URLRequest(url: URL(string: "https://127.0.0.1:\(port)" + path)!)
            request.httpMethod = method; request.httpBody = body; request.timeoutInterval = 3
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            if let token { request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization") }
            let (data, response) = try await session.data(for: request)
            return ((response as! HTTPURLResponse).statusCode, try JSONSerialization.jsonObject(with: data) as! [String: Any])
        }
        let health = try await send("/health")
        XCTAssertEqual(health.0, 200); XCTAssertEqual(health.1["model_state"] as? String, "unloaded")
        XCTAssertNil(health.1["token"])
        let unauthorized = try await send("/v1/models")
        XCTAssertEqual(unauthorized.0, 401)
        let code = try await registry.open(fingerprint: identity.fingerprint)
        let device = UUID()
        let pairBody = try JSONSerialization.data(withJSONObject: ["nonce": code.nonce, "device_id": device.uuidString, "device_name": "合成测试 iPhone"])
        let pair = try await send("/pair", method: "POST", body: pairBody)
        XCTAssertEqual(pair.0, 200)
        let token = try XCTUnwrap(pair.1["token"] as? String)
        let replay = try await send("/pair", method: "POST", body: pairBody)
        XCTAssertEqual(replay.0, 401)
        let paused = try await send("/v1/models", token: token)
        XCTAssertEqual(paused.0, 503)
        await router.setAvailable(true)
        let notReady = try await send("/v1/chat/completions", method: "POST", body: requestBody(), token: token)
        XCTAssertEqual(notReady.0, 503)
        try await runtime.load("test-model", directory: URL(fileURLWithPath: "/stub"))
        let models = try await send("/v1/models", token: token)
        XCTAssertEqual((models.1["data"] as? [[String: Any]])?.first?["id"] as? String, "test-model")
        let generated = try await send("/v1/chat/completions", method: "POST", body: requestBody(), token: token)
        XCTAssertEqual(generated.0, 200)
        let choice = (generated.1["choices"] as? [[String: Any]])?.first
        XCTAssertEqual((choice?["message"] as? [String: Any])?["content"] as? String, "中文结果[1]")
        let stream = try await send("/v1/chat/completions", method: "POST", body: requestBody(["stream": true]), token: token)
        XCTAssertEqual(stream.0, 400)
        let oversized = try await send("/v1/chat/completions", method: "POST", body: Data(repeating: 32, count: TextRequest.maximumBodyBytes + 1), token: token)
        XCTAssertEqual(oversized.0, 413)
        let wrong = URLSession(configuration: .ephemeral, delegate: PinnedSession(String(repeating: "0", count: 64)), delegateQueue: nil)
        do { _ = try await wrong.data(from: URL(string: "https://127.0.0.1:\(port)/health")!); XCTFail("Wrong TLS pin accepted") } catch { }
        wrong.invalidateAndCancel()
        do { _ = try await session.data(from: URL(string: "http://127.0.0.1:\(port)/health")!); XCTFail("Cleartext accepted") } catch { }
        let revoked = try await send("/pair", method: "DELETE", token: token)
        XCTAssertEqual(revoked.0, 200)
        let denied = try await send("/v1/chat/completions", method: "POST", body: requestBody(), token: token)
        XCTAssertEqual(denied.0, 401)
        let calls = await engine.calls
        XCTAssertEqual(calls, ["只发送本条文字"])
        await router.stop(); await server.stop(); await runtime.shutdown()
    }
    func testPublicBindIsRejected() async throws {
        let registry = try PairingRegistry(store: MemorySecrets()), runtime = ModelRuntime(engine: StubEngine())
        let identity = try TLSIdentity.load(store: MemorySecrets(), serviceID: await registry.serviceID)
        do {
            _ = try await LocalHTTPServer().start(address: "0.0.0.0", identity: identity, router: APIRouter(registry: registry, runtime: runtime))
            XCTFail("Accepted wildcard listener")
        } catch { XCTAssertEqual((error as? ServiceError)?.code, "no_local_interface") }
    }
    func testConcurrentStopAndListenerRestart() async throws {
        let registry = try PairingRegistry(store: MemorySecrets()), runtime = ModelRuntime(engine: StubEngine())
        let identity = try TLSIdentity.load(store: MemorySecrets(), serviceID: await registry.serviceID)
        let router = APIRouter(registry: registry, runtime: runtime), server = LocalHTTPServer()
        _ = try await server.start(address: "127.0.0.1", identity: identity, router: router, allowLoopbackForTests: true)
        async let first: Void = server.stop()
        async let second: Void = server.stop()
        _ = await (first, second)
        let newPort = try await server.start(address: "127.0.0.1", identity: identity, router: router, allowLoopbackForTests: true)
        XCTAssertGreaterThan(newPort, 0)
        await server.stop()
    }
}
