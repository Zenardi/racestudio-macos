//! Tests for the RaceChrono-compatible AiM CSV writer (issue 5.1).
//!
//! Synthetic sessions (built in `support`) exercise the writer deterministically
//! and drive coverage; the `fuji_*` tests are corpus conformance against the
//! committed byte golden and the RaceStudio reference — they skip gracefully when
//! the git-ignored `fixtures/*.xrk`/reference are absent (fetched in CI).

mod support;

use std::collections::HashMap;

use racestudio_decode::{decode_session, Session};
use racestudio_io::{write_aim_csv, ExportOptions, ExportReport, IoError};

use support::{
    column_index, empty_session, equirect_distance, fixtures_dir, gps_session, is_genuine_xrk,
    nan_channel_session, no_gps_session, parse_csv,
};

/// Export `session` at the default rate, returning the CSV text and the report.
fn export(session: &Session) -> (String, ExportReport) {
    let mut buf = Vec::new();
    let report =
        write_aim_csv(session, &mut buf, &ExportOptions::default()).expect("export succeeds");
    (String::from_utf8(buf).expect("valid UTF-8"), report)
}

/// The parsed `(names_row, units_row, data_rows)` of an exported CSV.
fn sections(text: &str) -> (Vec<String>, Vec<String>, Vec<Vec<String>>) {
    let rows = parse_csv(text);
    // The names row is the "Time" row after the blank separator — distinct from
    // the metadata `Time` header row earlier in the file.
    let names_idx = (1..rows.len())
        .find(|&i| {
            rows[i - 1].is_empty()
                && rows[i].first().map(String::as_str) == Some("Time")
                && rows[i].len() > 1
        })
        .expect("names row (Time, after the blank separator)");
    let names = rows[names_idx].clone();
    let units = rows[names_idx + 1].clone();
    // names, units, blank, then data rows.
    let data = rows[names_idx + 3..].to_vec();
    (names, units, data)
}

// --------------------------------------------------------------------------- //
// GPS column semantics
// --------------------------------------------------------------------------- //

#[test]
fn test_gps_speed_scaled_to_kmh() {
    // The synthetic session logs a constant 10 m/s → every GPS Speed cell is
    // 36.0000 km/h (×3.6), with km/h as its unit.
    let (text, _) = export(&gps_session());
    let (names, units, data) = sections(&text);
    let idx = column_index(&names, "GPS Speed");
    assert_eq!(units[idx], "km/h");
    for row in &data {
        assert_eq!(row[idx], "36.0000", "10 m/s → 36.0000 km/h");
    }
}

#[test]
fn test_latlong_have_eight_decimals() {
    let (text, _) = export(&gps_session());
    let (names, _, data) = sections(&text);
    for col in ["GPS Latitude", "GPS Longitude"] {
        let idx = column_index(&names, col);
        for row in &data {
            let decimals = row[idx].split('.').nth(1).unwrap_or("");
            assert_eq!(
                decimals.len(),
                8,
                "{col} cell {:?} must carry 8 decimals",
                row[idx]
            );
        }
    }
}

#[test]
fn test_heading_inserted_directly_after_gps_speed() {
    let (text, _) = export(&gps_session());
    let (names, units, _) = sections(&text);
    let speed = column_index(&names, "GPS Speed");
    let heading = column_index(&names, "GPS Heading");
    assert_eq!(heading, speed + 1, "GPS Heading follows GPS Speed");
    assert_eq!(units[heading], "deg");
}

#[test]
fn test_gps_velocity_accuracy_scaled_to_kmh() {
    // GPS SpdAccuracy is the renamed velocity-accuracy channel, ×3.6 → km/h.
    let (text, _) = export(&gps_session());
    let (names, units, data) = sections(&text);
    let idx = column_index(&names, "GPS SpdAccuracy");
    assert_eq!(units[idx], "km/h");
    // 1.00 m/s → 3.60 km/h at 2 dp.
    assert_eq!(data[0][idx], "3.60");
}

#[test]
fn test_gps_nsat_unit_is_single_space() {
    // The satellite-count column keeps AiM's single-space "unit".
    let (text, _) = export(&gps_session());
    let (names, units, _) = sections(&text);
    let idx = column_index(&names, "GPS Nsat");
    assert_eq!(units[idx], " ");
}

// --------------------------------------------------------------------------- //
// No-GPS session
// --------------------------------------------------------------------------- //

#[test]
fn test_no_gps_file_omits_heading_and_reports_has_gps_false() {
    let (text, report) = export(&no_gps_session());
    assert!(!report.has_gps, "no GPS lat/long → has_gps=false");
    let (names, _, _) = sections(&text);
    assert!(
        !names.contains(&"GPS Heading".to_string()),
        "no heading synthesized"
    );
    assert!(
        !names.contains(&"GPS Speed".to_string()),
        "no GPS columns at all"
    );
    assert!(
        names.contains(&"RPM".to_string()),
        "the analog channel is still exported"
    );
}

// --------------------------------------------------------------------------- //
// Quoting / structure
// --------------------------------------------------------------------------- //

#[test]
fn test_every_field_is_quoted_and_no_trailing_comma() {
    let (text, _) = export(&gps_session());
    for line in text.split("\r\n") {
        if line.is_empty() {
            continue; // blank separator rows are genuinely empty
        }
        assert!(
            line.starts_with('"'),
            "row must open with a quote: {line:?}"
        );
        assert!(line.ends_with('"'), "row must close with a quote: {line:?}");
        assert!(
            !line.ends_with(','),
            "row must not end with a comma: {line:?}"
        );
    }
}

#[test]
fn test_header_block_matches_metadata() {
    let (text, _) = export(&gps_session());
    let rows = parse_csv(&text);
    assert_eq!(rows[0], vec!["Format", "AiM CSV File"]);
    assert_eq!(rows[1], vec!["Session", "Fuji"]); // Venue = track
    assert_eq!(rows[2], vec!["Vehicle", "SFJ"]);
    assert_eq!(rows[3], vec!["Racer", "CMD"]);
    assert_eq!(rows[4], vec!["Championship", "Practice"]);
    assert_eq!(rows[5], vec!["Comment", ""]); // no Long Comment in the decoded model
    assert_eq!(rows[6], vec!["Date", "11/04/2025"]);
    assert_eq!(rows[7], vec!["Time", "15:50:07"]);
    assert_eq!(rows[8], vec!["Sample Rate", "20"]);
    assert_eq!(rows[9], vec!["Duration", "0.5"]);
    assert_eq!(rows[10], vec!["Segment", "Session"]);
}

#[test]
fn test_beacon_markers_and_segment_times() {
    let (text, _) = export(&gps_session());
    let rows = parse_csv(&text);
    // Laps of 60 s and 90 s → beacon end-times 60 s and 150 s.
    assert_eq!(rows[11], vec!["Beacon Markers", "60", "150"]);
    assert_eq!(rows[12], vec!["Segment Times", "1:00.000", "1:30.000"]);
}

#[test]
fn test_time_column_is_seconds_at_three_dp() {
    let (text, _) = export(&gps_session());
    let (names, units, data) = sections(&text);
    assert_eq!(names[0], "Time");
    assert_eq!(units[0], "s");
    assert_eq!(data[0][0], "0.000");
    assert_eq!(data[1][0], "0.050", "20 Hz → 50 ms steps");
}

#[test]
fn test_blank_separator_rows_frame_the_names_and_units() {
    let (text, _) = export(&gps_session());
    let rows = parse_csv(&text);
    // Blank row after the Segment Times header, and after the units row.
    assert!(rows[13].is_empty(), "blank row before names");
    assert_eq!(rows[14][0], "Time", "names row");
    assert_eq!(rows[15][0], "s", "units row");
    assert!(rows[16].is_empty(), "blank row before data");
}

#[test]
fn test_nan_values_written_as_empty_field() {
    // Missing / NaN values are written as an empty (quoted) field, never a number.
    let (text, _) = export(&nan_channel_session());
    let (names, _, data) = sections(&text);
    let math = column_index(&names, "MATH");
    for row in &data {
        assert_eq!(row[math], "", "a NaN cell is written empty");
    }
    // The neighbouring valid channel is still populated.
    let rpm = column_index(&names, "RPM");
    assert!(!data[0][rpm].is_empty(), "the valid channel is unaffected");
}

#[test]
fn test_remaining_channel_keeps_native_name_and_unit() {
    let (text, _) = export(&gps_session());
    let (names, units, _) = sections(&text);
    let idx = column_index(&names, "RPM");
    assert_eq!(units[idx], "rpm");
}

// --------------------------------------------------------------------------- //
// Report + error paths
// --------------------------------------------------------------------------- //

#[test]
fn test_report_summarizes_the_export() {
    let (_, report) = export(&gps_session());
    assert_eq!(report.samples, 11, "0..=500 ms at 20 Hz");
    assert_eq!(report.laps, 2);
    assert!(report.has_gps);
    assert_eq!(report.channels, 12, "11 GPS columns (incl. heading) + RPM");
    assert!((report.duration_s - 0.5).abs() < 1e-9);
}

#[test]
fn test_no_channels_errors() {
    let mut buf = Vec::new();
    let err = write_aim_csv(&empty_session(), &mut buf, &ExportOptions::default())
        .expect_err("a session with no channels cannot be exported");
    assert!(matches!(err, IoError::NoChannels), "got {err:?}");
    assert!(buf.is_empty(), "nothing is written on error");
}

#[test]
fn test_invalid_rate_errors() {
    let session = gps_session();
    for rate in [0.0, -20.0, f64::NAN, f64::INFINITY] {
        let mut buf = Vec::new();
        let err = write_aim_csv(&session, &mut buf, &ExportOptions { rate_hz: rate })
            .expect_err("non-positive/non-finite rate is rejected");
        assert!(
            matches!(err, IoError::InvalidRate(_)),
            "rate {rate}: got {err:?}"
        );
    }
}

#[test]
fn test_default_rate_is_twenty_hz() {
    assert!((ExportOptions::default().rate_hz - 20.0).abs() < 1e-9);
}

#[test]
fn test_io_error_displays_and_wraps_source() {
    // The write path surfaces the underlying io::Error (Display + source()).
    use std::error::Error;
    let inner = std::io::Error::new(std::io::ErrorKind::BrokenPipe, "pipe");
    let err = IoError::from(inner);
    assert!(err.to_string().contains("pipe"));
    assert!(err.source().is_some(), "Write wraps its io::Error source");
    assert!(IoError::NoChannels.source().is_none());
    assert!(IoError::NoChannels.to_string().contains("no channels"));
    assert!(IoError::InvalidRate(0.0).to_string().contains("positive"));
}

#[test]
fn test_write_failure_is_reported() {
    // A writer that always fails surfaces as IoError::Write.
    struct FailWriter;
    impl std::io::Write for FailWriter {
        fn write(&mut self, _: &[u8]) -> std::io::Result<usize> {
            Err(std::io::Error::other("nope"))
        }
        fn flush(&mut self) -> std::io::Result<()> {
            Ok(())
        }
    }
    let err = write_aim_csv(&gps_session(), &mut FailWriter, &ExportOptions::default())
        .expect_err("write failure propagates");
    assert!(matches!(err, IoError::Write(_)), "got {err:?}");
}

// --------------------------------------------------------------------------- //
// Corpus conformance (skips when the git-ignored fixtures are absent)
// --------------------------------------------------------------------------- //

#[test]
fn test_fuji_export_matches_byte_golden() {
    let xrk = fixtures_dir().join("fuji_0033.xrk");
    if !is_genuine_xrk(&xrk) {
        eprintln!("skip: {} absent (run `make fixtures`)", xrk.display());
        return;
    }
    let session = decode_session(&xrk).expect("decode fuji_0033.xrk");
    let mut buf = Vec::new();
    write_aim_csv(&session, &mut buf, &ExportOptions::default()).expect("export fuji");

    let golden = fixtures_dir().join("golden").join("fuji_0033.csv");
    let expected = std::fs::read(&golden).unwrap_or_else(|e| {
        panic!(
            "missing byte golden {} ({e}); regenerate with scripts/gen_csv_golden.sh",
            golden.display()
        )
    });
    assert!(
        buf == expected,
        "fuji export ({} bytes) does not match the byte golden ({} bytes)",
        buf.len(),
        expected.len()
    );
}

/// A `(GPS Speed, GPS Latitude, GPS Longitude)` sample from one CSV row.
type GpsSample = (f64, f64, f64);

/// Build `time_string → (GPS Speed, GPS Latitude, GPS Longitude)` from a parsed
/// AiM CSV, for the field-tolerant reference comparison.
fn gps_by_time(text: &str) -> HashMap<String, GpsSample> {
    let (names, _, data) = sections(text);
    let (t, s) = (
        column_index(&names, "Time"),
        column_index(&names, "GPS Speed"),
    );
    let (la, lo) = (
        column_index(&names, "GPS Latitude"),
        column_index(&names, "GPS Longitude"),
    );
    let parse = |row: &[String], i: usize| row[i].parse::<f64>().ok();
    data.iter()
        .filter_map(|row| {
            Some((
                row[t].clone(),
                (parse(row, s)?, parse(row, la)?, parse(row, lo)?),
            ))
        })
        .collect()
}

/// Decode fuji, export, and pair it with the RaceStudio reference over the shared
/// timestamps in `[200, 1600] s`. Returns `None` (skip) when either is absent.
fn fuji_vs_reference() -> Option<Vec<(GpsSample, GpsSample)>> {
    let xrk = fixtures_dir().join("fuji_0033.xrk");
    let reference = fixtures_dir().join("fuji_0033_reference.csv");
    if !is_genuine_xrk(&xrk) || std::fs::metadata(&reference).map(|m| m.len()).unwrap_or(0) < 1024 {
        eprintln!("skip: fuji fixture or reference CSV absent (run `make fixtures`)");
        return None;
    }
    let session = decode_session(&xrk).expect("decode fuji_0033.xrk");
    let mut buf = Vec::new();
    write_aim_csv(&session, &mut buf, &ExportOptions::default()).expect("export fuji");
    let mine = gps_by_time(&String::from_utf8(buf).expect("utf8"));

    let ref_text = std::fs::read_to_string(&reference).expect("read reference");
    let theirs = gps_by_time(&ref_text);

    let mut pairs = Vec::new();
    for (time, &m) in &mine {
        let secs: f64 = time.parse().unwrap_or(f64::NAN);
        if !(200.0..=1600.0).contains(&secs) {
            continue;
        }
        if let Some(&r) = theirs.get(time) {
            pairs.push((m, r));
        }
    }
    assert!(
        pairs.len() > 1000,
        "expected a substantial overlap in [200,1600]s, got {}",
        pairs.len()
    );
    Some(pairs)
}

#[test]
fn test_speed_within_half_kmh_of_reference() {
    let Some(pairs) = fuji_vs_reference() else {
        return;
    };
    let mut worst = 0.0_f64;
    for ((ms, _, _), (rs, _, _)) in pairs {
        worst = worst.max((ms - rs).abs());
    }
    assert!(
        worst <= 0.5,
        "worst GPS Speed error {worst:.4} km/h exceeds 0.5"
    );
}

#[test]
fn test_position_within_one_meter_of_reference() {
    let Some(pairs) = fuji_vs_reference() else {
        return;
    };
    let mut worst = 0.0_f64;
    for ((_, mlat, mlon), (_, rlat, rlon)) in pairs {
        worst = worst.max(equirect_distance(mlat, mlon, rlat, rlon));
    }
    assert!(
        worst <= 1.0,
        "worst position error {worst:.4} m exceeds 1.0"
    );
}
