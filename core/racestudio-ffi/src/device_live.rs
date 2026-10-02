//! The live MyChron connection across the FFI boundary (issue #179).
//!
//! Swift discovers devices with [`discover_devices`], opens a
//! [`DeviceConnection`], lists the stored sessions and downloads them one by
//! one. Every call blocks on the network, so the app makes them off the main
//! thread; [`DeviceConnection::cancel`] may be called from any thread to stop a
//! call in progress. After any failure other than a rejected file name the
//! connection is dropped, so the next call reports `ConnectionClosed` and the
//! app reconnects instead of talking to a device that is out of step.

use std::net::{IpAddr, SocketAddr, TcpStream};
use std::sync::{Arc, Mutex, MutexGuard};
use std::time::Duration;

use racestudio_device::{
    connect as core_connect, discover_live, Canceller, Catalog, DeviceClient,
    DeviceClock as CoreDeviceClock, DeviceError as CoreDeviceError, SessionDate as CoreSessionDate,
    SessionEntry, Timeouts,
};

use crate::{Device, DiscoveryError, DownloadProgress, ProgressAdapter, SessionDate};

/// The clock the app hands the device when it connects: the local time and the
/// same instant in UTC.
#[derive(Debug, Clone, Copy, uniffi::Record)]
pub struct DeviceClock {
    /// The local wall-clock time.
    pub local: SessionDate,
    /// The same instant in UTC.
    pub utc: SessionDate,
}

/// One session stored on the device, as its catalog lists it.
#[derive(Debug, Clone, uniffi::Record)]
pub struct DeviceSession {
    /// The on-device file name (`a_0061.xrz`); pass it to
    /// [`DeviceConnection::download`].
    pub file_name: String,
    /// The stored (compressed) size in bytes — what the download transfers.
    pub size_bytes: u32,
    /// When the session started (device-local time).
    pub date: SessionDate,
    /// Number of recorded laps.
    pub lap_count: u16,
    /// The best lap's number, when the logger timed one.
    pub best_lap_number: Option<u16>,
    /// The best lap's time in milliseconds, when the logger timed one.
    pub best_lap_ms: Option<u32>,
    /// The driver name configured on the logger (often empty).
    pub driver: String,
    /// The track the logger matched.
    pub track_name: String,
    /// The vehicle name configured on the logger.
    pub vehicle: String,
    /// The championship name configured on the logger.
    pub championship: String,
    /// The session's duration in milliseconds.
    pub duration_ms: Option<u32>,
    /// The track's latitude in degrees.
    pub track_latitude: Option<f64>,
    /// The track's longitude in degrees.
    pub track_longitude: Option<f64>,
}

/// The device's catalog: the stored sessions, plus how many unreadable rows
/// were left out.
#[derive(Debug, Clone, uniffi::Record)]
pub struct DeviceCatalog {
    /// The stored sessions, in the device's order.
    pub sessions: Vec<DeviceSession>,
    /// Catalog rows that could not be read.
    pub skipped_rows: u32,
}

impl From<SessionEntry> for DeviceSession {
    fn from(e: SessionEntry) -> Self {
        DeviceSession {
            file_name: e.file_name,
            size_bytes: e.size_bytes,
            date: e.date.into(),
            lap_count: e.lap_count,
            best_lap_number: e.best_lap_number,
            best_lap_ms: e.best_lap_ms,
            driver: e.driver,
            track_name: e.track_name,
            vehicle: e.vehicle,
            championship: e.championship,
            duration_ms: e.duration_ms,
            track_latitude: e.track_latitude,
            track_longitude: e.track_longitude,
        }
    }
}

impl From<Catalog> for DeviceCatalog {
    fn from(c: Catalog) -> Self {
        DeviceCatalog {
            sessions: c.sessions.into_iter().map(DeviceSession::from).collect(),
            skipped_rows: u32::try_from(c.skipped_rows).unwrap_or(u32::MAX),
        }
    }
}

/// Find MyChron devices on the network the Mac is joined to: send the AiM
/// discovery probe and collect the replies for `timeout_ms`. When nothing
/// answers, the access-point gateway (`10.0.0.1:2000`) is offered, so the list
/// is never empty.
///
/// # Errors
/// [`DiscoveryError::ConnectionFailed`] when no UDP socket can be opened.
#[uniffi::export]
pub fn discover_devices(timeout_ms: u32) -> Result<Vec<Device>, DiscoveryError> {
    let devices = discover_live(Duration::from_millis(u64::from(timeout_ms)))?;
    Ok(devices.into_iter().map(Device::from).collect())
}

/// An open conversation with one MyChron.
#[derive(uniffi::Object)]
pub struct DeviceConnection {
    client: Mutex<Option<DeviceClient<TcpStream>>>,
    canceller: Canceller,
}

#[uniffi::export]
impl DeviceConnection {
    /// Connect to `device` and run the opening handshake, handing it `clock`.
    ///
    /// # Errors
    /// `ConnectionFailed` / `Timeout` when the device cannot be reached;
    /// `UnexpectedResponse` when it does not answer like a MyChron.
    #[uniffi::constructor]
    pub fn connect(device: Device, clock: DeviceClock) -> Result<Arc<Self>, DiscoveryError> {
        let ip: IpAddr = device
            .address
            .parse()
            .map_err(|_| DiscoveryError::ConnectionFailed)?;
        let clock = CoreDeviceClock {
            local: core_date(clock.local),
            utc: core_date(clock.utc),
        };
        let (client, canceller) = core_connect(
            SocketAddr::new(ip, device.port),
            &clock,
            Timeouts::default(),
        )?;
        Ok(Arc::new(DeviceConnection {
            client: Mutex::new(Some(client)),
            canceller,
        }))
    }

    /// Read the catalog of sessions stored on the device.
    ///
    /// # Errors
    /// Any exchange failure; the connection is then closed.
    pub fn list_sessions(&self) -> Result<DeviceCatalog, DiscoveryError> {
        with_client(self, DeviceClient::list_sessions).map(DeviceCatalog::from)
    }

    /// Download the stored session `file_name` and return the `.xrk` bytes,
    /// reporting progress in stored bytes. Nothing on the device is changed.
    ///
    /// # Errors
    /// `InvalidPath` for a name the catalog could not have listed (the
    /// connection stays open); any other exchange failure closes it. No partial
    /// file is ever returned.
    pub fn download(
        &self,
        file_name: String,
        progress: Box<dyn DownloadProgress>,
    ) -> Result<Vec<u8>, DiscoveryError> {
        let mut sink = ProgressAdapter(progress);
        with_client(self, |client| client.download(&file_name, &mut sink))
    }

    /// Stop the call in progress (from any thread). The connection is closed;
    /// the interrupted call reports `Cancelled`.
    pub fn cancel(&self) {
        self.canceller.cancel();
    }

    /// End the conversation politely and close the connection.
    pub fn close(&self) {
        if let Some(client) = lock(self).take() {
            // The device sends no reply to a close; a failure to send it only
            // means the link is already gone.
            let _ = client.close();
        }
    }
}

/// Run `op` on the open client. A failure other than a rejected file name
/// drops the client, closing the socket.
fn with_client<T>(
    conn: &DeviceConnection,
    op: impl FnOnce(&mut DeviceClient<TcpStream>) -> Result<T, CoreDeviceError>,
) -> Result<T, DiscoveryError> {
    let mut slot = lock(conn);
    let client = slot.as_mut().ok_or(DiscoveryError::ConnectionClosed)?;
    let result = op(client);
    if matches!(&result, Err(err) if *err != CoreDeviceError::InvalidPath) {
        *slot = None;
    }
    result.map_err(DiscoveryError::from)
}

/// The client slot. A panic while it was held cannot leave it half-written (it
/// is only ever replaced whole), so a poisoned lock is still safe to use.
fn lock(conn: &DeviceConnection) -> MutexGuard<'_, Option<DeviceClient<TcpStream>>> {
    conn.client
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner)
}

fn core_date(d: SessionDate) -> CoreSessionDate {
    CoreSessionDate {
        year: d.year,
        month: d.month,
        day: d.day,
        hour: d.hour,
        minute: d.minute,
        second: d.second,
    }
}
