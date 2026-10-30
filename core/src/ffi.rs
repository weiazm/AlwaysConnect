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
}
