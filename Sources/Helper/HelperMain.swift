import Foundation

/// Privileged helper (LaunchDaemon, installed once with admin authorization).
/// Owns the pf fallback rules: the second line of fail-closed defense.
///
/// Rules (see DESIGN.md §6/§13):
/// - Outbound on the physical interface: default DENY.
/// - Always allowed: 192.168.0.0/16 (home LAN), DHCP (67/68), loopback,
///   link-local multicast (mDNS/Bonjour/AirDrop discovery).
/// - IPv6 outbound on the physical interface: default DENY, except
///   fe80::/10 link-local, unless the gateway provides an IPv6 tunnel.
/// - Rules are REMOVED only on intentional user disconnect, never on an
///   unexpected drop — even if the tunnel provider process dies, the pf
///   rules keep holding the line.
///
/// TODO (Phase 2): implement with pf anchors via a small C helper or
/// pfctl invocation from the daemon. Validate across macOS upgrades.
@main
struct HelperMain {
    static func main() {
        // TODO (Phase 2)
        fputs("AlwaysConnectHelper: not implemented yet (Phase 2)\n", stderr)
        exit(1)
    }
}
