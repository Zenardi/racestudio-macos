//! Issue #179 — the live device connection as Swift sees it: discover, connect,
//! list and download over loopback TCP against the fake MyChron, with failures
//! surfacing as thrown `DiscoveryError`s and a broken connection reported as
//! closed rather than reused out of step.

#[path = "../../racestudio-device/tests/support/fake_mychron.rs"]
mod fake_mychron;

use std::collections::HashMap;
use std::net::TcpListener;
use std::sync::{Arc, Mutex};

use fake_mychron::{catalog_csv, golden_xrk, stored_session, FakeMyChron, Fault};
use racestudio_ffi::{
    discover_devices, Device, DeviceClock, DeviceConnection, DiscoveryError, DownloadProgress,
    SessionDate,
};

const DATE: SessionDate = SessionDate {
    year: 2026,
    month: 7,
    day: 21,
    hour: 14,
    minute: 16,
    second: 0,
};
const CLOCK: DeviceClock = DeviceClock {
    local: DATE,
    utc: DATE,
};

fn device_at(address: &str, port: u16) -> Device {
    Device {
        name: "MyChron @ test".to_string(),
        address: address.to_string(),
        port,
        model: "MyChron".to_string(),
    }
}

fn connect_to(fake: &FakeMyChron) -> Arc<DeviceConnection> {
    DeviceConnection::connect(device_at("127.0.0.1", fake.addr.port()), CLOCK).expect("connects")
}

#[derive(Clone, Default)]
struct Recorder(Arc<Mutex<Vec<(u64, u64)>>>);

impl DownloadProgress for Recorder {
    fn on_progress(&self, bytes_done: u64, total: u64) {
        self.0.lock().expect("lock").push((bytes_done, total));
    }
}

#[test]
fn test_connection_lists_the_stored_sessions() {
    let fake = FakeMyChron::start(Fault::None);
    let conn = connect_to(&fake);

    let catalog = conn.list_sessions().expect("catalog");

    assert_eq!(catalog.sessions.len(), 6);
    assert_eq!(catalog.sessions[0].file_name, "a_0062.xrz");
    assert_eq!(catalog.sessions[0].best_lap_ms, Some(60026));
    assert_eq!(catalog.skipped_rows, 0);
}

#[test]
fn test_connection_downloads_a_session_as_xrk() {
    let fake = FakeMyChron::start(Fault::None);
    let conn = connect_to(&fake);
    let progress = Recorder::default();

    let xrk = conn
        .download("a_0062.xrz".to_string(), Box::new(progress.clone()))
        .expect("download");

    let stored = stored_session().len() as u64;
    assert_eq!(xrk, golden_xrk());
    assert_eq!(
        progress.0.lock().expect("lock").last(),
        Some(&(stored, stored))
    );
}

#[test]
fn test_unreadable_catalog_rows_are_counted() {
    let mut csv = catalog_csv();
    csv.extend_from_slice(b"broken row\r\n");
    let fake = FakeMyChron::start_with(csv, HashMap::new(), Fault::None);
    let conn = connect_to(&fake);

    let catalog = conn.list_sessions().expect("catalog");

    assert_eq!(catalog.skipped_rows, 1);
}

#[test]
fn test_rejected_file_name_keeps_the_connection_open() {
    let fake = FakeMyChron::start(Fault::None);
    let conn = connect_to(&fake);

    let err = conn.download("../x.xrz".to_string(), Box::new(Recorder::default()));

    assert!(matches!(err, Err(DiscoveryError::InvalidPath)));
    assert!(conn.list_sessions().is_ok());
}

#[test]
fn test_failed_exchange_closes_the_connection() {
    let fake = FakeMyChron::start(Fault::WrongEcho);
    let conn = connect_to(&fake);

    let first = conn.list_sessions();
    let second = conn.list_sessions();

    assert!(matches!(first, Err(DiscoveryError::UnexpectedResponse)));
    assert!(matches!(second, Err(DiscoveryError::ConnectionClosed)));
}

#[test]
fn test_closed_connection_reports_closed() {
    let fake = FakeMyChron::start(Fault::None);
    let conn = connect_to(&fake);

    conn.close();
    conn.close();

    assert!(matches!(
        conn.list_sessions(),
        Err(DiscoveryError::ConnectionClosed)
    ));
}

#[test]
fn test_cancelled_connection_reports_cancelled() {
    let fake = FakeMyChron::start(Fault::None);
    let conn = connect_to(&fake);

    conn.cancel();

    assert!(matches!(
        conn.list_sessions(),
        Err(DiscoveryError::Cancelled)
    ));
}

#[test]
fn test_unparseable_address_fails_to_connect() {
    let err = DeviceConnection::connect(device_at("not an address", 2000), CLOCK);

    assert!(matches!(err, Err(DiscoveryError::ConnectionFailed)));
}

#[test]
fn test_closed_port_fails_to_connect() {
    let port = TcpListener::bind("127.0.0.1:0")
        .expect("bind")
        .local_addr()
        .expect("addr")
        .port();

    let err = DeviceConnection::connect(device_at("127.0.0.1", port), CLOCK);

    assert!(matches!(err, Err(DiscoveryError::ConnectionFailed)));
}

#[test]
fn test_discovery_always_offers_a_device() {
    let devices = discover_devices(50).expect("discovery");

    assert!(!devices.is_empty());
}

#[test]
fn test_new_errors_have_messages() {
    let messages: Vec<String> = [
        DiscoveryError::UnexpectedResponse,
        DiscoveryError::InvalidPath,
        DiscoveryError::Timeout,
        DiscoveryError::ConnectionFailed,
        DiscoveryError::ConnectionClosed,
        DiscoveryError::Cancelled,
    ]
    .iter()
    .map(ToString::to_string)
    .collect();

    assert!(messages.iter().all(|m| !m.is_empty()));
}
