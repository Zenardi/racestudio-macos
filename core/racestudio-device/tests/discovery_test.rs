//! Behavioural tests for device discovery (issue 6.3) — written test-first.
//!
//! `parse_discovery` turns the recorded, de-identified AiM discovery response
//! (`fixtures/device/discovery/response.bin`) into typed [`Device`]s, matching
//! the golden oracle `fixtures/device/golden/discovery.json`. The live
//! `NWBrowser` adapter is injected behind the [`DeviceBrowser`] trait so these
//! tests replay recorded bytes with no live device attached.

use std::net::{IpAddr, Ipv4Addr};
use std::path::PathBuf;

use racestudio_device::{
    ap_mode_fallback, discover, parse_discovery, Device, DeviceBrowser, DeviceError,
};
use serde::Deserialize;

/// Repo-root-relative fixture path.
fn fixture(rel: &str) -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("../..")
        .join(rel)
}

/// The recorded discovery response bytes.
fn recorded_response() -> Vec<u8> {
    std::fs::read(fixture("fixtures/device/discovery/response.bin"))
        .expect("recorded discovery response fixture must exist")
}

// --- golden oracle -------------------------------------------------------- //

#[derive(Deserialize)]
struct Golden {
    devices: Vec<GoldenDevice>,
}

#[derive(Deserialize)]
struct GoldenDevice {
    name: String,
    address: String,
    port: u16,
    model: String,
}

/// The golden devices, parsed into the same `Device` shape the code produces.
fn golden_devices() -> Vec<Device> {
    let raw = std::fs::read_to_string(fixture("fixtures/device/golden/discovery.json"))
        .expect("golden discovery oracle must exist");
    let golden: Golden = serde_json::from_str(&raw).expect("golden json must parse");
    golden
        .devices
        .into_iter()
        .map(|d| Device {
            name: d.name,
            address: d.address.parse().expect("golden address must be an IP"),
            port: d.port,
            model: d.model,
        })
        .collect()
}

/// A `DeviceBrowser` that replays a fixed byte buffer — the recorded fixture in
/// place of a live mDNS/AP responder.
struct ReplayBrowser {
    bytes: Vec<u8>,
}

impl DeviceBrowser for ReplayBrowser {
    fn browse(&self) -> Result<Vec<u8>, DeviceError> {
        Ok(self.bytes.clone())
    }
}

/// A `DeviceBrowser` that finds no responder — exercises the AP-mode fallback.
struct NoServiceBrowser;

impl DeviceBrowser for NoServiceBrowser {
    fn browse(&self) -> Result<Vec<u8>, DeviceError> {
        Err(DeviceError::NoService)
    }
}

/// A `DeviceBrowser` that surfaces a framing error rather than "no responder".
struct MalformedBrowser;

impl DeviceBrowser for MalformedBrowser {
    fn browse(&self) -> Result<Vec<u8>, DeviceError> {
        Err(DeviceError::MalformedRecord)
    }
}

// --- named behaviours ----------------------------------------------------- //

#[test]
fn test_parse_discovery_matches_golden() {
    // Given the recorded discovery response, When parse_discovery runs, Then it
    // returns exactly the golden Vec<Device>.
    let devices = parse_discovery(&recorded_response()).expect("recorded response must parse");
    assert_eq!(devices, golden_devices());
}

#[test]
fn test_device_fields_populated() {
    // Every documented field is populated with the decoded/derived value.
    let devices = parse_discovery(&recorded_response()).expect("recorded response must parse");
    let device = devices.first().expect("at least one device");
    assert!(!device.name.is_empty(), "name is populated");
    assert_eq!(device.address, IpAddr::V4(Ipv4Addr::new(10, 0, 0, 1)));
    assert_eq!(device.port, 2000, "connect on the control port");
    assert_eq!(device.model, "MyChron");
}

#[test]
fn test_duplicate_announcements_deduplicated() {
    // Two identical announcements (repeated on the wire) collapse to one Device.
    let mut doubled = recorded_response();
    doubled.extend_from_slice(&recorded_response());
    let devices = parse_discovery(&doubled).expect("concatenated responses must parse");
    assert_eq!(
        devices.len(),
        1,
        "identical announcements are de-duplicated"
    );
    assert_eq!(devices, golden_devices());
}

#[test]
fn test_ap_mode_fallback_returns_gateway_device() {
    // With no mDNS responder, discovery yields the well-known AP gateway device.
    let device = ap_mode_fallback();
    assert_eq!(device.address, IpAddr::V4(Ipv4Addr::new(10, 0, 0, 1)));
    assert_eq!(device.port, 2000);
    assert_eq!(device.model, "MyChron");
    assert!(!device.name.is_empty());
}

#[test]
fn test_malformed_record_returns_error() {
    // A truncated record (header only, no full body) is a typed error, not a panic.
    let truncated = &recorded_response()[..8];
    assert_eq!(
        parse_discovery(truncated),
        Err(DeviceError::MalformedRecord)
    );

    // A record whose declared length overruns the buffer is malformed.
    let mut overrun = recorded_response();
    overrun[0] = 0xFF; // length = 0x000000FF = 255 > 236-byte buffer
    assert_eq!(parse_discovery(&overrun), Err(DeviceError::MalformedRecord));

    // A record with the wrong type tag is not an AiM discovery response.
    let mut wrong_type = recorded_response();
    wrong_type[4] = 0x09; // type field byte 0 -> non-2
    assert_eq!(
        parse_discovery(&wrong_type),
        Err(DeviceError::MalformedRecord)
    );
}

#[test]
fn test_browser_trait_replays_recorded_fixtures() {
    // The injected browser replays recorded bytes; discover parses them to the golden.
    let replay = ReplayBrowser {
        bytes: recorded_response(),
    };
    assert_eq!(
        discover(&replay).expect("replayed bytes parse"),
        golden_devices()
    );

    // A browser that finds no responder falls back to the AP gateway device.
    let none = NoServiceBrowser;
    assert_eq!(
        discover(&none).expect("fallback never errors"),
        vec![ap_mode_fallback()]
    );
}

// --- edge / negative cases ------------------------------------------------ //

#[test]
fn test_empty_buffer_yields_no_devices() {
    // An empty announcement buffer is not an error — it simply names no devices.
    assert_eq!(parse_discovery(&[]), Ok(Vec::new()));
}

#[test]
fn test_discover_propagates_browser_framing_error() {
    // A framing error from the browser propagates (only NoService triggers fallback).
    let bad = MalformedBrowser;
    assert_eq!(discover(&bad), Err(DeviceError::MalformedRecord));
}

#[test]
fn test_device_error_is_human_readable() {
    // Both variants render a distinct, non-empty message (Display), and the type
    // round-trips through Clone/Eq.
    let malformed = DeviceError::MalformedRecord;
    let no_service = DeviceError::NoService;
    assert!(!malformed.to_string().is_empty());
    assert!(!no_service.to_string().is_empty());
    assert_ne!(malformed.to_string(), no_service.to_string());
    assert_eq!(malformed.clone(), DeviceError::MalformedRecord);
}
