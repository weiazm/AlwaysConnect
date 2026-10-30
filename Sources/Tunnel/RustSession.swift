import Foundation

/// Swift wrapper over the session driver C ABI (core/src/session.rs,
/// exported in core/src/ffi.rs as ac_session_*).
/// Action and state codes must match the Rust side exactly; see the
/// comment block above ac_session_new in ffi.rs.
final class RustSessionDriver {
    enum Action: Equatable {
        case noAction
        case reconnectInProcess(delay: TimeInterval)
        case reauthenticate(delay: TimeInterval)
        case waitApproval(timeout: TimeInterval)
        case stopNeedsUser
        case tornDown
        case ignored
    }

    /// Outcome codes for ac_session_auth_outcome.
    enum AuthOutcome: Int32 {
        case success = 0
        case needsApproval = 1
        case rejected = 2
        case transient = 3
    }

    private var handle: UnsafeMutableRawPointer?

    init(seed: UInt64) {
        handle = ac_session_new(seed)
    }

    deinit {
        if let h = handle {
            ac_session_free(h)
        }
    }

    var state: SessionStatus {
        guard let h = handle else { return .disconnected }
        switch ac_session_state(h) {
        case 1: return .connecting
        case 2: return .authenticating
        case 3: return .awaitingApproval
        case 4: return .connected
        case 5: return .reconnecting
        default: return .disconnected
        }
    }

    func start() -> Action {
        call { ac_session_start($0, $1) }
    }

    func authenticated() -> Action {
        call { ac_session_authenticated($0, $1) }
    }

    func drop(cookieAlive: Bool) -> Action {
        call { ac_session_drop($0, cookieAlive, $1) }
    }

    func reconnected() -> Action {
        call { ac_session_reconnected($0, $1) }
    }

    func authOutcome(_ outcome: AuthOutcome) -> Action {
        call { ac_session_auth_outcome($0, outcome.rawValue, $1) }
    }

    func approved() -> Action {
        call { ac_session_approved($0, $1) }
    }

    func approvalTimeout() -> Action {
        call { ac_session_approval_timeout($0, $1) }
    }

    func manualDisconnect() -> Action {
        call { ac_session_manual_disconnect($0, $1) }
    }

    /// Runs one C call, decoding its action code and delay/timeout.
    /// A missing handle fails closed to .ignored (never a crash).
    private func call(
        _ fn: (UnsafeMutableRawPointer, UnsafeMutablePointer<Double>) -> Int32
    ) -> Action {
        guard let h = handle else { return .ignored }
        var secs = 0.0
        let code = fn(h, &secs)
        switch code {
        case 1: return .reconnectInProcess(delay: secs)
        case 2: return .reauthenticate(delay: secs)
        case 3: return .waitApproval(timeout: secs)
        case 4: return .stopNeedsUser
        case 5: return .tornDown
        case 6: return .ignored
        default: return .noAction
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
    _ delaySecsOut: UnsafeMutablePointer<Double>
) -> Int32

@_silgen_name("ac_session_authenticated")
func ac_session_authenticated(
    _ handle: UnsafeMutableRawPointer?,
    _ delaySecsOut: UnsafeMutablePointer<Double>
) -> Int32

@_silgen_name("ac_session_drop")
func ac_session_drop(
    _ handle: UnsafeMutableRawPointer?,
    _ cookieAlive: Bool,
    _ delaySecsOut: UnsafeMutablePointer<Double>
) -> Int32

@_silgen_name("ac_session_reconnected")
func ac_session_reconnected(
    _ handle: UnsafeMutableRawPointer?,
    _ delaySecsOut: UnsafeMutablePointer<Double>
) -> Int32

@_silgen_name("ac_session_auth_outcome")
func ac_session_auth_outcome(
    _ handle: UnsafeMutableRawPointer?,
    _ outcome: Int32,
    _ delaySecsOut: UnsafeMutablePointer<Double>
) -> Int32

@_silgen_name("ac_session_approved")
func ac_session_approved(
    _ handle: UnsafeMutableRawPointer?,
    _ delaySecsOut: UnsafeMutablePointer<Double>
) -> Int32

@_silgen_name("ac_session_approval_timeout")
func ac_session_approval_timeout(
    _ handle: UnsafeMutableRawPointer?,
    _ delaySecsOut: UnsafeMutablePointer<Double>
) -> Int32

@_silgen_name("ac_session_manual_disconnect")
func ac_session_manual_disconnect(
    _ handle: UnsafeMutableRawPointer?,
    _ delaySecsOut: UnsafeMutablePointer<Double>
) -> Int32
