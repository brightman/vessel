import XCTest
@testable import CompanionCore

final class PairingTests: XCTestCase {
    func testSingleUseExpirationRevocationAndPersistence() async throws {
        let store = MemorySecrets(), now = Date()
        let registry = try PairingRegistry(store: store)
        let code = try await registry.open(fingerprint: String(repeating: "a", count: 64), now: now)
        XCTAssertEqual(code.nonce.count, 43)
        XCTAssertFalse(code.url.absoluteString.contains("127.0.0.1"))
        let id = UUID()
        let token = try await registry.pair(nonce: code.nonce, deviceID: id, name: "测试 iPhone", peer: "192.168.0.2", now: now)
        let restored = try PairingRegistry(store: store)
        let device = try await restored.authenticate("Bearer " + token)
        XCTAssertEqual(device.id, id)
        let stored = String(data: try XCTUnwrap(store.read("paired-devices")), encoding: .utf8)!
        XCTAssertFalse(stored.contains(token)); XCTAssertFalse(stored.contains(code.nonce))
        do { _ = try await registry.pair(nonce: code.nonce, deviceID: id, name: "replay", peer: "192.168.0.2", now: now); XCTFail("Accepted replay") } catch { }
        let expired = try await registry.open(fingerprint: "pin", now: now)
        do { _ = try await registry.pair(nonce: expired.nonce, deviceID: id, name: "expired", peer: "192.168.0.2", now: now.addingTimeInterval(121)); XCTFail("Accepted expired nonce") } catch { }
        try await restored.revoke(id)
        do { _ = try await restored.authenticate("Bearer " + token); XCTFail("Accepted revoked token") } catch { XCTAssertEqual(error as? ServiceError, .unauthorized) }
        let serviceID = await registry.serviceID, restoredID = await restored.serviceID
        XCTAssertEqual(serviceID, restoredID)
    }
    func testRateLimitAndWrongTokens() async throws {
        let registry = try PairingRegistry(store: MemorySecrets())
        _ = try await registry.open(fingerprint: "pin")
        for _ in 0..<5 { do { _ = try await registry.pair(nonce: "wrong", deviceID: UUID(), name: "phone", peer: "same") } catch { } }
        do { _ = try await registry.pair(nonce: "wrong", deviceID: UUID(), name: "phone", peer: "same"); XCTFail("Not rate limited") }
        catch { XCTAssertEqual((error as? ServiceError)?.code, "pairing_rate_limited") }
        for token in [nil, "", "Basic abc", "Bearer invalid"] {
            do { _ = try await registry.authenticate(token); XCTFail("Accepted invalid token") } catch { }
        }
    }
    func testTLSIdentityIsStableAndPinMatchesDER() throws {
        let store = MemorySecrets(), serviceID = UUID().uuidString
        let first = try TLSIdentity.load(store: store, serviceID: serviceID)
        let second = try TLSIdentity.load(store: store, serviceID: serviceID)
        XCTAssertEqual(first.fingerprint, second.fingerprint)
        XCTAssertEqual(first.fingerprint, Secrets.hash(first.certificateDER))
        XCTAssertNotEqual(first.fingerprint, try TLSIdentity.load(store: MemorySecrets(), serviceID: serviceID).fingerprint)
    }
}
