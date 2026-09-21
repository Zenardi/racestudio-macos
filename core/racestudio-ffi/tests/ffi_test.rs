//! UniFFI decode-interface tests (issue 1.7).
//!
//! These exercise the FFI surface — `open_session`, the `SessionHandle` object,
//! and the windowed `samples` accessor — that Swift drives without copying whole
//! sessions across the boundary. Deterministic coverage comes from synthetic
//! `.xrk` files written to a temp dir; the real `aim_official_test.xrk` sample
//! (git-ignored, fetched by `make fixtures`) additionally cross-checks that the
//! windowed FFI values are exactly what `decode_session` produces — the
//! golden-validated source. Its arm skips cleanly when the sample is absent.

use std::path::{Path, PathBuf};

use racestudio_decode::decode_session;
use racestudio_ffi::{open_session, FfiDecodeError, Sample};

const SAMPLE: &str = "aim_official_test.xrk";

/// Write `bytes` to a uniquely named file under the integration-test temp dir.
fn write_fixture(name: &str, bytes: &[u8]) -> PathBuf {
    let path = Path::new(env!("CARGO_TARGET_TMPDIR")).join(name);
    std::fs::write(&path, bytes).expect("write synthetic fixture");
    path
}

/// The repo-root path of a fixture, or `None` (with a skip note) when the
/// git-ignored `.xrk` sample is absent or is not a genuine `.xrk`.
fn xrk_or_skip(name: &str) -> Option<PathBuf> {
    // CARGO_MANIFEST_DIR = <repo>/core/racestudio-ffi → up two to the repo root.
    let path = Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../../fixtures")
        .join(name);
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

#[test]
fn test_open_session_returns_handle() {
    // Given a valid .xrk path, When opened, Then a handle is returned whose
    // metadata and channel listing reflect the decoded session.
    let path = write_fixture("ffi_open.xrk", &synth::session_with_samples(6));
    let handle = open_session(path.to_string_lossy().into_owned()).expect("open session");

    assert_eq!(
        handle.metadata().driver,
        "SESSION DRIVER",
        "metadata driver"
    );
    let channels = handle.channels();
    assert_eq!(channels.len(), 1, "one channel");
    assert_eq!(channels[0].name, "RPM", "channel name");
    assert_eq!(channels[0].sample_count, 6, "sample count in listing");
}

#[test]
fn test_open_bad_path_maps_decode_error() {
    // A missing path maps to Io; a bad-magic file maps to BadMagic — never a
    // panic/trap across the boundary.
    let missing = Path::new(env!("CARGO_TARGET_TMPDIR")).join("ffi_absent.xrk");
    let _ = std::fs::remove_file(&missing);
    let err = open_session(missing.to_string_lossy().into_owned()).expect_err("missing errors");
    assert!(
        matches!(err, FfiDecodeError::Io { .. }),
        "missing → Io, got {err:?}"
    );

    let bad = write_fixture("ffi_bad_magic.xrk", b"XX not an xrk file");
    let err = open_session(bad.to_string_lossy().into_owned()).expect_err("bad magic errors");
    assert!(
        matches!(err, FfiDecodeError::BadMagic),
        "bad magic → BadMagic, got {err:?}"
    );
}

#[test]
fn test_channels_listing_has_no_bulk_samples() {
    // The channel listing carries only metadata (name/unit/rate/decimals/count):
    // the count is reported without copying the samples, which are fetched
    // separately by `samples(...)`. The listing count equals a full windowed pull.
    let path = write_fixture("ffi_listing.xrk", &synth::session_with_samples(6));
    let handle = open_session(path.to_string_lossy().into_owned()).expect("open session");

    let info = &handle.channels()[0];
    assert_eq!(info.sample_count, 6, "listing reports the count");
    assert_eq!(info.unit, "", "unit");
    assert!((info.sample_rate_hz - 10.0).abs() < 1e-9, "sample rate");

    // The metadata count matches the number of samples the window accessor yields.
    let full = handle
        .samples(0, 0, info.sample_count)
        .expect("full window");
    assert_eq!(
        full.len() as u32,
        info.sample_count,
        "count == windowed pull"
    );
}

#[test]
fn test_window_returns_requested_slice() {
    // `samples(channel, start, count)` returns exactly the requested window.
    let path = write_fixture("ffi_window.xrk", &synth::session_with_samples(6));
    let handle = open_session(path.to_string_lossy().into_owned()).expect("open session");

    let full = handle.samples(0, 0, 6).expect("full");
    assert_eq!(full.len(), 6, "all six samples");

    let window = handle.samples(0, 1, 2).expect("window [1,3)");
    assert_eq!(window.len(), 2, "two samples");
    assert_eq!(
        sample_pair(window[0]),
        sample_pair(full[1]),
        "window[0] == full[1]"
    );
    assert_eq!(
        sample_pair(window[1]),
        sample_pair(full[2]),
        "window[1] == full[2]"
    );
}

#[test]
fn test_window_out_of_range_is_bounded() {
    // Out-of-range start/count clamp (never over-read); an out-of-range channel
    // index returns a typed error.
    let path = write_fixture("ffi_bounds.xrk", &synth::session_with_samples(6));
    let handle = open_session(path.to_string_lossy().into_owned()).expect("open session");

    // count overruns the end → clamped to what remains.
    let tail = handle.samples(0, 5, 100).expect("clamped tail");
    assert_eq!(tail.len(), 1, "only the last sample remains");

    // start past the end → empty, not an over-read.
    let past = handle.samples(0, 100, 10).expect("past end");
    assert!(past.is_empty(), "nothing past the end");

    // zero count → empty.
    let none = handle.samples(0, 0, 0).expect("zero count");
    assert!(none.is_empty(), "zero count yields nothing");

    // channel index out of range → typed error, never a panic.
    let err = handle.samples(99, 0, 1).expect_err("bad channel index");
    assert!(
        matches!(
            err,
            FfiDecodeError::ChannelOutOfRange {
                index: 99,
                channel_count: 1
            }
        ),
        "channel out of range, got {err:?}"
    );
}

#[test]
fn test_adjacent_windows_stitch_to_golden() {
    // Two adjacent windows stitch to a single wider window — and, on the real
    // sample, to exactly the values `decode_session` produces (the golden source).
    // Proves no whole-session copy is required to read channel data.
    let path = write_fixture("ffi_stitch.xrk", &synth::session_with_samples(6));
    let handle = open_session(path.to_string_lossy().into_owned()).expect("open session");
    let a = handle.samples(0, 0, 2).expect("window a");
    let b = handle.samples(0, 2, 2).expect("window b");
    let stitched: Vec<_> = a.iter().chain(b.iter()).map(|&s| sample_pair(s)).collect();
    let wide: Vec<_> = handle
        .samples(0, 0, 4)
        .expect("wide")
        .iter()
        .map(|&s| sample_pair(s))
        .collect();
    assert_eq!(stitched, wide, "adjacent windows stitch to the wide window");

    let Some(real) = xrk_or_skip(SAMPLE) else {
        return;
    };
    let handle = open_session(real.to_string_lossy().into_owned()).expect("open real session");
    let session = decode_session(&real).expect("decode real session");
    let channel = &session.channels()[0];
    let golden: Vec<(f64, f64)> = channel.samples().iter().take(64).copied().collect();
    assert!(golden.len() >= 4, "enough samples to window");

    let half = golden.len() / 2;
    let a = handle.samples(0, 0, half as u32).expect("real window a");
    let b = handle
        .samples(0, half as u32, (golden.len() - half) as u32)
        .expect("real window b");
    let stitched: Vec<(f64, f64)> = a.iter().chain(b.iter()).map(|&s| sample_pair(s)).collect();
    assert_eq!(
        stitched, golden,
        "FFI windows stitch to the decoded (golden) samples"
    );
}

#[test]
fn test_gps_and_laps_summaries() {
    // The GPS summary and lap listing reflect the decoded session; a session
    // without GPS reports no summary.
    let path = write_fixture("ffi_summaries.xrk", &synth::session_with_samples(6));
    let handle = open_session(path.to_string_lossy().into_owned()).expect("open session");

    let gps = handle.gps_summary().expect("gps present");
    assert_eq!(gps.fix_count, 2, "two GPS fixes");
    assert!(gps.channel_count > 0, "gps channels present");

    let laps = handle.laps();
    assert_eq!(laps.len(), 2, "two laps");
    assert!(
        laps[1].duration_s < laps[0].duration_s,
        "second lap is faster"
    );

    // A session with no GPS reports no summary.
    let no_gps = write_fixture("ffi_no_gps.xrk", &synth::frame("RCR", b"NOBODY\0"));
    let handle = open_session(no_gps.to_string_lossy().into_owned()).expect("open header-only");
    assert!(handle.gps_summary().is_none(), "no GPS → no summary");
    assert!(handle.laps().is_empty(), "no laps");
    assert!(handle.channels().is_empty(), "no channels");
}

/// Compare `Sample`s by value (the type is not `PartialEq` across the boundary).
fn sample_pair(s: Sample) -> (f64, f64) {
    (s.timecode, s.value)
}

/// Minimal `.xrk` framing helpers for the synthetic fixtures (mirrors the decode
/// crate's test synth, kept local so the FFI crate has no test-only dependency).
mod synth {
    const MAGIC: [u8; 2] = [0x3C, 0x68];

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

    fn data_s(channel: u16, tc: i32, data: &[u8]) -> Vec<u8> {
        let mut m = vec![b'(', b'S'];
        m.extend_from_slice(&tc.to_le_bytes());
        m.extend_from_slice(&channel.to_le_bytes());
        m.extend_from_slice(data);
        m.push(b')');
        m
    }

    fn gps_record(tc: i32, ex: i32, ey: i32, vy: i32) -> Vec<u8> {
        let mut p = vec![0u8; 56];
        p[0..4].copy_from_slice(&tc.to_le_bytes());
        p[14] = 3; // 3D fix
        p[16..20].copy_from_slice(&ex.to_le_bytes());
        p[20..24].copy_from_slice(&ey.to_le_bytes());
        p[36..40].copy_from_slice(&vy.to_le_bytes());
        p[28..32].copy_from_slice(&50u32.to_le_bytes());
        p[44..48].copy_from_slice(&30u32.to_le_bytes());
        p[48..50].copy_from_slice(&150u16.to_le_bytes());
        p[51] = 9; // satellites
        p
    }

    fn lap(segment: u8, number: u16, duration_ms: u32) -> Vec<u8> {
        let mut p = vec![0u8; 32];
        p[1] = segment;
        p[2..4].copy_from_slice(&number.to_le_bytes());
        p[4..8].copy_from_slice(&duration_ms.to_le_bytes());
        p
    }

    /// A synthetic session whose single `RPM` channel carries `n` samples, plus
    /// metadata, two GPS records, and two whole-lap markers.
    pub fn session_with_samples(n: u32) -> Vec<u8> {
        let mut cnf = Vec::new();
        cnf.extend(frame("CHS", &chs(0, "RPM", 6, 0, 4, 100_000))); // number, i32, size 4, 10 Hz
        let mut file = frame("CNF", &cnf);
        file.extend(frame("RCR", b"SESSION DRIVER\0"));
        file.extend(frame("VEH", b"CAR-7\0"));

        let mut gps = gps_record(0, 637_813_700, 0, 100);
        gps.extend(gps_record(100, 637_813_700, 1_000, 100));
        file.extend(frame("GPS", &gps));

        for i in 0..n {
            let tc = (i as i32) * 10;
            let value = ((i + 1) * 10) as i32;
            file.extend(data_s(0, tc, &value.to_le_bytes()));
        }

        file.extend(frame("LAP", &lap(0, 1, 60_000)));
        file.extend(frame("LAP", &lap(0, 2, 55_000)));
        file
    }
}

// ---------------------------------------------------------------------------
// CSV import through `open_session` (user request: "allow imports from xrk and csv")
// ---------------------------------------------------------------------------

/// Write `body` to a uniquely named file under the temp dir and return its path.
///
/// The crate carries no dev-dependencies on purpose (see Cargo.toml), so this
/// stands in for `tempfile`.
fn write_temp(name: &str, body: &str) -> std::path::PathBuf {
    let path = std::env::temp_dir().join(format!(
        "rs-ffi-{}-{}-{name}",
        std::process::id(),
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_nanos())
            .unwrap_or(0)
    ));
    std::fs::write(&path, body).expect("write temp csv");
    path
}

/// An AiM "AiM CSV File" export: header block, name row, unit row, data rows.
/// Mirrors the layout RaceStudio 3 writes (and the samples in the user's corpus).
const AIM_CSV: &str = concat!(
    "\"Format\",\"AiM CSV File\"\n",
    "\"Session\",\"S.MarinoK\"\n",
    "\"Vehicle\",\"Kart 7\"\n",
    "\"Racer\",\"E. Zenardi\"\n",
    "\"Championship\",\"\"\n",
    "\"Comment\",\"\"\n",
    "\"Date\",\"09/19/2026\"\n",
    "\"Time\",\"09:37:10\"\n",
    "\"Sample Rate\",\"20\"\n",
    "\"Duration\",\"3.0\"\n",
    "\"Segment\",\"Session\"\n",
    "\"Beacon Markers\",\"1.0\",\"2.0\"\n",
    "\"Segment Times\",\"0:01.000\",\"0:01.000\"\n",
    "\n",
    "\"Time\",\"GPS Speed\",\"RPM\"\n",
    "\"s\",\"km/h\",\"rpm\"\n",
    "\n",
    "\"0.0\",\"36.0\",\"1000\"\n",
    "\"1.0\",\"72.0\",\"2000\"\n",
    "\"2.0\",\"108.0\",\"3000\"\n",
    "\"3.0\",\"144.0\",\"4000\"\n",
);

#[test]
fn test_open_session_imports_an_aim_csv() {
    // Given an AiM CSV, When opened through the same entry point the app uses for
    // .xrk, Then it decodes into a usable session (metadata + channels).
    let path = write_temp("aim.csv", AIM_CSV);
    let handle = open_session(path.to_string_lossy().into_owned()).expect("import AiM csv");
    let _ = std::fs::remove_file(&path);

    assert_eq!(handle.metadata().track, "S.MarinoK");
    assert_eq!(handle.metadata().vehicle, "Kart 7");
    assert_eq!(handle.metadata().driver, "E. Zenardi");
    let names: Vec<String> = handle.channels().iter().map(|c| c.name.clone()).collect();
    assert!(
        names.iter().any(|n| n == "RPM"),
        "expected an RPM channel, got {names:?}"
    );
}

#[test]
fn test_open_session_recovers_laps_from_csv_beacon_markers() {
    // Given `Beacon Markers`, Then laps are reconstructed — the CSV path must not
    // silently import a lapless session.
    let path = write_temp("laps.csv", AIM_CSV);
    let handle = open_session(path.to_string_lossy().into_owned()).expect("import AiM csv");
    let _ = std::fs::remove_file(&path);

    assert!(
        !handle.laps().is_empty(),
        "Beacon Markers must yield laps on the CSV import path"
    );
}

#[test]
fn test_open_session_csv_extension_is_case_insensitive() {
    // Given `.CSV`, Then it still imports — Finder happily hands over uppercase.
    let path = write_temp("upper.CSV", AIM_CSV);
    let result = open_session(path.to_string_lossy().into_owned());
    let _ = std::fs::remove_file(&path);

    assert!(result.is_ok(), "uppercase .CSV must import: {result:?}");
}

#[test]
fn test_open_session_maps_a_malformed_csv_to_a_typed_error() {
    // Given an unparseable CSV, Then the boundary returns a typed error rather
    // than panicking or masquerading as an .xrk decode failure.
    let path = write_temp("bad.csv", "\"Time\",\"A\"\n\"0.0\",\"1.0\",\"2.0\"\n");
    let result = open_session(path.to_string_lossy().into_owned());
    let _ = std::fs::remove_file(&path);

    assert!(result.is_err(), "a ragged CSV must not import");
}

#[test]
fn test_open_session_still_rejects_a_non_csv_non_xrk_file() {
    // Given a .xrk path holding junk, Then the .xrk decoder still reports BadMagic
    // — adding CSV support must not weaken the .xrk contract.
    let path = write_temp("junk.xrk", "not a telemetry file at all");
    let result = open_session(path.to_string_lossy().into_owned());
    let _ = std::fs::remove_file(&path);

    assert!(matches!(result, Err(FfiDecodeError::BadMagic)), "got {result:?}");
}

#[test]
fn test_open_session_maps_an_unreadable_csv_to_an_io_error() {
    // Given a .csv path that does not exist, Then the failure is reported as I/O
    // -- distinct from a parse failure, so the UI can tell "gone" from "corrupt".
    let missing = std::env::temp_dir().join("rs-ffi-definitely-absent.csv");
    let _ = std::fs::remove_file(&missing);

    let result = open_session(missing.to_string_lossy().into_owned());

    assert!(
        matches!(result, Err(FfiDecodeError::Io { .. })),
        "got {result:?}"
    );
}
