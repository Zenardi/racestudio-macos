//! Session-model tests (issue 1.6).
//!
//! `decode_session(path)` bundles the four decode layers — metadata (1.2),
//! channels (1.3), GPS (1.4), laps (1.5) — into one immutable [`Session`], via a
//! single consolidated [`DecodeError`]. These tests prove the bundle equals the
//! sum of the individual decoders, that every accessor returns the decoded
//! value, that `DecodeError` reports a human-readable message for each variant,
//! and — the safety contract — that no malformed / truncated / missing input
//! ever panics and that no `unwrap`/`expect`/`panic!` remains on the decode path.
//!
//! The per-layer decode logic is already covered by 1.2–1.5. Here the synthetic
//! fixtures are written to a temp file because `decode_session` takes a path; the
//! real `aim_official_test.xrk` sample is additionally cross-checked when present
//! (it is git-ignored — `make fixtures` fetches it — so its arm skips otherwise).

mod support;

use std::panic::catch_unwind;
use std::path::{Path, PathBuf};

use racestudio_decode::{
    decode_channels, decode_gps, decode_laps, decode_session, open_container, DecodeError, Session,
};
use support::fixtures::fixture_path;

const SAMPLE: &str = "aim_official_test.xrk";

/// Write `bytes` to a uniquely named file under the integration-test temp dir
/// and return its path.
fn write_fixture(name: &str, bytes: &[u8]) -> PathBuf {
    let path = Path::new(env!("CARGO_TARGET_TMPDIR")).join(name);
    std::fs::write(&path, bytes).expect("write synthetic fixture");
    path
}

/// A real `.xrk` sample path, or `None` (with a skip note) when the git-ignored
/// sample is absent or is not a genuine `.xrk` (placeholder / partial download).
fn xrk_or_skip(name: &str) -> Option<PathBuf> {
    let path = fixture_path(name);
    match std::fs::read(&path) {
        Ok(bytes) if bytes.starts_with(b"<h") => Some(path),
        _ => {
            eprintln!(
                "skipping: {} is not a real .xrk sample — run `make fixtures` to fetch it",
                path.display()
            );
            None
        }
    }
}

/// NaN-safe structural comparison: `Debug`-format both sides (float fields make
/// `PartialEq` non-reflexive, but `NaN` formats identically to `NaN`).
fn debug_str<T: std::fmt::Debug>(value: T) -> String {
    format!("{value:?}")
}

/// Assert `decode_session(path)` bundles exactly what the individual decoders
/// (1.2–1.5) produce for the same file — the core "equals the sum of parts".
fn assert_bundle_equals_parts(path: &Path) {
    let session = decode_session(path).expect("decode session");
    let container = open_container(path).expect("open container");

    assert_eq!(
        session.metadata(),
        container.metadata(),
        "metadata == open_container"
    );
    assert_eq!(
        debug_str(session.channels()),
        debug_str(&decode_channels(&container).expect("decode channels")[..]),
        "channels == decode_channels"
    );
    assert_eq!(
        debug_str(session.gps()),
        debug_str(decode_gps(&container).expect("decode gps").as_ref()),
        "gps == decode_gps"
    );
    assert_eq!(
        debug_str(session.laps()),
        debug_str(decode_laps(&container).expect("decode laps")),
        "laps == decode_laps"
    );
}

#[test]
fn test_decode_session_bundles_all_parts() {
    // Given a container carrying metadata + channels + GPS + laps, When decoded
    // as a session, Then every part is present (non-empty), decoded up front.
    let path = write_fixture("session_full.xrk", &synth::full_session());
    let session: Session = decode_session(&path).expect("decode session");

    assert!(
        !session.metadata().driver.is_empty(),
        "metadata is populated"
    );
    assert!(!session.channels().is_empty(), "channels are present");
    assert!(session.gps().is_some(), "GPS is present");
    assert!(!session.laps().is_empty(), "laps are present");
}

#[test]
fn test_session_equals_individual_decoders() {
    // The bundled Session equals the sum of the individual decoders — proven on a
    // synthetic container (always) and on the real sample (when fetched).
    let path = write_fixture("session_parts.xrk", &synth::full_session());
    assert_bundle_equals_parts(&path);

    if let Some(real) = xrk_or_skip(SAMPLE) {
        assert_bundle_equals_parts(&real);
    }
}

#[test]
fn test_session_accessors_return_expected() {
    // Each typed accessor returns exactly the decoded value for a known container.
    let path = write_fixture("session_accessors.xrk", &synth::full_session());
    let session = decode_session(&path).expect("decode session");

    let meta = session.metadata();
    assert_eq!(meta.driver, "SESSION DRIVER", "metadata().driver");
    assert_eq!(meta.vehicle, "CAR-7", "metadata().vehicle");
    assert_eq!(meta.track, "Test Circuit", "metadata().track");

    assert_eq!(session.channels().len(), 1, "channels().len()");
    assert_eq!(session.channels()[0].name(), "RPM", "channel name");
    assert_eq!(session.channels()[0].samples().len(), 2, "channel samples");

    let gps = session.gps().expect("gps().is_some()");
    assert_eq!(gps.len(), 2, "gps().len()");

    let laps = session.laps();
    assert_eq!(laps.len(), 2, "laps().len()");
    assert_eq!(laps.best_lap_index(), Some(1), "best lap is the faster one");
    let best = laps.best_lap().expect("a best lap");
    assert!((best.duration_s() - 55.0).abs() < 1e-9, "best lap duration");
}

#[test]
fn test_decode_error_display_messages() {
    // Every DecodeError variant renders a non-empty, human-readable message and
    // implements std::error::Error; only Io carries an underlying source.
    use std::error::Error;

    let io = DecodeError::from(std::io::Error::new(std::io::ErrorKind::NotFound, "gone"));
    assert!(io.to_string().contains("gone"), "Io wraps the OS message");
    assert!(io.source().is_some(), "Io exposes its source");

    let variants = [
        (DecodeError::BadMagic, "magic"),
        (DecodeError::TruncatedHeader, "header"),
        (DecodeError::TruncatedChannel, "channel"),
        (DecodeError::BadSampleCount, "count"),
        (DecodeError::UnknownUnit, "unit"),
        (DecodeError::TruncatedGps, "GPS"),
        (DecodeError::TruncatedLaps, "lap"),
    ];
    for (err, keyword) in variants {
        let message = err.to_string();
        assert!(!message.is_empty(), "{err:?} has a message");
        assert!(
            message.contains(keyword),
            "{err:?} message mentions {keyword:?}: {message}"
        );
        assert!(err.source().is_none(), "{err:?} has no source");
    }
}

#[test]
fn test_malformed_inputs_never_panic() {
    // A battery of malformed/truncated/valid-but-empty inputs: decode_session must
    // return a Result for every one — never unwind — regardless of Ok or Err.
    let cases: Vec<(&str, Vec<u8>)> = vec![
        ("empty", Vec::new()),
        ("one_byte", vec![b'<']),
        ("bad_magic", b"XX not an xrk".to_vec()),
        (
            "truncated_header",
            vec![0x3C, 0x68, b'T', b'M', b'T', 0x20, 0xFF, 0xFF, 0x00, 0x00],
        ),
        ("truncated_channel", synth::truncated_channel()),
        ("truncated_gps", synth::frame("GPS", &[0u8; 40])),
        ("truncated_laps", synth::frame("LAP", &[0u8; 8])),
        ("garbage_after_magic", synth::garbage_tail()),
        ("valid_but_empty", synth::frame("RCR", b"X\0")),
        ("full_ok", synth::full_session()),
    ];

    for (label, bytes) in cases {
        let path = write_fixture(&format!("panic_{label}.xrk"), &bytes);
        let outcome = catch_unwind(|| decode_session(&path));
        assert!(
            outcome.is_ok(),
            "decode_session panicked on malformed input: {label}"
        );
    }
}

#[test]
fn test_missing_file_maps_to_io_error() {
    // A nonexistent path maps to DecodeError::Io (never a panic), carrying the
    // underlying std::io::Error as its source.
    use std::error::Error;

    let missing = Path::new(env!("CARGO_TARGET_TMPDIR")).join("does_not_exist_1_6.xrk");
    let _ = std::fs::remove_file(&missing); // ensure absence
    let err = decode_session(&missing).expect_err("missing file must error");
    assert!(
        matches!(err, DecodeError::Io(_)),
        "expected Io, got {err:?}"
    );
    assert!(err.source().is_some(), "Io error exposes its source");
}

#[test]
fn test_no_unwrap_on_decode_path() {
    // Static guard complementing the clippy lint: no shipped (non-test) source in
    // the decode crate uses unwrap/expect/panic. Each module keeps its unit tests
    // in a trailing `#[cfg(test)]` block, which is excluded from the scan.
    let src = Path::new(env!("CARGO_MANIFEST_DIR")).join("src");
    let forbidden = [
        ".unwrap()",
        ".expect(",
        "panic!",
        "unreachable!",
        "todo!",
        "unimplemented!",
    ];

    let mut scanned = 0;
    for entry in std::fs::read_dir(&src).expect("read src dir") {
        let path = entry.expect("dir entry").path();
        if path.extension().and_then(|e| e.to_str()) != Some("rs") {
            continue;
        }
        let text = std::fs::read_to_string(&path).expect("read source file");
        let shipped = match text.find("#[cfg(test)]") {
            Some(idx) => &text[..idx],
            None => &text[..],
        };
        for needle in forbidden {
            assert!(
                !shipped.contains(needle),
                "{} contains `{}` on a shipped path",
                path.display(),
                needle
            );
        }
        scanned += 1;
    }
    assert!(
        scanned >= 6,
        "scanned the crate's source modules (got {scanned})"
    );
}

/// Minimal `.xrk` framing helpers for the synthetic fixtures.
mod synth {
    const MAGIC: [u8; 2] = [0x3C, 0x68];

    /// Build a framed header message (`<h … >`) with a correct checksum.
    pub fn frame(token: &str, payload: &[u8]) -> Vec<u8> {
        let mut tb = token.as_bytes().to_vec();
        while tb.len() < 4 {
            tb.push(0);
        }
        let tok = u32::from_le_bytes([tb[0], tb[1], tb[2], tb[3]]);
        let mut out = Vec::new();
        out.extend_from_slice(&MAGIC);
        out.extend_from_slice(&tok.to_le_bytes());
        out.extend_from_slice(&(payload.len() as i32).to_le_bytes());
        out.push(0); // version
        out.push(b'>');
        out.extend_from_slice(payload);
        out.push(b'<');
        out.extend_from_slice(&tok.to_le_bytes());
        let checksum = (payload.iter().map(|&b| u32::from(b)).sum::<u32>() & 0xFFFF) as u16;
        out.extend_from_slice(&checksum.to_le_bytes());
        out.push(b'>');
        out
    }

    /// A 112-byte CHS payload: index, unit type, decoder type, name, sample
    /// period (µs), and per-sample data size.
    fn chs(
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
        let n = name.as_bytes();
        p[32..32 + n.len()].copy_from_slice(n);
        p[64..68].copy_from_slice(&period_us.to_le_bytes());
        p[72] = data_size;
        p
    }

    /// A TRK payload whose 32-byte name field holds `name`.
    fn trk(name: &str) -> Vec<u8> {
        let mut p = vec![0u8; 44];
        let n = name.as_bytes();
        p[..n.len()].copy_from_slice(n);
        p
    }

    /// A `(S` single-sample data message: `(S` + timecode(4) + channel(2) + data.
    fn data_s(channel: u16, tc: i32, data: &[u8]) -> Vec<u8> {
        let mut m = vec![b'(', b'S'];
        m.extend_from_slice(&tc.to_le_bytes());
        m.extend_from_slice(&channel.to_le_bytes());
        m.extend_from_slice(data);
        m.push(b')');
        m
    }

    /// A 56-byte NAV-SOL record with finite ECEF (near the equator).
    fn gps_record(tc: i32, ex: i32, ey: i32, ez: i32, vy: i32, sats: u8, fix: u8) -> Vec<u8> {
        let mut p = vec![0u8; 56];
        p[0..4].copy_from_slice(&tc.to_le_bytes());
        p[14] = fix;
        p[16..20].copy_from_slice(&ex.to_le_bytes());
        p[20..24].copy_from_slice(&ey.to_le_bytes());
        p[24..28].copy_from_slice(&ez.to_le_bytes());
        p[28..32].copy_from_slice(&50u32.to_le_bytes()); // pAcc
        p[36..40].copy_from_slice(&vy.to_le_bytes()); // ecefVY
        p[44..48].copy_from_slice(&30u32.to_le_bytes()); // sAcc
        p[48..50].copy_from_slice(&150u16.to_le_bytes()); // pDOP
        p[51] = sats;
        p
    }

    /// A 32-byte LAP marker: segment, lap number, duration (ms).
    fn lap(segment: u8, number: u16, duration_ms: u32) -> Vec<u8> {
        let mut p = vec![0u8; 32];
        p[1] = segment;
        p[2..4].copy_from_slice(&number.to_le_bytes());
        p[4..8].copy_from_slice(&duration_ms.to_le_bytes());
        p
    }

    /// A complete synthetic session: one channel (2 samples), 2 GPS records, and
    /// two whole-lap markers, plus session metadata.
    pub fn full_session() -> Vec<u8> {
        let mut cnf = Vec::new();
        cnf.extend(frame("CHS", &chs(0, "RPM", 6, 0, 4, 100_000))); // number, i32, size 4, 10 Hz

        let mut file = frame("CNF", &cnf);
        file.extend(frame("RCR", b"SESSION DRIVER\0"));
        file.extend(frame("VEH", b"CAR-7\0"));
        file.extend(frame("TRK", &trk("Test Circuit")));
        file.extend(frame("TMD", b"07/15/2026\0"));
        file.extend(frame("TMT", b"14:30:00\0"));

        // GPS: two 56-byte NAV-SOL records with finite positions.
        let mut gps = gps_record(0, 637_813_700, 0, 0, 100, 9, 3);
        gps.extend(gps_record(100, 637_813_700, 1_000, 0, 100, 9, 3));
        file.extend(frame("GPS", &gps));

        // Channel 0 samples (i32, size 4) at increasing timecodes.
        file.extend(data_s(0, 0, &1i32.to_le_bytes()));
        file.extend(data_s(0, 100, &2i32.to_le_bytes()));

        // Two whole-lap (segment 0) markers → two laps (the second is faster).
        file.extend(frame("LAP", &lap(0, 1, 60_000)));
        file.extend(frame("LAP", &lap(0, 2, 55_000)));
        file
    }

    /// A container whose `(S` data message runs one byte short of its 4-byte
    /// sample at EOF → the channel decoder returns a truncation error.
    pub fn truncated_channel() -> Vec<u8> {
        let mut cnf = Vec::new();
        cnf.extend(frame("CHS", &chs(0, "RPM", 6, 0, 4, 100_000)));
        let mut file = frame("CNF", &cnf);
        file.extend_from_slice(&[b'(', b'S', 0, 0, 0, 0, 0, 0, 0x11]); // only 1 of 4 data bytes
        file
    }

    /// A valid header followed by an unparseable byte run (stops the walk).
    pub fn garbage_tail() -> Vec<u8> {
        let mut file = frame("RCR", b"BOB\0");
        file.extend_from_slice(&[0xEE, 0xEE, 0x01, 0x02]);
        file
    }
}
