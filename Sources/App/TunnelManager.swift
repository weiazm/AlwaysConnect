import Foundation
import NetworkExtension

/// SUPERSEDED by the v0.5 fork decision (DESIGN.md §十五, 2026-10-31)
/// AND by Phase 1 step 3 (HelperClient, 2026-10-31): the panel's state
/// source is now Helper XPC state, and this manager is out of the App
/// flow entirely. It still compiles as reference; delete it once the
/// HelperClient path is proven on a Mac.
///
/// Owns the NETunnelProviderManager for the AlwaysConnect tunnel.
/// Credentials reach the provider via providerConfiguration (the system
/// stores VPN configurations protected); the App's Keychain copy is the
/// source of truth the user edits. The provider reads its configuration
/// in startTunnel (Phase 1); this side only constructs it.
final class TunnelManager: ObservableObject {
    static let shared = TunnelManager()

    @Published private(set) var status: NEVPNStatus = .invalid
    @Published private(set) var lastError: String?

    private var manager: NETunnelProviderManager?
    private var statusObserver: NSObjectProtocol?
    private let tunnelBundleId = "com.alwaysconnect.app.tunnel"

    private init() {}

    /// Load the saved manager, or create + save a fresh one for the
    /// profile. Call before start.
    func loadOrCreate(
        profile: Profile,
        username: String,
        password: String,
        completion: @escaping (Error?) -> Void
    ) {
        NETunnelProviderManager.loadAllFromPreferences { [weak self] managers, error in
            guard let self else { return }
            if let error {
                self.lastError = error.localizedDescription
                completion(error)
                return
            }
            // Explicit loop instead of a compactMap/first chain: the
            // loadAllFromPreferences completion's element type does not
            // infer cleanly into closure parameters on this SDK.
            var existing: NETunnelProviderManager?
            if let managers {
                for m in managers {
                    if let t = m as? NETunnelProviderManager,
                       (t.protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier == self.tunnelBundleId {
                        existing = t
                        break
                    }
                }
            }
            let manager = existing ?? NETunnelProviderManager()
            let proto = NETunnelProviderProtocol()
            proto.providerBundleIdentifier = self.tunnelBundleId
            proto.serverAddress = profile.server
            var config: [String: Any] = [
                "server": profile.server,
                "group": profile.group,
                "username": username,
                "password": password,
                "defaultMode": profile.defaultMode.rawValue,
            ]
            if let rulesData = try? JSONEncoder().encode(ProfileStore.loadRules()),
               let rulesJSON = String(data: rulesData, encoding: .utf8) {
                config["rulesJSON"] = rulesJSON
            }
            proto.providerConfiguration = config
            manager.protocolConfiguration = proto
            manager.localizedDescription = "AlwaysConnect"
            manager.isEnabled = true
            self.manager = manager
            self.observeStatus()
            manager.saveToPreferences { error in
                self.lastError = error?.localizedDescription
                completion(error)
            }
        }
    }

    func start(completion: @escaping (Error?) -> Void) {
        guard let manager else {
            let error = NSError(
                domain: "AlwaysConnect",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "No tunnel manager loaded. Call loadOrCreate first."]
            )
            lastError = error.localizedDescription
            completion(error)
            return
        }
        manager.isEnabled = true
        manager.saveToPreferences { [weak self] error in
            guard let self else { return }
            if let error {
                self.lastError = error.localizedDescription
                completion(error)
                return
            }
            do {
                try manager.connection.startVPNTunnel()
                self.lastError = nil
                completion(nil)
            } catch {
                self.lastError = error.localizedDescription
                completion(error)
            }
        }
    }

    func stop() {
        manager?.connection.stopVPNTunnel()
    }

    private func observeStatus() {
        if let observer = statusObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        statusObserver = NotificationCenter.default.addObserver(
            forName: .NEVPNStatusDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self, let manager = self.manager else { return }
            self.status = manager.connection.status
        }
        if let manager {
            status = manager.connection.status
        }
    }
}
