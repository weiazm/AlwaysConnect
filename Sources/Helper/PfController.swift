import Foundation

/// pfctl load/unload for the killswitch anchor (DESIGN.md §16.6).
///
/// Load happens only on the `AC_HOOK connect` signal (tunnel up);
/// unload happens only on a user-confirmed manual disconnect. Every
/// other exit path deliberately leaves the anchor loaded: fail closed.
///
/// On a host without pfctl (Linux CI), every call fails with
/// `.unavailable` instead of pretending success — the engine surfaces
/// that as the UI's red "pf 兜底未生效" line, never as a silent pass.
enum PfController {
    static let anchor = "com.alwaysconnect.killswitch"

    enum PfError: Error, CustomStringConvertible {
        case unavailable
        case loadFailed(String)
        case unloadFailed(String)

        var description: String {
            switch self {
            case .unavailable: return "pfctl not available on this host"
            case .loadFailed(let s): return "pfctl load failed: \(s)"
            case .unloadFailed(let s): return "pfctl unload failed: \(s)"
            }
        }
    }

    private static func pfctlPath() -> String? {
        for candidate in ["/sbin/pfctl", "/usr/sbin/pfctl"] {
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }

    private static func runPfctl(_ args: [String]) throws -> String {
        guard let path = pfctlPath() else { throw PfError.unavailable }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = args
        let errPipe = Pipe()
        process.standardError = errPipe
        process.standardOutput = Pipe()
        try process.run()
        process.waitUntilExit()
        let errText = String(
            data: errPipe.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8) ?? ""
        guard process.terminationStatus == 0 else {
            throw PfError.loadFailed(errText.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return errText
    }

    static func load(anchorText: String) throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("alwaysconnect-anchor-\(ProcessInfo.processInfo.processIdentifier).pf")
        do {
            try anchorText.write(to: tmp, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600], ofItemAtPath: tmp.path)
            do {
                _ = try runPfctl(["-a", anchor, "-f", tmp.path])
            } catch PfError.loadFailed(let s) {
                throw PfError.loadFailed(s)
            }
        } catch let e as PfError {
            try? FileManager.default.removeItem(at: tmp)
            throw e
        } catch {
            try? FileManager.default.removeItem(at: tmp)
            throw PfError.loadFailed(error.localizedDescription)
        }
        try? FileManager.default.removeItem(at: tmp)
    }

    static func unload() throws {
        do {
            _ = try runPfctl(["-a", anchor, "-F", "rules"])
        } catch PfError.loadFailed(let s) {
            throw PfError.unloadFailed(s)
        }
    }
}
