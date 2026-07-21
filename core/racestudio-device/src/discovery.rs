//! Device discovery (issue 6.3): turn a recorded/observed AiM discovery response
//! into typed [`Device`]s, and provide the AP-mode fallback for when the Mac has
//! joined the device's own access point.
//!
//! The parsing/selection logic here is pure and fixture-tested. The live
//! mDNS/Bonjour browser (`NWBrowser`) is a thin Swift adapter injected behind the
//! [`DeviceBrowser`] trait, so tests replay recorded bytes with no live device.
//! No networking client lands here — that is issues 6.4–6.6.

use std::net::{IpAddr, Ipv4Addr};

use crate::error::DeviceError;
use crate::{parse_discovery_response, CONTROL_PORT};

/// The AiM discovery-response `type` tag identifying a MyChron announcement
/// (`docs/device/PROTOCOL.md` §2, offset `0x04`).
const DISCOVERY_TYPE_MYCHRON: u32 = 2;

/// The bytes of a discovery record we decode: `length(u32) + type(u32) + ipv4(4)`.
const DISCOVERY_HEADER_LEN: usize = 12;

/// The device family we label a type-2 announcement. The specific model
/// (MYC5/MYC6) is carried in the SSID/serial, which are de-identified out of the
/// committed fixture; on the live mDNS path it comes from the Bonjour metadata.
const MYCHRON_MODEL: &str = "MyChron";

/// The well-known gateway the MyChron serves on when it is its own WiFi access
/// point (`docs/device/PROTOCOL.md` §1).
const AP_GATEWAY: Ipv4Addr = Ipv4Addr::new(10, 0, 0, 1);

/// A discovered MyChron device.
///
/// `address` is decoded from the announcement; `port` is the control/transfer
/// port we connect to next ([`CONTROL_PORT`]); `model` is the device family; and
/// `name` is a stable display name. Two announcements comparing `Eq` are the same
/// device, so repeated announcements de-duplicate into one entry.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Device {
    /// Human-readable display name.
    pub name: String,
    /// The device's IP address (decoded from the announcement).
    pub address: IpAddr,
    /// The TCP port to connect to for control + transfer ([`CONTROL_PORT`]).
    pub port: u16,
    /// The device family/model (e.g. `MyChron`).
    pub model: String,
}

impl Device {
    /// Build a [`Device`] for the MyChron family at `address`, connecting on
    /// [`CONTROL_PORT`], with a deterministic display name.
    fn mychron_at(address: IpAddr, name: String) -> Self {
        Device {
            name,
            address,
            port: CONTROL_PORT,
            model: MYCHRON_MODEL.to_string(),
        }
    }
}

/// A source of raw discovery-response bytes — the seam behind which the live
/// `NWBrowser`/AP-mode responder is injected. Returning [`DeviceError::NoService`]
/// signals "no responder found" and selects the AP-mode fallback.
pub trait DeviceBrowser {
    /// Return the raw discovery-response bytes observed on the wire.
    ///
    /// # Errors
    /// [`DeviceError::NoService`] when no responder is found;
    /// [`DeviceError::MalformedRecord`] is reserved for a browser that validates
    /// framing itself.
    fn browse(&self) -> Result<Vec<u8>, DeviceError>;
}

/// Parse one or more concatenated AiM discovery responses into typed devices,
/// de-duplicating identical announcements.
///
/// Each record is self-delimited by its own `length` prefix (`u32` LE at offset
/// `0`), so a buffer carrying a repeated announcement yields a single [`Device`].
///
/// # Errors
/// [`DeviceError::MalformedRecord`] if any record is too short, declares a length
/// that overruns the buffer, or carries a type tag that is not an AiM discovery
/// response. Never panics on malformed input.
pub fn parse_discovery(bytes: &[u8]) -> Result<Vec<Device>, DeviceError> {
    let mut devices: Vec<Device> = Vec::new();
    let mut rest = bytes;
    while !rest.is_empty() {
        let (device, consumed) = parse_one(rest)?;
        // Linear-scan dedup: the input is a single bounded UDP datagram and each
        // record is >= 12 bytes, so the record count (and thus this O(n²) scan)
        // is small even for a hostile responder — no allocation blow-up.
        if !devices.contains(&device) {
            devices.push(device);
        }
        // `parse_one` guarantees `consumed <= rest.len()` (it rejects a declared
        // length that overruns the buffer), so this split never panics.
        rest = &rest[consumed..];
    }
    Ok(devices)
}

/// Parse the single discovery record at the start of `bytes`, returning the
/// [`Device`] and the number of bytes it consumed (its declared `length`).
///
/// Reuses the 6.2 [`parse_discovery_response`] decoder for the bounds-checked
/// `length`/`type`/`ipv4` reads, then applies the 6.3 validation + typing.
fn parse_one(bytes: &[u8]) -> Result<(Device, usize), DeviceError> {
    let response = parse_discovery_response(bytes).ok_or(DeviceError::MalformedRecord)?;
    let length = response.length as usize;
    // The declared length must cover the header and stay within the buffer.
    if length < DISCOVERY_HEADER_LEN || length > bytes.len() {
        return Err(DeviceError::MalformedRecord);
    }
    if response.kind != DISCOVERY_TYPE_MYCHRON {
        return Err(DeviceError::MalformedRecord);
    }
    let address = IpAddr::V4(Ipv4Addr::from(response.device_ip));
    let name = format!("{MYCHRON_MODEL} @ {address}");
    Ok((Device::mychron_at(address, name), length))
}

/// The AP-mode fallback device: the well-known gateway [`AP_GATEWAY`] the MyChron
/// serves on when the Mac has joined its own access point and no mDNS responder
/// is present.
#[must_use]
pub fn ap_mode_fallback() -> Device {
    let address = IpAddr::V4(AP_GATEWAY);
    Device::mychron_at(address, format!("{MYCHRON_MODEL} (AP mode) @ {address}"))
}

/// Discover devices through `browser`, falling back to AP mode when it reports no
/// responder.
///
/// Runs the primary (mDNS/Bonjour or replayed) browse; on
/// [`DeviceError::NoService`] returns the single AP-mode fallback device instead.
///
/// # Errors
/// Propagates [`DeviceError::MalformedRecord`] from the browser or the parser.
pub fn discover(browser: &dyn DeviceBrowser) -> Result<Vec<Device>, DeviceError> {
    match browser.browse() {
        Ok(bytes) => parse_discovery(&bytes),
        Err(DeviceError::NoService) => Ok(vec![ap_mode_fallback()]),
        Err(other) => Err(other),
    }
}
