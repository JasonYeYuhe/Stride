import Foundation
import Security

/// Minimal Keychain wrapper for storing session tokens securely.
enum KeychainHelper {
    private static let service = "yyh.stride.habittracker"

    static func save(key: String, value: String) {
        guard let data = value.data(using: .utf8) else { return }
        delete(key: key)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        SecItemAdd(query as CFDictionary, nil)
    }

    static func read(key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete(key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        SecItemDelete(query as CFDictionary)
    }
}

/// Where the session token lives. `APIClient` and `AuthService` both read and clear it, so they
/// must share one store; in the app that is always the Keychain.
///
/// The protocol exists for StrideAppTests. The test host IS Stride.app — same bundle id, same
/// Keychain service — so a test writing or clearing the real item would sign out whatever
/// account the simulator's copy of the app is using, and on an unsigned simulator build the
/// Keychain can refuse the write outright (-34018). Tests hand both services an in-memory store.
protocol SessionTokenStore: Sendable {
    func read() -> String?
    func save(_ token: String)
    func delete()
}

/// The production store: one Keychain item under the key every shipped build has used. The key
/// must not change — a new one would sign every user out on update.
struct KeychainSessionTokenStore: SessionTokenStore {
    static let key = "stride_session_token"

    func read() -> String? { KeychainHelper.read(key: Self.key) }
    func save(_ token: String) { KeychainHelper.save(key: Self.key, value: token) }
    func delete() { KeychainHelper.delete(key: Self.key) }
}
