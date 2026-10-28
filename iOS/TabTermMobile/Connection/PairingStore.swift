import Foundation
import Security

import TabTermKit

/// Keeps the pairing in the Keychain rather than UserDefaults: the device token
/// is a credential that opens a shell on the Mac.
///
/// Readable after first unlock, so a reconnect that happens while the phone is
/// locked — answering a notification, say — can still find it.
enum PairingStore {
    private static let service = "com.tabterm.TabTermMobile.pairing"
    private static let account = "mac"

    static func load() -> PairedHost? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data
        else { return nil }
        return try? JSONDecoder().decode(PairedHost.self, from: data)
    }

    @discardableResult
    static func save(_ mac: PairedHost) -> Bool {
        guard let data = try? JSONEncoder().encode(mac) else { return false }
        clear()
        let item: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecValueData as String: data,
        ]
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }

    static func clear() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
