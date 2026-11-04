import Foundation
import Security

/// The Apple ID password, in the iOS Keychain, for users who turn on automatic refresh.
/// It stays on this iPhone: it isn't included in backups or synced to iCloud.
enum SavedPassword {
    private static let service = "com.jlazzprog.gpsteleport.apple-id"

    private static var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
        ]
    }

    static var exists: Bool {
        load() != nil
    }

    static func load() -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    static func save(_ password: String) -> Bool {
        delete()
        var query = baseQuery
        query[kSecValueData as String] = Data(password.utf8)
        // Available after the first unlock, so a refresh can run if the app opens while locked.
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(query as CFDictionary, nil) == errSecSuccess
    }

    static func delete() {
        SecItemDelete(baseQuery as CFDictionary)
    }
}
