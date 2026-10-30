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
/// This binary's current surface is deliberately small: it generates the
/// pf anchor text (Rust core) on stdout so the install path and the CI
/// runner can verify generation without touching the live packet filter.
/// Loading (`pfctl -a ANCHOR -f file`) and removal (`pfctl -a ANCHOR -F
/// rules`) arrive with the LaunchDaemon installation (Phase 2); they need
/// root and a Mac, so they are not faked here.
///
/// Usage:
///   AlwaysConnectHelper generate-pf --phys <if> --tun <if>
///       --gateway <ip[,ip...]> [--allow <cidr[,cidr...]>]
/// Exit codes: 0 success, 1 generation rejected, 2 usage error.
@main
struct HelperMain {
    static func main() {
        var args = CommandLine.arguments.dropFirst()
        guard args.first == "generate-pf" else {
            usage()
            exit(2)
        }
        args = args.dropFirst()
        var phys: String?
        var tun: String?
        var gateway: String?
        var allow: String?
        while let flag = args.first {
            args = args.dropFirst()
            guard let value = args.first else {
                fputs("missing value for \(flag)\n", stderr)
                exit(2)
            }
            args = args.dropFirst()
            switch flag {
            case "--phys": phys = value
            case "--tun": tun = value
            case "--gateway": gateway = value
            case "--allow": allow = value
            default:
                fputs("unknown flag: \(flag)\n", stderr)
                exit(2)
            }
        }
        guard let phys, let tun, let gateway else {
            fputs("required: --phys, --tun, --gateway\n", stderr)
            exit(2)
        }
        let gateways = gateway.split(separator: ",").map(String.init)
        let allows = (allow ?? "").split(separator: ",").map(String.init)
        guard let text = PfAnchor.generate(
            physicalIf: phys,
            tunnelIf: tun,
            gatewayIps: gateways,
            allowNetworks: allows
        ) else {
            fputs("pf generation rejected (bad interface, empty gateway, or invalid network/IP)\n", stderr)
            exit(1)
        }
        print(text, terminator: "")
    }

    private static func usage() {
        fputs("Usage: AlwaysConnectHelper generate-pf --phys <if> --tun <if> --gateway <ip[,ip...]> [--allow <cidr[,cidr...]>]\n", stderr)
    }
}
