import Foundation
import Security

/// Keychain storage for VPN credentials.
/// - One generic-password item per server+username (account
///   "username@server"); the password never touches a plaintext file,
///   a log, or diagnostics.
/// - Accessibility AfterFirstUnlock: launch-time auto-connect works
///   without unlocking the device first.
/// - Touch ID gating belongs in the Settings UI for viewing/editing
///   (Phase 2); it must never gate auto-login itself, or launch-time
///   auto-connect would be interrupted.
enum KeychainStore {
    private static let service = "com.alwaysconnect.app"

    private static func query(server: String, username: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: "\(username)@\(server)",
        ]
    }

    static func save(server: String, username: String, password: String) -> Bool {
        var item = query(server: server, username: username)
        item[kSecValueData as String] = Data(password.utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        var status = SecItemAdd(item as CFDictionary, nil)
        if status == errSecDuplicateItem {
            let update: [String: Any] = [kSecValueData as String: Data(password.utf8)]
            status = SecItemUpdate(
                query(server: server, username: username) as CFDictionary,
                update as CFDictionary
            )
        }
        return status == errSecSuccess
    }

    /// Returns nil when absent or unreadable; callers treat nil as
    /// "no stored password".
    static func read(server: String, username: String) -> String? {
        var q = query(server: server, username: username)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    static func delete(server: String, username: String) -> Bool {
        let status = SecItemDelete(query(server: server, username: username) as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}
