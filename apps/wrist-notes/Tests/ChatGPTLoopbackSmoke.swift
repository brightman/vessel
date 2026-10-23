import Foundation

private func expect(_ value: @autoclosure () -> Bool, _ message: String) {
    if !value() { fatalError(message) }
}

@main
struct ChatGPTLoopbackSmoke {
    static func main() async throws {
        let callback = URL(string: "http://127.0.0.1:49152/auth/callback")!
        let parser = ChatGPTLoopbackRequestParser(callbackURL: callback, expectedState: "opaque-state")
        let valid = "GET /auth/callback?code=private-code&state=opaque-state HTTP/1.1\r\nHost: ignored\r\n\r\n"
        expect(parser.parse(Data(valid.utf8)) == .callback(URL(string: "http://127.0.0.1:49152/auth/callback?code=private-code&state=opaque-state")!), "matching callback returns exact URL")
        expect(parser.parse(Data("GET /auth/callback?state=opaque-state".utf8)) == .needMore, "fragmented first line waits for CRLF")
        let rejected = [
            "POST /auth/callback?state=opaque-state HTTP/1.1\r\n",
            "GET /favicon.ico?state=opaque-state HTTP/1.1\r\n",
            "GET /auth/callback/extra?state=opaque-state HTTP/1.1\r\n",
            "GET /auth/%63allback?state=opaque-state HTTP/1.1\r\n",
            "GET /auth/callback?state=wrong HTTP/1.1\r\n",
            "GET /auth/callback?code=private-code HTTP/1.1\r\n",
            "GET /auth/callback?state=opaque-state&state=opaque-state HTTP/1.1\r\n",
            "GET /auth/callback?state=opaque-state#fragment HTTP/1.1\r\n",
            "GET http://127.0.0.1:49152/auth/callback?state=opaque-state HTTP/1.1\r\n",
            "GET //evil.example/auth/callback?state=opaque-state HTTP/1.1\r\n",
            "GET /auth/callback?state=opaque-state HTTP/2\r\n",
            "GET /auth/callback?state=opaque-state%00 HTTP/1.1\r\n",
            "GET /auth/callback?state=opaque-state&bad=%GG HTTP/1.1\r\n",
            "GET /auth/callback?state=opaque-state HTTP/1.1\n",
            String(repeating: "a", count: 4097),
            valid + String(repeating: "a", count: 8193)
        ]
        for request in rejected {
            expect(parser.parse(Data(request.utf8)) == .rejected, "malformed/unmatched request rejected")
        }
        expect(parser.parse(Data("GET /auth/callback?error=access_denied&state=opaque-state HTTP/1.0\r\n".utf8)) == .callback(URL(string: "http://127.0.0.1:49152/auth/callback?error=access_denied&state=opaque-state")!), "matching OAuth error reaches core validation")
        try await liveListener()
        print("ChatGPT loopback parser and listener smoke passed")
    }

    @MainActor private static func liveListener() async throws {
        let loopback = ChatGPTLoopback()
        let callback = try await loopback.start()
        expect(callback.host == "127.0.0.1" && callback.port != nil && callback.port != 0, "loopback binds IPv4 localhost at ephemeral port")
        expect(callback.path == "/auth/callback", "loopback uses documented path")
        loopback.expectedState = "network-state"
        var delivered: URL?
        loopback.onCallback = { delivered = $0 }
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 3
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel(); loopback.stop() }
        let wrong = URL(string: callback.absoluteString + "?state=wrong&code=ignored")!
        let (_, rejected) = try await session.data(from: wrong)
        expect((rejected as? HTTPURLResponse)?.statusCode == 400, "bad state gets static rejection")
        expect(delivered == nil, "bad state does not complete authorization")
        let correct = URL(string: callback.absoluteString + "?state=network-state&code=never-log")!
        let (body, accepted) = try await session.data(from: correct)
        expect((accepted as? HTTPURLResponse)?.statusCode == 200, "matching callback accepted")
        expect(delivered == correct, "listener returns the matched callback")
        expect(!String(decoding: body, as: UTF8.self).contains("never-log"), "browser response never echoes code")
        loopback.stop()
        do {
            _ = try await session.data(from: correct)
            fatalError("stopped listener accepted a new request")
        } catch {}
        let cancelled = ChatGPTLoopback()
        let task = Task { try await cancelled.start() }
        task.cancel()
        do {
            _ = try await task.value
            fatalError("cancelled listener start succeeded")
        } catch is CancellationError {}
    }
}
