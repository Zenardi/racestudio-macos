//! UniFFI boundary exposing the RaceStudio Rust core to the SwiftUI frontend.
//!
//! Milestone M0 (issue 0.1) ships only a compiling stub; the `uniffi`
//! dependencies, scaffolding, and `build.rs` arrive in issue 0.4.

/// Compiling stub proving the crate builds, links, and is testable.
///
/// Returns an inert sentinel (`0`). The UniFFI surface arrives in issue 0.4.
#[must_use]
pub fn placeholder() -> u32 {
    0
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_ffi_crate_placeholder() {
        assert_eq!(placeholder(), 0);
    }
}
