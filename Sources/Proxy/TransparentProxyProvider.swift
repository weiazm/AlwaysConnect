import NetworkExtension

/// Transparent proxy provider for per-app split rules.
/// Same mechanism as IVPN / PIA / GlobalProtect on macOS.
///
/// How it works: the system hands every NEW outbound TCP/UDP connection to
/// this extension. The extension checks the source app's identity against
/// the rule list:
/// - Excluded apps -> forwarded out the physical interface (direct).
/// - Everything else -> declined, so it follows normal routing (the VPN
///   tunnel) — this is the mature "exclusion" model.
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
    /// from the App Groups container in startProxy (Phase 2); until
    /// then every decision fails closed to the VPN.
    private var ruleEngine: RustRuleEngine?

    /// False until the Phase 2 flow pump lands (TCP/UDP byte relay via
    /// NWConnection). While false, direct-bound flows ALSO take the VPN:
    /// that is the safe direction — no leak, only a wrong route for
    /// exclusions — whereas returning true without a pump would stall
    /// the flow outright.
    private let pumpAvailable = false

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

    /// Extract the decision inputs from a flow. App identity comes from
    /// the flow's signing identifier; the destination hostname from the
    /// flow; the IP from the TCP endpoint when it is a literal address
    /// (a hostname endpoint leaves ip empty — the engine then decides
    /// on app/domain/default, which is safe). UDP flows contribute app
    /// + hostname only for now.
    private func extract(_ flow: NEAppProxyFlow) -> (app: String, domain: String, ip: String) {
        let app = flow.sourceAppSigningIdentifier ?? ""
        let domain = flow.remoteHostname ?? ""
        var ip = ""
        if let tcp = flow as? NEAppProxyTCPFlow,
           case .hostPort(let host, _) = tcp.remoteEndpoint {
            switch host {
            case .ipv4(let addr): ip = "\(addr)"
            case .ipv6(let addr): ip = "\(addr)"
            case .name: break
            @unknown default: break
            }
        }
        return (app, domain, ip)
    }

    override func startProxy(options: [String: Any]?) async throws {
        // TODO (Phase 0/2):
        // 1. Load app rules from the App Groups container, then
        //    configureEngine(profile:rules:).
        // 2. Verify coexistence with the packet tunnel: excluded flows must
        //    egress via the physical interface while the tunnel is up.
        // 3. Validate (or rule out) inverse mode.
    }

    override func stopProxy(with reason: NEProviderStopReason) async {
        // TODO (Phase 2)
        ruleEngine = nil
    }

    override func handleNewFlow(_ flow: NEAppProxyFlow) -> Bool {
        let (app, domain, ip) = extract(flow)
        let direct = directEgress(app: app, domain: domain, ip: ip)
        // Phase 2: when direct is true AND the pump exists, return true
        // and relay the flow out the physical interface. Until then,
        // fail closed (see pumpAvailable).
        if direct && pumpAvailable {
            return true
        }
        return false
    }
}
