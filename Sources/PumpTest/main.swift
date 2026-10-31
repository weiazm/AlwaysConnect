import Foundation

/// PumpTest: runner-verifiable checks for the Phase 2 pump core
/// (DESIGN.md §17.6). No NetworkExtension here: socketpairs stand in
/// for flows, so the SAME Relay + FDEndpoint code the provider uses
/// is exercised for real bytes, half-close, and error teardown.
/// Exit 0 iff every hard check passes; IPv6 bind is reported but not
/// asserted (a runner without IPv6 loopback would fail it for
/// environmental reasons, not code reasons).
///
/// All diagnostics go to stderr, unbuffered: stdout is block-buffered
/// when piped, so a crash (SIGTRAP) would otherwise swallow every
/// PASS line printed before it and hide which check died.

var failures = 0

func log(_ line: String) {
    FileHandle.standardError.write((line + "\n").data(using: .utf8)!)
}

func check(_ name: String, _ body: () -> Bool) {
    log("START \(name)")
    let ok = body()
    log("\(ok ? "PASS" : "FAIL") \(name)")
    if !ok { failures += 1 }
}

func setNonBlocking(_ fd: Int32) {
    let flags = Darwin.fcntl(fd, F_GETFL)
    _ = Darwin.fcntl(fd, F_SETFL, flags | O_NONBLOCK)
}

func setRecvTimeout(_ fd: Int32, seconds: Int) {
    var tv = timeval(tv_sec: seconds, tv_usec: 0)
    _ = Darwin.setsockopt(
        fd, SOL_SOCKET, SO_RCVTIMEO, &tv,
        socklen_t(MemoryLayout<timeval>.size))
}

func makePair() -> (Int32, Int32)? {
    var fds = [Int32](repeating: -1, count: 2)
    guard Darwin.socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0 else {
        return nil
    }
    return (fds[0], fds[1])
}

func writeAll(_ fd: Int32, _ string: String) -> Bool {
    let bytes = Array(string.utf8)
    var sent = 0
    while sent < bytes.count {
        let n = bytes.withUnsafeBytes { raw in
            Darwin.write(fd, raw.baseAddress!.advanced(by: sent), bytes.count - sent)
        }
        if n <= 0 { return false }
        sent += n
    }
    return true
}

func readExact(_ fd: Int32, _ count: Int) -> String? {
    var buffer = [UInt8](repeating: 0, count: count)
    var got = 0
    while got < count {
        let n = buffer.withUnsafeMutableBytes { raw in
            Darwin.read(fd, raw.baseAddress!.advanced(by: got), count - got)
        }
        if n <= 0 { return nil }
        got += n
    }
    return String(bytes: buffer, encoding: .utf8)
}

func readEOF(_ fd: Int32) -> Bool {
    var byte: UInt8 = 0
    return Darwin.read(fd, &byte, 1) == 0
}

// MARK: - Relay checks

check("relay bytes both directions") {
    guard let (a1, a2) = makePair(), let (b1, b2) = makePair() else {
        return false
    }
    // Only the test-side fds are closed here: a2/b2 belong to the
    // endpoints, which close them on relay finish. Closing them here
    // would race the endpoints' async close and could double-close a
    // reused fd number.
    defer {
        Darwin.close(a1)
        Darwin.close(b1)
    }
    setNonBlocking(a2); setNonBlocking(b2)
    setRecvTimeout(a1, seconds: 5); setRecvTimeout(b1, seconds: 5)
    let done = DispatchSemaphore(value: 0)
    let relay = Relay(
        a: FDEndpoint(fd: a2), b: FDEndpoint(fd: b2)) { done.signal() }
    relay.start()
    guard writeAll(a1, "hello") else { return false }
    guard readExact(b1, 5) == "hello" else { return false }
    guard writeAll(b1, "world") else { return false }
    guard readExact(a1, 5) == "world" else { return false }
    relay.stop()
    guard done.wait(timeout: .now() + 5) == .success else { return false }
    // Same drain as the half-close check: let the endpoints' async
    // closes finish before the next check reuses fd numbers.
    usleep(100_000)
    return true
}

check("relay half-close drains then finishes") {
    guard let (a1, a2) = makePair(), let (b1, b2) = makePair() else {
        return false
    }
    // Test-side fds only (see the first check): a2/b2 belong to the
    // endpoints.
    defer {
        Darwin.close(a1)
        Darwin.close(b1)
    }
    setNonBlocking(a2); setNonBlocking(b2)
    setRecvTimeout(a1, seconds: 5); setRecvTimeout(b1, seconds: 5)
    let done = DispatchSemaphore(value: 0)
    let relay = Relay(
        a: FDEndpoint(fd: a2), b: FDEndpoint(fd: b2)) { done.signal() }
    relay.start()
    // a1 half-closes: b1 must see EOF, but b1 -> a1 still flows.
    log("  half-close: shutdown a1 write")
    Darwin.shutdown(a1, Int32(SHUT_WR))
    guard readEOF(b1) else { log("  half-close: b1 EOF missing"); return false }
    log("  half-close: b1 saw EOF")
    guard writeAll(b1, "back") else { log("  half-close: b1 write failed"); return false }
    log("  half-close: b1 wrote back")
    guard readExact(a1, 4) == "back" else { log("  half-close: a1 back mismatch"); return false }
    log("  half-close: a1 got back")
    // b1 half-closes: a1 must see EOF, and the relay finishes.
    Darwin.shutdown(b1, Int32(SHUT_WR))
    log("  half-close: shutdown b1 write")
    guard readEOF(a1) else { log("  half-close: a1 EOF missing"); return false }
    log("  half-close: a1 saw EOF")
    guard done.wait(timeout: .now() + 5) == .success else {
        log("  half-close: onDone missing")
        return false
    }
    log("  half-close: onDone fired")
    // Let the endpoints' async closes drain before the next check
    // creates new socketpairs: otherwise a pending close can land on
    // a reused fd number and corrupt the next check's sockets.
    usleep(100_000)
    return true
}

check("relay error teardown finishes") {
    guard let (a1, a2) = makePair(), let (b1, b2) = makePair() else {
        return false
    }
    // a1 only: b1 is closed abruptly in the body, a2/b2 belong to the
    // endpoints.
    defer {
        Darwin.close(a1)
    }
    setNonBlocking(a2); setNonBlocking(b2)
    let done = DispatchSemaphore(value: 0)
    let relay = Relay(
        a: FDEndpoint(fd: a2), b: FDEndpoint(fd: b2)) { done.signal() }
    relay.start()
    // RST the b side (linger 0 + close), then push bytes at a1: the
    // relay must fail the pump and fire onDone, not stall.
    var ling = linger(l_onoff: 1, l_linger: 0)
    _ = Darwin.setsockopt(
        b1, SOL_SOCKET, SO_LINGER, &ling,
        socklen_t(MemoryLayout<linger>.size))
    Darwin.close(b1)
    _ = writeAll(a1, "x")
    return done.wait(timeout: .now() + 5) == .success
}

// MARK: - Interface selection checks (pure function)

func info(
    _ name: String, up: Bool = true, running: Bool = true,
    loopback: Bool = false, v4: Bool = true
) -> InterfaceInfo {
    InterfaceInfo(
        name: name, isUp: up, isRunning: running,
        isLoopback: loopback, hasIPv4: v4)
}

check("select single candidate") {
    selectPhysicalInterface(from: [info("en0")]) == "en0"
}

check("select prefers en0 over en1") {
    selectPhysicalInterface(from: [info("en1"), info("en0")]) == "en0"
}

check("select excludes tunnel and loopback") {
    selectPhysicalInterface(from: [
        info("utun5"), info("lo0", loopback: true), info("en0"),
    ]) == "en0"
}

check("select nil when nothing usable") {
    selectPhysicalInterface(from: [
        info("lo0", loopback: true),
        info("utun5"),
        info("en0", v4: false),
        info("en1", up: false),
    ]) == nil
}

check("select lowest enN then lexicographic") {
    selectPhysicalInterface(from: [
        info("eth1"), info("en3"), info("en2"), info("eth0"),
    ]) == "en2"
}

// MARK: - Bind smoke checks (real setsockopt, no network needed)

check("IP_BOUND_IF setsockopt succeeds") {
    let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
    guard fd >= 0 else { return false }
    defer { Darwin.close(fd) }
    let lo0 = interfaceIndex(for: "lo0")
    guard lo0 != 0 else { return false }
    var idx = lo0
    return Darwin.setsockopt(
        fd, IPPROTO_IP, IP_BOUND_IF, &idx,
        socklen_t(MemoryLayout<UInt32>.size)) == 0
}

// IPv6 bind is reported, not asserted: see the header comment.
do {
    let fd = Darwin.socket(AF_INET6, SOCK_STREAM, 0)
    if fd >= 0 {
        defer { Darwin.close(fd) }
        let lo0 = interfaceIndex(for: "lo0")
        var idx = lo0
        let ok = lo0 != 0 && Darwin.setsockopt(
            fd, IPPROTO_IPV6, IPV6_BOUND_IF, &idx,
            socklen_t(MemoryLayout<UInt32>.size)) == 0
        log("INFO IPV6_BOUND_IF setsockopt: \(ok ? "ok" : "unavailable")")
    } else {
        log("INFO IPV6_BOUND_IF setsockopt: no IPv6 socket")
    }
}

// Live discovery is informational only: a loopback-only runner has
// no physical interface, and that is not a code failure.
log("INFO live physical interface: \(discoverPhysicalInterface() ?? "none")")

log(failures == 0 ? "PUMPTEST ALL PASS" : "PUMPTEST \(failures) FAILURES")
exit(failures == 0 ? 0 : 1)
