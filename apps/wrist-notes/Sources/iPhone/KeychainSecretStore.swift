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
        guard status == errSecSuccess, let data = result as? Data,
              let value = String(data: data, encoding: .utf8) else { throw failure }
        return value
    }

    func write(_ value: String) throws {
        let data = Data(value.utf8)
        let attributes: [String: Any] = [kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            let addition = query.merging(attributes) { _, new in new }
            guard SecItemAdd(addition as CFDictionary, nil) == errSecSuccess else { throw failure }
        } else if status != errSecSuccess { throw failure }
    }

    private var failure: AIServiceError {
        .invalidConfiguration("无法访问安全保存的 API Key，请解锁 iPhone 后重试。")
    }
}
