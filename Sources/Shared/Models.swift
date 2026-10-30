import Foundation

// MARK: - Profile

/// One VPN gateway configuration. The shipped default matches the user's
/// company gateway; values are editable in Settings.
struct Profile: Codable, Equatable {
    var server: String = "SZDC"
    var group: String = "SecureVPN"
    var autoConnectOnLaunch: Bool = true
    var defaultMode: DefaultMode = .secure
}

/// Default routing policy for traffic that matches no rule.
/// - secure: everything goes through the VPN (Cloudflare WARP "Exclude" mode).
/// - split: only listed traffic goes through the VPN (Cloudflare WARP "Include" mode).
enum DefaultMode: String, Codable {
    case secure
    case split
}

// MARK: - Rules

enum RuleType: String, Codable {
    case app
    case domain
    case network
}

enum RuleDirection: String, Codable {
    case viaVPN
    case direct
}

/// A single split rule. Priority: app > domain > network > default mode.
/// The 192.168.0.0/16 LAN hard rule always wins over everything.
struct Rule: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var type: RuleType
    /// App: signing identifier. Domain: wildcard allowed, e.g. *.example.com.
    /// Network: CIDR, e.g. 192.168.0.0/16.
    var target: String
    var direction: RuleDirection
    var isEnabled: Bool = true
}

// MARK: - Network policy

struct NetworkPolicy: Codable, Equatable {
    /// Excluded from the tunnel while connected (home LAN).
    var splitExcludes: [String] = ["192.168.0.0/16"]
    /// Still reachable while disconnected under kill switch.
    var killSwitchAllowlist: [String] = ["192.168.0.0/16"]
    var pfFallbackEnabled: Bool = true
}

// MARK: - Session state (shared App <-> Provider via App Groups)

enum SessionStatus: String, Codable {
    case disconnected
    case connecting
    case authenticating
    case awaitingApproval   // Waiting for the user to approve the SeaTalk push.
    case connected
    case reconnecting       // Kill switch active, traffic blackholed.
}

struct SessionState: Codable, Equatable {
    var status: SessionStatus = .disconnected
    var gateway: String = ""
    var tunnelAddress: String = ""
    var connectedSince: Date?
    var reconnectCount: Int = 0
    var lastDropAt: Date?
    var bytesIn: Int64 = 0
    var bytesOut: Int64 = 0
}
