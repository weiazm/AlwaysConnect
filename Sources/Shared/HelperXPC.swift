import Foundation

/// Shared XPC contract between the App and the privileged Helper
/// (DESIGN.md §16.1/§16.9). This file is compiled into BOTH targets
/// (Sources/Shared is in the App's and the Helper's source lists),
/// so the protocol, service name, and state codes cannot drift apart.
///
/// State codes match the Rust session driver (ffi.rs encode_state):
///   0 Disconnected, 1 Connecting, 2 Authenticating,
///   3 AwaitingApproval, 4 Connected, 5 Reconnecting.
/// There is no seventh state: a credentials rejection is reported as
/// the error detail on a terminal callback, not as a state.

let AlwaysConnectHelperMachService = "com.alwaysconnect.app.helper"

/// App -> Helper. All methods carry a reply block, as NSXPC requires
/// for two-way calls.
@objc protocol AlwaysConnectHelperProtocol {
    /// Start (or restart) a session. Credentials travel over XPC and
    /// live only in Helper memory; they are never written to disk.
    /// Reply: true when the engine accepted the request.
    func connect(
        server: String,
        group: String,
        username: String,
        password: String,
        withReply reply: @escaping (Bool) -> Void
    )
    /// User-confirmed manual disconnect: stop the CLI, restore the
    /// local network, unload pf.
    func disconnect(withReply reply: @escaping () -> Void)
    /// Current state code + human-readable detail (reason + next step,
    /// never a raw error dump, never a credential).
    func getStatus(withReply reply: @escaping (Int, String) -> Void)
}

/// Helper -> App. Fire-and-forget pushes (no reply block): the Helper
/// reports every state change the moment it happens; the App never
/// polls.
@objc protocol AlwaysConnectHelperClientProtocol {
    func statusChanged(state: Int, detail: String)
}
