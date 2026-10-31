import NetworkExtension

/// Transparent proxy provider for per-app split rules.
/// Same mechanism as IVPN / PIA / GlobalProtect on macOS.
///
/// How it works (DESIGN.md §17): the system hands every NEW outbound
/// TCP/UDP connection to this extension. The extension checks the
/// source app's identity against the rule list:
/// - Direct-bound flows -> pumped out the physical interface
///   (FlowPump, via an IP_BOUND_IF socket that bypasses the tunnel).
/// - Everything else -> declined (handleNewFlow returns false), so it
///   follows normal routing (the VPN tunnel) — this is the mature
///   "exclusion" model.
///
/// Failure direction (DESIGN.md §17.1): a synchronous setup failure
/// (no physical interface, unusable endpoint) returns false, so the
/// flow goes via VPN. An asynchronous failure after true was returned
/// closes the connection instead of silently falling back to VPN, so
/// a direct rule cannot silently become a VPN route.
///
/// Known limits (see DESIGN.md §4.3, must be surfaced in UI, not hidden):
/// - Only new connections are affected; already-open connections keep
///   their route until the app re-establishes them.
/// - TCP/UDP only. System-service DNS lookups still use the VPN;
///   raw sockets (e.g. ping) always use the VPN.
/// - "Inverse mode" (only selected apps use the VPN, rest direct) is not
///   established on macOS — Phase 0 must validate whether it can be built
///   by forwarding selected flows into the tunnel; if not, split-mode app
///   rules degrade to exclusion + a warning.
/// - Safari exclusion is restricted by the system; do not promise it.
final class TransparentProxyProvider: NETransparentProxyProvider {

    /// Rule engine (Rust core, same bridge as the Tunnel). Configured
    /// in startProxy from the App Groups container; until then every
    /// decision fails closed to the VPN.
    private var ruleEngine: RustRuleEngine?

    /// Live pumps, by identity. Removed on each pump's onDone;
    /// stopProxy cancels whatever is left.
    private var activePumps: [ObjectIdentifier: FlowPumpCancellable] = [:]

    /// Build the rule engine from a profile + rules (called by startProxy
    /// once rules are loaded from the App Groups container).
    func configureEngine(profile: Profile, rules: [Rule]) {
        let engine = RustRuleEngine(defaultMode: profile.defaultMode)
        for rule in rules {
            engine.addRule(rule)
        }
        ruleEngine = engine
    }

    /// Direct-egress decision for one connection. Fails closed to the
    /// VPN when the engine is not configured yet.
    func directEgress(app: String, domain: String, ip: String) -> Bool {
        guard let engine = ruleEngine else { return false }
        return !engine.shouldUseVPN(app: app, domain: domain, ip: ip)
    }

    /// Extract the decision inputs from a flow. App identity comes
    /// from the flow metadata's signing identifier (flow.metaData,
    /// NOT a direct property of the flow — the compiler rejects
    /// flow.sourceAppSigningIdentifier); the destination hostname from
    /// the flow; the IP from the TCP endpoint's hostname when it is an
    /// IP literal (a DNS name leaves ip empty — the engine then decides
    /// on app/domain/default, which is safe; a hostname can never match
    /// a CIDR or the LAN check anyway). UDP flows contribute app +
    /// hostname only for now.
    private func extract(_ flow: NEAppProxyFlow) -> (app: String, domain: String, ip: String) {
        // metaData is non-optional NEFlowMetaData (per the compiler);
        // the signing identifier itself may be absent, hence ?? "".
        let app = flow.metaData.sourceAppSigningIdentifier ?? ""
        let domain = flow.remoteHostname ?? ""
        var ip = ""
        if let tcp = flow as? NEAppProxyTCPFlow,
           let hostEndpoint = tcp.remoteEndpoint as? NWHostEndpoint {
            let host = hostEndpoint.hostname
            let looksLikeIP = !host.isEmpty
                && host.allSatisfy({ $0.isHexDigit || $0 == "." || $0 == ":" })
                && (host.contains(".") || host.contains(":"))
            if looksLikeIP {
                ip = host
            }
        }
        return (app, domain, ip)
    }

    override func startProxy(options: [String: Any]?) async throws {
        // Load profile + rules from the App Groups container. The keys
        // ("profile", "rules") are shared with ProfileStore in the App
        // target, which the Proxy target cannot import — keep the
        // strings in sync with ProfileStore by hand. Any failure here
        // leaves the engine nil, so every flow fails closed to VPN.
        if let defaults = UserDefaults(
            suiteName: "group.com.alwaysconnect.app"),
           let profileData = defaults.data(forKey: "profile"),
           let profile = try? JSONDecoder().decode(
            Profile.self, from: profileData),
           let rulesData = defaults.data(forKey: "rules"),
           let rules = try? JSONDecoder().decode(
            [Rule].self, from: rulesData) {
            configureEngine(profile: profile, rules: rules)
        }
        // Coexistence with the packet tunnel is a Mac-only verification
        // (DESIGN.md §17.6): excluded flows must egress via the
        // physical interface while the tunnel is up, and the pf
        // connected set must be loaded for them to pass.
    }

    override func stopProxy(with reason: NEProviderStopReason) async {
        let pumps = activePumps.values
        activePumps = [:]
        for pump in pumps { pump.cancel() }
        ruleEngine = nil
    }

    override func handleNewFlow(_ flow: NEAppProxyFlow) -> Bool {
        let (app, domain, ip) = extract(flow)
        guard directEgress(app: app, domain: domain, ip: ip) else {
            return false
        }
        // No usable physical interface -> VPN (fail closed, §17.3).
        guard let physicalIf = discoverPhysicalInterface() else {
            return false
        }
        let ifIndex = interfaceIndex(for: physicalIf)
        guard ifIndex != 0 else { return false }
        if let tcp = flow as? NEAppProxyTCPFlow {
            let pump = TCPFlowPump(flow: tcp, ifIndex: ifIndex)
            let id = ObjectIdentifier(pump)
            pump.onDone = { [weak self] in
                self?.activePumps.removeValue(forKey: id)
            }
            guard pump.start() else { return false }
            activePumps[id] = pump
            return true
        }
        if let udp = flow as? NEAppProxyUDPFlow {
            let pump = UDPFlowPump(flow: udp, ifIndex: ifIndex)
            let id = ObjectIdentifier(pump)
            pump.onDone = { [weak self] in
                self?.activePumps.removeValue(forKey: id)
            }
            guard pump.start() else { return false }
            activePumps[id] = pump
            return true
        }
        return false
    }
}
