import XCTest
@testable import CompanionCore

final class RouterTests: XCTestCase {
    func testPausingWhilePairingCancelsInferenceButKeepsPairingAvailable() async throws {
        let engine = StubEngine(delay: .seconds(2)), runtime = try await readyRuntime(engine: engine)
        let registry = try PairingRegistry(store: MemorySecrets())
        let code = try await registry.open(fingerprint: "pin"), device = UUID()
        let token = try await registry.pair(nonce: code.nonce, deviceID: device, name: "phone", peer: "local")
        _ = try await registry.open(fingerprint: "pin")
        let router = APIRouter(registry: registry, runtime: runtime)
        await router.setAvailable(true)
        let task = Task { await router.handle(method: "POST", path: "/v1/chat/completions", authorization: "Bearer " + token, body: try requestBody(), peer: "local") }
        try await waitUntil { await runtime.snapshot().active }
        await router.setAvailable(false)
        let response = try await task.value
        XCTAssertEqual(response.status, 409)
        let open = await registry.isPairing()
        XCTAssertTrue(open)
        let paused = await router.handle(method: "GET", path: "/v1/models", authorization: "Bearer " + token, body: Data(), peer: "local")
        XCTAssertEqual(paused.status, 503)
        await runtime.shutdown()
    }
    func testRePairRotatesOldCredential() async throws {
        let registry = try PairingRegistry(store: MemorySecrets()), device = UUID()
        let first = try await registry.open(fingerprint: "pin")
        let old = try await registry.pair(nonce: first.nonce, deviceID: device, name: "phone", peer: "local")
        let second = try await registry.open(fingerprint: "pin")
        let new = try await registry.pair(nonce: second.nonce, deviceID: device, name: "phone", peer: "local")
        XCTAssertNotEqual(old, new)
        do { _ = try await registry.authenticate("Bearer " + old); XCTFail("Old credential accepted") } catch { XCTAssertEqual(error as? ServiceError, .unauthorized) }
        let paired = try await registry.authenticate("Bearer " + new)
        XCTAssertEqual(paired.id, device)
    }
}
