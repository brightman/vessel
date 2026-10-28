import CommonCrypto
import Foundation
import Security

protocol AppPasscodeSecretStore: Sendable {
    func read() throws -> Data?
    func write(_ data: Data) throws
}

struct AppPasscodeKeychainStore: AppPasscodeSecretStore {
    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: (Bundle.main.bundleIdentifier ?? "cloud.karama.wisenote") + ".app-passcode",
         kSecAttrAccount as String: "credentials-v1"]
    }

    func read() throws -> Data? {
        var request = query
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw AppPasscodeError.storage(status)
        }
        return data
    }

    func write(_ data: Data) throws {
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            let status = SecItemAdd(query.merging(attributes) { _, new in new } as CFDictionary, nil)
            guard status == errSecSuccess else { throw AppPasscodeError.storage(status) }
        } else if status != errSecSuccess { throw AppPasscodeError.storage(status) }
    }
}

enum AppPasscodeError: LocalizedError {
    case invalidCode, invalidConfiguration, alreadyConfigured, notConfigured
    case incorrectCode, cooldown(Date), storage(OSStatus), derivation
    var errorDescription: String? {
        switch self {
        case .invalidCode: return "请输入六位数字密码。"
        case .invalidConfiguration: return "密码配置无法读取，请重试。"
        case .alreadyConfigured: return "已设置密码，请通过“修改密码”更新。"
        case .notConfigured: return "请先设置 App 密码。"
        case .incorrectCode: return "密码不正确，请重试。"
        case .cooldown: return "尝试次数过多，请稍后重试。"
        case .storage(let code): return "无法访问系统钥匙串（\(code)），请解锁设备后重试。"
        case .derivation: return "密码暂未保存，请重试。"
        }
    }
}

/// Owns verification and durable throttling off the main actor. No plaintext PIN is persisted.
actor AppPasscodeVault {
    struct Snapshot: Sendable {
        let isConfigured: Bool
        let biometricState: Data?
        let retryAt: Date?
    }
    enum Verification: Equatable, Sendable {
        case accepted, incorrect, cooldown(Date)
    }
    private struct Credential: Codable {
        let version: Int
        let salt: Data
        let digest: Data
        let rounds: Int
        var biometricState: Data?
        var failures: Int
        var retryAt: Date?
    }
    private let store: any AppPasscodeSecretStore
    private let now: @Sendable () -> Date
    private static let rounds = 150_000

    init(store: any AppPasscodeSecretStore = AppPasscodeKeychainStore(),
         now: @escaping @Sendable () -> Date = { Date() }) {
        self.store = store
        self.now = now
    }

    func snapshot() throws -> Snapshot {
        let value = try load()
        return .init(isConfigured: value != nil, biometricState: value?.biometricState,
                     retryAt: value?.retryAt.flatMap { $0 > now() ? $0 : nil })
    }

    func setInitialPasscode(_ code: String, biometricState: Data? = nil) throws {
        guard try load() == nil else { throw AppPasscodeError.alreadyConfigured }
        try save(makeCredential(code, biometricState: biometricState))
    }

    func verify(_ code: String) throws -> Verification {
        guard var value = try load() else { throw AppPasscodeError.notConfigured }
        if let date = value.retryAt, date > now() { return .cooldown(date) }
        guard Self.isValid(code) else { return .incorrect }
        let candidate = try Self.derive(code, salt: value.salt, rounds: value.rounds)
        if Self.constantTimeEqual(candidate, value.digest) {
            value.failures = 0; value.retryAt = nil
            try save(value)
            return .accepted
        }
        value.failures = min(100, value.failures + 1)
        if value.failures >= 5 {
            let delay = min(300.0, 30 * pow(2, Double(min(4, value.failures - 5))))
            value.retryAt = now().addingTimeInterval(delay)
        }
        try save(value)
        return value.retryAt.map(Verification.cooldown) ?? .incorrect
    }

    func changePasscode(current: String, replacement: String) throws {
        try requireValidCurrent(current)
        let state = try load()?.biometricState
        try save(makeCredential(replacement, biometricState: state))
    }

    func enableBiometrics(state: Data, current: String) throws {
        guard !state.isEmpty, state.count <= 4096 else { throw AppPasscodeError.invalidConfiguration }
        try requireValidCurrent(current)
        guard var value = try load() else { throw AppPasscodeError.notConfigured }
        value.biometricState = state
        try save(value)
    }

    func disableBiometrics() throws {
        guard var value = try load() else { throw AppPasscodeError.notConfigured }
        value.biometricState = nil
        try save(value)
    }

    private func requireValidCurrent(_ code: String) throws {
        switch try verify(code) {
        case .accepted: return
        case .incorrect: throw AppPasscodeError.incorrectCode
        case .cooldown(let date): throw AppPasscodeError.cooldown(date)
        }
    }

    private func makeCredential(_ code: String, biometricState: Data?) throws -> Credential {
        guard Self.isValid(code) else { throw AppPasscodeError.invalidCode }
        guard biometricState.map({ !$0.isEmpty && $0.count <= 4096 }) ?? true else {
            throw AppPasscodeError.invalidConfiguration
        }
        var bytes = [UInt8](repeating: 0, count: 16)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw AppPasscodeError.derivation
        }
        let salt = Data(bytes)
        return .init(version: 1, salt: salt, digest: try Self.derive(code, salt: salt, rounds: Self.rounds),
                     rounds: Self.rounds, biometricState: biometricState, failures: 0, retryAt: nil)
    }

    private func load() throws -> Credential? {
        guard let data = try store.read() else { return nil }
        guard let value = try? JSONDecoder().decode(Credential.self, from: data),
              value.version == 1, value.salt.count == 16, value.digest.count == 32,
              value.rounds == Self.rounds, (0...100).contains(value.failures),
              value.retryAt?.timeIntervalSinceReferenceDate.isFinite ?? true,
              value.biometricState.map({ !$0.isEmpty && $0.count <= 4096 }) ?? true else {
            throw AppPasscodeError.invalidConfiguration
        }
        return value
    }
    private func save(_ value: Credential) throws { try store.write(JSONEncoder().encode(value)) }
    private static func isValid(_ value: String) -> Bool {
        value.utf8.count == 6 && value.utf8.allSatisfy { (48...57).contains($0) }
    }
    private static func derive(_ code: String, salt: Data, rounds: Int) throws -> Data {
        var result = [UInt8](repeating: 0, count: 32)
        let status = code.withCString { password in
            salt.withUnsafeBytes { saltBytes in
                CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), password, code.utf8.count,
                    saltBytes.bindMemory(to: UInt8.self).baseAddress, salt.count,
                    CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), UInt32(rounds), &result, result.count)
            }
        }
        guard status == kCCSuccess else { throw AppPasscodeError.derivation }
        return Data(result)
    }
    private static func constantTimeEqual(_ left: Data, _ right: Data) -> Bool {
        guard left.count == right.count else { return false }
        return zip(left, right).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }
}
