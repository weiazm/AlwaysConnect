import Foundation

/// Swift wrapper over the Rust core's session driver (core/src/session.rs
/// via core/src/ffi.rs). The driver is the single source of truth for the
/// Helper-side state machine; the CLI orchestrator feeds it CLI-observed
/// events and honors the actions it returns.
///
/// Action codes (ffi.rs encode_action):
///   0 NoAction, 1 ReconnectInProcess{delay}, 2 Reauthenticate{delay},
///   3 WaitApproval{timeout}, 4 StopNeedsUser, 5 TornDown, 6 Ignored.
/// State codes (ffi.rs encode_state):
///   0 Disconnected, 1 Connecting, 2 Authenticating, 3 AwaitingApproval,
///   4 Connected, 5 Reconnecting; -1 on null handle.
/// AuthOutcome codes in (ac_session_auth_outcome):
///   0 Success, 1 NeedsApproval, 2 Rejected, 3 Transient.
///
/// Threading: confined to the orchestrator's queue (same pattern as
/// RustRuleEngine). The Rust side is Mutex-protected, but this class
/// itself is deliberately not Sendable.
final class SessionDriverClient {
    enum State: Int {
        case disconnected = 0
        case connecting = 1
        case authenticating = 2
        case awaitingApproval = 3
        case connected = 4
        case reconnecting = 5
    }

    enum Action {
        case noAction
        case reconnectInProcess(delay: Double)
        case reauthenticate(delay: Double)
        case waitApproval(timeout: Double)
        case stopNeedsUser
        case tornDown
        case ignored
    }

    private var handle: UnsafeMutableRawPointer?

    init() {
        let seed = UInt64(Date().timeIntervalSince1970 * 1000)
        handle = ac_session_new(seed)
    }

    deinit {
        if let h = handle {
            ac_session_free(h)
        }
    }

    var state: State? {
        guard let h = handle else { return nil }
        return State(rawValue: Int(ac_session_state(h)))
    }

    @discardableResult
    func start() -> Action {
        call { ac_session_start($0, &$1) }
    }

    @discardableResult
    func authenticated() -> Action {
        call { ac_session_authenticated($0, &$1) }
    }

    @discardableResult
    func drop(cookieAlive: Bool) -> Action {
        call { ac_session_drop($0, cookieAlive, &$1) }
    }

    @discardableResult
    func authOutcome(_ outcome: Int32) -> Action {
        call { ac_session_auth_outcome($0, outcome, &$1) }
    }

    @discardableResult
    func approved() -> Action {
        call { ac_session_approved($0, &$1) }
    }

    @discardableResult
    func approvalTimeout() -> Action {
        call { ac_session_approval_timeout($0, &$1) }
    }

    @discardableResult
    func manualDisconnect() -> Action {
        call { ac_session_manual_disconnect($0, &$1) }
    }

    private func call(
        _ fn: (UnsafeMutableRawPointer?, inout Double) -> Int32
    ) -> Action {
        guard let h = handle else { return .ignored }
        var delay: Double = 0
        let code = fn(h, &delay)
        switch code {
        case 0: return .noAction
        case 1: return .reconnectInProcess(delay: delay)
        case 2: return .reauthenticate(delay: delay)
        case 3: return .waitApproval(timeout: delay)
        case 4: return .stopNeedsUser
        case 5: return .tornDown
        default: return .ignored
        }
    }
}

// MARK: - C ABI imports (alwaysconnect-core, core/src/ffi.rs)

@_silgen_name("ac_session_new")
func ac_session_new(_ seed: UInt64) -> UnsafeMutableRawPointer?

@_silgen_name("ac_session_free")
func ac_session_free(_ handle: UnsafeMutableRawPointer?)

@_silgen_name("ac_session_state")
func ac_session_state(_ handle: UnsafeMutableRawPointer?) -> Int32

@_silgen_name("ac_session_start")
func ac_session_start(
    _ handle: UnsafeMutableRawPointer?,
    _ delaySecsOut: UnsafeMutablePointer<Double>?
) -> Int32

@_silgen_name("ac_session_authenticated")
func ac_session_authenticated(
    _ handle: UnsafeMutableRawPointer?,
    _ delaySecsOut: UnsafeMutablePointer<Double>?
) -> Int32

@_silgen_name("ac_session_drop")
func ac_session_drop(
    _ handle: UnsafeMutableRawPointer?,
    _ cookieAlive: Bool,
    _ delaySecsOut: UnsafeMutablePointer<Double>?
) -> Int32

@_silgen_name("ac_session_auth_outcome")
func ac_session_auth_outcome(
    _ handle: UnsafeMutableRawPointer?,
    _ outcome: Int32,
    _ delaySecsOut: UnsafeMutablePointer<Double>?
) -> Int32

@_silgen_name("ac_session_approved")
func ac_session_approved(
    _ handle: UnsafeMutableRawPointer?,
    _ delaySecsOut: UnsafeMutablePointer<Double>?
) -> Int32

@_silgen_name("ac_session_approval_timeout")
func ac_session_approval_timeout(
    _ handle: UnsafeMutableRawPointer?,
    _ delaySecsOut: UnsafeMutablePointer<Double>?
) -> Int32

@_silgen_name("ac_session_manual_disconnect")
func ac_session_manual_disconnect(
    _ handle: UnsafeMutableRawPointer?,
    _ delaySecsOut: UnsafeMutablePointer<Double>?
) -> Int32
