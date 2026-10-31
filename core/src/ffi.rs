//! C ABI for the Swift app shell.
//!
//! The Swift side holds an opaque `ac_engine_t` handle. All functions are
//! null-safe and return -1 on bad input; direction codes are 0 = VPN,
//! 1 = direct. Rule and engine state live behind a Mutex, so the handle
//! is safe to share across threads.

use crate::rules::{self, DefaultMode, Direction, Rule, RuleType};
use std::ffi::CStr;
use std::os::raw::{c_char, c_int};
use std::sync::Mutex;

pub struct Engine {
    rules: Mutex<Vec<Rule>>,
    default: DefaultMode,
}

/// Engine version string (static, never freed by the caller).
#[no_mangle]
pub extern "C" fn ac_version() -> *const c_char {
    b"0.1.0\0".as_ptr() as *const c_char
}

/// default_mode: 0 = secure (default VPN), 1 = split (default direct).
/// Returns a null pointer on an invalid mode.
#[no_mangle]
pub extern "C" fn ac_engine_new(default_mode: c_int) -> *mut Engine {
    let default = match default_mode {
        0 => DefaultMode::Secure,
        1 => DefaultMode::Split,
        _ => return std::ptr::null_mut(),
    };
    Box::into_raw(Box::new(Engine {
        rules: Mutex::new(Vec::new()),
        default,
    }))
}

/// rule_type: 0 = app, 1 = domain, 2 = network.
/// direction: 0 = VPN, 1 = direct. Returns 0 on success, -1 on bad input.
#[no_mangle]
pub extern "C" fn ac_engine_add_rule(
    engine: *mut Engine,
    rule_type: c_int,
    target: *const c_char,
    direction: c_int,
    enabled: bool,
) -> c_int {
    if engine.is_null() || target.is_null() {
        return -1;
    }
    let rule_type = match rule_type {
        0 => RuleType::App,
        1 => RuleType::Domain,
        2 => RuleType::Network,
        _ => return -1,
    };
    let direction = match direction {
        0 => Direction::Vpn,
        1 => Direction::Direct,
        _ => return -1,
    };
    let target = unsafe {
        match CStr::from_ptr(target).to_str() {
            Ok(s) => s.to_owned(),
            Err(_) => return -1,
        }
    };
    let engine = unsafe { &*engine };
    engine.rules.lock().unwrap().push(Rule {
        rule_type,
        target,
        direction,
        enabled,
    });
    0
}

/// Returns 0 (VPN), 1 (direct), or -1 on bad input.
#[no_mangle]
pub extern "C" fn ac_engine_resolve(
    engine: *mut Engine,
    app: *const c_char,
    domain: *const c_char,
    ip: *const c_char,
) -> c_int {
    if engine.is_null() || app.is_null() || domain.is_null() || ip.is_null() {
        return -1;
    }
    let read = |p: *const c_char| unsafe { CStr::from_ptr(p).to_str().ok() };
    let (Some(app), Some(domain), Some(ip)) = (read(app), read(domain), read(ip)) else {
        return -1;
    };
    let engine = unsafe { &*engine };
    let rules = engine.rules.lock().unwrap();
    match rules::resolve(app, domain, ip, &rules, engine.default).0 {
        Direction::Vpn => 0,
        Direction::Direct => 1,
    }
}

#[no_mangle]
pub extern "C" fn ac_engine_free(engine: *mut Engine) {
    if !engine.is_null() {
        unsafe {
            drop(Box::from_raw(engine));
        }
    }
}

// ---- Session driver (core/src/session.rs) ----
//
// Action codes returned by every ac_session_* call:
//   0 = NoAction, 1 = ReconnectInProcess, 2 = Reauthenticate,
//   3 = WaitApproval, 4 = StopNeedsUser, 5 = TornDown, 6 = Ignored.
// The delay/timeout seconds for actions 1/2/3 are written to
// `delay_secs_out` when it is non-null, else ignored.
// State codes (ac_session_state):
//   0 = Disconnected, 1 = Connecting, 2 = Authenticating,
//   3 = AwaitingApproval, 4 = Connected, 5 = Reconnecting; -1 on null.
// AuthOutcome codes in: 0 = Success, 1 = NeedsApproval, 2 = Rejected,
// 3 = Transient; any other code returns Ignored and leaves the driver
// untouched. Null handles return Ignored (state: -1) and never crash.

use crate::session::{AuthOutcome, DriverAction, SessionDriver};
use crate::state_machine::SessionStatus;

pub struct SessionHandle {
    driver: Mutex<SessionDriver>,
}

fn encode_action(action: DriverAction, delay_secs_out: *mut f64) -> c_int {
    let (code, secs) = match action {
        DriverAction::NoAction => (0, 0.0),
        DriverAction::ReconnectInProcess { delay } => (1, delay.as_secs_f64()),
        DriverAction::Reauthenticate { delay } => (2, delay.as_secs_f64()),
        DriverAction::WaitApproval { timeout } => (3, timeout.as_secs_f64()),
        DriverAction::StopNeedsUser => (4, 0.0),
        DriverAction::TornDown => (5, 0.0),
        DriverAction::Ignored => (6, 0.0),
    };
    if !delay_secs_out.is_null() {
        unsafe {
            *delay_secs_out = secs;
        }
    }
    code
}

fn encode_state(state: SessionStatus) -> c_int {
    match state {
        SessionStatus::Disconnected => 0,
        SessionStatus::Connecting => 1,
        SessionStatus::Authenticating => 2,
        SessionStatus::AwaitingApproval => 3,
        SessionStatus::Connected => 4,
        SessionStatus::Reconnecting => 5,
    }
}

#[no_mangle]
pub extern "C" fn ac_session_new(seed: u64) -> *mut SessionHandle {
    Box::into_raw(Box::new(SessionHandle {
        driver: Mutex::new(SessionDriver::new(seed)),
    }))
}

#[no_mangle]
pub extern "C" fn ac_session_free(handle: *mut SessionHandle) {
    if !handle.is_null() {
        unsafe {
            drop(Box::from_raw(handle));
        }
    }
}

#[no_mangle]
pub extern "C" fn ac_session_state(handle: *mut SessionHandle) -> c_int {
    if handle.is_null() {
        return -1;
    }
    let handle = unsafe { &*handle };
    encode_state(handle.driver.lock().unwrap().state)
}

#[no_mangle]
pub extern "C" fn ac_session_start(
    handle: *mut SessionHandle,
    delay_secs_out: *mut f64,
) -> c_int {
    if handle.is_null() {
        return 6;
    }
    let handle = unsafe { &*handle };
    let action = handle.driver.lock().unwrap().start();
    encode_action(action, delay_secs_out)
}

#[no_mangle]
pub extern "C" fn ac_session_authenticated(
    handle: *mut SessionHandle,
    delay_secs_out: *mut f64,
) -> c_int {
    if handle.is_null() {
        return 6;
    }
    let handle = unsafe { &*handle };
    let action = handle.driver.lock().unwrap().on_authenticated();
    encode_action(action, delay_secs_out)
}

#[no_mangle]
pub extern "C" fn ac_session_drop(
    handle: *mut SessionHandle,
    cookie_alive: bool,
    delay_secs_out: *mut f64,
) -> c_int {
    if handle.is_null() {
        return 6;
    }
    let handle = unsafe { &*handle };
    let action = handle
        .driver
        .lock()
        .unwrap()
        .on_drop(cookie_alive);
    encode_action(action, delay_secs_out)
}

#[no_mangle]
pub extern "C" fn ac_session_reconnected(
    handle: *mut SessionHandle,
    delay_secs_out: *mut f64,
) -> c_int {
    if handle.is_null() {
        return 6;
    }
    let handle = unsafe { &*handle };
    let action = handle.driver.lock().unwrap().on_reconnected();
    encode_action(action, delay_secs_out)
}

#[no_mangle]
pub extern "C" fn ac_session_auth_outcome(
    handle: *mut SessionHandle,
    outcome: c_int,
    delay_secs_out: *mut f64,
) -> c_int {
    if handle.is_null() {
        return 6;
    }
    let outcome = match outcome {
        0 => AuthOutcome::Success,
        1 => AuthOutcome::NeedsApproval,
        2 => AuthOutcome::Rejected,
        3 => AuthOutcome::Transient,
        _ => return 6,
    };
    let handle = unsafe { &*handle };
    let action = handle.driver.lock().unwrap().on_auth_outcome(outcome);
    encode_action(action, delay_secs_out)
}

#[no_mangle]
pub extern "C" fn ac_session_approved(
    handle: *mut SessionHandle,
    delay_secs_out: *mut f64,
) -> c_int {
    if handle.is_null() {
        return 6;
    }
    let handle = unsafe { &*handle };
    let action = handle.driver.lock().unwrap().on_approved();
    encode_action(action, delay_secs_out)
}

#[no_mangle]
pub extern "C" fn ac_session_approval_timeout(
    handle: *mut SessionHandle,
    delay_secs_out: *mut f64,
) -> c_int {
    if handle.is_null() {
        return 6;
    }
    let handle = unsafe { &*handle };
    let action = handle.driver.lock().unwrap().on_approval_timeout();
    encode_action(action, delay_secs_out)
}

#[no_mangle]
pub extern "C" fn ac_session_manual_disconnect(
    handle: *mut SessionHandle,
    delay_secs_out: *mut f64,
) -> c_int {
    if handle.is_null() {
        return 6;
    }
    let handle = unsafe { &*handle };
    let action = handle.driver.lock().unwrap().on_manual_disconnect();
    encode_action(action, delay_secs_out)
}

// ---- pf anchor generation (core/src/pf.rs) ----
//
// ac_pf_generate returns a malloc'd C string the caller frees with
// ac_string_free, or null on bad input (null pointers, non-UTF8,
// invalid networks/IPs, empty gateway list). The two list arguments
// are comma-separated; surrounding whitespace is trimmed; an empty
// allow list is valid (no allow lines in the output). The final
// argument selects the pf set (DESIGN.md §17.5): 0 = blocking set
// (fail-closed default), nonzero = connected set (physical outbound
// passes, so provider-pumped direct traffic can egress).

use crate::pf::{PfInput, PfError};
use std::ffi::CString;

fn split_csv(s: &str) -> Vec<String> {
    if s.trim().is_empty() {
        return Vec::new();
    }
    s.split(',')
        .map(|part| part.trim().to_owned())
        .filter(|part| !part.is_empty())
        .collect()
}

fn read_cstr(p: *const c_char) -> Option<String> {
    if p.is_null() {
        return None;
    }
    unsafe { CStr::from_ptr(p).to_str().ok().map(|s| s.to_owned()) }
}

#[no_mangle]
pub extern "C" fn ac_pf_generate(
    physical_if: *const c_char,
    tunnel_if: *const c_char,
    gateway_ips_csv: *const c_char,
    allow_networks_csv: *const c_char,
    allow_direct_egress: i32,
) -> *mut c_char {
    let (Some(physical_if), Some(tunnel_if), Some(gateway_ips_csv), Some(allow_networks_csv)) = (
        read_cstr(physical_if),
        read_cstr(tunnel_if),
        read_cstr(gateway_ips_csv),
        read_cstr(allow_networks_csv),
    ) else {
        return std::ptr::null_mut();
    };
    let input = PfInput {
        physical_if,
        tunnel_if,
        gateway_ips: split_csv(&gateway_ips_csv),
        allow_networks: split_csv(&allow_networks_csv),
        allow_direct_egress: allow_direct_egress != 0,
    };
    match crate::pf::generate(&input) {
        Ok(text) => match CString::new(text) {
            Ok(c) => c.into_raw(),
            Err(_) => std::ptr::null_mut(),
        },
        Err(PfError::EmptyInterface)
        | Err(PfError::EmptyGateway)
        | Err(PfError::BadNetwork(_))
        | Err(PfError::BadIp(_)) => std::ptr::null_mut(),
    }
}

#[no_mangle]
pub extern "C" fn ac_string_free(s: *mut c_char) {
    if !s.is_null() {
        unsafe {
            drop(CString::from_raw(s));
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::ffi::CString;

    fn c(s: &str) -> CString {
        CString::new(s).unwrap()
    }

    #[test]
    fn ffi_round_trip() {
        let e = ac_engine_new(0);
        assert!(!e.is_null());
        let app = c("com.claude.app");
        let dom = c("a.video.example");
        let tgt = c("*.video.example");
        assert_eq!(ac_engine_add_rule(e, 1, tgt.as_ptr(), 1, true), 0);
        let ip = c("1.2.3.4");
        // Domain rule says direct...
        assert_eq!(
            ac_engine_resolve(e, c("other.app").as_ptr(), dom.as_ptr(), ip.as_ptr()),
            1
        );
        // ...but the LAN hard rule still wins.
        let lan = c("192.168.1.1");
        assert_eq!(
            ac_engine_resolve(e, app.as_ptr(), dom.as_ptr(), lan.as_ptr()),
            1
        );
        // Bad input is rejected, not a crash.
        assert_eq!(
            ac_engine_resolve(
                std::ptr::null_mut(),
                app.as_ptr(),
                dom.as_ptr(),
                ip.as_ptr()
            ),
            -1
        );
        assert_eq!(ac_engine_new(9), std::ptr::null_mut());
        ac_engine_free(e);
    }

    #[test]
    fn session_abi_full_flow() {
        let h = ac_session_new(42);
        assert!(!h.is_null());
        let mut delay = -1.0f64;
        assert_eq!(ac_session_start(h, &mut delay), 0);
        assert_eq!(ac_session_state(h), 1);
        assert_eq!(ac_session_authenticated(h, &mut delay), 0);
        assert_eq!(ac_session_state(h), 2);
        assert_eq!(ac_session_auth_outcome(h, 0, &mut delay), 0);
        assert_eq!(ac_session_state(h), 4);
        // Drop with a live in-process cookie: reconnect in process.
        assert_eq!(ac_session_drop(h, true, &mut delay), 1);
        assert!(delay > 0.0 && delay < 2.0);
        assert_eq!(ac_session_state(h), 5);
        assert_eq!(ac_session_reconnected(h, &mut delay), 0);
        assert_eq!(ac_session_state(h), 4);
        // User-initiated disconnect tears down.
        assert_eq!(ac_session_manual_disconnect(h, &mut delay), 5);
        assert_eq!(ac_session_state(h), 0);
        ac_session_free(h);
    }

    #[test]
    fn session_abi_approval_and_reject() {
        let h = ac_session_new(7);
        let mut delay = -1.0f64;
        ac_session_start(h, &mut delay);
        ac_session_authenticated(h, &mut delay);
        assert_eq!(ac_session_auth_outcome(h, 1, &mut delay), 3);
        assert!((delay - 120.0).abs() < f64::EPSILON);
        assert_eq!(ac_session_state(h), 3);
        assert_eq!(ac_session_approval_timeout(h, &mut delay), 2);
        assert_eq!(ac_session_state(h), 2);
        assert_eq!(ac_session_auth_outcome(h, 2, &mut delay), 4);
        assert_eq!(ac_session_state(h), 0);
        ac_session_free(h);
    }

    #[test]
    fn session_abi_bad_input() {
        let null = std::ptr::null_mut();
        let mut delay = -1.0f64;
        assert_eq!(ac_session_state(null), -1);
        assert_eq!(ac_session_start(null, &mut delay), 6);
        assert_eq!(ac_session_drop(null, true, &mut delay), 6);
        assert_eq!(ac_session_auth_outcome(null, 0, &mut delay), 6);
        // Null out-param is fine on a legal call.
        let h = ac_session_new(1);
        assert_eq!(ac_session_start(h, std::ptr::null_mut()), 0);
        // Invalid outcome code leaves the driver untouched.
        assert_eq!(ac_session_auth_outcome(h, 9, &mut delay), 6);
        assert_eq!(ac_session_state(h), 1);
        ac_session_free(null);
        ac_session_free(h);
    }

    #[test]
    fn pf_abi_generate_and_free() {
        let phys = c("en0");
        let tun = c("utun5");
        let gw = c("203.0.113.10");
        let allow = c("192.168.0.0/16");
        let out = ac_pf_generate(
            phys.as_ptr(),
            tun.as_ptr(),
            gw.as_ptr(),
            allow.as_ptr(),
            0,
        );
        assert!(!out.is_null());
        let text = unsafe { CStr::from_ptr(out).to_str().unwrap().to_owned() };
        assert!(text.contains("block drop out quick on en0 all\n"));
        assert!(text.contains("pass out quick on en0 to 203.0.113.10\n"));
        ac_string_free(out);
        // Connected set (nonzero flag) ends with a pass, not a block.
        let out = ac_pf_generate(
            phys.as_ptr(),
            tun.as_ptr(),
            gw.as_ptr(),
            allow.as_ptr(),
            1,
        );
        assert!(!out.is_null());
        let text = unsafe { CStr::from_ptr(out).to_str().unwrap().to_owned() };
        assert!(text.ends_with("pass out quick on en0 all\n"));
        ac_string_free(out);
        // Bad input yields null, never a crash.
        assert!(ac_pf_generate(
            std::ptr::null(),
            tun.as_ptr(),
            gw.as_ptr(),
            allow.as_ptr(),
            0
        )
        .is_null());
        let empty_gw = c("");
        assert!(ac_pf_generate(
            phys.as_ptr(),
            tun.as_ptr(),
            empty_gw.as_ptr(),
            allow.as_ptr(),
            0
        )
        .is_null());
        let bad_net = c("10.0.0.0/33");
        assert!(ac_pf_generate(
            phys.as_ptr(),
            tun.as_ptr(),
            gw.as_ptr(),
            bad_net.as_ptr(),
            0
        )
        .is_null());
        ac_string_free(std::ptr::null_mut());
    }
}
