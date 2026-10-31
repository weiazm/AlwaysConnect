import Foundation
import NetworkExtension

/// NE flow adapter for the pump (DESIGN.md §17.4) + the interface-bound
/// outbound socket (DESIGN.md §17.2).
///
/// Failure direction, stated once because it shapes every branch here:
/// a synchronous setup failure (no physical interface, unusable
/// endpoint) makes handleNewFlow return false, so the flow goes via
/// VPN. An asynchronous failure AFTER handleNewFlow returned true
/// (flow open error, connect timeout) cannot hand the flow back, so
/// the connection closes instead of silently falling back to VPN:
/// a direct rule that silently becomes a VPN route would violate the
/// rule the user wrote. No path ever opens an unbound socket for a
/// direct flow — a bind failure is a pump failure, never a fallback.

/// Outbound socket bound to the physical interface (DESIGN.md §17.2).
/// Only the bound path exists: if setsockopt(IP_BOUND_IF /
/// IPV6_BOUND_IF) fails, the socket is closed and the next address
/// tried; there is no unbound fallback.
enum BoundSocket {
    /// Connects to host:port through interface ifIndex. Returns a
    /// non-blocking connected fd, or nil when every resolved address
    /// failed (bind failure included). The caller owns the fd.
    /// The port passes through to getaddrinfo as the service string
    /// (NWHostEndpoint.port is a String in this SDK, e.g. "443").
    static func connect(
        host: String, port: String, ifIndex: UInt32, socktype: Int32
    ) -> Int32? {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = socktype
        var res: UnsafeMutablePointer<addrinfo>?
        let status = host.withCString { h in
            port.withCString { p in
                getaddrinfo(h, p, &hints, &res)
            }
        }
        guard status == 0, let res else { return nil }
        defer { freeaddrinfo(res) }
        var ai: UnsafeMutablePointer<addrinfo>? = res
        while let current = ai {
            let info = current.pointee
            let fd = Darwin.socket(info.ai_family, info.ai_socktype, info.ai_protocol)
            if fd >= 0 {
                var idx = ifIndex
                let bound: Int32
                if info.ai_family == AF_INET {
                    bound = Darwin.setsockopt(
                        fd, IPPROTO_IP, IP_BOUND_IF, &idx,
                        socklen_t(MemoryLayout<UInt32>.size))
                } else if info.ai_family == AF_INET6 {
                    bound = Darwin.setsockopt(
                        fd, IPPROTO_IPV6, IPV6_BOUND_IF, &idx,
                        socklen_t(MemoryLayout<UInt32>.size))
                } else {
                    bound = -1
                }
                if bound == 0,
                   let addr = info.ai_addr,
                   Darwin.connect(fd, addr, info.ai_addrlen) == 0 {
                    _ = Darwin.fcntl(fd, F_SETFL, O_NONBLOCK)
                    return fd
                }
                Darwin.close(fd)
            }
            ai = info.ai_next
        }
        return nil
    }
}

/// NE TCP flow as a PumpEndpoint (DESIGN.md §17.4). EOF is the
/// empty-data + nil-error completion, which the relay already treats
/// as EOF; close() is closeRead + closeWrite (NE has no separate
/// single close).
final class TCPFlowEndpoint: PumpEndpoint {
    private let flow: NEAppProxyTCPFlow

    init(flow: NEAppProxyTCPFlow) { self.flow = flow }

    func read(completion: @escaping (Data?, Error?) -> Void) {
        flow.readData(completionHandler: completion)
    }

    func write(_ data: Data, completion: @escaping (Error?) -> Void) {
        if data.isEmpty {
            completion(nil)
            return
        }
        flow.writeData(data, withCompletionHandler: completion)
    }

    func closeRead() { flow.closeReadWithError(nil) }
    func closeWrite() { flow.closeWriteWithError(nil) }

    func close() {
        flow.closeReadWithError(nil)
        flow.closeWriteWithError(nil)
    }
}

protocol FlowPumpCancellable: AnyObject {
    var onDone: (() -> Void)? { get set }
    func start() -> Bool
    func cancel()
}

/// TCP pump: NE flow <-> interface-bound socket, via Relay.
/// The socket connect runs on a background queue so a slow connect
/// never stalls the provider queue; a 30s setup timeout tears the
/// pump down (flow closed, socket closed) if open/connect did not
/// both complete.
final class TCPFlowPump: FlowPumpCancellable {
    var onDone: (() -> Void)?

    private let flow: NEAppProxyTCPFlow
    private let ifIndex: UInt32
    private let queue = DispatchQueue(label: "com.alwaysconnect.pump.tcp")
    private var relay: Relay?
    private var flowEndpoint: TCPFlowEndpoint?
    private var fdEndpoint: FDEndpoint?
    private var socketFd: Int32 = -1
    private var flowOpened = false
    private var socketReady = false
    private var tornDown = false
    private var timeoutItem: DispatchWorkItem?

    init(flow: NEAppProxyTCPFlow, ifIndex: UInt32) {
        self.flow = flow
        self.ifIndex = ifIndex
    }

    /// False only for a synchronously unusable endpoint (not a host
    /// endpoint, empty hostname, empty port): the caller then returns
    /// false from handleNewFlow and the flow goes via VPN.
    func start() -> Bool {
        guard let hostEndpoint = flow.remoteEndpoint as? NWHostEndpoint,
              !hostEndpoint.hostname.isEmpty, !hostEndpoint.port.isEmpty else {
            return false
        }
        let host = hostEndpoint.hostname
        let port = hostEndpoint.port
        let ifIndex = self.ifIndex
        flow.open(withLocalEndpoint: nil) { [weak self] error in
            self?.queue.async {
                guard let self, !self.tornDown else { return }
                if error != nil {
                    self.tearDown()
                    return
                }
                self.flowOpened = true
                self.maybeStartRelay()
            }
        }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let fd = BoundSocket.connect(
                host: host, port: port, ifIndex: ifIndex,
                socktype: SOCK_STREAM)
            guard let self else {
                // Pump gone: the fd must not outlive it.
                if let fd { Darwin.close(fd) }
                return
            }
            self.queue.async {
                guard !self.tornDown else {
                    if let fd { Darwin.close(fd) }
                    return
                }
                if let fd {
                    self.socketFd = fd
                    self.socketReady = true
                    self.maybeStartRelay()
                } else {
                    self.tearDown()
                }
            }
        }
        let item = DispatchWorkItem { [weak self] in
            self?.queue.async { self?.tearDown() }
        }
        timeoutItem = item
        queue.asyncAfter(deadline: .now() + 30, execute: item)
        return true
    }

    func cancel() {
        queue.async { [weak self] in self?.tearDown() }
    }

    private func maybeStartRelay() {
        guard flowOpened, socketReady, relay == nil, !tornDown else { return }
        timeoutItem?.cancel()
        timeoutItem = nil
        let flowEndpoint = TCPFlowEndpoint(flow: flow)
        let fdEndpoint = FDEndpoint(fd: socketFd)
        self.flowEndpoint = flowEndpoint
        self.fdEndpoint = fdEndpoint
        let relay = Relay(
            a: flowEndpoint,
            b: fdEndpoint) { [weak self] in
                self?.queue.async { self?.tearDown() }
            }
        self.relay = relay
        relay.start()
    }

    private func tearDown() {
        guard !tornDown else { return }
        tornDown = true
        timeoutItem?.cancel()
        timeoutItem = nil
        // Close the endpoints directly: relay.stop() is async, and if
        // the pump is released right after onDone, the relay's queued
        // teardown may never run — the endpoints must not depend on
        // it. All closes here are idempotent (FDEndpoint's closed flag,
        // NE's repeated close), so a later relay finish is harmless.
        relay?.stop()
        flowEndpoint?.close()
        fdEndpoint?.close()
        if relay == nil {
            // The fd still belongs to the pump (never handed to an
            // endpoint); the relay path closes both endpoints itself.
            flow.closeReadWithError(nil)
            flow.closeWriteWithError(nil)
            if socketFd >= 0 {
                Darwin.close(socketFd)
                socketFd = -1
            }
        }
        onDone?()
    }
}

/// UDP pump: one interface-bound connected UDP socket per remote
/// endpoint seen in the flow's datagrams (DESIGN.md §17.4). Datagrams
/// to an endpoint that cannot be bound are dropped (UDP is
/// unreliable by contract; the flow itself survives). 120s of total
/// idleness closes the pump.
final class UDPFlowPump: FlowPumpCancellable {
    var onDone: (() -> Void)?

    private let flow: NEAppProxyUDPFlow
    private let ifIndex: UInt32
    private let queue = DispatchQueue(label: "com.alwaysconnect.pump.udp")
    private var sockets: [String: UDPSocket] = [:]
    private var tornDown = false
    private var idleItem: DispatchWorkItem?

    private struct UDPSocket {
        var fd: Int32
        var source: DispatchSourceRead
        var endpoint: NWEndpoint
    }

    init(flow: NEAppProxyUDPFlow, ifIndex: UInt32) {
        self.flow = flow
        self.ifIndex = ifIndex
    }

    func start() -> Bool {
        flow.open(withLocalEndpoint: nil) { [weak self] error in
            self?.queue.async {
                guard let self, !self.tornDown else { return }
                if error != nil {
                    self.tearDown()
                    return
                }
                self.readLoop()
                self.armIdleTimer()
            }
        }
        return true
    }

    func cancel() {
        queue.async { [weak self] in self?.tearDown() }
    }

    private func endpointKey(_ endpoint: NWEndpoint) -> String {
        if let host = endpoint as? NWHostEndpoint {
            return "\(host.hostname):\(host.port)"
        }
        return String(describing: endpoint)
    }

    private func readLoop() {
        flow.readDatagrams { [weak self] datas, endpoints, error in
            self?.queue.async {
                guard let self, !self.tornDown else { return }
                if error != nil {
                    self.tearDown()
                    return
                }
                if let datas, let endpoints {
                    for (data, endpoint) in zip(datas, endpoints) {
                        self.sendDatagram(data, to: endpoint)
                    }
                }
                self.armIdleTimer()
                self.readLoop()
            }
        }
    }

    private func sendDatagram(_ data: Data, to endpoint: NWEndpoint) {
        let key = endpointKey(endpoint)
        if sockets[key] == nil {
            guard let host = endpoint as? NWHostEndpoint,
                  !host.hostname.isEmpty, !host.port.isEmpty,
                  let fd = BoundSocket.connect(
                    host: host.hostname, port: host.port,
                    ifIndex: ifIndex, socktype: SOCK_DGRAM) else {
                return // Unresolvable/unbindable endpoint: drop.
            }
            let source = DispatchSource.makeReadSource(
                fileDescriptor: fd, queue: queue)
            source.setEventHandler { [weak self] in
                self?.onSocketReadable(key: key)
            }
            source.setCancelHandler {}
            source.resume()
            sockets[key] = UDPSocket(fd: fd, source: source, endpoint: endpoint)
        }
        guard let socket = sockets[key] else { return }
        data.withUnsafeBytes { raw in
            if let base = raw.baseAddress {
                _ = Darwin.send(socket.fd, base, data.count, 0)
            }
        }
        armIdleTimer()
    }

    private func onSocketReadable(key: String) {
        guard let socket = sockets[key], !tornDown else { return }
        var buffer = [UInt8](repeating: 0, count: 65536)
        let n = buffer.withUnsafeMutableBytes { raw in
            Darwin.recv(socket.fd, raw.baseAddress!, 65536, 0)
        }
        guard n > 0 else {
            if n < 0 {
                let err = errno
                if err != EAGAIN && err != EWOULDBLOCK {
                    closeSocket(key: key)
                }
            }
            return
        }
        armIdleTimer()
        let data = Data(buffer[..<n])
        flow.writeDatagrams([data], sentBy: [socket.endpoint]) { _ in }
    }

    private func closeSocket(key: String) {
        if let socket = sockets.removeValue(forKey: key) {
            socket.source.cancel()
            Darwin.close(socket.fd)
        }
    }

    private func armIdleTimer() {
        idleItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            self?.queue.async { self?.tearDown() }
        }
        idleItem = item
        queue.asyncAfter(deadline: .now() + 120, execute: item)
    }

    private func tearDown() {
        guard !tornDown else { return }
        tornDown = true
        idleItem?.cancel()
        idleItem = nil
        for key in sockets.keys { closeSocket(key: key) }
        flow.closeReadWithError(nil)
        flow.closeWriteWithError(nil)
        onDone?()
    }
}
