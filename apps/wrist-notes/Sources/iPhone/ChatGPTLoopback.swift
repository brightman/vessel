import Foundation

/// Parses only a bounded HTTP request line; headers and callback data are never logged.
struct ChatGPTLoopbackRequestParser {
    enum Result: Equatable { case needMore, rejected, callback(URL) }
    static let maximumRequestBytes = 8192
    static let maximumLineBytes = 4096
    let callbackURL: URL
    let expectedState: String

    func parse(_ bytes: Data) -> Result {
        guard bytes.count <= Self.maximumRequestBytes else { return .rejected }
        guard let ending = bytes.range(of: Data([13, 10])) else {
            return bytes.count > Self.maximumLineBytes || bytes.contains(10) ? .rejected : .needMore
        }
        let line = bytes[..<ending.lowerBound]
        guard line.count <= Self.maximumLineBytes,
              line.allSatisfy({ $0 >= 32 && $0 < 127 }),
              let text = String(data: line, encoding: .ascii) else { return .rejected }
        let parts = text.split(separator: " ", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0] == "GET", ["HTTP/1.0", "HTTP/1.1"].contains(parts[2]) else { return .rejected }
        let target = String(parts[1])
        guard target.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).first == "/auth/callback",
              !target.contains("#"), validPercentEncoding(target),
              let url = URL(string: callbackURL.absoluteString + String(target.dropFirst("/auth/callback".count))),
              let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else { return .rejected }
        let states = query.filter { $0.name == "state" }
        guard states.count == 1, let state = states.first?.value,
              !expectedState.isEmpty, constantTimeEqual(state, expectedState) else { return .rejected }
        return .callback(url)
    }

    private func validPercentEncoding(_ target: String) -> Bool {
        let bytes = Array(target.utf8)
        let hex: (UInt8) -> Bool = { (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }
        var index = 0
        while index < bytes.count {
            if bytes[index] == 37 {
                guard index + 2 < bytes.count, hex(bytes[index + 1]), hex(bytes[index + 2]) else { return false }
                index += 3
            } else { index += 1 }
        }
        return true
    }

    private func constantTimeEqual(_ left: String, _ right: String) -> Bool {
        let lhs = Array(left.utf8), rhs = Array(right.utf8)
        guard lhs.count == rhs.count else { return false }
        var difference: UInt8 = 0
        for index in lhs.indices { difference |= lhs[index] ^ rhs[index] }
        return difference == 0
    }
}

#if canImport(Network)
@preconcurrency import Network

/// One-use listener. All Network callbacks hop to the main actor before touching state.
@MainActor
final class ChatGPTLoopback {
    enum Failure: Error { case unavailable }
    var expectedState: String?
    var onCallback: ((URL) -> Void)?
    var onFailure: (() -> Void)?
    private var listener: NWListener?
    private var startContinuation: CheckedContinuation<URL, Error>?
    private var callbackURL: URL?
    private var started = false
    private var stopped = false
    private var delivered = false
    private struct Client {
        let connection: NWConnection
        var data = Data()
        var timeout: Task<Void, Never>?
    }
    private var clients: [UUID: Client] = [:]

    func start() async throws -> URL {
        try Task.checkCancellation()
        guard !started, !stopped else { throw Failure.unavailable }
        started = true
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                startContinuation = continuation
                do {
                    let parameters = NWParameters.tcp
                    parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
                    parameters.allowLocalEndpointReuse = false
                    parameters.acceptLocalOnly = true
                    parameters.includePeerToPeer = false
                    let listener = try NWListener(using: parameters)
                    self.listener = listener
                    listener.stateUpdateHandler = { [weak self] state in
                        Task { @MainActor in self?.listenerChanged(state) }
                    }
                    listener.newConnectionHandler = { [weak self] connection in
                        Task { @MainActor in
                            guard let self else { connection.cancel(); return }
                            self.accept(connection)
                        }
                    }
                    listener.start(queue: .main)
                } catch { fail() }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.stop() }
        }
    }

    func stop() {
        guard !stopped else { return }
        stopped = true
        onCallback = nil
        onFailure = nil
        listener?.stateUpdateHandler = nil
        listener?.newConnectionHandler = nil
        listener?.cancel()
        listener = nil
        for client in clients.values {
            client.timeout?.cancel()
            client.connection.cancel()
        }
        clients.removeAll()
        let continuation = startContinuation
        startContinuation = nil
        continuation?.resume(throwing: CancellationError())
    }

    private func listenerChanged(_ state: NWListener.State) {
        guard !stopped else { return }
        switch state {
        case .ready:
            guard let port = listener?.port, port.rawValue != 0,
                  let url = URL(string: "http://127.0.0.1:\(port.rawValue)/auth/callback") else { fail(); return }
            callbackURL = url
            let continuation = startContinuation
            startContinuation = nil
            continuation?.resume(returning: url)
        case .failed: fail()
        default: break
        }
    }

    private func fail() {
        guard !stopped else { return }
        let continuation = startContinuation
        startContinuation = nil
        let failure = onFailure
        stop()
        continuation?.resume(throwing: Failure.unavailable)
        failure?()
    }

    private func accept(_ connection: NWConnection) {
        guard !stopped, !delivered, clients.count < 8 else { connection.cancel(); return }
        let id = UUID()
        let timeout = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(3)) } catch { return }
            self?.removeClient(id)
        }
        clients[id] = Client(connection: connection, timeout: timeout)
        connection.start(queue: .main)
        receive(id)
    }

    private func receive(_ id: UUID) {
        guard let client = clients[id], !stopped else { return }
        client.connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, complete, error in
            Task { @MainActor in self?.received(data, complete: complete, failed: error != nil, id: id) }
        }
    }

    private func received(_ data: Data?, complete: Bool, failed: Bool, id: UUID) {
        guard var client = clients[id], !stopped else { return }
        if let data { client.data.append(data) }
        clients[id] = client
        guard let callbackURL, let expectedState else { respond(id, callback: nil); return }
        let result = ChatGPTLoopbackRequestParser(callbackURL: callbackURL, expectedState: expectedState).parse(client.data)
        switch result {
        case .needMore:
            if complete || failed { removeClient(id) } else { receive(id) }
        case .rejected: respond(id, callback: nil)
        case .callback(let url):
            guard !delivered else { respond(id, callback: nil); return }
            delivered = true
            respond(id, callback: url)
        }
    }

    private func respond(_ id: UUID, callback: URL?) {
        guard let client = clients[id] else { return }
        let status = callback == nil ? "400 Bad Request" : "200 OK"
        let body = callback == nil ? "Request rejected." : "Sign-in received. You can return to WiseLife."
        let response = "HTTP/1.1 \(status)\r\nContent-Type: text/plain; charset=utf-8\r\nCache-Control: no-store\r\nContent-Security-Policy: default-src 'none'\r\nConnection: close\r\nContent-Length: \(body.utf8.count)\r\n\r\n\(body)"
        client.connection.send(content: Data(response.utf8), completion: .contentProcessed { [weak self] _ in
            Task { @MainActor in
                guard let self, !self.stopped, self.clients[id] != nil else { return }
                self.removeClient(id)
                if let callback { self.onCallback?(callback) }
            }
        })
    }

    private func removeClient(_ id: UUID) {
        guard let client = clients.removeValue(forKey: id) else { return }
        client.timeout?.cancel()
        client.connection.cancel()
    }
}
#endif
