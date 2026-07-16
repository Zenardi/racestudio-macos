//! UniFFI analysis-interface tests (issue 3.8).
//!
//! These exercise the windowed analysis accessors — `list_laps`,
//! `delta_t_series`, `channel_stats`, `eval_math_channel`, `fft_spectrum` — that
//! Swift drives across the boundary. Deterministic coverage comes from a
//! synthetic `.xrk` (a single `RPM` channel + two laps); the real
//! `aim_official_test.xrk` sample additionally cross-checks the FFI values
//! against `racestudio-analysis` directly and against the committed goldens.
//! Real-sample arms skip cleanly when the git-ignored sample is absent.

use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU32, Ordering};
use std::sync::Arc;

use racestudio_analysis::{delta_t, segment_laps, spectrum, stats_over_range, Window as FftWindow};
use racestudio_decode::decode_session;
use racestudio_ffi::{open_session, AnalysisError, FfiWindow, SessionHandle, SpectrumWindow};

const SAMPLE: &str = "aim_official_test.xrk";

fn win(start: f64, end: f64) -> FfiWindow {
    FfiWindow { start, end }
}

/// The whole real-numbers window, for "everything" queries.
fn all() -> FfiWindow {
    win(f64::NEG_INFINITY, f64::INFINITY)
}

fn write_fixture(name: &str, bytes: &[u8]) -> PathBuf {
    let path = Path::new(env!("CARGO_TARGET_TMPDIR")).join(name);
    std::fs::write(&path, bytes).expect("write synthetic fixture");
    path
}

/// A synthetic session with an `RPM` channel of `n` samples (tc `i·10` ms, value
/// `(i+1)·10`) and two laps — returned as both the opened handle and its path so
/// tests can cross-check against a direct decode.
fn synth_session(n: u32) -> (Arc<SessionHandle>, PathBuf) {
    // A process-unique filename so parallel tests never race on the same file.
    static COUNTER: AtomicU32 = AtomicU32::new(0);
    let id = COUNTER.fetch_add(1, Ordering::Relaxed);
    let path = write_fixture(
        &format!("analysis_ffi_{id}.xrk"),
        &synth::session_with_samples(n),
    );
    let handle = open_session(path.to_string_lossy().into_owned()).expect("open synth session");
    (handle, path)
}

fn xrk_or_skip() -> Option<PathBuf> {
    let path = Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../../fixtures")
        .join(SAMPLE);
    match std::fs::read(&path) {
        Ok(bytes) if bytes.starts_with(b"<h") => Some(path),
        _ => {
            eprintln!("skipping: {} absent — run `make fixtures`", path.display());
            None
        }
    }
}

// --------------------------------------------------------------------------- //
// list_laps
// --------------------------------------------------------------------------- //

#[test]
fn test_list_laps_ffi_matches_rust() {
    let (handle, _) = synth_session(8);
    let laps = handle.list_laps(all()).expect("list laps");
    assert_eq!(laps.len(), 2, "two laps");
    assert!(laps[1].duration_s < laps[0].duration_s, "second lap faster");

    // A window intersecting only the first lap returns just it.
    let first = &laps[0];
    let only_first = handle
        .list_laps(win(first.start_time_s, first.end_time_s - 0.001))
        .expect("windowed laps");
    assert_eq!(only_first.len(), 1, "window selects the first lap only");
    assert_eq!(only_first[0].index, 0);

    // On the real sample the listing equals a direct decode's laps.
    let Some(path) = xrk_or_skip() else { return };
    let handle = open_session(path.to_string_lossy().into_owned()).expect("open real");
    let session = decode_session(&path).expect("decode");
    let ffi = handle.list_laps(all()).expect("ffi laps");
    let direct = session.laps().laps();
    assert_eq!(ffi.len(), direct.len(), "same lap count");
    for (a, b) in ffi.iter().zip(direct) {
        assert_eq!(a.index, b.index());
        assert!((a.start_time_s - b.start_time_s()).abs() < 1e-9);
        assert!((a.duration_s - b.duration_s()).abs() < 1e-9);
    }
}

// --------------------------------------------------------------------------- //
// channel_stats
// --------------------------------------------------------------------------- //

#[test]
fn test_channel_stats_over_window() {
    let (handle, path) = synth_session(64);
    let session = decode_session(&path).expect("decode");
    let rpm = session
        .channels()
        .iter()
        .find(|c| c.name() == "RPM")
        .expect("rpm channel");

    // Full window matches stats_over_range computed directly.
    let ffi = handle.channel_stats("RPM".into(), all()).expect("stats");
    let direct = stats_over_range(rpm.samples(), f64::NEG_INFINITY, f64::INFINITY).expect("direct");
    assert_eq!(ffi.count, 64);
    assert!((ffi.mean - direct.mean()).abs() < 1e-12);
    assert!((ffi.min - direct.min()).abs() < 1e-12);
    assert!((ffi.max - direct.max()).abs() < 1e-12);
    assert!((ffi.std_pop - direct.std_pop()).abs() < 1e-12);
    assert!((ffi.range - direct.range()).abs() < 1e-12);

    // A sub-window (timecodes [100, 300)) matches the same range directly.
    let ffi = handle
        .channel_stats("RPM".into(), win(100.0, 300.0))
        .expect("sub");
    let direct = stats_over_range(rpm.samples(), 100.0, 300.0).expect("direct sub");
    assert_eq!(ffi.count as usize, direct.count());
    assert!((ffi.mean - direct.mean()).abs() < 1e-12);
}

#[test]
fn test_missing_channel_throws_typed_error() {
    let (handle, _) = synth_session(8);
    let err = handle
        .channel_stats("NoSuchChannel".into(), all())
        .expect_err("missing channel");
    assert!(
        matches!(err, AnalysisError::MissingChannel { ref name } if name == "NoSuchChannel"),
        "got {err:?}"
    );
}

// --------------------------------------------------------------------------- //
// eval_math_channel
// --------------------------------------------------------------------------- //

#[test]
fn test_eval_math_channel_ffi() {
    let (handle, path) = synth_session(64);
    let session = decode_session(&path).expect("decode");
    let rpm: Vec<(f64, f64)> = session
        .channels()
        .iter()
        .find(|c| c.name() == "RPM")
        .expect("rpm")
        .samples()
        .to_vec();

    // `2 * RPM + 1` evaluated over the full window equals 2·value+1 per sample.
    let out = handle
        .eval_math_channel("2 * RPM + 1".into(), all())
        .expect("eval");
    assert_eq!(out.len(), rpm.len());
    for (sample, &(t, v)) in out.iter().zip(&rpm) {
        assert!((sample.timecode - t).abs() < 1e-9, "timecode preserved");
        assert!(
            (sample.value - (2.0 * v + 1.0)).abs() < 1e-9,
            "value = 2·RPM+1"
        );
    }

    // A constant expression has no timebase → no samples.
    assert!(handle
        .eval_math_channel("2 + 3".into(), all())
        .expect("const")
        .is_empty());
}

#[test]
fn test_invalid_expr_throws_typed_error() {
    let (handle, _) = synth_session(8);
    for bad in ["2 +", "sqrt(", "@bad", "min(1)"] {
        let err = handle
            .eval_math_channel(bad.into(), all())
            .expect_err("invalid expr");
        assert!(
            matches!(err, AnalysisError::InvalidExpression { .. }),
            "`{bad}` → {err:?}"
        );
    }

    // An expression referencing an unknown channel is a missing-channel error.
    let err = handle
        .eval_math_channel("Nonexistent * 2".into(), all())
        .expect_err("unknown channel");
    assert!(
        matches!(err, AnalysisError::MissingChannel { .. }),
        "got {err:?}"
    );
}

// --------------------------------------------------------------------------- //
// fft_spectrum
// --------------------------------------------------------------------------- //

#[test]
fn test_fft_spectrum_matches_direct_pipeline() {
    let (handle, path) = synth_session(128);
    let session = decode_session(&path).expect("decode");
    let rpm: Vec<(f64, f64)> = session
        .channels()
        .iter()
        .find(|c| c.name() == "RPM")
        .expect("rpm")
        .samples()
        .to_vec();

    let ffi = handle
        .fft_spectrum("RPM".into(), SpectrumWindow::Hann, all())
        .expect("fft");

    // Reproduce the accessor's pipeline directly: average rate → resample on a
    // seconds timebase → window+transform (issues 3.3/3.7).
    let fs = 1000.0 * (rpm.len() as f64 - 1.0) / (rpm.last().unwrap().0 - rpm.first().unwrap().0);
    let in_seconds: Vec<(f64, f64)> = rpm.iter().map(|&(t, v)| (t / 1000.0, v)).collect();
    let uniform = racestudio_analysis::resample_uniform(&in_seconds, fs);
    let values: Vec<f64> = uniform.iter().map(|&(_, v)| v).collect();
    let direct = spectrum(&values, fs, FftWindow::Hann).expect("direct spectrum");

    assert_eq!(ffi.freqs.len(), direct.freqs().len());
    assert_eq!(ffi.freqs[0], 0.0, "DC bin");
    for (got, want) in ffi.freqs.iter().zip(direct.freqs()) {
        assert!((got - want).abs() < 1e-9);
    }
    for (got, want) in ffi.amps.iter().zip(direct.amps()) {
        assert!((got - want).abs() < 1e-9);
    }
}

#[test]
fn test_fft_spectrum_ffi_matches_golden() {
    let Some(path) = xrk_or_skip() else { return };
    let golden: FftGolden = load_fft_golden().expect("fft golden");
    let handle = open_session(path.to_string_lossy().into_owned()).expect("open real");

    let spec = handle
        .fft_spectrum(
            golden.channel.clone(),
            golden.window(),
            win(golden.start, golden.end),
        )
        .expect("fft spectrum");

    assert_eq!(spec.freqs.len(), golden.freqs.len(), "bin count");
    for (got, want) in spec.freqs.iter().zip(&golden.freqs) {
        assert!((got - want).abs() < 1e-6, "freq {got} vs {want}");
    }
    for (got, want) in spec.amps.iter().zip(&golden.amps) {
        assert!((got - want).abs() < 1e-6, "amp {got} vs {want}");
    }
}

// --------------------------------------------------------------------------- //
// delta_t_series
// --------------------------------------------------------------------------- //

#[test]
fn test_delta_t_series_windowed_accessor() {
    let Some(path) = xrk_or_skip() else { return };
    let handle = open_session(path.to_string_lossy().into_owned()).expect("open real");
    let session = decode_session(&path).expect("decode");
    let laps = segment_laps(&session);
    let (reference, comparison) = (1u32, 8u32);

    // The FFI series matches delta_t computed directly (full window).
    let ffi = handle
        .delta_t_series(reference, comparison, all())
        .expect("ffi delta");
    let direct = delta_t(&laps[reference as usize], &laps[comparison as usize]).expect("direct");
    assert_eq!(ffi.len(), direct.len(), "same point count");
    for (point, &(distance, dt)) in ffi.iter().zip(&direct) {
        assert!((point.distance - distance).abs() < 1e-9);
        assert!((point.dt - dt).abs() < 1e-9);
    }

    // A distance window returns only the points inside it.
    let mid = direct[direct.len() / 2].0;
    let windowed = handle
        .delta_t_series(reference, comparison, win(0.0, mid))
        .expect("windowed delta");
    assert!(windowed.len() < ffi.len(), "window trims the series");
    assert!(
        windowed.iter().all(|p| p.distance <= mid),
        "all within window"
    );

    // An out-of-range lap index is a typed error.
    let err = handle
        .delta_t_series(9_999, comparison, all())
        .expect_err("bad lap index");
    assert!(
        matches!(err, AnalysisError::LapOutOfRange { index: 9_999, .. }),
        "got {err:?}"
    );
}

// --------------------------------------------------------------------------- //
// Window validation
// --------------------------------------------------------------------------- //

#[test]
fn test_window_out_of_bounds_throws() {
    let (handle, _) = synth_session(8);
    // An inverted window (start > end) throws across every windowed accessor.
    let inverted = win(500.0, 100.0);
    assert!(matches!(
        handle
            .channel_stats("RPM".into(), inverted)
            .expect_err("stats"),
        AnalysisError::WindowOutOfBounds { .. }
    ));
    assert!(matches!(
        handle.list_laps(inverted).expect_err("laps"),
        AnalysisError::WindowOutOfBounds { .. }
    ));
    assert!(matches!(
        handle
            .eval_math_channel("RPM".into(), inverted)
            .expect_err("eval"),
        AnalysisError::WindowOutOfBounds { .. }
    ));
    assert!(matches!(
        handle
            .fft_spectrum("RPM".into(), SpectrumWindow::Hann, inverted)
            .expect_err("fft"),
        AnalysisError::WindowOutOfBounds { .. }
    ));

    // A NaN bound is also rejected.
    assert!(matches!(
        handle
            .channel_stats("RPM".into(), win(f64::NAN, 1.0))
            .expect_err("nan"),
        AnalysisError::WindowOutOfBounds { .. }
    ));
}

#[test]
fn test_empty_window_stats_is_typed_error() {
    let (handle, _) = synth_session(8);
    // A valid window that selects nothing → EmptyRange.
    let err = handle
        .channel_stats("RPM".into(), win(1e9, 1e10))
        .expect_err("empty window");
    assert!(matches!(err, AnalysisError::EmptyRange), "got {err:?}");
}

#[test]
fn test_fft_and_eval_degenerate_windows() {
    let (handle, _) = synth_session(16);

    // A window selecting nothing → fft EmptyRange; eval yields no samples.
    assert!(matches!(
        handle
            .fft_spectrum("RPM".into(), SpectrumWindow::Hann, win(1e9, 1e10))
            .expect_err("empty fft"),
        AnalysisError::EmptyRange
    ));
    assert!(handle
        .eval_math_channel("2 * RPM".into(), win(1e9, 1e10))
        .expect("empty eval")
        .is_empty());

    // A window selecting a single sample (zero span) → fft EmptyRange.
    assert!(matches!(
        handle
            .fft_spectrum("RPM".into(), SpectrumWindow::Hann, win(0.0, 5.0))
            .expect_err("single-sample fft"),
        AnalysisError::EmptyRange
    ));
}

#[test]
fn test_fft_all_window_functions() {
    let (handle, _) = synth_session(64);
    for window_fn in [
        SpectrumWindow::Rectangular,
        SpectrumWindow::Hann,
        SpectrumWindow::Hamming,
        SpectrumWindow::Blackman,
    ] {
        let spec = handle
            .fft_spectrum("RPM".into(), window_fn, all())
            .expect("fft");
        assert_eq!(spec.freqs.len(), spec.amps.len());
        assert!(spec.freqs.len() > 1);
        assert_eq!(spec.freqs[0], 0.0);
    }
}

#[test]
fn test_analysis_error_display_and_mapping() {
    use racestudio_analysis::AnalysisError as Core;

    // Every core analysis error maps to its FFI counterpart.
    assert!(matches!(
        AnalysisError::from(Core::MissingChannel { name: "x".into() }),
        AnalysisError::MissingChannel { .. }
    ));
    assert!(matches!(
        AnalysisError::from(Core::EmptyLap),
        AnalysisError::EmptyLap
    ));
    assert!(matches!(
        AnalysisError::from(Core::DistanceNotMonotonic),
        AnalysisError::DistanceNotMonotonic
    ));
    assert!(matches!(
        AnalysisError::from(Core::EmptyRange),
        AnalysisError::EmptyRange
    ));

    // Every FFI variant renders a non-empty message (the Swift error text).
    let variants = [
        AnalysisError::MissingChannel { name: "RPM".into() },
        AnalysisError::EmptyLap,
        AnalysisError::DistanceNotMonotonic,
        AnalysisError::EmptyRange,
        AnalysisError::InvalidExpression {
            message: "bad".into(),
        },
        AnalysisError::LapOutOfRange { index: 3, count: 2 },
        AnalysisError::WindowOutOfBounds {
            start: 5.0,
            end: 1.0,
        },
    ];
    for err in &variants {
        assert!(!err.to_string().is_empty(), "{err:?} has a message");
    }
    assert!(AnalysisError::MissingChannel { name: "RPM".into() }
        .to_string()
        .contains("RPM"));
    assert!(AnalysisError::LapOutOfRange { index: 3, count: 2 }
        .to_string()
        .contains("out of range"));
}

// --------------------------------------------------------------------------- //
// FFT golden loader + generator
// --------------------------------------------------------------------------- //

struct FftGolden {
    channel: String,
    start: f64,
    end: f64,
    window: String,
    freqs: Vec<f64>,
    amps: Vec<f64>,
}

impl FftGolden {
    fn window(&self) -> SpectrumWindow {
        match self.window.as_str() {
            "rectangular" => SpectrumWindow::Rectangular,
            "hamming" => SpectrumWindow::Hamming,
            "blackman" => SpectrumWindow::Blackman,
            _ => SpectrumWindow::Hann,
        }
    }
}

fn fft_golden_path() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../../fixtures/golden")
        .join("aim_official_test.fft.json")
}

/// A tiny hand-rolled JSON reader for the fft golden (avoids a serde_json dev-dep
/// in the FFI crate): the file is generated by `generate_fft_golden` below.
fn load_fft_golden() -> Option<FftGolden> {
    let text = std::fs::read_to_string(fft_golden_path()).ok()?;
    let str_field = |key: &str| {
        let at = text.find(&format!("\"{key}\""))?;
        let colon = text[at..].find(':')? + at;
        let q1 = text[colon..].find('"')? + colon + 1;
        let q2 = text[q1..].find('"')? + q1;
        Some(text[q1..q2].to_string())
    };
    let num_field = |key: &str| -> Option<f64> {
        let at = text.find(&format!("\"{key}\""))?;
        let colon = text[at..].find(':')? + at + 1;
        let rest = text[colon..].trim_start();
        let end = rest.find([',', '}', '\n']).unwrap_or(rest.len());
        rest[..end].trim().parse().ok()
    };
    let array = |key: &str| -> Option<Vec<f64>> {
        let at = text.find(&format!("\"{key}\""))?;
        let lb = text[at..].find('[')? + at + 1;
        let rb = text[lb..].find(']')? + lb;
        Some(
            text[lb..rb]
                .split(',')
                .filter_map(|s| s.trim().parse().ok())
                .collect(),
        )
    };
    Some(FftGolden {
        channel: str_field("channel")?,
        start: num_field("start")?,
        end: num_field("end")?,
        window: str_field("window")?,
        freqs: array("freqs")?,
        amps: array("amps")?,
    })
}

/// Regenerate `fixtures/golden/aim_official_test.fft.json` from the FFI on the
/// real sample. Not part of the normal run:
/// `cargo test -p racestudio-ffi --test analysis_ffi_test -- --ignored generate_fft_golden`
#[test]
#[ignore = "regenerates the fft golden; run with --ignored"]
fn generate_fft_golden() {
    let path = xrk_or_skip().expect("fixture required to regenerate the golden");
    let handle = open_session(path.to_string_lossy().into_owned()).expect("open");
    let (channel, start, end, window) = ("RPM", 0.0, 5000.0, "hann");
    let spec = handle
        .fft_spectrum(channel.into(), SpectrumWindow::Hann, win(start, end))
        .expect("spectrum");

    let round = |x: f64| (x * 1e6).round() / 1e6;
    let join = |v: &[f64]| {
        v.iter()
            .map(|&x| round(x).to_string())
            .collect::<Vec<_>>()
            .join(", ")
    };
    let json = format!(
        "{{\n  \"file\": \"{SAMPLE}\",\n  \"channel\": \"{channel}\",\n  \"start\": {start},\n  \"end\": {end},\n  \"window\": \"{window}\",\n  \"bins\": {},\n  \"freqs\": [{}],\n  \"amps\": [{}]\n}}\n",
        spec.freqs.len(),
        join(&spec.freqs),
        join(&spec.amps),
    );
    std::fs::write(fft_golden_path(), json).expect("write fft golden");
    eprintln!("wrote {}", fft_golden_path().display());
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
        p[14] = 3;
        p[16..20].copy_from_slice(&ex.to_le_bytes());
        p[20..24].copy_from_slice(&ey.to_le_bytes());
        p[36..40].copy_from_slice(&vy.to_le_bytes());
        p[28..32].copy_from_slice(&50u32.to_le_bytes());
        p[44..48].copy_from_slice(&30u32.to_le_bytes());
        p[48..50].copy_from_slice(&150u16.to_le_bytes());
        p[51] = 9;
        p
    }

    fn lap(segment: u8, number: u16, duration_ms: u32) -> Vec<u8> {
        let mut p = vec![0u8; 32];
        p[1] = segment;
        p[2..4].copy_from_slice(&number.to_le_bytes());
        p[4..8].copy_from_slice(&duration_ms.to_le_bytes());
        p
    }

    /// A synthetic session: one `RPM` channel of `n` samples (tc `i·10` ms, value
    /// `(i+1)·10`) at 100 Hz, plus two GPS records and two whole-lap markers.
    pub fn session_with_samples(n: u32) -> Vec<u8> {
        let mut cnf = Vec::new();
        cnf.extend(frame("CHS", &chs(0, "RPM", 6, 0, 4, 100_000)));
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
