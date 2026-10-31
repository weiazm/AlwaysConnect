//! pf kill-switch anchor generator (DESIGN.md §6.4, second line of
//! defense). Pure text generation: no pfctl invocation, no file I/O.
//! The privileged Helper owns loading (`pfctl -a ANCHOR -f file`) and
//! removal (`pfctl -a ANCHOR -F rules`); this module only decides WHAT
//! the rules say, so it is fully testable on Linux.
//!
//! Semantics (pf `quick` = first match wins, so order is the policy):
//! 1. Everything on the tunnel interface passes (it is already inside
//!    the VPN; the kill switch guards the PHYSICAL interface).
//! 2. Loopback passes.
//! 3. DHCP client traffic (UDP 68 -> 67) passes: without it the machine
//!    cannot obtain a LAN address at all.
//! 4. The gateway IPs pass (all protocols): the reconnect itself must
//!    reach the gateway through pf, or the client could never recover
//!    while the rules are installed. This is why gateway endpoints are
//!    REQUIRED (empty list is an error, not a silent footgun).
//! 5. The allowlist networks pass (union of split-excludes and the
//!    kill-switch allowlist, deduplicated, order preserved).
//! 6. Bonjour discovery passes (mDNS 224.0.0.251 / ff02::fb port 5353)
//!    and IPv6 link-local (fe80::/10) passes.
//! 7. The final rule depends on the mode (DESIGN.md §17.5):
//!    - blocking set (allow_direct_egress = false, the default): everything
//!      else outbound on the physical interface is dropped. This is the
//!      fail-closed set, loaded when the tunnel is down.
//!    - connected set (allow_direct_egress = true): everything else
//!      outbound on the physical interface passes, so provider-pumped
//!      direct-rule traffic can egress. Loaded only on the connect
//!      hook, while the tunnel is up; a drop reloads the blocking set.
//!
//! Caller responsibilities, stated plainly because the generator cannot
//! enforce them: resolve gateway hostnames to IPs BEFORE calling (this
//! API takes IPs only); regenerate + reload when a gateway IP changes;
//! install these rules only once the tunnel is up (before first connect
//! there is no tunnel and nothing to leak, and no gateway IP is known
//! yet); treat a pfctl load failure as a hard error surfaced to the
//! user, never as a silent skip. Rules are outbound-only; inbound
//! traffic is untouched by this anchor. pfctl itself is the final
//! validator of the generated text.

use std::fmt;

/// pf anchor name the Helper loads this text under.
pub const ANCHOR: &str = "com.alwaysconnect.killswitch";

/// Inputs to anchor generation.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PfInput {
    /// Physical interface, e.g. "en0".
    pub physical_if: String,
    /// Tunnel interface, e.g. "utun5".
    pub tunnel_if: String,
    /// Gateway IPs (resolved, not hostnames). Must be non-empty.
    pub gateway_ips: Vec<String>,
    /// Networks allowed out the physical interface, as CIDRs
    /// (e.g. "192.168.0.0/16"). Union of split-excludes and the
    /// kill-switch allowlist; deduplicated in output.
    pub allow_networks: Vec<String>,
    /// Connected set (DESIGN.md §17.5): when true, the final rule
    /// passes the rest of physical-interface outbound instead of
    /// dropping it, so provider-pumped direct traffic can egress.
    /// False (the default) keeps the fail-closed blocking set.
    pub allow_direct_egress: bool,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum PfError {
    EmptyInterface,
    EmptyGateway,
    BadNetwork(String),
    BadIp(String),
}

impl fmt::Display for PfError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            PfError::EmptyInterface => write!(f, "interface name must be non-empty"),
            PfError::EmptyGateway => write!(
                f,
                "at least one gateway IP is required: without it pf would block the reconnect itself"
            ),
            PfError::BadNetwork(n) => write!(f, "invalid CIDR network: {n}"),
            PfError::BadIp(ip) => write!(f, "invalid IP address: {ip}"),
        }
    }
}

impl std::error::Error for PfError {}

fn valid_iface(s: &str) -> bool {
    !s.is_empty() && s.chars().all(|c| !c.is_whitespace())
}

fn valid_ipv4(s: &str) -> bool {
    let parts: Vec<&str> = s.split('.').collect();
    parts.len() == 4
        && parts.iter().all(|p| {
            !p.is_empty()
                && p.len() <= 3
                && p.chars().all(|c| c.is_ascii_digit())
                && p.parse::<u16>().map(|n| n <= 255).unwrap_or(false)
        })
}

fn valid_ipv6_shape(s: &str) -> bool {
    // Shape check only (pfctl validates fully on load): must contain a
    // colon, no whitespace, no slash, hex digits/colons/dots only.
    !s.is_empty()
        && s.contains(':')
        && !s.contains('/')
        && s.chars()
            .all(|c| c.is_ascii_hexdigit() || c == ':' || c == '.')
}

fn valid_ip(s: &str) -> bool {
    valid_ipv4(s) || valid_ipv6_shape(s)
}

fn valid_cidr(s: &str) -> bool {
    let mut it = s.split('/');
    let (Some(addr), Some(prefix), None) = (it.next(), it.next(), it.next()) else {
        return false;
    };
    if prefix.is_empty() || !prefix.chars().all(|c| c.is_ascii_digit()) {
        return false;
    }
    let prefix: u32 = match prefix.parse() {
        Ok(n) => n,
        Err(_) => return false,
    };
    if addr.contains(':') {
        valid_ipv6_shape(addr) && prefix <= 128
    } else {
        valid_ipv4(addr) && prefix <= 32
    }
}

/// Generate the anchor text. Deterministic: same input, same output
/// byte for byte (tests pin the exact text).
pub fn generate(input: &PfInput) -> Result<String, PfError> {
    if !valid_iface(&input.physical_if) || !valid_iface(&input.tunnel_if) {
        return Err(PfError::EmptyInterface);
    }
    if input.gateway_ips.is_empty() {
        return Err(PfError::EmptyGateway);
    }
    for ip in &input.gateway_ips {
        if !valid_ip(ip) {
            return Err(PfError::BadIp(ip.clone()));
        }
    }
    let mut networks: Vec<&str> = Vec::new();
    for n in &input.allow_networks {
        if !valid_cidr(n) {
            return Err(PfError::BadNetwork(n.clone()));
        }
        if !networks.contains(&n.as_str()) {
            networks.push(n.as_str());
        }
    }

    let phys = &input.physical_if;
    let mut out = String::new();
    out.push_str("# AlwaysConnect kill-switch anchor (generated; do not hand-edit)\n");
    out.push_str(&format!(
        "# Physical interface: {phys}. Tunnel interface: {}.\n",
        input.tunnel_if
    ));
    out.push_str(&format!("pass out quick on {} all\n", input.tunnel_if));
    out.push_str("pass out quick on lo0 all\n");
    out.push_str("pass out quick proto udp from any port 68 to any port 67\n");
    for ip in &input.gateway_ips {
        out.push_str(&format!("pass out quick on {phys} to {ip}\n"));
    }
    for n in &networks {
        out.push_str(&format!("pass out quick on {phys} to {n}\n"));
    }
    out.push_str(&format!(
        "pass out quick on {phys} proto udp to 224.0.0.251 port 5353\n"
    ));
    out.push_str(&format!(
        "pass out quick on {phys} proto udp to ff02::fb port 5353\n"
    ));
    out.push_str(&format!("pass out quick on {phys} inet6 to fe80::/10\n"));
    if input.allow_direct_egress {
        out.push_str(&format!("pass out quick on {phys} all\n"));
    } else {
        out.push_str(&format!("block drop out quick on {phys} all\n"));
    }
    Ok(out)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn secure_input() -> PfInput {
        PfInput {
            physical_if: "en0".to_string(),
            tunnel_if: "utun5".to_string(),
            gateway_ips: vec!["203.0.113.10".to_string()],
            allow_networks: vec!["192.168.0.0/16".to_string()],
            allow_direct_egress: false,
        }
    }

    #[test]
    fn secure_mode_exact_output() {
        let expected = "# AlwaysConnect kill-switch anchor (generated; do not hand-edit)\n\
# Physical interface: en0. Tunnel interface: utun5.\n\
pass out quick on utun5 all\n\
pass out quick on lo0 all\n\
pass out quick proto udp from any port 68 to any port 67\n\
pass out quick on en0 to 203.0.113.10\n\
pass out quick on en0 to 192.168.0.0/16\n\
pass out quick on en0 proto udp to 224.0.0.251 port 5353\n\
pass out quick on en0 proto udp to ff02::fb port 5353\n\
pass out quick on en0 inet6 to fe80::/10\n\
block drop out quick on en0 all\n";
        assert_eq!(generate(&secure_input()).unwrap(), expected);
    }

    #[test]
    fn connected_mode_passes_physical_outbound() {
        let input = PfInput {
            allow_direct_egress: true,
            ..secure_input()
        };
        let expected = "# AlwaysConnect kill-switch anchor (generated; do not hand-edit)\n\
# Physical interface: en0. Tunnel interface: utun5.\n\
pass out quick on utun5 all\n\
pass out quick on lo0 all\n\
pass out quick proto udp from any port 68 to any port 67\n\
pass out quick on en0 to 203.0.113.10\n\
pass out quick on en0 to 192.168.0.0/16\n\
pass out quick on en0 proto udp to 224.0.0.251 port 5353\n\
pass out quick on en0 proto udp to ff02::fb port 5353\n\
pass out quick on en0 inet6 to fe80::/10\n\
pass out quick on en0 all\n";
        assert_eq!(generate(&input).unwrap(), expected);
        // The blocking set is unchanged by the new field's default.
        assert!(generate(&secure_input())
            .unwrap()
            .ends_with("block drop out quick on en0 all\n"));
    }

    #[test]
    fn split_mode_extra_networks_and_ipv6() {
        let input = PfInput {
            allow_networks: vec![
                "192.168.0.0/16".to_string(),
                "10.0.0.0/8".to_string(),
                "2001:db8:1::/48".to_string(),
            ],
            gateway_ips: vec!["2001:db8::1".to_string()],
            ..secure_input()
        };
        let text = generate(&input).unwrap();
        // Order preserved: gateway, then allowlist in given order.
        let gw = text.find("to 2001:db8::1\n").unwrap();
        let lan = text.find("to 192.168.0.0/16\n").unwrap();
        let extra = text.find("to 10.0.0.0/8\n").unwrap();
        let v6 = text.find("to 2001:db8:1::/48\n").unwrap();
        let block = text.find("block drop out quick on en0 all\n").unwrap();
        assert!(gw < lan && lan < extra && extra < v6 && v6 < block);
    }

    #[test]
    fn allowlist_deduplicated() {
        let input = PfInput {
            allow_networks: vec![
                "192.168.0.0/16".to_string(),
                "192.168.0.0/16".to_string(),
            ],
            ..secure_input()
        };
        let text = generate(&input).unwrap();
        assert_eq!(text.matches("to 192.168.0.0/16\n").count(), 1);
    }

    #[test]
    fn validation_errors() {
        let mut bad = secure_input();
        bad.physical_if = String::new();
        assert_eq!(generate(&bad), Err(PfError::EmptyInterface));
        let mut bad = secure_input();
        bad.tunnel_if = "utun 5".to_string();
        assert_eq!(generate(&bad), Err(PfError::EmptyInterface));
        let mut bad = secure_input();
        bad.gateway_ips = vec![];
        assert_eq!(generate(&bad), Err(PfError::EmptyGateway));
        let mut bad = secure_input();
        bad.gateway_ips = vec!["999.1.1.1".to_string()];
        assert_eq!(
            generate(&bad),
            Err(PfError::BadIp("999.1.1.1".to_string()))
        );
        let mut bad = secure_input();
        bad.allow_networks = vec!["192.168.1.0/33".to_string()];
        assert_eq!(
            generate(&bad),
            Err(PfError::BadNetwork("192.168.1.0/33".to_string()))
        );
        let mut bad = secure_input();
        bad.allow_networks = vec!["not-a-cidr".to_string()];
        assert_eq!(
            generate(&bad),
            Err(PfError::BadNetwork("not-a-cidr".to_string()))
        );
    }
}
