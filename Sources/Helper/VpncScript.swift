import Foundation

/// The Helper's custom vpnc-script (DESIGN.md §16.4).
///
/// openconnect invokes it with the reason as $1 (vpnc-script standard:
/// pre-init, connect, disconnect, attempt-reconnect) and the tunnel
/// parameters in the environment ($TUNDEV, $VPNGATEWAY,
/// $INTERNAL_IP4_ADDRESS, $INTERNAL_IP4_DNS, ...).
///
/// The two properties that matter for AlwaysConnect, both fully
/// implemented here and testable without a Mac:
/// - connect emits `AC_HOOK connect tun=<if> gateway=<ip>` on stdout
///   so the engine (and only the engine) learns the tunnel is up;
/// - disconnect NEVER tears anything down unless the engine marked
///   this stop as manual (ALWAYSCONNECT_MANUAL_DISCONNECT=1). An
///   unexpected drop leaves routes and pf in place: fail closed.
///
/// Mac-only, UNVERIFIED until the Mac proof run: the connect-path
/// `route`/`scutil` commands below. They follow the stock vpnc-script
/// shape for macOS, but the exact scutil key and route flags have not
/// been run against a real Mac gateway yet. The script is written so
/// a route/DNS failure exits non-zero WITHOUT emitting the hook, so
/// the engine never reports Connected when setup did not complete.
/// Test/sandbox runs set ALWAYSCONNECT_NO_ROUTES=1 to skip the
/// macOS-only commands and still exercise the hook logic.
enum VpncScript {
    static let text = #"""
    #!/bin/sh
    # AlwaysConnect vpnc-script. See DESIGN.md §16.4.
    # $1 = reason. Env: TUNDEV, VPNGATEWAY, INTERNAL_IP4_ADDRESS,
    # INTERNAL_IP4_DNS, ALWAYSCONNECT_MANUAL_DISCONNECT,
    # ALWAYSCONNECT_NO_ROUTES.
    log() { echo "AC-SCRIPT [$1] $2" >&2; }
    hook() { echo "AC_HOOK $*"; }
    case "$1" in
      pre-init)
        exit 0
        ;;
      connect)
        if [ -n "$ALWAYSCONNECT_NO_ROUTES" ]; then
          log connect "routes skipped (test mode)"
        else
          # MAC-UNVERIFIED: stock vpnc-script shape, pending Mac proof.
          route -n add -inet default -interface "$TUNDEV" 2>/dev/null || {
            log connect "default route via $TUNDEV failed"; exit 1; }
          if [ -n "$INTERNAL_IP4_DNS" ]; then
            printf 'd.init\nd.add ServerAddresses * %s\nset Setup:/Network/Service/%s/DNS\n' "$INTERNAL_IP4_DNS" "$TUNDEV" | scutil 2>/dev/null || {
              log connect "scutil DNS setup failed"; exit 1; }
          fi
        fi
        hook "connect tun=$TUNDEV gateway=$VPNGATEWAY"
        exit 0
        ;;
      disconnect)
        if [ "$ALWAYSCONNECT_MANUAL_DISCONNECT" = "1" ]; then
          # Only a user-confirmed manual disconnect restores the
          # local network. Everything else keeps holding the line.
          if [ -z "$ALWAYSCONNECT_NO_ROUTES" ]; then
            route -n delete -inet default -interface "$TUNDEV" 2>/dev/null || true
            printf 'd.init\nremove Setup:/Network/Service/%s/DNS\n' "$TUNDEV" | scutil 2>/dev/null || true
          fi
          hook "disconnect-manual"
        else
          log disconnect "held: routes and pf left in place (not a manual disconnect)"
          hook "disconnect-held"
        fi
        exit 0
        ;;
      attempt-reconnect)
        log attempt-reconnect "tunnel layer retrying internally"
        exit 0
        ;;
      *)
        log "$1" "unknown reason, ignoring"
        exit 0
        ;;
    esac
    """#

    /// Writes the script to a Helper-owned file (0700 dir, 0700 file)
    /// and returns its path. The engine passes this path to openconnect
    /// via --script. `overridePath` (run-once tests) skips the install.
    static func install(to directory: URL? = nil) throws -> String {
        let dir = directory ?? FileManager.default.urls(
            for: .applicationSupportDirectory, in: .localDomainMask)
            .first!.appendingPathComponent("AlwaysConnect")
        try FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let url = dir.appendingPathComponent("alwaysconnect-vpnc.sh")
        try text.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700], ofItemAtPath: url.path)
        return url.path
    }
}
