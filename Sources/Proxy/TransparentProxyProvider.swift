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

    override func startProxy(options: [String: Any]?) async throws {
        // TODO (Phase 0/2):
        // 1. Load app rules from the App Groups container.
        // 2. Verify coexistence with the packet tunnel: excluded flows must
        //    egress via the physical interface while the tunnel is up.
        // 3. Validate (or rule out) inverse mode.
    }

    override func stopProxy(with reason: NEProviderStopReason) async {
        // TODO (Phase 2)
    }

    override func handleNewFlow(_ flow: NEAppProxyFlow) -> Bool {
        // TODO (Phase 2): return true to handle the flow (direct egress),
        // false to decline it (normal routing -> VPN tunnel).
        return false
    }
}
