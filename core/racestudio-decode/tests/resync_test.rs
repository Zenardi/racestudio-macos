//! Regression: a data message for a channel with no `CHS` definition must not
//! discard the rest of the file.
//!
//! Real MyChron exports log channels that are never defined in the `CHS` table
//! (a user's `stint*.xrk` referenced 14 such indices). The walkers size a data
//! message from its channel's `CHS` entry, so an undefined channel made them
//! unable to advance — and every walker answered that by `break`ing, silently
//! dropping everything after the first such message. On the file that prompted
//! this test that was 99.7% of the session: 0 channels, 0 laps, no GPS, yet
//! `decode_session` still returned `Ok`.

use racestudio_decode::{decode_session, open_container};

const MAGIC: [u8; 2] = [0x3C, 0x68];

fn token_to_u32(token: &str) -> u32 {
    let mut bytes = token.as_bytes().to_vec();
    while bytes.len() < 4 {
        bytes.push(b' ');
    }
    u32::from_le_bytes([bytes[0], bytes[1], bytes[2], bytes[3]])
}

/// A framed header message (`<h … >`) with a correct checksum.
fn frame(token: &str, payload: &[u8]) -> Vec<u8> {
    let tok = token_to_u32(token);
    let mut out = Vec::new();
    out.extend_from_slice(&MAGIC);
    out.extend_from_slice(&tok.to_le_bytes());
    out.extend_from_slice(&(payload.len() as i32).to_le_bytes());
    out.push(0);
    out.push(b'>');
    out.extend_from_slice(payload);
    out.push(b'<');
    out.extend_from_slice(&tok.to_le_bytes());
    let checksum = (payload.iter().map(|&b| u32::from(b)).sum::<u32>() & 0xFFFF) as u16;
    out.extend_from_slice(&checksum.to_le_bytes());
    out.push(b'>');
    out
}

/// A 112-byte `CHS` payload for a keepable 2-byte channel: `index`, a `U16`
/// decoder (type 1, itemsize 2), a 10 ms sample period, and a name.
fn chs(index: u16, data_size: u8) -> Vec<u8> {
    let mut p = vec![0u8; 112];
    p[0..2].copy_from_slice(&index.to_le_bytes());
    p[20] = 1; // decoder type: U16 (itemsize 2, so it fits data_size)
    let name = b"Probe";
    p[32..32 + name.len()].copy_from_slice(name);
    p[64..68].copy_from_slice(&10_000u32.to_le_bytes()); // 10 ms period -> 100 Hz
    p[72] = data_size;
    p
}

fn trk(name: &str) -> Vec<u8> {
    let mut p = vec![0u8; 44];
    p[..name.len()].copy_from_slice(name.as_bytes());
    p
}

/// A single-sample data message: `'(S' + timecode + channel + data + ')'`.
fn s_msg(timecode: u32, channel: u16, data: &[u8]) -> Vec<u8> {
    let mut m = vec![b'(', b'S'];
    m.extend_from_slice(&timecode.to_le_bytes());
    m.extend_from_slice(&channel.to_le_bytes());
    m.extend_from_slice(data);
    m.push(b')');
    m
}

/// A container whose data stream references `undefined` (no `CHS` entry) between
/// two samples of the defined channel 0, optionally followed by GPS and lap
/// markers. `with_trailers` is off for the sample-level test because a synthetic
/// `GPS` payload is not a whole number of fixes (`decode_session` rejects that,
/// correctly) — the container-level test asserts on the trailers instead.
fn file_with_undefined_channel(undefined: u16, with_trailers: bool) -> Vec<u8> {
    let mut cnf = Vec::new();
    cnf.extend(frame("CHS", &chs(0, 2)));

    let mut file = Vec::new();
    file.extend(frame("CNF", &cnf));
    file.extend(frame("TRK", &trk("Imola")));
    file.extend(s_msg(0, 0, &[0x11, 0x22]));
    file.extend(s_msg(1, undefined, &[0x33, 0x44]));
    file.extend(s_msg(2, 0, &[0x55, 0x66]));
    if with_trailers {
        file.extend(frame("GPS", &[0u8; 8]));
        file.extend(frame("LAP", &[0u8; 8]));
    }
    file
}

fn write_temp(name: &str, bytes: &[u8]) -> std::path::PathBuf {
    let path = std::env::temp_dir().join(format!(
        "rs-resync-{}-{}-{name}",
        std::process::id(),
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_nanos())
            .unwrap_or(0)
    ));
    std::fs::write(&path, bytes).expect("write temp xrk");
    path
}

#[test]
fn test_undefined_channel_does_not_hide_later_gps_and_laps() {
    let path = write_temp("gps-laps.xrk", &file_with_undefined_channel(99, true));
    let container = open_container(&path).expect("open");
    let _ = std::fs::remove_file(&path);

    assert!(
        container.has_gps(),
        "GPS after an unsized data message must still be seen"
    );
    assert_eq!(
        container.lap_marker_count(),
        1,
        "lap markers after an unsized data message must still be counted"
    );
    assert_eq!(container.metadata().track, "Imola");
}

#[test]
fn test_undefined_channel_does_not_truncate_the_defined_channel() {
    let path = write_temp("samples.xrk", &file_with_undefined_channel(99, false));
    let session = decode_session(path.to_string_lossy().into_owned()).expect("decode");
    let _ = std::fs::remove_file(&path);

    let channel = session.channels().first().expect("channel 0 must decode");
    assert_eq!(
        channel.samples().len(),
        2,
        "the sample after the unsized message must survive"
    );
}

#[test]
fn test_recovery_reports_how_many_messages_were_skipped() {
    // Silent recovery would trade one silent failure for another; the count makes
    // an undecodable region observable.
    let path = write_temp("counted.xrk", &file_with_undefined_channel(99, true));
    let container = open_container(&path).expect("open");
    let _ = std::fs::remove_file(&path);

    assert_eq!(container.unsized_message_count(), 1);
}

#[test]
fn test_a_fully_defined_container_reports_no_skips() {
    // The recovery path must not trigger on a well-formed file.
    let path = write_temp("clean.xrk", &file_with_undefined_channel(0, true));
    let container = open_container(&path).expect("open");
    let _ = std::fs::remove_file(&path);

    assert_eq!(container.unsized_message_count(), 0);
}
