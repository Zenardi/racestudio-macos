//! UniFFI boundary exposing the RaceStudio Rust core to the SwiftUI frontend.
//!
//! Milestone M0 (issue 0.4) proves the Rust→Swift pipeline end-to-end with the
//! smallest possible surface: a single exported `core_version()`. Real
//! decode/analysis exports arrive in M1+.

uniffi::setup_scaffolding!();

/// The RaceStudio Rust core version, exported across the UniFFI boundary.
///
/// Returns the `racestudio-ffi` crate version (`CARGO_PKG_VERSION`). Swift calls
/// this as `coreVersion()`; a round-trip test asserts the string crosses the
/// boundary unchanged, proving the FFI pipeline works.
#[uniffi::export]
#[must_use]
pub fn core_version() -> String {
    env!("CARGO_PKG_VERSION").to_string()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_core_version_returns_crate_version() {
        assert_eq!(core_version(), env!("CARGO_PKG_VERSION"));
    }
}
