import NetworkExtension

/// Packet tunnel provider: owns the tunnel, the reconnect state machine,
/// fail-closed kill switch, and the DNS-proxy-based domain rules.
///
/// Architecture notes (see DESIGN.md):
/// - The provider is a system-managed process: it keeps running (and keeps
///   retrying) even if the App quits. That is what makes fail-closed real:
///   on an unexpected drop the provider does NOT tear down utun or routes,
///   it just stops forwarding, so traffic blackholes instead of leaking
///   to the physical interface.
/// - OpenConnect is linked as libopenconnect (C library) into this target.
///   Do NOT drive the openconnect CLI as a subprocess: subprocesses are
///   restricted inside a system extension sandbox and state sync is painful.
///
/// Phase 0 validation items for this target:
/// 1. libopenconnect builds and runs inside a PacketTunnelProvider on macOS.
/// 2. One full connection with manual credentials + SeaTalk approval works.
/// 3. Session resumption across a quick drop works without a new approval.
/// 4. Dynamic route updates from DNS answers work (domain rules).
final class PacketTunnelProvider: NEPacketTunnelProvider {

    private enum State {
        case disconnected
        case connecting
        case authenticating
        case awaitingApproval
        case connected
        case reconnecting
    }

    private var state: State = .disconnected
    private var reconnectAttempt = 0

    /// Rule engine (Rust core) for split decisions. Wired now; the
    /// packet pump and auth driver plug into it in Phase 0/1.
    private var ruleEngine: RustRuleEngine?

    /// Build the rule engine from a profile + rules (called by the App
    /// via provider configuration, and by startTunnel).
    func configureEngine(profile: Profile, rules: [Rule]) {
        let engine = RustRuleEngine(defaultMode: profile.defaultMode)
        for rule in rules {
            engine.addRule(rule)
        }
        ruleEngine = engine
    }

    /// Split decision for one connection. Fails closed to VPN when the
    /// engine is not configured yet.
    func shouldUseVPN(app: String, domain: String, ip: String) -> Bool {
        ruleEngine?.shouldUseVPN(app: app, domain: domain, ip: ip) ?? true
    }

    override func startTunnel(options: [String: NSObject]?) async throws {
        // TODO (Phase 0/1):
        // 1. Read Profile + credentials from the App Groups container
        //    (passed by the App via NETunnelProviderManager).
        // 2. Authenticate via libopenconnect: server + Group (SecureVPN) +
        //    username + password. If the gateway demands a fresh approval,
        //    report .awaitingApproval and wait (the user taps SeaTalk).
        // 3. On success: install utun settings — default route via tunnel,
        //    excludedRoutes = 192.168.0.0/16 (home LAN), tunnel DNS from
        //    the gateway, DNS proxy for rule domains.
        // 4. Start the reconnect watchdog (keepalive timeout -> reconnect).
        // 5. Wire the packet pump: packetFlow <-> libopenconnect tunnel,
        //    consulting shouldUseVPN(app:domain:ip:) per connection.
        throw NEVPNError(.configurationInvalid)
    }

    override func stopTunnel(with reason: NEProviderStopReason) async {
        // Distinguish intentional disconnect from unexpected drops:
        // - .userInitiated: tear down utun/routes, clear pf rules.
        // - anything else: keep routes installed, keep retrying (fail-closed).
        // TODO (Phase 1): implement the two paths.
        ruleEngine = nil
    }

    override func handleAppMessage(_ messageData: Data) async -> Data? {
        // TODO (Phase 1): rule hot-updates from the App (incremental route
        // + DNS changes, no reconnect), status queries.
        return nil
    }

    // MARK: - Reconnect

    /// Backoff: 1s, 2s, 5s, 10s, 30s cap, with jitter, never gives up.
    /// Reset on success. NWPathMonitor triggers an immediate attempt on
    /// network change / wake from sleep (no waiting for the backoff timer).
    private func nextBackoff() -> TimeInterval {
        // TODO (Phase 1)
        return 30
    }
}
