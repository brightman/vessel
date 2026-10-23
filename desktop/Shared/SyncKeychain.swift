import Foundation
import Security

struct SyncKeychain {
    let service: String
    func read(_ account: String) throws -> Data? {
        var query = base(account)
        query[kSecReturnData as String] = true; query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw failure(status) }
        return data
    }
    func write(_ data: Data, account: String) throws {
        let attributes: [String: Any] = [kSecValueData as String: data, kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        let status = SecItemUpdate(base(account) as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            let add = SecItemAdd(base(account).merging(attributes) { _, new in new } as CFDictionary, nil)
            guard add == errSecSuccess else { throw failure(add) }
        } else if status != errSecSuccess { throw failure(status) }
    }
    func remove(_ account: String) throws {
        let status = SecItemDelete(base(account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw failure(status) }
    }
    private func base(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }
    private func failure(_ status: OSStatus) -> DesktopSyncError { .invalid("钥匙串暂不可用（\(status)），请解锁设备后重试。") }
}
