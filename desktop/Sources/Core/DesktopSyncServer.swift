import Foundation
import Network
import Security
import Darwin

final class DesktopSyncServer: @unchecked Sendable {
    let serverID: String
    private let identity: DesktopTLSIdentity
    private let store: DesktopStore
    private let queue = DispatchQueue(label: "WiseLife.Desktop.Server")
    private var listener: NWListener?
    private var channels: [UUID: SyncConnection] = [:]
    private var secret = ""
    private var expiresAt = Date.distantPast
    private var attempts = 0
    var onReady: ((UInt16) -> Void)?
    var onChange: (() -> Void)?
    var onFailure: (() -> Void)?
    init(serverID: String, identity: DesktopTLSIdentity, store: DesktopStore) { self.serverID = serverID; self.identity = identity; self.store = store }
    func start() throws {
        let tls = NWProtocolTLS.Options()
        guard let local = sec_identity_create(identity.identity) else { throw DesktopSyncError.invalid("无法启用加密同步。") }
        sec_protocol_options_set_local_identity(tls.securityProtocolOptions, local)
        sec_protocol_options_set_min_tls_protocol_version(tls.securityProtocolOptions, .TLSv12)
        let parameters = NWParameters(tls: tls); parameters.includePeerToPeer = false
        let listener = try NWListener(using: parameters)
        listener.service = .init(name: serverID, type: "_wiselife-sync._tcp")
        listener.stateUpdateHandler = { [weak self, weak listener] state in
            switch state {
            case .ready: if let port = listener?.port?.rawValue { self?.onReady?(port) }
            case .failed: self?.onFailure?()
            default: break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        self.listener = listener; listener.start(queue: queue)
    }
    func stop() {
        queue.async { [weak self] in
            self?.listener?.cancel(); self?.listener = nil
            self?.channels.values.forEach { $0.close() }; self?.channels.removeAll()
        }
    }
    func pairingCode(host: String, port: UInt16) async -> DesktopPairingCode {
        await withCheckedContinuation { continuation in
            queue.async {
                self.secret = DesktopSyncCodec.secret(); self.expiresAt = .now.addingTimeInterval(300); self.attempts = 0
                continuation.resume(returning: DesktopPairingCode(serverID: self.serverID, name: Host.current().localizedName ?? "Mac", host: host, port: port, certificateHash: self.identity.certificateHash, secret: self.secret, expiresAt: self.expiresAt))
            }
        }
    }
    private func accept(_ connection: NWConnection) {
        guard channels.count < 8 else { connection.cancel(); return }
        let id = UUID(), channel = SyncConnection(connection: connection); channels[id] = channel
        Task { [weak self] in
            guard let self else { channel.close(); return }
            defer { channel.close(); self.queue.async { self.channels[id] = nil } }
            do {
                try await channel.start()
                let request = try await channel.receive(DesktopSyncRequest.self)
                let response = await self.handle(request)
                try await channel.send(response)
            } catch { /* Never log transcript, credentials, endpoint or packet contents. */ }
        }
    }
    private func handle(_ request: DesktopSyncRequest) async -> DesktopSyncResponse {
        await withCheckedContinuation { continuation in
            queue.async {
                do {
                    guard request.version == 1 else { continuation.resume(returning: DesktopSyncResponse(serverID: self.serverID, error: "version_mismatch")); return }
                    guard request.serverID == self.serverID else { throw DesktopSyncError.unauthorized }
                    var response: DesktopSyncResponse
                    if request.operation == "pair" {
                        self.attempts += 1
                        guard self.attempts <= 5, self.expiresAt > .now, !self.secret.isEmpty,
                              DesktopSyncCodec.tokenMatches(self.secret, request.credential) else { throw DesktopSyncError.unauthorized }
                        let token = try self.store.pair(deviceID: request.deviceID, name: request.deviceName)
                        self.secret = ""; self.expiresAt = .distantPast
                        response = DesktopSyncResponse(serverID: self.serverID, deviceToken: token)
                    } else { response = try self.store.exchange(request, serverID: self.serverID) }
                    self.onChange?(); continuation.resume(returning: response)
                } catch {
                    let code: String
                    switch error {
                    case DesktopSyncError.unauthorized: code = "unauthorized"
                    case DesktopSyncError.storage: code = "storage_unavailable"
                    default: code = "invalid_request"
                    }
                    continuation.resume(returning: DesktopSyncResponse(serverID: self.serverID, error: code))
                }
            }
        }
    }
    static func localAddresses() -> [String] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0 else { return [] }
        defer { freeifaddrs(head) }
        var values: [String] = [], cursor = head
        while let item = cursor {
            defer { cursor = item.pointee.ifa_next }
            guard let address = item.pointee.ifa_addr, address.pointee.sa_family == UInt8(AF_INET),
                  item.pointee.ifa_flags & UInt32(IFF_UP) != 0, item.pointee.ifa_flags & UInt32(IFF_LOOPBACK) == 0 else { continue }
            var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(address, socklen_t(address.pointee.sa_len), &buffer, socklen_t(buffer.count), nil, 0, NI_NUMERICHOST) == 0 {
                let host = String(cString: buffer)
                if DesktopPairingCode.isLocalHost(host) { values.append(host) }
            }
        }
        return Array(Set(values)).sorted()
    }
}
