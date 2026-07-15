//! Clean-room decoder for AiM RaceStudio telemetry (`.xrk`) files.
//!
//! Milestone M0 (issue 0.1) ships only a compiling stub; the real decode
//! surface — validated against XRKConverter's `libxrk` output as the golden
//! oracle — arrives in milestone M1.

/// Compiling stub proving the crate builds, links, and is testable.
///
/// Returns an inert sentinel (`0`). The real decode API arrives in M1.
#[must_use]
pub fn placeholder() -> u32 {
    0
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_decode_crate_placeholder() {
        assert_eq!(placeholder(), 0);
    }
}
