import Foundation

/// Swift wrapper over the Rust core's C ABI (see core/src/ffi.rs).
/// Symbol names must match the #[no_mangle] exports exactly.
/// This file lives in Sources/Bridge, compiled into the Tunnel and Proxy
/// targets (both link the Rust staticlib); the App target does NOT
/// include it and does NOT link the staticlib, so it must stay out of
/// Sources/Shared.
///
/// Threading: the engine is confined to the caller's queue (the provider
/// queue here). The Rust side is Mutex-protected, but this class itself
/// is deliberately not Sendable.
final class RustRuleEngine {
    private var handle: UnsafeMutableRawPointer?

    init(defaultMode: DefaultMode) {
        handle = ac_engine_new(defaultMode == .secure ? 0 : 1)
    }

    deinit {
        if let h = handle {
            ac_engine_free(h)
        }
    }

    /// False when the engine failed to initialise or the rule is bad.
    @discardableResult
    func addRule(_ rule: Rule) -> Bool {
        guard let h = handle else { return false }
        return rule.target.withCString { target in
            ac_engine_add_rule(h, typeCode(for: rule.type), target,
                               rule.direction == .viaVPN ? 0 : 1,
                               rule.isEnabled) == 0
        }
    }

    /// True = route via VPN, false = direct. Fails closed to VPN when
    /// the engine is gone or the inputs are bad.
    func shouldUseVPN(app: String, domain: String, ip: String) -> Bool {
        guard let h = handle else { return true }
        let result = app.withCString { appC in
            domain.withCString { domainC in
                ip.withCString { ipC in
                    ac_engine_resolve(h, appC, domainC, ipC)
                }
            }
        }
        return result != 1
    }

    private func typeCode(for type: RuleType) -> Int32 {
        switch type {
        case .app: return 0
        case .domain: return 1
        case .network: return 2
        }
    }
}

// MARK: - C ABI imports (alwaysconnect-core, core/src/ffi.rs)

@_silgen_name("ac_version")
func ac_version() -> UnsafePointer<CChar>

@_silgen_name("ac_engine_new")
func ac_engine_new(_ defaultMode: Int32) -> UnsafeMutableRawPointer?

@_silgen_name("ac_engine_add_rule")
func ac_engine_add_rule(
    _ engine: UnsafeMutableRawPointer?,
    _ ruleType: Int32,
    _ target: UnsafePointer<CChar>,
    _ direction: Int32,
    _ enabled: Bool
) -> Int32

@_silgen_name("ac_engine_resolve")
func ac_engine_resolve(
    _ engine: UnsafeMutableRawPointer?,
    _ app: UnsafePointer<CChar>,
    _ domain: UnsafePointer<CChar>,
    _ ip: UnsafePointer<CChar>
) -> Int32

@_silgen_name("ac_engine_free")
func ac_engine_free(_ engine: UnsafeMutableRawPointer?)
