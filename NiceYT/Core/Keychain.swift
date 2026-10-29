import Foundation
import Security

enum Keychain {
    private static let service = "NiceYT"

    static func set(_ data: Data?, for key: String) {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]
        SecItemDelete(base as CFDictionary)
        guard let data else { return }
        var add = base
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let status = SecItemAdd(add as CFDictionary, nil)
        if status != errSecSuccess {
            // Sideloaded builds sometimes lack keychain entitlements; fall back to defaults.
            UserDefaults.standard.set(data, forKey: "kc." + key)
        } else {
            UserDefaults.standard.removeObject(forKey: "kc." + key)
        }
        if data.isEmpty { UserDefaults.standard.removeObject(forKey: "kc." + key) }
    }

    static func get(_ key: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        if SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data {
            return data
        }
        return UserDefaults.standard.data(forKey: "kc." + key)
    }

    static func remove(_ key: String) {
        set(nil, for: key)
        UserDefaults.standard.removeObject(forKey: "kc." + key)
    }
}
