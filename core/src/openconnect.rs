//! libopenconnect FFI binding (feature `openconnect`).
//!
//! Signatures verified against `/usr/include/openconnect.h` (openconnect
//! 9.12, Ubuntu 24.04). This module covers session init/free only; the
//! auth flow (`openconnect_parse_url`, `openconnect_obtain_cookie`,
//! `openconnect_connect`, `openconnect_mainloop`) and the packet pump
//! between the NE packet flow and libopenconnect's tunnel are Phase 0
//! work on macOS, where the real gateway and SeaTalk approval live.
//!
//! Note on the progress callback: upstream declares it variadic
//! (`...`), which stable Rust cannot express (`c_variadic` is nightly).
//! The binding therefore only ever passes NULL for it. A real progress
//! callback needs a tiny C shim or nightly Rust; that decision belongs
//! to Phase 0, not to this smoke-test binding.

#![cfg(feature = "openconnect")]

use std::ffi::{c_char, c_int, c_void, CString};

#[link(name = "openconnect")]
extern "C" {
    fn openconnect_init_ssl() -> c_int;
    fn openconnect_vpninfo_new(
        useragent: *const c_char,
        validate_peer_cert: Option<ValidatePeerCertFn>,
        write_new_config: Option<WriteNewConfigFn>,
        process_auth_form: Option<ProcessAuthFormFn>,
        progress: Option<ProgressFn>,
        privdata: *mut c_void,
    ) -> *mut VpnInfo;
    fn openconnect_vpninfo_free(vpninfo: *mut VpnInfo);
}

/// Opaque libopenconnect session handle.
#[repr(C)]
pub struct VpnInfo {
    _private: [u8; 0],
}

pub type ValidatePeerCertFn = unsafe extern "C" fn(*mut c_void, *const c_char) -> c_int;
pub type WriteNewConfigFn = unsafe extern "C" fn(*mut c_void, *const c_char, c_int);
pub type ProcessAuthFormFn = unsafe extern "C" fn(*mut c_void, *mut c_void) -> c_int;
/// NULL-only on stable Rust; see the module note on the variadic upstream.
pub type ProgressFn = unsafe extern "C" fn(*mut c_void, c_int, *const c_char);

/// RAII wrapper: frees the session on drop.
pub struct VpnSession {
    raw: *mut VpnInfo,
}

impl VpnSession {
    /// Initialise libopenconnect and allocate a session. Returns `None`
    /// if SSL init fails or allocation fails.
    pub fn new(useragent: &str) -> Option<Self> {
        unsafe {
            if openconnect_init_ssl() != 0 {
                return None;
            }
            let ua = CString::new(useragent).ok()?;
            let raw =
                openconnect_vpninfo_new(ua.as_ptr(), None, None, None, None, std::ptr::null_mut());
            if raw.is_null() {
                None
            } else {
                Some(Self { raw })
            }
        }
    }
}

impl Drop for VpnSession {
    fn drop(&mut self) {
        unsafe {
            openconnect_vpninfo_free(self.raw);
        }
    }
}

// The session handle is only touched on one thread in this design
// (the tunnel thread owns it); it is deliberately NOT Send/Sync.
#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn session_init_and_free_links() {
        // Proves the Rust -> libopenconnect binding links and runs:
        // init_ssl + vpninfo_new + vpninfo_free against the real library.
        let session = VpnSession::new("AlwaysConnect/0.1.0");
        assert!(session.is_some());
        drop(session);
        // Second session proves free() did not corrupt library state.
        assert!(VpnSession::new("AlwaysConnect/0.1.0").is_some());
    }
}
