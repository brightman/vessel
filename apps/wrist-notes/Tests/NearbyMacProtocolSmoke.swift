import Foundation
import Network

private func expect(_ value: @autoclosure () -> Bool, _ message: String) {
    guard value() else { fatalError(message) }
}

@main struct NearbyMacProtocolSmoke {
    static func main() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let service = UUID().uuidString
        let code = "wiselife-mac://pair?v=1&service=\(service)&fingerprint=\(String(repeating: "a", count: 64))&nonce=\(String(repeating: "A", count: 43))&expires=1800000120"
        let parsed = try NearbyMacPairingCode.parse(code, now: now)
        expect(parsed.serviceID == service, "QR keeps opaque identity")
        for invalid in [code + "&nonce=x", code.replacingOccurrences(of: "v=1", with: "v=2"),
                        code.replacingOccurrences(of: "wiselife-mac", with: "https"), code + "#fragment",
                        code.replacingOccurrences(of: "expires=1800000120", with: "expires=1800000900"),
                        code.replacingOccurrences(of: "nonce=" + String(repeating: "A", count: 43), with: "nonce=x"),
                        code.replacingOccurrences(of: "pair?", with: "pair/path?")] {
            do { _ = try NearbyMacPairingCode.parse(invalid, now: now); fatalError("accepted invalid QR") }
            catch NearbyMacFailure.invalidCode { }
        }
        do { _ = try NearbyMacPairingCode.parse(code, now: now.addingTimeInterval(121)); fatalError("accepted expired QR") }
        catch NearbyMacFailure.expiredCode { }
        let content = Data("{\"text\":\"中文\"}".utf8)
        var valid = Data("HTTP/1.1 200 OK\r\nContent-Length: \(content.count)\r\nContent-Type: application/json\r\n\r\n".utf8); valid.append(content)
        let reply = try NearbyMacHTTPS.parse(valid, complete: false)
        expect(reply?.body == content, "HTTP counts bytes, preserving Chinese")
        let partial = try NearbyMacHTTPS.parse(Data(valid.dropLast()), complete: false)
        expect(partial == nil, "fragmented response waits for complete body")
        for invalid in [Data(valid.dropLast()), Data("HTTP/1.1 200 OK\r\nContent-Length: 0\r\nContent-Length: 0\r\n\r\n".utf8),
                        Data("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n0\r\n\r\n".utf8),
                        Data("HTTP/1.1 200 OK\r\nContent-Length: 2000001\r\n\r\n".utf8),
                        Data("HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\nsmuggled".utf8)] {
            do { _ = try NearbyMacHTTPS.parse(invalid, complete: true); fatalError("accepted invalid HTTP framing") }
            catch NearbyMacFailure.response { }
        }
        var config = AIConfiguration(); config.mode = .nearbyMac
        config.contextWindowTokens = 16384
        config.nearbyMacServiceID = service; config.nearbyMacName = "合成测试 Mac"
        let restored = try JSONDecoder().decode(AIConfiguration.self, from: JSONEncoder().encode(config))
        expect(restored == config && restored.isRemote, "Mac provider survives relaunch and retains external-send consent")
        _ = try config.validated(apiKey: "")
        let old = try JSONDecoder().decode(AIConfiguration.self, from: Data(#"{"mode":"local","model":"","baseURL":""}"#.utf8))
        expect(old.nearbyMacServiceID.isEmpty && old.mode == .local, "existing configurations migrate without changing provider")
        do {
            _ = try await NearbyMacClient.shared.generate(content: "private", instruction: "test", configuration: config, isCurrent: { false })
            fatalError("stale request must not discover or send")
        } catch is CancellationError { }
        do {
            _ = try await NearbyMacClient.shared.generate(content: "private", instruction: "test", configuration: config, isCurrent: { true }, authorized: { false })
            fatalError("revoked consent must not discover or send")
        } catch is CancellationError { }
        var invalid = config; invalid.nearbyMacServiceID = "invalid-service"
        for operation in 0..<3 {
            do {
                let transport = CustomAISummarizer()
                if operation == 0 { _ = try await transport.summarize("示例文字", configuration: invalid, apiKey: "", isCurrent: { true }) }
                if operation == 1 { _ = try await transport.answer(question: "问题", context: "[1] 示例文字", configuration: invalid, apiKey: "", isCurrent: { true }) }
                if operation == 2 { _ = try await transport.recordingTitle("示例文字", configuration: invalid, apiKey: "", isCurrent: { true }) }
                fatalError("unpaired Mac must fail without local or cloud fallback")
            } catch NearbyMacFailure.pairing { }
        }
        struct Fixture: Decodable { let port: UInt16; let pin: String }
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])))
        let endpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: fixture.port)!)
        let health = try await NearbyMacHTTPS(endpoint: endpoint, pin: fixture.pin).send(path: "/health", method: "GET", body: Data(), token: nil)
        expect(health.status == 200, "real TLS with exact leaf pin succeeds")
        do {
            _ = try await NearbyMacHTTPS(endpoint: endpoint, pin: String(repeating: "0", count: 64)).send(path: "/health", method: "GET", body: Data(), token: nil)
            fatalError("accepted wrong certificate pin")
        } catch NearbyMacFailure.certificate { }
        let redirect = try await NearbyMacHTTPS(endpoint: endpoint, pin: fixture.pin).send(path: "/redirect", method: "POST", body: Data("synthetic".utf8), token: "synthetic-test-token")
        expect(redirect.status == 302, "redirect is returned, never followed with a bearer token")
        let start = Date()
        let task = Task { try await NearbyMacHTTPS(endpoint: endpoint, pin: fixture.pin).send(path: "/slow", method: "GET", body: Data(), token: nil) }
        try await Task.sleep(for: .milliseconds(100)); task.cancel()
        do { _ = try await task.value; fatalError("cancelled request completed") } catch is CancellationError { }
        expect(Date().timeIntervalSince(start) < 2, "cancellation closes transport promptly")
        print("PASS Nearby Mac: strict QR, migration, HTTP framing, real pinned TLS, wrong-pin rejection, redirect isolation and cancellation")
    }
}
