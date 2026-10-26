import Foundation
import Network
import Security
import CryptoKit

enum NearbyMacFailure: LocalizedError, Equatable {
    case invalidCode, expiredCode, unavailable, permission, certificate, pairing, modelNotReady, paused, busy, context, response
    var errorDescription: String? {
        switch self {
        case .invalidCode: "请扫描 WiseLife Mac Companion 的配对码。"
        case .expiredCode: "配对码已过期，请在 Mac 上重新生成。"
        case .unavailable: "无法连接已配对的 Mac。请保持桌面端运行，并连接可互通的同一 Wi-Fi 后重试。"
        case .permission: "请在 iPhone 设置中允许 WiseLife 访问本地网络，然后重试。"
        case .certificate: "Mac 的安全身份与配对码不一致，未发送文字。请重新配对。"
        case .pairing: "配对无效或已撤销，请重新扫描 Mac 配对码。"
        case .modelNotReady: "Mac 模型尚未就绪，请在桌面端下载并加载模型。"
        case .paused: "Mac 已暂停本地 AI，请在桌面端开启服务。"
        case .busy: "Mac 正在处理其他请求，请稍后重试。"
        case .context: "本次文字超过 Mac 模型的上下文限制，请减少选中的内容后重试。"
        case .response: "Mac 未返回完整有效的结果，请重试。"
        }
    }
}

struct NearbyMacPairingCode: Equatable, Sendable {
    let serviceID: String
    let fingerprint: String
    let nonce: String
    let expiresAt: Date
    static func parse(_ value: String, now: Date = .now) throws -> Self {
        guard value.utf8.count < 2_048, let parts = URLComponents(string: value.trimmingCharacters(in: .whitespacesAndNewlines)),
              parts.scheme == "wiselife-mac", parts.host == "pair", parts.path.isEmpty,
              parts.user == nil, parts.password == nil, parts.port == nil, parts.fragment == nil,
              let items = parts.queryItems, items.count == 5,
              Set(items.map(\.name)) == ["v", "service", "fingerprint", "nonce", "expires"] else { throw NearbyMacFailure.invalidCode }
        func field(_ name: String) -> String { items.first { $0.name == name }?.value ?? "" }
        let service = field("service"), pin = field("fingerprint"), nonce = field("nonce")
        guard field("v") == "1", UUID(uuidString: service) != nil,
              pin.count == 64, pin.allSatisfy(\.isHexDigit), nonce.count == 43,
              nonce.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 95 }),
              let seconds = TimeInterval(field("expires")), seconds.isFinite else { throw NearbyMacFailure.invalidCode }
        let expiry = Date(timeIntervalSince1970: seconds)
        guard expiry > now else { throw NearbyMacFailure.expiredCode }
        guard expiry.timeIntervalSince(now) <= 180 else { throw NearbyMacFailure.invalidCode }
        return .init(serviceID: service, fingerprint: pin.lowercased(), nonce: nonce, expiresAt: expiry)
    }
}

struct NearbyMacPeer: Codable, Equatable, Sendable {
    let serviceID: String
    let name: String
    let deviceID: UUID
    let fingerprint: String
    let token: String
}

/// Credentials, including the pinned identity, stay together in this app's Keychain.
enum NearbyMacKeychain {
    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: (Bundle.main.bundleIdentifier ?? "cloud.karama.wisenote") + ".nearby-mac",
         kSecAttrAccount as String: "paired-mac-v1"]
    }
    static func read() throws -> NearbyMacPeer? {
        var q = query; q[kSecReturnData as String] = true; q[kSecMatchLimit as String] = kSecMatchLimitOne
        var value: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &value)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = value as? Data else { throw NearbyMacFailure.pairing }
        guard let peer = try? JSONDecoder().decode(NearbyMacPeer.self, from: data) else { throw NearbyMacFailure.pairing }
        return peer
    }
    static func write(_ peer: NearbyMacPeer) throws {
        let data = try JSONEncoder().encode(peer)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var q = query; q[kSecValueData as String] = data
            q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            guard SecItemAdd(q as CFDictionary, nil) == errSecSuccess else { throw NearbyMacFailure.pairing }
        } else if status != errSecSuccess { throw NearbyMacFailure.pairing }
    }
    static func remove() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw NearbyMacFailure.pairing }
    }
}

actor NearbyMacClient {
    static let shared = NearbyMacClient()
    func peer() throws -> NearbyMacPeer? { try NearbyMacKeychain.read() }

    func pair(_ text: String, deviceName: String) async throws -> NearbyMacPeer {
        let code = try NearbyMacPairingCode.parse(text)
        let endpoint = try await NearbyMacDiscovery(serviceID: code.serviceID).resolve()
        try Task.checkCancellation()
        guard code.expiresAt > .now else { throw NearbyMacFailure.expiredCode }
        let deviceID = try NearbyMacKeychain.read()?.deviceID ?? UUID()
        let body = try JSONSerialization.data(withJSONObject: ["nonce": code.nonce, "device_id": deviceID.uuidString,
            "device_name": String(deviceName.prefix(100))])
        let response = try await exchange(endpoint: endpoint, pin: code.fingerprint, path: "/pair", method: "POST", body: body)
        guard response["protocol_version"] as? Int == 1,
              response["service_id"] as? String == code.serviceID,
              response["device_id"] as? String == deviceID.uuidString,
              let token = response["token"] as? String, token.count >= 32, token.count <= 256,
              !token.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { throw NearbyMacFailure.response }
        let name = String((response["server_name"] as? String ?? "我的 Mac").prefix(100))
        let peer = NearbyMacPeer(serviceID: code.serviceID, name: name, deviceID: deviceID, fingerprint: code.fingerprint, token: token)
        do { try Task.checkCancellation(); try NearbyMacKeychain.write(peer) }
        catch {
            // Do not leave an orphaned Mac credential if this iPhone cannot persist its token.
            _ = try? await exchange(endpoint: endpoint, pin: peer.fingerprint, path: "/pair", method: "DELETE", token: peer.token)
            throw error
        }
        return peer
    }

    func readiness(serviceID: String) async throws -> String {
        let peer = try authenticatedPeer(serviceID)
        let endpoint = try await NearbyMacDiscovery(serviceID: serviceID).resolve()
        return try await model(endpoint: endpoint, peer: peer)
    }

    func generate(content: String, instruction: String, configuration: AIConfiguration,
                  isCurrent: @escaping @MainActor () -> Bool, authorized: @escaping @MainActor () async throws -> Bool = { true }) async throws -> String {
        try Task.checkCancellation()
        guard await isCurrent(), try await authorized() else { throw CancellationError() }
        // Discover without reading a bearer credential. Recheck consent/revision after discovery.
        let endpoint = try await NearbyMacDiscovery(serviceID: configuration.nearbyMacServiceID).resolve()
        guard await isCurrent(), try await authorized() else { throw CancellationError() }
        let peer = try authenticatedPeer(configuration.nearbyMacServiceID)
        let modelID = try await model(endpoint: endpoint, peer: peer)
        guard await isCurrent(), try await authorized() else { throw CancellationError() }
        guard try authenticatedPeer(configuration.nearbyMacServiceID) == peer else { throw NearbyMacFailure.pairing }
        let body = try JSONSerialization.data(withJSONObject: ["model": modelID, "stream": false, "max_tokens": 2_048,
            "temperature": 0.2, "messages": [["role": "system", "content": instruction], ["role": "user", "content": content]]])
        guard body.count <= 1_048_576 else { throw NearbyMacFailure.context }
        let response = try await exchange(endpoint: endpoint, pin: peer.fingerprint, path: "/v1/chat/completions", method: "POST", body: body, token: peer.token)
        try Task.checkCancellation()
        guard await isCurrent(), try await authorized() else { throw CancellationError() }
        guard let choices = response["choices"] as? [[String: Any]], let choice = choices.first,
              choice["finish_reason"] as? String == "stop",
              let message = choice["message"] as? [String: Any], let text = message["content"] as? String,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw NearbyMacFailure.response }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func unpair(localOnly: Bool = false) async throws {
        guard let peer = try NearbyMacKeychain.read() else { return }
        if !localOnly {
            let endpoint = try await NearbyMacDiscovery(serviceID: peer.serviceID).resolve()
            _ = try await exchange(endpoint: endpoint, pin: peer.fingerprint, path: "/pair", method: "DELETE", token: peer.token)
        }
        try NearbyMacKeychain.remove()
    }
    private func authenticatedPeer(_ serviceID: String) throws -> NearbyMacPeer {
        guard !serviceID.isEmpty, let peer = try NearbyMacKeychain.read(), peer.serviceID == serviceID else { throw NearbyMacFailure.pairing }
        return peer
    }
    private func model(endpoint: NWEndpoint, peer: NearbyMacPeer) async throws -> String {
        let value = try await exchange(endpoint: endpoint, pin: peer.fingerprint, path: "/v1/models", token: peer.token)
        guard let models = value["data"] as? [[String: Any]], models.count == 1,
              let item = models.first, item["ready"] as? Bool == true, let id = item["id"] as? String, !id.isEmpty else {
            throw NearbyMacFailure.modelNotReady
        }
        return id
    }
    private func exchange(endpoint: NWEndpoint, pin: String, path: String, method: String = "GET", body: Data = Data(), token: String? = nil) async throws -> [String: Any] {
        let response = try await NearbyMacHTTPS(endpoint: endpoint, pin: pin).send(path: path, method: method, body: body, token: token)
        let object = (try? JSONSerialization.jsonObject(with: response.body)) as? [String: Any] ?? [:]
        let code = (object["error"] as? [String: Any])?["code"] as? String
        guard response.status == 200 else {
            switch (response.status, code) {
            case (401, _): throw NearbyMacFailure.pairing
            case (429, _): throw NearbyMacFailure.busy
            case (_, "model_not_ready"): throw NearbyMacFailure.modelNotReady
            case (_, "service_paused"): throw NearbyMacFailure.paused
            case (_, "context_length_exceeded"), (413, _): throw NearbyMacFailure.context
            case (504, _): throw AIServiceError.timedOut
            case (409, _): throw CancellationError()
            default: throw NearbyMacFailure.response
            }
        }
        return object
    }
}

/// Each operation owns its browser, timeout and cancellation. No host/port is persisted.
private final class NearbyMacDiscovery: @unchecked Sendable {
    let serviceID: String
    private let queue = DispatchQueue(label: "WiseLife.NearbyMac.Discovery")
    private var browser: NWBrowser?
    private var continuation: CheckedContinuation<NWEndpoint, Error>?
    private var finished = false
    init(serviceID: String) { self.serviceID = serviceID }
    func resolve() async throws -> NWEndpoint {
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                queue.async { [self] in
                    guard !finished else { continuation.resume(throwing: CancellationError()); return }
                    self.continuation = continuation
                    guard UUID(uuidString: serviceID) != nil else { finish(.failure(NearbyMacFailure.pairing)); return }
                    let parameters = NWParameters.tcp; parameters.includePeerToPeer = true
                    let browser = NWBrowser(for: .bonjour(type: "_wiselife-llm._tcp", domain: nil), using: parameters)
                    self.browser = browser
                    browser.browseResultsChangedHandler = { [weak self] results, _ in
                        guard let self else { return }
                        if let result = results.first(where: {
                            if case .service(let name, _, _, _) = $0.endpoint { return name == self.serviceID }
                            return false
                        }) { self.finish(.success(result.endpoint)) }
                    }
                    browser.stateUpdateHandler = { [weak self] state in
                        if case .failed = state { self?.finish(.failure(NearbyMacFailure.unavailable)) }
                        if case .waiting(let error) = state,
                           case .dns(let code) = error, code == -65570 { self?.finish(.failure(NearbyMacFailure.permission)) }
                    }
                    browser.start(queue: queue)
                    queue.asyncAfter(deadline: .now() + 12) { [weak self] in self?.finish(.failure(NearbyMacFailure.unavailable)) }
                }
            }
        }, onCancel: { self.queue.async { self.finish(.failure(CancellationError())) } })
    }
    private func finish(_ result: Result<NWEndpoint, Error>) {
        guard !finished else { return }; finished = true
        browser?.cancel(); browser = nil
        let callback = continuation; continuation = nil; callback?.resume(with: result)
    }
}

/// Direct TLS to the Bonjour endpoint; verify the exact QR-pinned leaf before sending headers/body.
/// One bounded, non-redirected HTTP/1.1 exchange per connection, matching the Mac API contract.
final class NearbyMacHTTPS: @unchecked Sendable {
    struct Response { let status: Int; let body: Data }
    private let endpoint: NWEndpoint
    private let pin: String
    private let queue = DispatchQueue(label: "WiseLife.NearbyMac.HTTPS")
    private var connection: NWConnection?
    private var continuation: CheckedContinuation<Response, Error>?
    private var finished = false
    private var bytes = Data()
    init(endpoint: NWEndpoint, pin: String) { self.endpoint = endpoint; self.pin = pin }
    func send(path: String, method: String, body: Data, token: String?) async throws -> Response {
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                queue.async { [self] in
                    guard !finished else { continuation.resume(throwing: CancellationError()); return }
                    self.continuation = continuation
                    let tls = NWProtocolTLS.Options()
                    sec_protocol_options_set_min_tls_protocol_version(tls.securityProtocolOptions, .TLSv12)
                    sec_protocol_options_add_tls_application_protocol(tls.securityProtocolOptions, "http/1.1")
                    sec_protocol_options_set_verify_block(tls.securityProtocolOptions, { [weak self] _, trust, complete in
                        let securityTrust = sec_trust_copy_ref(trust).takeRetainedValue()
                        guard let self, let leaf = (SecTrustCopyCertificateChain(securityTrust) as? [SecCertificate])?.first else { complete(false); return }
                        let digest = SHA256.hash(data: SecCertificateCopyData(leaf) as Data).map { String(format: "%02x", $0) }.joined()
                        let matches = digest == self.pin
                        complete(matches)
                        if !matches { self.finish(.failure(NearbyMacFailure.certificate)) }
                    }, queue)
                    let parameters = NWParameters(tls: tls, tcp: NWProtocolTCP.Options()); parameters.includePeerToPeer = true
                    let connection = NWConnection(to: endpoint, using: parameters)
                    self.connection = connection
                    connection.stateUpdateHandler = { [weak self] state in
                        guard let self, !self.finished else { return }
                        switch state {
                        case .ready:
                            var header = "\(method) \(path) HTTP/1.1\r\nHost: wiselife.local\r\nAccept: application/json\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\n"
                            if let token { header += "Authorization: Bearer \(token)\r\n" }
                            var data = Data((header + "\r\n").utf8); data.append(body)
                            connection.send(content: data, completion: .contentProcessed { [weak self] error in
                                if error != nil { self?.finish(.failure(NearbyMacFailure.unavailable)) }
                                else { self?.receive() }
                            })
                        case .failed: self.finish(.failure(NearbyMacFailure.unavailable))
                        case .cancelled: self.finish(.failure(CancellationError()))
                        default: break
                        }
                    }
                    connection.start(queue: queue)
                    queue.asyncAfter(deadline: .now() + 125) { [weak self] in self?.finish(.failure(AIServiceError.timedOut)) }
                }
            }
        }, onCancel: { self.queue.async { self.finish(.failure(CancellationError())) } })
    }
    private func receive() {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, complete, error in
            guard let self, !self.finished else { return }
            if let data { self.bytes.append(data) }
            guard self.bytes.count <= 2_100_000 else { self.finish(.failure(NearbyMacFailure.response)); return }
            do {
                if let response = try Self.parse(self.bytes, complete: complete) { self.finish(.success(response)); return }
            } catch { self.finish(.failure(error)); return }
            if error != nil || complete { self.finish(.failure(NearbyMacFailure.response)) }
            else { self.receive() }
        }
    }
    static func parse(_ data: Data, complete: Bool) throws -> Response? {
        guard let separator = data.range(of: Data("\r\n\r\n".utf8)) else {
            if data.count > 32_768 || complete { throw NearbyMacFailure.response }; return nil
        }
        guard separator.lowerBound <= 32_768,
              let header = String(data: data[..<separator.lowerBound], encoding: .utf8) else { throw NearbyMacFailure.response }
        let lines = header.components(separatedBy: "\r\n")
        let statusLine = lines[0].split(separator: " ")
        guard statusLine.count >= 2, statusLine[0] == "HTTP/1.1", let status = Int(statusLine[1]) else { throw NearbyMacFailure.response }
        var lengths: [Int] = []
        for line in lines.dropFirst() {
            let fields = line.split(separator: ":", maxSplits: 1).map(String.init)
            guard fields.count == 2 else { throw NearbyMacFailure.response }
            if fields[0].lowercased() == "transfer-encoding" { throw NearbyMacFailure.response }
            if fields[0].lowercased() == "content-length" {
                guard let length = Int(fields[1].trimmingCharacters(in: .whitespaces)), (0...2_000_000).contains(length) else { throw NearbyMacFailure.response }
                lengths.append(length)
            }
        }
        guard lengths.count == 1, let length = lengths.first else { throw NearbyMacFailure.response }
        let body = data[separator.upperBound...]
        guard body.count <= length else { throw NearbyMacFailure.response }
        if body.count == length { return .init(status: status, body: Data(body)) }
        if complete { throw NearbyMacFailure.response }
        return nil
    }
    private func finish(_ result: Result<Response, Error>) {
        guard !finished else { return }; finished = true
        let callback = continuation; continuation = nil
        connection?.cancel(); connection = nil; bytes.removeAll()
        callback?.resume(with: result)
    }
}
