import Foundation

/// App-side client for the privileged Helper (DESIGN.md §16.9).
///
/// Replaces TunnelManager (SUPERSEDED, Phase 1 step 3): the panel's
/// state source is now Helper-reported state over XPC, never
/// NEVPNStatus. Credentials come from the Keychain and are sent over
/// XPC once per connect; the Helper holds them in memory only.
///
/// Connection lifecycle: the connection is created lazily and kept
/// until interrupted or invalidated, at which point helperAvailable
/// drops to false and the panel shows the red "Helper 未运行" line.
/// A dead Helper does not auto-resurrect the session: the next user
/// action (panel switch, App launch auto-connect) reconnects, so a
/// missing Helper can never spin a silent retry loop.
final class HelperClient: NSObject, ObservableObject, AlwaysConnectHelperClientProtocol {
    static let shared = HelperClient()

    enum State: Int {
        case disconnected = 0
        case connecting = 1
        case authenticating = 2
        case awaitingApproval = 3
        case connected = 4
        case reconnecting = 5
    }

    @Published private(set) var state: State = .disconnected
    @Published private(set) var detail: String = ""
    @Published private(set) var lastError: String?
    @Published private(set) var helperAvailable = false

    private var connection: NSXPCConnection?

    private override init() {}

    /// The panel switch is "on" for every state except a confirmed
    /// manual disconnect. AwaitingApproval keeps the switch on: the
    /// user is mid-flow, not disconnected.
    var switchIsOn: Bool {
        state != .disconnected
    }

    func connect(server: String, group: String, username: String, password: String) {
        ensureConnection { proxy in
            proxy.connect(
                server: server, group: group, username: username, password: password
            ) { [weak self] accepted in
                DispatchQueue.main.async {
                    if !accepted {
                        self?.lastError = "Helper 未接受连接请求"
                    }
                }
            }
        }
    }

    func disconnect() {
        ensureConnection { proxy in
            proxy.disconnect { }
        }
    }

    func refreshStatus() {
        ensureConnection { proxy in
            proxy.getStatus { [weak self] stateCode, detail in
                DispatchQueue.main.async {
                    if let state = State(rawValue: stateCode) {
                        self?.state = state
                    }
                    self?.detail = detail
                }
            }
        }
    }

    // MARK: - AlwaysConnectHelperClientProtocol (Helper -> App pushes)

    func statusChanged(state: Int, detail: String) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if let parsed = State(rawValue: state) {
                self.state = parsed
            }
            self.detail = detail
        }
    }

    // MARK: - Connection management

    private func ensureConnection(_ body: @escaping (AlwaysConnectHelperProtocol) -> Void) {
        if let connection,
           let proxy = connection.remoteObjectProxy as? AlwaysConnectHelperProtocol {
            body(proxy)
            return
        }
        let connection = NSXPCConnection(
            machServiceName: AlwaysConnectHelperMachService, options: [])
        connection.remoteObjectInterface = NSXPCInterface(
            with: AlwaysConnectHelperProtocol.self)
        connection.exportedInterface = NSXPCInterface(
            with: AlwaysConnectHelperClientProtocol.self)
        connection.exportedObject = self
        connection.interruptionHandler = { [weak self] in
            DispatchQueue.main.async {
                self?.helperAvailable = false
                self?.lastError = "Helper 连接中断"
            }
        }
        connection.invalidationHandler = { [weak self] in
            DispatchQueue.main.async {
                self?.helperAvailable = false
                self?.lastError = "Helper 未运行"
                self?.connection = nil
            }
        }
        connection.resume()
        self.connection = connection
        DispatchQueue.main.async { [weak self] in
            self?.helperAvailable = true
        }
        if let proxy = connection.remoteObjectProxy as? AlwaysConnectHelperProtocol {
            body(proxy)
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.lastError = "Helper 协议不匹配"
            }
        }
    }
}
