import Foundation
import Network
import Security

/// One bounded request per TLS connection. Credentials are never sent before certificate pinning.
final class SyncConnection: @unchecked Sendable {
    static let maximumFrame = 8 * 1024 * 1024
    let connection: NWConnection
    private let queue = DispatchQueue(label: "WiseLife.Sync.Connection")
    private var timeout: DispatchWorkItem?
    private var startCompleted = false
    init(connection: NWConnection) { self.connection = connection }
    func start() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.stateUpdateHandler = { [weak self] state in
                guard let self, !self.startCompleted else { return }
                switch state {
                case .ready: self.startCompleted = true; continuation.resume()
                case .failed, .cancelled: self.startCompleted = true; continuation.resume(throwing: DesktopSyncError.network)
                default: break
                }
            }
            let timeout = DispatchWorkItem { [weak self] in self?.connection.cancel() }
            self.timeout = timeout
            queue.asyncAfter(deadline: .now() + 30, execute: timeout)
            connection.start(queue: queue)
        }
    }
    func close() { timeout?.cancel(); connection.cancel() }
    func send<T: Encodable>(_ value: T) async throws {
        let data = try DesktopSyncCodec.encode(value)
        guard data.count <= Self.maximumFrame else { throw DesktopSyncError.invalid("单条录音文字过大，暂无法同步。") }
        var length = UInt32(data.count).bigEndian
        var frame = Data(bytes: &length, count: 4); frame.append(data)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: frame, completion: .contentProcessed { error in
                if error != nil { continuation.resume(throwing: DesktopSyncError.network) } else { continuation.resume() }
            })
        }
    }
    func receive<T: Decodable>(_ type: T.Type) async throws -> T {
        let header = try await read(count: 4)
        let length = header.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        guard length > 0, length <= Self.maximumFrame else { throw DesktopSyncError.invalid("同步消息大小无效。") }
        let data = try await read(count: Int(length))
        return try DesktopSyncCodec.decode(type, data)
    }
    private func read(count: Int) async throws -> Data {
        var result = Data()
        while result.count < count {
            let remaining = count - result.count
            let piece: Data = try await withCheckedThrowingContinuation { continuation in
                connection.receive(minimumIncompleteLength: 1, maximumLength: remaining) { data, _, done, error in
                    guard error == nil, let data, !data.isEmpty else { continuation.resume(throwing: DesktopSyncError.network); return }
                    continuation.resume(returning: data)
                }
            }
            result.append(piece)
        }
        return result
    }
    static func exchange(_ request: DesktopSyncRequest, code: DesktopPairingCode, host: String? = nil, port: UInt16? = nil, endpoint: NWEndpoint? = nil) async throws -> DesktopSyncResponse {
        let tls = NWProtocolTLS.Options()
        sec_protocol_options_set_min_tls_protocol_version(tls.securityProtocolOptions, .TLSv12)
        sec_protocol_options_set_verify_block(tls.securityProtocolOptions, { _, trust, complete in
            let trust = sec_trust_copy_ref(trust).takeRetainedValue()
            guard let certificates = SecTrustCopyCertificateChain(trust) as? [SecCertificate], let certificate = certificates.first else { complete(false); return }
            let hash = DesktopSyncCodec.hash(SecCertificateCopyData(certificate) as Data)
            complete(DesktopSyncCodec.tokenMatches(hash, code.certificateHash))
        }, DispatchQueue(label: "WiseLife.Sync.Certificate"))
        let target = host ?? code.host
        guard DesktopPairingCode.isLocalHost(target), let endpointPort = NWEndpoint.Port(rawValue: port ?? code.port) else { throw DesktopSyncError.invalid("仅支持局域网同步地址。") }
        let destination = endpoint ?? .hostPort(host: NWEndpoint.Host(target), port: endpointPort)
        let channel = SyncConnection(connection: NWConnection(to: destination, using: NWParameters(tls: tls)))
        defer { channel.close() }
        return try await withTaskCancellationHandler(operation: {
            try await channel.start(); try Task.checkCancellation()
            try await channel.send(request)
            let response = try await channel.receive(DesktopSyncResponse.self)
            guard response.version == 1, response.serverID == code.serverID else { throw DesktopSyncError.invalid("桌面端协议不匹配，请更新两端。") }
            if let error = response.error {
                switch error {
                case "storage_unavailable": throw DesktopSyncError.storage
                case "invalid_request": throw DesktopSyncError.invalid("同步数据无效，请更新两端后重试。")
                case "version_mismatch": throw DesktopSyncError.invalid("桌面端协议不匹配，请更新两端。")
                default: throw DesktopSyncError.unauthorized
                }
            }
            return response
        }, onCancel: { channel.close() })
    }
}
