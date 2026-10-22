import Foundation
import Security

protocol SecretStore {
    func read() throws -> String
    func write(_ value: String) throws
}

struct KeychainSecretStore: SecretStore {
    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: (Bundle.main.bundleIdentifier ?? "cloud.karama.wisenote") + ".ai",
         kSecAttrAccount as String: "custom-model-api-key"]
    }

    func read() throws -> String {
        var request = query
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return "" }
        guard status == errSecSuccess else { throw failure(status) }
        guard let data = result as? Data,
              let value = String(data: data, encoding: .utf8) else { throw failure(errSecDecode) }
        return value
    }

    func write(_ value: String) throws {
        let data = Data(value.utf8)
        let attributes: [String: Any] = [kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            let addition = query.merging(attributes) { _, new in new }
            let addStatus = SecItemAdd(addition as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw failure(addStatus) }
        } else if status != errSecSuccess { throw failure(status) }
    }

    private func failure(_ status: OSStatus) -> AIServiceError {
        let message: String
        switch status {
        case errSecMissingEntitlement:
            message = "当前 App 的签名缺少钥匙串访问权限（错误 \(status)）。请使用正确签名的版本后重试。"
        case errSecInteractionNotAllowed:
            message = "系统暂不允许访问钥匙串（错误 \(status)），请解锁 iPhone 后重试。"
        default:
            message = "无法访问系统钥匙串（错误 \(status)），请稍后重试。"
        }
        return .invalidConfiguration(message)
    }
}
