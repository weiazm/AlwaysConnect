import Foundation

/// Physical-interface discovery for the pump (DESIGN.md §17.3).
/// The provider finds the interface itself (it shares no runtime state
/// with the Helper); the pure selection function is harness-tested,
/// the getifaddrs enumeration is the thin live wrapper.

/// One interface as seen by getifaddrs, merged across its addresses.
struct InterfaceInfo: Equatable {
    var name: String
    var isUp: Bool
    var isRunning: Bool
    var isLoopback: Bool
    var hasIPv4: Bool
}

/// Tunnel-ish interface name prefixes. Anything matching one is never
/// the physical interface, even if it is up with an IPv4 address
/// (utun* is the VPN itself; the rest are other tunnel devices).
private let tunnelPrefixes = ["utun", "stf", "gif", "pdp_ip", "ipsec", "ppp"]

/// Pure selection (DESIGN.md §17.3): filter, then prefer en0, then the
/// lowest enN, then the lexicographically first survivor. Nil means
/// "no usable physical interface" — the caller fails the pump closed
/// (flow goes via VPN) instead of guessing.
func selectPhysicalInterface(from interfaces: [InterfaceInfo]) -> String? {
    let candidates = interfaces.filter { info in
        info.isUp && info.isRunning && !info.isLoopback && info.hasIPv4
            && !tunnelPrefixes.contains(where: { info.name.hasPrefix($0) })
    }
    guard !candidates.isEmpty else { return nil }
    func enNumber(_ name: String) -> Int? {
        guard name.hasPrefix("en") else { return nil }
        return Int(name.dropFirst(2))
    }
    return candidates.sorted { a, b in
        let aEn = enNumber(a.name)
        let bEn = enNumber(b.name)
        // Group 0 = en0, 1 = other enN, 2 = non-en.
        let aGroup = aEn == 0 ? 0 : (aEn == nil ? 2 : 1)
        let bGroup = bEn == 0 ? 0 : (bEn == nil ? 2 : 1)
        if aGroup != bGroup { return aGroup < bGroup }
        if let aEn, let bEn, aEn != bEn { return aEn < bEn }
        return a.name < b.name
    }.first?.name
}

/// Live enumeration via getifaddrs, merged per interface name.
func enumerateInterfaces() -> [InterfaceInfo] {
    var head: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&head) == 0, let head else { return [] }
    defer { freeifaddrs(head) }
    var merged: [String: InterfaceInfo] = [:]
    var cursor: UnsafeMutablePointer<ifaddrs>? = head
    while let current = cursor {
        let ifa = current.pointee
        let name = String(cString: ifa.ifa_name)
        let flags = ifa.ifa_flags
        var info = merged[name] ?? InterfaceInfo(
            name: name,
            isUp: (flags & UInt32(IFF_UP)) != 0,
            isRunning: (flags & UInt32(IFF_RUNNING)) != 0,
            isLoopback: (flags & UInt32(IFF_LOOPBACK)) != 0,
            hasIPv4: false)
        if let addr = ifa.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET) {
            info.hasIPv4 = true
        }
        merged[name] = info
        cursor = ifa.ifa_next
    }
    return Array(merged.values)
}

/// Live discovery: enumerate + select. Nil on a host with no usable
/// physical interface (loopback-only runner, VPN-only routing).
func discoverPhysicalInterface() -> String? {
    selectPhysicalInterface(from: enumerateInterfaces())
}

/// Interface name -> kernel index for IP_BOUND_IF. 0 = unknown.
func interfaceIndex(for name: String) -> UInt32 {
    name.withCString { if_nametoindex($0) }
}
