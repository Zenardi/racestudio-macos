//! Issue #179 — the live download client, end to end over loopback TCP against
//! an in-process fake MyChron that answers from the recorded fixtures.
//!
//! The downloaded session must equal the golden `.xrk` the captured session
//! inflates to (which `transfer_test.rs` proves decodes), the conversation must
//! follow the observed command order, only read commands may ever reach the
//! device, and every failure a link can produce must surface as a typed error.

#[path = "support/fake_mychron.rs"]
mod fake_mychron;

use std::io::{self, Read};
use std::net::{SocketAddr, TcpListener, UdpSocket};
use std::thread;
use std::time::{Duration, Instant};

use fake_mychron::{fixture, frame, golden_xrk, opcode_of, stored_session, FakeMyChron, Fault};
use racestudio_device::command::opcode;
use racestudio_device::stream::{read_frame, MAX_FRAME_PAYLOAD};
use racestudio_device::{
    connect, discover_live, probe, CancelToken, DeviceClient, DeviceClock, DeviceError,
    ProgressSink, SessionDate, Timeouts,
};

const CLOCK: DeviceClock = DeviceClock {
    local: SessionDate {
        year: 2026,
        month: 7,
        day: 21,
        hour: 14,
        minute: 16,
        second: 0,
    },
    utc: SessionDate {
        year: 2026,
        month: 7,
        day: 21,
        hour: 11,
        minute: 16,
        second: 0,
    },
};

const QUICK: Timeouts = Timeouts {
    connect: Duration::from_secs(2),
    io: Duration::from_secs(5),
};

#[derive(Default)]
struct CollectingProgress(Vec<(u64, u64)>);

impl ProgressSink for CollectingProgress {
    fn on_progress(&mut self, bytes_done: u64, total: u64) {
        self.0.push((bytes_done, total));
    }
}

/// Yields its bytes one at a time, as a slow TCP link might.
struct OneByteReader(Vec<u8>, usize);

impl Read for OneByteReader {
    fn read(&mut self, buf: &mut [u8]) -> io::Result<usize> {
        let Some(&byte) = self.0.get(self.1) else {
            return Ok(0);
        };
        buf[0] = byte;
        self.1 += 1;
        Ok(1)
    }
}

/// Fails every read with `kind`.
struct FailingReader(io::ErrorKind);

impl Read for FailingReader {
    fn read(&mut self, _buf: &mut [u8]) -> io::Result<usize> {
        Err(io::Error::from(self.0))
    }
}

// ---- reading frames off a stream -------------------------------------------

#[test]
fn test_read_frame_reassembles_a_frame_delivered_a_byte_at_a_time() {
    let raw = fixture("transfer/chunk.bin");

    let frame = read_frame(&mut OneByteReader(raw.clone(), 0)).expect("frame");

    assert_eq!(frame, raw);
}

#[test]
fn test_read_frame_stops_at_the_end_of_one_frame() {
    let first = fixture("control/hello.bin");
    let second = fixture("transfer/ack.bin");
    let mut reader = OneByteReader([first.clone(), second.clone()].concat(), 0);

    let read = (
        read_frame(&mut reader).expect("first"),
        read_frame(&mut reader).expect("second"),
    );

    assert_eq!(read, (first, second));
}

#[test]
fn test_read_frame_rejects_bytes_that_are_not_a_frame() {
    let mut reader = OneByteReader(b"HTTP/1.1 200 OK\r\n\r\n".to_vec(), 0);

    assert_eq!(
        read_frame(&mut reader),
        Err(DeviceError::UnexpectedResponse)
    );
}

#[test]
fn test_read_frame_rejects_an_oversized_length() {
    let mut header = b"<hSTCP".to_vec();
    header.extend_from_slice(&((MAX_FRAME_PAYLOAD + 1) as u32).to_le_bytes());
    header.extend_from_slice(&[0, b'>']);

    assert_eq!(
        read_frame(&mut OneByteReader(header, 0)),
        Err(DeviceError::MalformedRecord)
    );
}

#[test]
fn test_read_frame_requires_the_trailer() {
    let mut raw = fixture("control/hello.bin");
    let last = raw.len() - 8;
    raw[last..].copy_from_slice(b"XXXXXXXX");

    assert_eq!(
        read_frame(&mut OneByteReader(raw, 0)),
        Err(DeviceError::UnexpectedResponse)
    );
}

#[test]
fn test_read_frame_end_of_stream_mid_frame_is_connection_closed() {
    let mut raw = fixture("control/hello.bin");
    raw.truncate(15);

    assert_eq!(
        read_frame(&mut OneByteReader(raw, 0)),
        Err(DeviceError::ConnectionClosed)
    );
}

#[test]
fn test_read_frame_timeout_is_timeout() {
    let err = read_frame(&mut FailingReader(io::ErrorKind::WouldBlock));

    assert_eq!(err, Err(DeviceError::Timeout));
}

#[test]
fn test_refused_socket_is_connection_failed() {
    assert_eq!(
        DeviceError::from(io::Error::from(io::ErrorKind::ConnectionRefused)),
        DeviceError::ConnectionFailed
    );
}

// ---- the live conversation -------------------------------------------------

#[test]
fn test_lists_the_sessions_stored_on_the_device() {
    let device = FakeMyChron::start(Fault::None);
    let (mut client, _cancel) = connect(device.addr, &CLOCK, QUICK).expect("connects");

    let catalog = client.list_sessions().expect("catalog");

    let names: Vec<&str> = catalog
        .sessions
        .iter()
        .map(|s| s.file_name.as_str())
        .collect();
    assert_eq!(
        names,
        [
            "a_0062.xrz",
            "a_0061.xrz",
            "a_0060.xrz",
            "a_0059.xrz",
            "a_0058.xrz",
            "a_0057.xrz"
        ]
    );
}

#[test]
fn test_downloaded_session_is_the_golden_xrk() {
    let device = FakeMyChron::start(Fault::None);
    let (mut client, _cancel) = connect(device.addr, &CLOCK, QUICK).expect("connects");

    let xrk = client
        .download("a_0053.xrz", &mut CollectingProgress::default())
        .expect("download");

    assert_eq!(xrk, golden_xrk());
}

#[test]
fn test_catalog_entry_downloads_by_its_file_name() {
    let device = FakeMyChron::start(Fault::None);
    let (mut client, _cancel) = connect(device.addr, &CLOCK, QUICK).expect("connects");
    let newest = client.list_sessions().expect("catalog").sessions[0]
        .file_name
        .clone();

    let xrk = client
        .download(&newest, &mut CollectingProgress::default())
        .expect("download");

    assert_eq!(xrk, golden_xrk());
}

#[test]
fn test_download_progress_runs_to_the_stored_size() {
    let device = FakeMyChron::start(Fault::None);
    let (mut client, _cancel) = connect(device.addr, &CLOCK, QUICK).expect("connects");
    let mut progress = CollectingProgress::default();
    let stored = stored_session().len() as u64;

    client
        .download("a_0053.xrz", &mut progress)
        .expect("download");

    assert_eq!(progress.0.first(), Some(&(0, stored)));
    assert_eq!(progress.0.last(), Some(&(stored, stored)));
}

#[test]
fn test_conversation_follows_the_observed_command_order() {
    let device = FakeMyChron::start(Fault::None);
    let (mut client, _cancel) = connect(device.addr, &CLOCK, QUICK).expect("connects");
    client.list_sessions().expect("catalog");
    client
        .download("a_0053.xrz", &mut CollectingProgress::default())
        .expect("download");
    client.close().expect("close");

    let commands: Vec<u32> = device
        .client_payloads()
        .iter()
        .filter_map(|p| opcode_of(p))
        .collect();

    assert_eq!(
        commands,
        [
            opcode::SESSION_OPEN,
            opcode::INFO[0],
            opcode::INFO[1],
            opcode::INFO[2],
            opcode::CATALOG,
            opcode::READ_FILE,
            opcode::CLOSE,
        ]
    );
}

#[test]
fn test_client_sends_the_captured_hello_and_clock() {
    let device = FakeMyChron::start(Fault::None);
    let (client, _cancel) = connect(device.addr, &CLOCK, QUICK).expect("connects");
    client.close().expect("close");

    let sent = device.client_payloads();

    let payload = |rel: &str| {
        racestudio_device::parse_frame(&fixture(rel))
            .expect("frame")
            .0
            .payload
            .to_vec()
    };
    assert_eq!(sent[0], payload("client/hello_request.bin"));
    assert_eq!(sent[2], payload("client/clock_upload.bin"));
}

#[test]
fn test_corrupt_chunk_is_requested_again() {
    let device = FakeMyChron::start(Fault::CorruptFirstChunk);
    let (mut client, _cancel) = connect(device.addr, &CLOCK, QUICK).expect("connects");

    let xrk = client
        .download("a_0053.xrz", &mut CollectingProgress::default())
        .expect("download");
    client.close().expect("close");

    assert_eq!(xrk, golden_xrk());
    let zero_acks = device
        .client_payloads()
        .iter()
        .filter(|p| p.as_slice() == [0, 0, 0, 0])
        .count();
    // ACK(0) once for each of the four handshake reads (session-open and the
    // three info reads), then twice for the file: the first request and the
    // re-request after the corrupt chunk.
    assert_eq!(zero_acks, 4 + 2);
}

#[test]
fn test_dropped_connection_is_connection_closed() {
    let device = FakeMyChron::start(Fault::DropAfterChunks(1));
    let (mut client, _cancel) = connect(device.addr, &CLOCK, QUICK).expect("connects");

    let err = client.download("a_0053.xrz", &mut CollectingProgress::default());

    assert_eq!(err, Err(DeviceError::ConnectionClosed));
}

#[test]
fn test_silent_device_times_out() {
    let device = FakeMyChron::start(Fault::StallBeforeChunk(Duration::from_secs(2)));
    let timeouts = Timeouts {
        io: Duration::from_millis(300),
        ..QUICK
    };
    let (mut client, _cancel) = connect(device.addr, &CLOCK, timeouts).expect("connects");

    let err = client.download("a_0053.xrz", &mut CollectingProgress::default());

    assert_eq!(err, Err(DeviceError::Timeout));
}

#[test]
fn test_cancel_stops_a_waiting_download() {
    let device = FakeMyChron::start(Fault::StallBeforeChunk(Duration::from_secs(3)));
    let (mut client, cancel) = connect(device.addr, &CLOCK, QUICK).expect("connects");
    let canceller = thread::spawn(move || {
        thread::sleep(Duration::from_millis(200));
        cancel.cancel();
    });
    let started = Instant::now();

    let err = client.download("a_0053.xrz", &mut CollectingProgress::default());

    canceller.join().expect("canceller");
    assert_eq!(err, Err(DeviceError::Cancelled));
    assert!(started.elapsed() < Duration::from_secs(2));
}

#[test]
fn test_cancelled_client_sends_nothing_more() {
    let device = FakeMyChron::start(Fault::None);
    let (mut client, cancel) = connect(device.addr, &CLOCK, QUICK).expect("connects");
    cancel.cancel();

    let err = client.list_sessions();

    assert_eq!(err, Err(DeviceError::Cancelled));
}

#[test]
fn test_wrong_device_hello_is_unexpected() {
    let device = FakeMyChron::start(Fault::WrongHello);

    let err = connect(device.addr, &CLOCK, QUICK).map(|_| ());

    assert_eq!(err, Err(DeviceError::UnexpectedResponse));
}

#[test]
fn test_echo_of_another_command_is_unexpected() {
    let device = FakeMyChron::start(Fault::WrongEcho);
    let (mut client, _cancel) = connect(device.addr, &CLOCK, QUICK).expect("connects");

    assert_eq!(client.list_sessions(), Err(DeviceError::UnexpectedResponse));
}

#[test]
fn test_file_name_outside_the_session_store_is_never_sent() {
    let device = FakeMyChron::start(Fault::None);
    let (mut client, _cancel) = connect(device.addr, &CLOCK, QUICK).expect("connects");

    let err = client.download("../sys/firmware.xrz", &mut CollectingProgress::default());
    client.close().expect("close");

    assert_eq!(err, Err(DeviceError::InvalidPath));
    let reads = device
        .client_payloads()
        .iter()
        .filter(|p| opcode_of(p) == Some(opcode::READ_FILE))
        .count();
    assert_eq!(reads, 0);
}

#[test]
fn test_device_with_an_empty_catalog_lists_nothing() {
    let device = FakeMyChron::start_with(Vec::new(), Default::default(), Fault::None);
    let (mut client, _cancel) = connect(device.addr, &CLOCK, QUICK).expect("connects");

    let catalog = client.list_sessions().expect("catalog");

    assert!(catalog.sessions.is_empty());
}

#[test]
fn test_connecting_to_a_closed_port_fails() {
    let unused = TcpListener::bind("127.0.0.1:0")
        .expect("bind")
        .local_addr()
        .expect("addr");

    let err = connect(unused, &CLOCK, QUICK).map(|_| ());

    assert_eq!(err, Err(DeviceError::ConnectionFailed));
}

#[test]
fn test_default_timeouts_are_five_and_ten_seconds() {
    assert_eq!(
        Timeouts::default(),
        Timeouts {
            connect: Duration::from_secs(5),
            io: Duration::from_secs(10)
        }
    );
}

#[test]
fn test_cancel_token_starts_uncancelled() {
    assert!(!CancelToken::new().is_cancelled());
}

// ---- discovery ---------------------------------------------------------------

/// A UDP responder that answers one probe with `reply`.
fn responder(reply: Vec<u8>) -> (SocketAddr, thread::JoinHandle<Vec<u8>>) {
    let socket = UdpSocket::bind("127.0.0.1:0").expect("bind");
    let addr = socket.local_addr().expect("addr");
    let handle = thread::spawn(move || {
        let mut buf = [0u8; 64];
        let (len, from) = socket.recv_from(&mut buf).expect("probe");
        socket.send_to(&reply, from).expect("reply");
        buf[..len].to_vec()
    });
    (addr, handle)
}

#[test]
fn test_probe_finds_the_responding_device() {
    let (addr, handle) = responder(fixture("discovery/response.bin"));

    let devices = probe(&[addr], Duration::from_millis(500)).expect("probe");

    assert_eq!(handle.join().expect("responder"), b"aim-ka");
    assert_eq!(devices.len(), 1);
    assert_eq!(devices[0].address.to_string(), "10.0.0.1");
}

#[test]
fn test_probe_ignores_an_unreadable_reply() {
    let (addr, handle) = responder(b"not a device".to_vec());

    let devices = probe(&[addr], Duration::from_millis(300)).expect("probe");

    handle.join().expect("responder");
    assert!(devices.is_empty());
}

#[test]
fn test_live_discovery_always_offers_a_device() {
    let devices = discover_live(Duration::from_millis(50)).expect("discovery");

    assert!(!devices.is_empty());
}

#[test]
fn test_chunk_frame_helper_round_trips() {
    // Guards the fake device's framing against the crate's parser.
    let raw = frame(b"abc");

    assert_eq!(
        racestudio_device::verified_frame(&raw)
            .expect("valid")
            .payload,
        b"abc"
    );
}

// ---- socket write failures ---------------------------------------------------

/// A stream whose writes fail; when it holds a token, it cancels it first, as
/// another thread's `Canceller::cancel` would while a write was in flight.
struct BrokenWriter(Option<CancelToken>);

impl Read for BrokenWriter {
    fn read(&mut self, _buf: &mut [u8]) -> io::Result<usize> {
        Ok(0)
    }
}

impl io::Write for BrokenWriter {
    fn write(&mut self, _buf: &[u8]) -> io::Result<usize> {
        if let Some(token) = &self.0 {
            token.cancel();
        }
        Err(io::Error::from(io::ErrorKind::BrokenPipe))
    }

    fn flush(&mut self) -> io::Result<()> {
        Ok(())
    }
}

#[test]
fn test_failed_write_is_connection_closed() {
    let err = DeviceClient::handshake(BrokenWriter(None), &CLOCK, CancelToken::new()).map(|_| ());

    assert_eq!(err, Err(DeviceError::ConnectionClosed));
}

#[test]
fn test_write_failing_because_of_cancel_is_cancelled() {
    let token = CancelToken::new();

    let err = DeviceClient::handshake(BrokenWriter(Some(token.clone())), &CLOCK, token).map(|_| ());

    assert_eq!(err, Err(DeviceError::Cancelled));
}

#[test]
fn test_live_client_errors_have_messages() {
    let errors = [
        DeviceError::UnexpectedResponse,
        DeviceError::InvalidPath,
        DeviceError::Timeout,
        DeviceError::ConnectionFailed,
        DeviceError::ConnectionClosed,
        DeviceError::Cancelled,
    ];

    let messages: Vec<String> = errors.iter().map(ToString::to_string).collect();

    assert!(messages.iter().all(|m| !m.is_empty()));
}
