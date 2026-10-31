import AppKit
import Foundation
import Security

/// Helper-side XPC daemon (DESIGN.md §16.9).
///
/// Run as a LaunchDaemon (root) via `AlwaysConnectHelper daemon`. It
/// owns one CLIOrchestrator at a time and forwards its state to the
/// App over XPC. The daemon never stores credentials: they arrive per
/// connect call and live only in the engine's memory.
///
/// Client validation: the connecting process must be signed with the
/// same team identifier as the Helper itself. The team is read off
/// the client's executable (via its pid) and off the Helper's own
/// code, both as static codes — NSXPCConnection exposes no audit
/// token to Swift, so the pid path is the one that compiles. In
/// unsigned dev builds both sides report no team identifier, which is
/// accepted with a log line; once signed with a real team ID, only
/// same-team clients pass. A mismatched client is refused at the
/// listener, before any method runs — an arbitrary local process
/// cannot drive the root daemon's pf rules or tunnel.
final class HelperDaemon: NSObject, NSXPCListenerDelegate {
    private let listener: NSXPCListener
    private var sessions: [HelperSession] = []

    init(machServiceName: String = AlwaysConnectHelperMachService) {
        listener = NSXPCListener(machServiceName: machServiceName)
        super.init()
        listener.delegate = self
    }

    func start() {
        listener.resume()
    }

    // MARK: - NSXPCListenerDelegate

    func listener(
        _ listener: NSXPCListener,
        shouldAcceptNewConnection connection: NSXPCConnection
    ) -> Bool {
        guard Self.clientTeamMatchesSelf(connection) else {
            fputs("HelperDaemon: refused client with mismatched team identifier\n", stderr)
            return false
        }
        let session = HelperSession()
        session.connection = connection
        sessions.append(session)
        connection.exportedInterface = NSXPCInterface(with: AlwaysConnectHelperProtocol.self)
        connection.exportedObject = session
        connection.remoteObjectInterface = NSXPCInterface(
            with: AlwaysConnectHelperClientProtocol.self)
        connection.invalidationHandler = { [weak self, weak session] in
            guard let self, let session else { return }
            session.shutdown()
            self.sessions.removeAll { $0 === session }
        }
        connection.resume()
        session.pushCurrentStatus()
        return true
    }

    // MARK: - Team validation

    private static func teamIdentifier(fromStaticCode code: SecStaticCode) -> String? {
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, [], &info) == errSecSuccess,
              let info
        else { return nil }
        return (info as NSDictionary)[kSecCodeInfoTeamIdentifier as String] as? String
    }

    private static func teamIdentifier(for connection: NSXPCConnection) -> String? {
        guard let app = NSRunningApplication(processIdentifier: connection.processIdentifier),
              let url = app.executableURL
        else { return nil }
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &staticCode) == errSecSuccess,
              let staticCode
        else { return nil }
        return teamIdentifier(fromStaticCode: staticCode)
    }

    private static func ownTeamIdentifier() -> String? {
        var selfCode: SecCode?
        guard SecCodeCopySelf([], &selfCode) == errSecSuccess,
              let selfCode
        else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(selfCode, [], &staticCode) == errSecSuccess,
              let staticCode
        else { return nil }
        return teamIdentifier(fromStaticCode: staticCode)
    }

    private static func clientTeamMatchesSelf(_ connection: NSXPCConnection) -> Bool {
        let client = teamIdentifier(for: connection)
        let own = ownTeamIdentifier()
        if client == nil, own == nil {
            // Unsigned dev builds on both sides: allowed, logged.
            fputs("HelperDaemon: unsigned client accepted (dev only)\n", stderr)
            return true
        }
        return client == own
    }
}

/// One App connection's session: translates XPC calls into engine
/// actions and engine state into XPC pushes.
final class HelperSession: NSObject, AlwaysConnectHelperProtocol {
    weak var connection: NSXPCConnection?
    private var engine: CLIOrchestrator?
    private var lastStateCode = 0
    private var lastDetail = ""

    func connect(
        server: String,
        group: String,
        username: String,
        password: String,
        withReply reply: @escaping (Bool) -> Void
    ) {
        engine?.stop()
        engine = nil
        let script: String
        do {
            script = try VpncScript.install()
        } catch {
            reply(false)
            return
        }
        let config = CLIOrchestrator.Config(
            server: server,
            group: group,
            username: username,
            password: password,
            openconnectPath: nil,
            scriptPath: script,
            cookieStore: CookieStore(fileURL: CookieStore.defaultFileURL),
            physicalIf: "en0",
            allowNetworks: ["192.168.0.0/16"],
            maxAttempts: nil,
            noRoutes: false,
            supportDir: nil
        )
        let engine = CLIOrchestrator(config: config)
        engine.onState = { [weak self] state, detail in
            guard let self else { return }
            self.lastStateCode = state.rawValue
            self.lastDetail = detail
            self.push(state: state.rawValue, detail: detail)
        }
        engine.onTerminal = { [weak self] reason in
            guard let self else { return }
            // Terminal state is already reflected by the last pushed
            // state + detail; the App maps authFailure to its error row.
            if reason == .authFailure, let error = engine.lastError {
                self.push(state: self.lastStateCode, detail: error)
            }
        }
        self.engine = engine
        engine.start()
        reply(true)
    }

    func disconnect(withReply reply: @escaping () -> Void) {
        engine?.stop()
        reply()
    }

    func getStatus(withReply reply: @escaping (Int, String) -> Void) {
        reply(lastStateCode, lastDetail)
    }

    func pushCurrentStatus() {
        push(state: lastStateCode, detail: lastDetail)
    }

    func shutdown() {
        engine?.stop()
        engine = nil
    }

    private func push(state: Int, detail: String) {
        guard let proxy = connection?.remoteObjectProxy
                as? AlwaysConnectHelperClientProtocol
        else { return }
        proxy.statusChanged(state: state, detail: detail)
    }
}
