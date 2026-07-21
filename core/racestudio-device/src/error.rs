//! Typed errors for device discovery (issue 6.3).

use std::fmt;

/// A failure while discovering a MyChron device or parsing its announcement.
///
/// The parser never panics on malformed input: a bad record surfaces as
/// [`DeviceError::MalformedRecord`], and the absence of a responder as
/// [`DeviceError::NoService`] (which the caller turns into the AP-mode fallback).
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum DeviceError {
    /// A discovery record was malformed or truncated: too short to hold the
    /// documented header, a declared length that overruns the buffer, or a type
    /// tag that is not an AiM discovery response.
    MalformedRecord,
    /// No discovery responder was found on the network — the caller falls back
    /// to AP mode (the device's own access-point gateway).
    NoService,
}

impl fmt::Display for DeviceError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            DeviceError::MalformedRecord => write!(f, "malformed discovery record"),
            DeviceError::NoService => write!(f, "no discovery responder found"),
        }
    }
}

impl std::error::Error for DeviceError {}
