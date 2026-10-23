import Foundation
import Security

struct ChatGPTRegistration: Codable, Equatable, Identifiable {
    var id: String { clientID }
    let clientID: String
    let subject: String
    let email: String?
    var credential: ChatGPTCredential?
    var acknowledgedPlan = false
}

struct ChatGPTAccountVault: Codable {
    var hostID = "urn:uuid:" + UUID().uuidString.lowercased()
    var registrations: [ChatGPTRegistration] = []
    var selectedID: String?
}

protocol ChatGPTAccountStoring {
    func load() throws -> ChatGPTAccountVault?
    func save(_ vault: ChatGPTAccountVault) throws
}

/// Tokens and the stable device identity never enter UserDefaults, iCloud or application logs.
struct ChatGPTKeychainStore: ChatGPTAccountStoring {
    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: (Bundle.main.bundleIdentifier ?? "cloud.karama.wisenote") + ".chatgpt",
         kSecAttrAccount as String: "account-vault", kSecAttrSynchronizable as String: false]
    }
    func load() throws -> ChatGPTAccountVault? {
        var request = query
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var value: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &value)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = value as? Data,
              let vault = try? JSONDecoder().decode(ChatGPTAccountVault.self, from: data) else { throw ChatGPTError.storage }
        return vault
    }
    func save(_ vault: ChatGPTAccountVault) throws {
        let attributes: [String: Any] = [kSecValueData as String: try JSONEncoder().encode(vault),
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            guard SecItemAdd(query.merging(attributes) { _, new in new } as CFDictionary, nil) == errSecSuccess else { throw ChatGPTError.storage }
        } else if status != errSecSuccess { throw ChatGPTError.storage }
    }
}
