//! Synthetic `.xrk` builders for the CSV-export tests (issue 5.1).
//!
//! [`write_aim_csv`](racestudio_io::write_aim_csv) takes a decoded
//! [`Session`](racestudio_decode::Session), whose fields are private and which is
//! only constructed by `decode_session`. To exercise the writer deterministically
//! — without depending on the large, git-ignored `fixtures/*.xrk` — these helpers
//! assemble a minimal `.xrk` byte stream (the exact framing the M1 decoders
//! parse), write it to a temp file, and decode it into a real `Session`.
//!
//! The builders mirror the framing helpers in the decode crate's own unit tests;
//! each test binary uses a subset, so unused helpers are expected.
#![allow(dead_code)]

use std::sync::atomic::{AtomicU64, Ordering};

use racestudio_decode::{decode_session, Session};

/// Header-message magic (`'<h'`).
const MAGIC: [u8; 2] = [0x3C, 0x68];

fn token_to_u32(token: &str) -> u32 {
    let mut b = token.as_bytes().to_vec();
    while b.len() < 4 {
        b.push(0);
    }
    u32::from_le_bytes([b[0], b[1], b[2], b[3]])
}

/// A framed header message (`<h … >`) with a correct checksum.
pub fn frame(token: &str, payload: &[u8]) -> Vec<u8> {
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

/// A 112-byte CHS channel definition.
pub fn chs(
    index: u16,
    name: &str,
    unit_type: u8,
    decoder: u8,
    data_size: u8,
    period_us: u32,
) -> Vec<u8> {
    let mut p = vec![0u8; 112];
    p[0..2].copy_from_slice(&index.to_le_bytes());
    p[12] = unit_type;
    p[20] = decoder;
    let nb = name.as_bytes();
    p[32..32 + nb.len()].copy_from_slice(nb);
    p[64..68].copy_from_slice(&period_us.to_le_bytes());
    p[72] = data_size;
    p
}

/// A `(S` single-sample data message.
pub fn data_s(channel: u16, tc: i32, data: &[u8]) -> Vec<u8> {
    let mut m = vec![b'(', b'S'];
    m.extend_from_slice(&tc.to_le_bytes());
    m.extend_from_slice(&channel.to_le_bytes());
    m.extend_from_slice(data);
    m.push(b')');
    m
}

/// A 32-byte whole-lap (`segment 0`) LAP marker. `end_time_ms` is the lap's
/// cumulative end timecode (offset 16), from which the decoder derives the
/// recording origin (`end_time − duration`).
pub fn lap_marker(segment: u8, lap: u16, duration_ms: u32, end_time_ms: u32) -> Vec<u8> {
    let mut p = vec![0u8; 32];
    p[1] = segment;
    p[2..4].copy_from_slice(&lap.to_le_bytes());
    p[4..8].copy_from_slice(&duration_ms.to_le_bytes());
    p[16..20].copy_from_slice(&end_time_ms.to_le_bytes());
    p
}

/// WGS84 geodetic → ECEF (metres), so a synthetic NAV-SOL record round-trips
/// back through the decoder's `ecef_to_lla` to the input latitude/longitude.
fn lla_to_ecef(lat_deg: f64, lon_deg: f64, h: f64) -> (f64, f64, f64) {
    let a = 6_378_137.0_f64;
    let e2 = 8.181_919_084_261_345e-2_f64.powi(2);
    let lat = lat_deg.to_radians();
    let lon = lon_deg.to_radians();
    let n = a / (1.0 - e2 * lat.sin().powi(2)).sqrt();
    let x = (n + h) * lat.cos() * lon.cos();
    let y = (n + h) * lat.cos() * lon.sin();
    let z = (n * (1.0 - e2) + h) * lat.sin();
    (x, y, z)
}

/// A 56-byte u-blox NAV-SOL record from geodetic position + ECEF velocity.
#[allow(clippy::too_many_arguments)]
pub fn gps_record(
    tc: i32,
    lat: f64,
    lon: f64,
    alt: f64,
    vel_cms: (i32, i32, i32),
    pacc_cm: u32,
    sacc_cms: u32,
    pdop_raw: u16,
    fix: u8,
    sats: u8,
) -> Vec<u8> {
    let (x, y, z) = lla_to_ecef(lat, lon, alt);
    let mut r = vec![0u8; 56];
    r[0..4].copy_from_slice(&tc.to_le_bytes());
    r[14] = fix;
    r[16..20].copy_from_slice(&((x * 100.0).round() as i32).to_le_bytes());
    r[20..24].copy_from_slice(&((y * 100.0).round() as i32).to_le_bytes());
    r[24..28].copy_from_slice(&((z * 100.0).round() as i32).to_le_bytes());
    r[28..32].copy_from_slice(&pacc_cm.to_le_bytes());
    r[32..36].copy_from_slice(&vel_cms.0.to_le_bytes());
    r[36..40].copy_from_slice(&vel_cms.1.to_le_bytes());
    r[40..44].copy_from_slice(&vel_cms.2.to_le_bytes());
    r[44..48].copy_from_slice(&sacc_cms.to_le_bytes());
    r[48..50].copy_from_slice(&pdop_raw.to_le_bytes());
    r[51] = sats;
    r
}

/// The standard synthetic metadata block (driver, vehicle, venue, series, date,
/// time) so the exported header rows carry assertable content.
pub fn metadata_frames() -> Vec<u8> {
    let mut out = Vec::new();
    out.extend(frame("RCR", b"CMD\0"));
    out.extend(frame("VEH", b"SFJ\0"));
    out.extend(frame("CMP", b"Practice\0"));
    out.extend(frame("VTY", b"Session\0"));
    out.extend(frame("TMD", b"11/04/2025\0"));
    out.extend(frame("TMT", b"15:50:07\0"));
    // TRK name lives in the first 32 bytes of the payload.
    let mut trk = vec![0u8; 44];
    trk[..4].copy_from_slice(b"Fuji");
    out.extend(frame("TRK", &trk));
    out
}

/// Write `bytes` to a unique temp `.xrk` and decode it into a real `Session`.
pub fn decode_bytes(bytes: &[u8]) -> Session {
    static COUNTER: AtomicU64 = AtomicU64::new(0);
    let id = COUNTER.fetch_add(1, Ordering::Relaxed);
    let path = std::env::temp_dir().join(format!("rs_io_synth_{}_{id}.xrk", std::process::id()));
    std::fs::write(&path, bytes).expect("write synthetic .xrk");
    let session = decode_session(&path).expect("decode synthetic session");
    let _ = std::fs::remove_file(&path);
    session
}

/// A session with metadata, one analog channel (`RPM`), six moving GPS fixes at a
/// constant 10 m/s, and two laps — the general-purpose GPS export fixture.
///
/// GPS Speed is a constant 10 m/s (so every `GPS Speed` cell is `36.0000` km/h),
/// while latitude/longitude climb north-east (so a real heading is synthesized).
pub fn gps_session() -> Session {
    let mut file = Vec::new();
    // CNF defining one analog channel: RPM, unit rpm (15), i32 decoder (0),
    // size 4, 10 Hz (100 ms period).
    file.extend(frame(
        "CNF",
        &frame("CHS", &chs(0, "RPM", 15, 0, 4, 100_000)),
    ));
    file.extend(metadata_frames());
    for i in 0..6i32 {
        let tc = i * 100;
        file.extend(frame(
            "GPS",
            &gps_record(
                tc,
                35.0 + f64::from(i) * 0.001,
                139.0 + f64::from(i) * 0.001,
                100.0,
                (1000, 0, 0), // |v| = 1000 cm/s → 10 m/s
                200,          // 2.00 m position accuracy
                100,          // 1.00 m/s speed accuracy → 3.60 km/h
                140,          // pDOP 1.40
                3,
                8,
            ),
        ));
        file.extend(data_s(0, tc, &(3000 + i * 100).to_le_bytes()));
    }
    // Two laps: 60 s then 90 s → beacons 60 s, 150 s. Lap 1 ends at 60 s (so its
    // start — the recording origin — is 0), lap 2 ends at 150 s.
    file.extend(frame("LAP", &lap_marker(0, 1, 60_000, 60_000)));
    file.extend(frame("LAP", &lap_marker(0, 2, 90_000, 150_000)));
    decode_bytes(&file)
}

/// A session with metadata and one analog channel (`RPM`) but no GPS stream.
pub fn no_gps_session() -> Session {
    let mut file = Vec::new();
    file.extend(frame(
        "CNF",
        &frame("CHS", &chs(0, "RPM", 15, 0, 4, 100_000)),
    ));
    file.extend(metadata_frames());
    for i in 0..6i32 {
        file.extend(data_s(0, i * 100, &(3000 + i * 100).to_le_bytes()));
    }
    decode_bytes(&file)
}

/// A no-GPS session with a valid `RPM` channel plus a `MATH` channel whose
/// samples are all `NaN` (an f32 NaN), so its resampled cells are written empty.
pub fn nan_channel_session() -> Session {
    let mut cnf = frame("CHS", &chs(0, "RPM", 15, 0, 4, 100_000));
    // Channel 1: dimensionless f32 (decoder 6, unit_type 6), carrying NaN samples.
    cnf.extend(frame("CHS", &chs(1, "MATH", 6, 6, 4, 100_000)));
    let mut file = frame("CNF", &cnf);
    file.extend(metadata_frames());
    for i in 0..4i32 {
        file.extend(data_s(0, i * 100, &(3000 + i * 100).to_le_bytes()));
        file.extend(data_s(1, i * 100, &f32::NAN.to_le_bytes()));
    }
    decode_bytes(&file)
}

/// A session whose only channel definition carries no samples (dropped by the
/// decoder) and which has no GPS — i.e. a session with zero exportable channels.
pub fn empty_session() -> Session {
    let file = frame("CNF", &frame("CHS", &chs(0, "RPM", 15, 0, 4, 100_000)));
    decode_bytes(&file)
}

// --------------------------------------------------------------------------- //
// CSV parsing + fixture helpers (used by csv_export_test).
// --------------------------------------------------------------------------- //

/// Parse a `QUOTE_ALL` CSV into rows of unquoted fields, tolerating either CRLF
/// (this crate's output) or LF (the RaceStudio reference) line endings. A blank
/// separator row parses to an empty `Vec`; the trailing terminator is not a row.
pub fn parse_csv(text: &str) -> Vec<Vec<String>> {
    let mut lines: Vec<&str> = text
        .split('\n')
        .map(|line| line.strip_suffix('\r').unwrap_or(line))
        .collect();
    if lines.last() == Some(&"") {
        lines.pop(); // the terminator after the final row, not a blank row
    }
    lines.iter().map(|line| parse_row(line)).collect()
}

fn parse_row(line: &str) -> Vec<String> {
    if line.is_empty() {
        return Vec::new();
    }
    let bytes = line.as_bytes();
    let mut fields = Vec::new();
    let mut i = 0;
    while i < bytes.len() {
        assert_eq!(bytes[i], b'"', "QUOTE_ALL: every field opens with a quote");
        i += 1;
        let mut field = String::new();
        while i < bytes.len() {
            if bytes[i] == b'"' {
                if bytes.get(i + 1) == Some(&b'"') {
                    field.push('"');
                    i += 2;
                } else {
                    i += 1;
                    break;
                }
            } else {
                field.push(bytes[i] as char);
                i += 1;
            }
        }
        fields.push(field);
        if bytes.get(i) == Some(&b',') {
            i += 1;
        }
    }
    fields
}

/// The 0-based index of `name` in a header/names row, or a panic naming the miss.
pub fn column_index(names: &[String], name: &str) -> usize {
    names
        .iter()
        .position(|n| n == name)
        .unwrap_or_else(|| panic!("column {name:?} not found in {names:?}"))
}

/// The repo-root `fixtures/` directory.
pub fn fixtures_dir() -> std::path::PathBuf {
    std::path::PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .and_then(|core| core.parent())
        .expect("workspace root above core/racestudio-io")
        .join("fixtures")
}

/// Whether `path` begins with the `.xrk` header magic (`<h`) — a genuine sample,
/// not a placeholder / LFS pointer. Reads only the two magic bytes.
pub fn is_genuine_xrk(path: &std::path::Path) -> bool {
    use std::io::Read;
    let mut magic = [0u8; 2];
    std::fs::File::open(path)
        .and_then(|mut f| f.read_exact(&mut magic))
        .is_ok()
        && &magic == b"<h"
}

/// Equirectangular ground distance (metres) between two lat/long pairs (degrees)
/// — the approximation the acceptance criterion uses for the 1 m tolerance.
pub fn equirect_distance(lat1: f64, lon1: f64, lat2: f64, lon2: f64) -> f64 {
    let mean_lat = ((lat1 + lat2) / 2.0).to_radians();
    let dx = (lon2 - lon1).to_radians() * mean_lat.cos() * 6_371_000.0;
    let dy = (lat2 - lat1).to_radians() * 6_371_000.0;
    dx.hypot(dy)
}
