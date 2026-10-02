//! The live network side (issue #179): the UDP discovery probe and the TCP
//! connection the [`DeviceClient`] runs over. `std::net` only — no new
//! dependencies, nothing asynchronous; the app calls these off the main thread.

use std::net::{Ipv4Addr, Shutdown, SocketAddr, SocketAddrV4, TcpStream, UdpSocket};
use std::time::{Duration, Instant};

use crate::client::{CancelToken, DeviceClient, DeviceClock};
use crate::discovery::{ap_mode_fallback, parse_discovery, Device};
use crate::error::DeviceError;
use crate::{DISCOVERY_PORT, DISCOVERY_PROBE};

/// The multicast group the AiM app sends its discovery probe to.
pub const DISCOVERY_GROUP: Ipv4Addr = Ipv4Addr::new(224, 4, 161, 221);

/// The device's own address when the Mac has joined its access point.
const AP_GATEWAY: Ipv4Addr = Ipv4Addr::new(10, 0, 0, 1);

/// The largest discovery reply accepted (the observed one is 236 bytes).
const MAX_DATAGRAM: usize = 2048;

/// How long each wait for a discovery reply lasts before the deadline is
/// re-checked.
const RECEIVE_SLICE: Duration = Duration::from_millis(100);

/// Socket timeouts for a device connection.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Timeouts {
    /// How long opening the TCP connection may take.
    pub connect: Duration,
    /// How long any single read or write may wait.
    pub io: Duration,
}

impl Default for Timeouts {
    /// 5 s to connect, 10 s per read or write.
    fn default() -> Self {
        Timeouts {
            connect: Duration::from_secs(5),
            io: Duration::from_secs(10),
        }
    }
}

/// Stops a connection from another thread: sets the [`CancelToken`] and shuts
/// the socket so a blocked read returns at once.
#[derive(Debug)]
pub struct Canceller {
    token: CancelToken,
    stream: TcpStream,
}

impl Canceller {
    /// Cancel the connection. Safe to call more than once.
    pub fn cancel(&self) {
        self.token.cancel();
        // The socket may already be closed; there is nothing more to do then.
        let _ = self.stream.shutdown(Shutdown::Both);
    }
}

/// Connect to the device at `address` and run the handshake.
///
/// # Errors
/// [`DeviceError::ConnectionFailed`] / [`DeviceError::Timeout`] when the
/// connection cannot be opened; any handshake error.
pub fn connect(
    address: SocketAddr,
    clock: &DeviceClock,
    timeouts: Timeouts,
) -> Result<(DeviceClient<TcpStream>, Canceller), DeviceError> {
    let stream = TcpStream::connect_timeout(&address, timeouts.connect).map_err(|err| {
        match DeviceError::from(err) {
            DeviceError::Timeout => DeviceError::Timeout,
            _ => DeviceError::ConnectionFailed,
        }
    })?;
    stream.set_read_timeout(Some(timeouts.io))?;
    stream.set_write_timeout(Some(timeouts.io))?;
    stream.set_nodelay(true)?;
    let token = CancelToken::new();
    let canceller = Canceller {
        token: token.clone(),
        stream: stream.try_clone()?,
    };
    let client = DeviceClient::handshake(stream, clock, token)?;
    Ok((client, canceller))
}

/// The addresses the live probe is sent to: the AiM multicast group, and the
/// access-point gateway directly.
#[must_use]
pub fn discovery_targets() -> Vec<SocketAddr> {
    [DISCOVERY_GROUP, AP_GATEWAY]
        .into_iter()
        .map(|ip| SocketAddr::V4(SocketAddrV4::new(ip, DISCOVERY_PORT)))
        .collect()
}

/// Send the `aim-ka` probe to each of `targets` and collect the devices that
/// answer within `timeout`. Unreadable replies are ignored; a target that
/// cannot be reached (no network, no route) is skipped.
///
/// # Errors
/// [`DeviceError::ConnectionFailed`] when no UDP socket can be opened at all.
pub fn probe(targets: &[SocketAddr], timeout: Duration) -> Result<Vec<Device>, DeviceError> {
    let socket =
        UdpSocket::bind((Ipv4Addr::UNSPECIFIED, 0)).map_err(|_| DeviceError::ConnectionFailed)?;
    socket.set_read_timeout(Some(RECEIVE_SLICE))?;
    for target in targets {
        // Unreachable targets (e.g. multicast with no route) are expected.
        let _ = socket.send_to(DISCOVERY_PROBE, target);
    }

    let deadline = Instant::now() + timeout;
    let mut devices: Vec<Device> = Vec::new();
    let mut buf = [0u8; MAX_DATAGRAM];
    while Instant::now() < deadline {
        let Ok((len, _from)) = socket.recv_from(&mut buf) else {
            continue; // timed-out slice, or a transient error; keep listening
        };
        for device in parse_discovery(&buf[..len]).unwrap_or_default() {
            if !devices.contains(&device) {
                devices.push(device);
            }
        }
    }
    Ok(devices)
}

/// Discover devices on the live network: probe [`discovery_targets`], and when
/// nothing answers offer the access-point gateway (the MyChron is its own AP),
/// so the result is never empty.
///
/// # Errors
/// [`DeviceError::ConnectionFailed`] when no UDP socket can be opened.
pub fn discover_live(timeout: Duration) -> Result<Vec<Device>, DeviceError> {
    let found = probe(&discovery_targets(), timeout)?;
    Ok(if found.is_empty() {
        vec![ap_mode_fallback()]
    } else {
        found
    })
}
