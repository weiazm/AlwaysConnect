import Foundation
import Security

/// Keychain storage for VPN credentials.
/// - Only generic-password items, never plaintext files, logs, or diagnostics.
/// - Touch ID gates viewing/editing only, never auto-login (otherwise
///   launch-time auto-connect would be interrupted).
enum KeychainStore {
    private static let service = "com.alwaysconnect.app"

    static func save(server: String, username: String, password: String) -> Bool {
        // TODO (Phase 1): SecItemAdd / SecItemUpdate with
        // kSecAttrAccessibleAfterFirstUnlock so launch-time auto-connect
        // works without unlocking the device first.
        return false
    }

    static func read(server: String, username: String) -> String? {
        // TODO (Phase 1): SecItemCopyMatching. Returns nil when absent.
        return nil
    }

    static func delete(server: String, username: String) -> Bool {
        // TODO (Phase 1): SecItemDelete.
        return false
    }
}
