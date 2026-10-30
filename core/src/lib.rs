//! AlwaysConnect core: portable decision logic, no Apple frameworks.
//!
//! This crate compiles and tests on Linux. The macOS app links it via the
//! C ABI in [`ffi`] and keeps only thin Swift adapters for NetworkExtension,
//! Keychain, and UI. Mirrors DESIGN.md v0.4 §4-§6.

pub mod backoff;
pub mod dns_routes;
pub mod ffi;
pub mod rules;
pub mod state_machine;

#[cfg(feature = "openconnect")]
pub mod openconnect;
