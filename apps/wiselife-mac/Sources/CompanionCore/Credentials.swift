import Foundation
import Security
import CryptoKit

public protocol SecretStore: Sendable {
    func read(_ account: String) throws -> Data?
    func write(_ data: Data, account: String) throws
}

public struct KeychainStore: SecretStore {
    public let service: String
    public init(service: String = "cloud.karama.wiselife.mac-companion") { self.service = service }
    private func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }
    public func read(_ account: String) throws -> Data? {
        var query = query(account); query[kSecReturnData as String] = true; query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw Self.failure }
        return data
    }
    public func write(_ data: Data, account: String) throws {
        let attributes: [String: Any] = [kSecValueData as String: data, kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        let result = SecItemUpdate(query(account) as CFDictionary, attributes as CFDictionary)
        if result == errSecItemNotFound {
            guard SecItemAdd(query(account).merging(attributes) { _, new in new } as CFDictionary, nil) == errSecSuccess else { throw Self.failure }
        } else if result != errSecSuccess { throw Self.failure }
    }
    private static let failure = ServiceError(503, "keychain_unavailable", "无法访问系统钥匙串，请解锁 Mac 后重试。")
}

public enum Secrets {
    public static func random() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw ServiceError.inference }
        return Data(bytes).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
    public static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    public static func hash(_ text: String) -> String { hash(Data(text.utf8)) }
    public static func equal(_ lhs: String, _ rhs: String) -> Bool {
        let a = Array(lhs.utf8), b = Array(rhs.utf8)
        guard a.count == b.count else { return false }
        return zip(a, b).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }
}

public struct PairedDevice: Codable, Sendable, Identifiable, Equatable {
    public let id: UUID
    public let name: String
    public let pairedAt: Date
}

public struct PairingCode: Codable, Sendable {
    public let version: Int
    public let serviceID: String
    public let fingerprint: String
    public let nonce: String
    public let expiresAt: Date
    public var url: URL {
        var parts = URLComponents(); parts.scheme = "wiselife-mac"; parts.host = "pair"
        parts.queryItems = [
            .init(name: "v", value: String(version)), .init(name: "service", value: serviceID),
            .init(name: "fingerprint", value: fingerprint), .init(name: "nonce", value: nonce),
            .init(name: "expires", value: String(Int(expiresAt.timeIntervalSince1970)))
        ]
        return parts.url!
    }
}

public actor PairingRegistry {
    private struct Credential: Codable { let device: PairedDevice; let verifier: String }
    private struct Archive: Codable { var serviceID: String; var credentials: [Credential] }
    private let store: any SecretStore
    private var archive: Archive
    private var code: PairingCode?
    private var attempts: [String: [Date]] = [:]
    public var serviceID: String { archive.serviceID }
    public var devices: [PairedDevice] { archive.credentials.map(\.device) }
    public init(store: any SecretStore) throws {
        self.store = store
        if let data = try store.read("paired-devices") {
            archive = try JSONDecoder().decode(Archive.self, from: data)
        } else {
            archive = Archive(serviceID: UUID().uuidString.lowercased(), credentials: [])
            try store.write(JSONEncoder().encode(archive), account: "paired-devices")
        }
    }
    public func open(fingerprint: String, now: Date = Date()) throws -> PairingCode {
        let new = PairingCode(version: 1, serviceID: archive.serviceID, fingerprint: fingerprint, nonce: try Secrets.random(), expiresAt: now.addingTimeInterval(120))
        code = new; return new
    }
    public func close() { code = nil }
    public func isPairing(now: Date = Date()) -> Bool { code.map { $0.expiresAt > now } ?? false }
    public func pair(nonce: String, deviceID: UUID, name: String, peer: String, now: Date = Date()) throws -> String {
        attempts = attempts.filter { $0.value.contains(where: { now.timeIntervalSince($0) < 60 }) }
        var recent = (attempts[peer] ?? []).filter { now.timeIntervalSince($0) < 60 }
        guard recent.count < 5, attempts.count < 128 || attempts[peer] != nil else {
            throw ServiceError(429, "pairing_rate_limited", "配对尝试过于频繁，请稍后重试。")
        }
        recent.append(now); attempts[peer] = recent
        guard let code, now < code.expiresAt, Secrets.equal(Secrets.hash(nonce), Secrets.hash(code.nonce)) else {
            throw ServiceError(401, "invalid_pairing_code", "配对码已过期或已使用，请在 Mac 上重新生成。")
        }
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, name.count <= 80,
              archive.credentials.count < 16 || archive.credentials.contains(where: { $0.device.id == deviceID }) else {
            throw ServiceError.invalidRequest
        }
        let token = try Secrets.random()
        var next = archive
        next.credentials.removeAll { $0.device.id == deviceID }
        next.credentials.append(.init(device: .init(id: deviceID, name: name, pairedAt: now), verifier: Secrets.hash(token)))
        try persist(next)
        self.code = nil // Consume only after a durable credential commit.
        return token
    }
    public func authenticate(_ authorization: String?) throws -> PairedDevice {
        guard let authorization, authorization.hasPrefix("Bearer "), authorization.utf8.count < 256 else { throw ServiceError.unauthorized }
        let verifier = Secrets.hash(String(authorization.dropFirst(7)))
        guard let credential = archive.credentials.first(where: { Secrets.equal($0.verifier, verifier) }) else { throw ServiceError.unauthorized }
        return credential.device
    }
    public func revoke(_ id: UUID) throws {
        var next = archive; next.credentials.removeAll { $0.device.id == id }; try persist(next)
    }
    private func persist(_ next: Archive) throws {
        try store.write(JSONEncoder().encode(next), account: "paired-devices"); archive = next
    }
}
