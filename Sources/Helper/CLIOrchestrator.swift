import Foundation

/// Helper-side openconnect CLI orchestration (DESIGN.md §15/§16).
///
/// Owns one session's lifecycle: spawn the CLI, feed the credential
/// over stdin, watch stdout/stderr, classify the child exit, and drive
/// the Rust session driver (SessionBridge) for state and retry
/// decisions. It never guesses: classification uses only Helper-observed
/// facts — the stop flag, the vpnc-script `AC_HOOK connect` signal,
/// which credential was fed, and stderr lines measured against
/// ocserv 1.2.4 + openconnect 9.12 (2026-10-31, see DESIGN.md §16.3).
///
/// Credential flow:
/// - Prefer a usable stored cookie (--cookie-on-stdin); else password
///   (--passwd-on-stdin). The password lives only in memory.
/// - The tunnel cookie is captured from the child's verbose stdout
///   (`Set-Cookie: webvpn=`) and persisted via CookieStore (0600).
///   A cookie-fed run that exits without a connect hook discards the
///   record and falls back to password once.
/// - A password-fed run that prints "Login failed." is an
///   AuthFailure: the engine closes stdin (the child then exits on
///   its own, as measured) and stops without retrying, so a bad
///   password can never loop into an account lockout.
///
/// Fail-closed: routes and pf are touched only on the connect hook
/// (load) and on a manual stop (unload + flag file so the script's
/// disconnect path restores the local network). Every other exit
/// leaves them in place.
///
/// The child process's stdout/stderr are NEVER logged raw: they can
/// carry the tunnel cookie. All stored/printed lines pass redact().
final class CLIOrchestrator {
    struct Config {
        var server: String
        var group: String
        var username: String
        var password: String
        var openconnectPath: String?
        var scriptPath: String
        var cookieStore: CookieStore
        var physicalIf: String
        var allowNetworks: [String]
        var maxAttempts: Int?
        var noRoutes: Bool
        /// Directory for the manual-disconnect flag file. Nil means the
        /// default Application Support dir (correct for the root
        /// daemon; run-once tests inject a temp dir).
        var supportDir: URL?
    }

    enum FedCredential { case password, cookie }
    enum TerminalReason { case stoppedManual, authFailure, attemptsExhausted }

    var onState: ((SessionDriverClient.State, String) -> Void)?
    var onTerminal: ((TerminalReason) -> Void)?

    private(set) var lastError: String?
    private(set) var pfError: String?

    private let config: Config
    private let queue = DispatchQueue(label: "com.alwaysconnect.helper.engine")
    private let driver = SessionDriverClient()
    private var process: Process?
    private var inputPipe: Pipe?
    private var outputPipe: Pipe?
    private var errorPipe: Pipe?
    private var stopRequested = false
    private var hookFired = false
    private var sawLoginFailed = false
    private var fedCredential: FedCredential = .password
    private var cookieFallbackUsed = false
    private var attempts = 0
    private var approvalWorkItem: DispatchWorkItem?
    private var forceKillWorkItem: DispatchWorkItem?
    private var manualFlagURL: URL?
    private var stdoutBuffer = ""
    private var stderrBuffer = ""
    private var redactedTail: [String] = []

    /// Substrings that mark a push-approval wait in --verbose output.
    /// EMPTY on purpose: real-gateway output shapes are a Phase 1
    ///待验证项 (DESIGN.md §16.5). Guessing patterns here would fake
    /// the AwaitingApproval state; the detector stays inactive until
    /// a pattern is observed against a real gateway. The mechanism
    /// (scan + 120s timer + re-initiate) is fully wired below.
    static let approvalPatterns: [String] = []

    init(config: Config) {
        self.config = config
    }

    // MARK: - Lifecycle

    func start() {
        queue.async { [weak self] in self?.begin() }
    }

    func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            guard !self.stopRequested else { return }
            self.stopRequested = true
            self.approvalWorkItem?.cancel()
            self.forceKillWorkItem?.cancel()
            _ = self.driver.manualDisconnect()
            self.reportState(detail: "manual disconnect")
            // Flag file first: the script's disconnect path reads it
            // to decide restore-vs-hold. Then terminate the child.
            self.installManualFlag()
            if let p = self.process, p.isRunning {
                p.terminate()
            } else {
                self.finishManualStop()
            }
        }
    }

    private func begin() {
        _ = driver.start()
        reportState(detail: "starting")
        spawnNext()
    }

    // MARK: - Spawn

    private func spawnNext() {
        if let max = config.maxAttempts, attempts >= max {
            finishTerminal(.attemptsExhausted, detail: "attempt limit reached")
            return
        }
        attempts += 1
        hookFired = false
        sawLoginFailed = false

        let useCookie = config.cookieStore.usableRecord(for: config.server)
        var args: [String] = []
        let executable = openConnectExecutable()
        if executable == "/usr/bin/env" {
            // PATH lookup fallback: env needs the binary name first.
            args += ["openconnect"]
        }
        args += ["--server=\(config.server)"]
        if !config.group.isEmpty {
            args += ["--authgroup=\(config.group)"]
        }
        args += ["--user=\(config.username)"]
        var credentialText: String
        if let record = useCookie {
            args += ["--cookie-on-stdin"]
            credentialText = record.cookie
            fedCredential = .cookie
        } else {
            args += ["--passwd-on-stdin"]
            credentialText = config.password
            fedCredential = .password
        }
        args += ["--script=\(config.scriptPath)", "--verbose"]

        let process = Process()
        process.executableURL = URL(fileURLWithPath: openConnectExecutable())
        process.arguments = args
        var env = ProcessInfo.processInfo.environment
        env.removeValue(forKey: "ALWAYSCONNECT_MANUAL_DISCONNECT")
        if config.noRoutes {
            env["ALWAYSCONNECT_NO_ROUTES"] = "1"
        }
        process.environment = env

        let inPipe = Pipe()
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardInput = inPipe
        process.standardOutput = outPipe
        process.standardError = errPipe

        let stdoutHandle = outPipe.fileHandleForReading
        let stderrHandle = errPipe.fileHandleForReading
        stdoutHandle.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            self?.queue.async { self?.consumeStdout(data) }
        }
        stderrHandle.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            self?.queue.async { self?.consumeStderr(data) }
        }
        process.terminationHandler = { [weak self] _ in
            self?.queue.async { self?.childExited() }
        }

        self.process = process
        self.inputPipe = inPipe
        self.outputPipe = outPipe
        self.errorPipe = errPipe
        _ = driver.authenticated()
        reportState(detail: "spawning openconnect (attempt \(attempts))")
        do {
            try process.run()
        } catch {
            // Spawn failure is a post-auth-style transient: retry with
            // backoff through the driver, same as a child exit.
            handlePostAuthFailure(detail: "spawn failed: \(error.localizedDescription)")
            return
        }
        // Feed the credential once; keep the pipe open so a second
        // prompt blocks instead of failing (the engine decides).
        if let data = (credentialText + "\n").data(using: .utf8) {
            inPipe.fileHandleForWriting.write(data)
        }
    }

    private func openConnectExecutable() -> String {
        if let explicit = config.openconnectPath, !explicit.isEmpty {
            return explicit
        }
        for candidate in [
            "/opt/homebrew/bin/openconnect",
            "/usr/local/bin/openconnect",
            "/usr/sbin/openconnect",
            "/usr/bin/openconnect",
        ] {
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return "/usr/bin/env"
    }

    // MARK: - Stream scanning

    private func consumeStdout(_ data: Data) {
        guard let text = String(data: data, encoding: .utf8) else { return }
        stdoutBuffer += text
        drainLines(&stdoutBuffer, isStdout: true)
    }

    private func consumeStderr(_ data: Data) {
        guard let text = String(data: data, encoding: .utf8) else { return }
        stderrBuffer += text
        drainLines(&stderrBuffer, isStdout: false)
    }

    private func drainLines(_ buffer: inout String, isStdout: Bool) {
        while let range = buffer.range(of: "\n") {
            let line = String(buffer[buffer.startIndex..<range.lowerBound])
                .trimmingCharacters(in: .newlines)
            buffer.removeSubrange(buffer.startIndex...range.lowerBound)
            handleLine(line, isStdout: isStdout)
        }
    }

    /// After the child exits, synchronously drain whatever is left in
    /// the pipes (the termination handler can fire before the last
    /// readability events arrive) and flush partial trailing lines.
    /// Without this, a "Login failed." line could be classified late
    /// and a form-stage rejection misread as a transient failure.
    private func drainPipesAtExit() {
        if let out = outputPipe {
            out.fileHandleForReading.readabilityHandler = nil
            let data = out.fileHandleForReading.readDataToEndOfFile()
            if let text = String(data: data, encoding: .utf8), !text.isEmpty {
                stdoutBuffer += text
            }
        }
        if let err = errorPipe {
            err.fileHandleForReading.readabilityHandler = nil
            let data = err.fileHandleForReading.readDataToEndOfFile()
            if let text = String(data: data, encoding: .utf8), !text.isEmpty {
                stderrBuffer += text
            }
        }
        drainLines(&stdoutBuffer, isStdout: true)
        drainLines(&stderrBuffer, isStdout: false)
        if !stdoutBuffer.isEmpty {
            handleLine(stdoutBuffer, isStdout: true)
            stdoutBuffer = ""
        }
        if !stderrBuffer.isEmpty {
            handleLine(stderrBuffer, isStdout: false)
            stderrBuffer = ""
        }
        outputPipe = nil
        errorPipe = nil
    }

    private func handleLine(_ line: String, isStdout: Bool) {
        appendTail(Self.redact(line))
        if line.hasPrefix("AC_HOOK ") {
            handleHook(String(line.dropFirst("AC_HOOK ".count)))
            return
        }
        if isStdout, let cookie = captureCookie(from: line) {
            config.cookieStore.save(cookie: cookie, gateway: config.server)
            return
        }
        if !isStdout, line.contains("Login failed.") {
            // Measured (ocserv 1.2.4 + openconnect 9.12): the child
            // re-prompts after this line. Closing stdin makes it exit
            // on its own instead of blocking; force-terminate is the
            // backstop if it does not exit within 3s.
            sawLoginFailed = true
            closeStdin()
            let item = DispatchWorkItem { [weak self] in
                self?.queue.async { self?.forceTerminateIfRunning() }
            }
            forceKillWorkItem = item
            queue.asyncAfter(deadline: .now() + 3, execute: item)
            return
        }
        if Self.approvalPatterns.contains(where: { line.contains($0) }) {
            handleApprovalSignal()
        }
    }

    private func captureCookie(from line: String) -> String? {
        // Exact prefix: "webvpncontext=" must NOT match.
        guard let range = line.range(of: "Set-Cookie: webvpn=") else { return nil }
        let rest = line[range.upperBound...]
        let value = rest.split(separator: ";", maxSplits: 1).first?
            .trimmingCharacters(in: .whitespaces) ?? ""
        return value.isEmpty ? nil : value
    }

    private func handleHook(_ payload: String) {
        let parts = payload.split(separator: " ")
        guard let event = parts.first else { return }
        switch event {
        case "connect":
            var tun: String?
            var gateway: String?
            for part in parts.dropFirst() {
                let kv = part.split(separator: "=", maxSplits: 1)
                if kv.count == 2 {
                    if kv[0] == "tun" { tun = String(kv[1]) }
                    if kv[0] == "gateway" { gateway = String(kv[1]) }
                }
            }
            hookFired = true
            approvalWorkItem?.cancel()
            _ = driver.authOutcome(0) // Success
            reportState(detail: "tunnel up")
            loadPf(tunnelIf: tun, gatewayIps: gateway.map { [$0] } ?? [])
        case "disconnect-held", "disconnect-manual":
            // State is driven by the child exit, not by the script.
            break
        default:
            break
        }
    }

    private func handleApprovalSignal() {
        guard driver.state == .authenticating else { return }
        let action = driver.authOutcome(1) // NeedsApproval
        if case .waitApproval(let timeout) = action {
            reportState(detail: "awaiting SeaTalk approval")
            let item = DispatchWorkItem { [weak self] in
                self?.queue.async { self?.approvalTimedOut() }
            }
            approvalWorkItem = item
            queue.asyncAfter(deadline: .now() + timeout, execute: item)
        }
    }

    private func approvalTimedOut() {
        // Re-initiate: spawn again (stored cookie first if one was
        // captured, else password) so the gateway pushes again.
        // The driver is already back in Authenticating.
        let action = driver.approvalTimeout()
        if case .reauthenticate(let delay) = action {
            respawnAfter(delay)
        }
    }

    /// Schedules a respawn that no-ops when a manual stop landed
    /// first. Without this guard, a pending backoff timer could
    /// resurrect a session the user deliberately stopped.
    private func respawnAfter(_ delay: TimeInterval) {
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, !self.stopRequested else { return }
            self.spawnNext()
        }
    }

    // MARK: - Child exit classification

    private func childExited() {
        drainPipesAtExit()
        process = nil
        inputPipe = nil
        forceKillWorkItem?.cancel()
        if stopRequested {
            finishManualStop()
            return
        }
        if sawLoginFailed {
            // Form-stage rejection: stop, never retry (anti-lockout).
            _ = driver.authOutcome(2) // Rejected
            lastError = "账号或密码被拒绝，请检查凭据"
            reportState(detail: lastError!)
            finishTerminal(.authFailure, detail: lastError!)
            return
        }
        if fedCredential == .cookie, !hookFired {
            // Cookie rejected before any tunnel: drop it, try the
            // password exactly once for this session start.
            config.cookieStore.clear()
            if !cookieFallbackUsed {
                cookieFallbackUsed = true
                spawnNext()
                return
            }
        }
        if hookFired {
            // Was connected, then dropped: in-process cookie is gone
            // with the dead child, so re-authenticate after backoff.
            let action = driver.drop(cookieAlive: false)
            if case .reauthenticate(let delay) = action {
                reportState(detail: "dropped, retrying")
                respawnAfter(delay)
                return
            }
            // Driver ignored the drop (was not Connected): fall through
            // to the post-auth transient path.
        }
        handlePostAuthFailure(detail: "child exited without connect hook")
    }

    private func handlePostAuthFailure(detail: String) {
        // Post-auth failure (measured instance: sandbox tun ban after
        // a successful auth). Retry with driver backoff; never report
        // this as an auth rejection.
        let action = driver.authOutcome(3) // Transient
        if case .reauthenticate(let delay) = action {
            reportState(detail: detail)
            respawnAfter(delay)
        } else {
            // Driver could not take Transient (not Authenticating):
            // treat as a drop-and-retry through the same path.
            let dropAction = driver.drop(cookieAlive: false)
            if case .reauthenticate(let delay) = dropAction {
                respawnAfter(delay)
            } else {
                finishTerminal(.attemptsExhausted, detail: detail)
            }
        }
    }

    // MARK: - pf + manual stop

    private func loadPf(tunnelIf: String?, gatewayIps: [String]) {
        guard let tun = tunnelIf, !gatewayIps.isEmpty else {
            pfError = "pf 兜底未生效：缺少隧道接口或网关 IP"
            reportState(detail: pfError!)
            return
        }
        guard let text = PfAnchor.generate(
            physicalIf: config.physicalIf,
            tunnelIf: tun,
            gatewayIps: gatewayIps,
            allowNetworks: config.allowNetworks
        ) else {
            pfError = "pf 兜底未生效：规则生成被拒"
            reportState(detail: pfError!)
            return
        }
        do {
            try PfController.load(anchorText: text)
            pfError = nil
        } catch {
            // Non-terminal: the tunnel's own routing still protects;
            // the UI shows the red line, never silence (UI-DESIGN §七).
            pfError = "pf 兜底未生效，故障关闭只有第一道"
            reportState(detail: pfError!)
        }
    }

    private func installManualFlag() {
        let dir = config.supportDir
            ?? CookieStore.defaultFileURL.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(
                at: dir, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            let url = dir.appendingPathComponent("manual-disconnect")
            FileManager.default.createFile(atPath: url.path, contents: nil,
                                           attributes: [.posixPermissions: 0o600])
            manualFlagURL = url
        } catch {
            // If the flag cannot be installed, the script's disconnect
            // path holds routes (fail closed) and the engine still
            // unloads pf below; the local network is restored by the
            // engine's pf unload + a best-effort route restore note.
            fputs("CLIOrchestrator: manual flag install failed\n", stderr)
        }
    }

    private func finishManualStop() {
        // Routes/DNS were restored by the script's manual path (it saw
        // the flag file); pf is the engine's own to unload.
        do {
            try PfController.unload()
        } catch {
            fputs("CLIOrchestrator: pf unload failed (best effort)\n", stderr)
        }
        if let url = manualFlagURL {
            try? FileManager.default.removeItem(at: url)
            manualFlagURL = nil
        }
        finishTerminal(.stoppedManual, detail: "manual disconnect")
    }

    private func finishTerminal(_ reason: TerminalReason, detail: String) {
        reportState(detail: detail)
        onTerminal?(reason)
    }

    // MARK: - Helpers

    private func closeStdin() {
        inputPipe?.fileHandleForWriting.closeFile()
    }

    private func forceTerminateIfRunning() {
        if let p = process, p.isRunning {
            p.terminate()
        }
    }

    private func reportState(detail: String) {
        let state = driver.state ?? .disconnected
        onState?(state, detail)
    }

    private func appendTail(_ redactedLine: String) {
        redactedTail.append(redactedLine)
        if redactedTail.count > 40 {
            redactedTail.removeFirst(redactedTail.count - 40)
        }
    }

    var redactedLogTail: [String] { redactedTail }

    /// Masks session tokens before any line is stored, printed, or
    /// put into diagnostics. The password never appears in child
    /// output (it goes over stdin), but cookies do.
    static func redact(_ line: String) -> String {
        var out = line
        for key in ["webvpncontext=", "webvpn="] {
            while let range = out.range(of: key) {
                let rest = out[range.upperBound...]
                let end = rest.firstIndex(where: { $0 == ";" || $0 == " " || $0 == "\t" })
                    ?? rest.endIndex
                out.replaceSubrange(range.upperBound..<end, with: "***")
            }
        }
        return out
    }
}
