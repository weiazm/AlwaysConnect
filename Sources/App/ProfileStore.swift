import Foundation

/// Non-secret persistence in the App Groups container (shared with the
/// extensions): profile, rules, and the username. Secrets NEVER go
/// here — the password lives in the Keychain (KeychainStore) and
/// reaches the provider via providerConfiguration.
enum ProfileStore {
    private static let suite = "group.com.alwaysconnect.app"
    private static let profileKey = "profile"
    private static let rulesKey = "rules"
    private static let usernameKey = "username"

    private static var defaults: UserDefaults? {
        UserDefaults(suiteName: suite)
    }

    static func loadProfile() -> Profile {
        guard let data = defaults?.data(forKey: profileKey),
              let profile = try? JSONDecoder().decode(Profile.self, from: data) else {
            return Profile()
        }
        return profile
    }

    static func saveProfile(_ profile: Profile) {
        if let data = try? JSONEncoder().encode(profile) {
            defaults?.set(data, forKey: profileKey)
        }
    }

    static func loadRules() -> [Rule] {
        guard let data = defaults?.data(forKey: rulesKey),
              let rules = try? JSONDecoder().decode([Rule].self, from: data) else {
            return []
        }
        return rules
    }

    static func saveRules(_ rules: [Rule]) {
        if let data = try? JSONEncoder().encode(rules) {
            defaults?.set(data, forKey: rulesKey)
        }
    }

    /// The username is not secret; only the password is.
    static func loadUsername() -> String? {
        defaults?.string(forKey: usernameKey)
    }

    static func saveUsername(_ username: String) {
        defaults?.set(username, forKey: usernameKey)
    }
}
