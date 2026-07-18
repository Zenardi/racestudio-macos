//! Tests for CSV import (issue 5.2) — parsing a generic or AiM RS2Analysis CSV
//! back into the `Session` model.

mod support;

use racestudio_decode::{Channel, Session};
use racestudio_io::{read_csv, ImportError};

/// Parse `text` as a CSV, returning the `Session` or the typed error.
fn read(text: &str) -> Result<Session, ImportError> {
    read_csv(text.as_bytes())
}

/// The named channel, or a panic identifying the miss.
fn channel<'a>(session: &'a Session, name: &str) -> &'a Channel {
    session
        .channels()
        .iter()
        .find(|c| c.name() == name)
        .unwrap_or_else(|| panic!("no channel {name:?}"))
}

/// A minimal AiM "AiM CSV File" with a header block, name/unit rows, and two
/// data rows (GPS Speed in km/h → normalized to m/s; a plain RPM channel).
const AIM_CSV: &str = "\"Format\",\"AiM CSV File\"\n\
\"Session\",\"Fuji GP Sh\"\n\
\"Vehicle\",\"SFJ\"\n\
\"Racer\",\"CMD\"\n\
\"Championship\",\"Fuji Practice\"\n\
\"Comment\",\"\"\n\
\"Date\",\"11/04/2025\"\n\
\"Time\",\"15:50:07\"\n\
\"Sample Rate\",\"20\"\n\
\"Duration\",\"0.5\"\n\
\"Segment\",\"Session\"\n\
\"Beacon Markers\",\"60\",\"150\"\n\
\"Segment Times\",\"1:00.000\",\"1:30.000\"\n\
\n\
\"Time\",\"GPS Speed\",\"RPM\"\n\
\"s\",\"km/h\",\"rpm\"\n\
\n\
\"0.000\",\"36.0000\",\"3000\"\n\
\"0.050\",\"36.0000\",\"3050\"\n";

#[test]
fn test_aim_header_populates_session_metadata() {
    let session = read(AIM_CSV).expect("import AiM CSV");
    let m = session.metadata();
    assert_eq!(m.track, "Fuji GP Sh"); // "Session" row → venue/track
    assert_eq!(m.vehicle, "SFJ");
    assert_eq!(m.driver, "CMD");
    assert_eq!(m.series, "Fuji Practice");
    assert_eq!(m.log_date, "11/04/2025");
    assert_eq!(m.log_time, "15:50:07");
}

#[test]
fn test_kmh_speed_normalized_to_ms() {
    let session = read(AIM_CSV).expect("import");
    let speed = channel(&session, "GPS Speed");
    assert_eq!(speed.unit(), "m/s", "km/h relabelled to m/s");
    for &(_, v) in speed.samples() {
        assert!((v - 10.0).abs() < 1e-6, "36 km/h ÷ 3.6 = 10 m/s, got {v}");
    }
    // A non-speed channel keeps its unit and value.
    let rpm = channel(&session, "RPM");
    assert_eq!(rpm.unit(), "rpm");
    assert_eq!(rpm.samples()[0].1, 3000.0);
}

#[test]
fn test_aim_reconstructs_laps_from_beacons() {
    let session = read(AIM_CSV).expect("import");
    let laps = session.laps().laps();
    assert_eq!(laps.len(), 2, "two beacons → two laps");
    assert!((laps[0].start_time_s() - 0.0).abs() < 1e-9);
    assert!((laps[0].end_time_s() - 60.0).abs() < 1e-9);
    assert!((laps[1].end_time_s() - 150.0).abs() < 1e-9);
}

#[test]
fn test_time_axis_is_seconds_to_ms() {
    // The Time column (seconds) drives each channel's sample timecodes (ms).
    let session = read(AIM_CSV).expect("import");
    let rpm = channel(&session, "RPM");
    assert_eq!(rpm.samples()[0].0, 0.0);
    assert_eq!(rpm.samples()[1].0, 50.0, "0.050 s → 50 ms");
}

#[test]
fn test_generic_csv_without_unit_row_defaults_units() {
    // No AiM block, no unit row: the first numeric column is Time, the rest are
    // channels with empty units.
    let csv = "Time,RPM,Speed\n0.0,3000,10\n0.1,3100,11\n";
    let session = read(csv).expect("import generic");
    assert!(
        session.metadata().vehicle.is_empty(),
        "no AiM header → empty metadata"
    );
    let rpm = channel(&session, "RPM");
    assert_eq!(rpm.unit(), "", "missing unit row → empty unit");
    assert_eq!(rpm.samples()[0].1, 3000.0);
    assert_eq!(rpm.samples()[1].0, 100.0, "0.1 s → 100 ms");
    assert!(
        session.channels().iter().all(|c| c.name() != "Time"),
        "the Time column is the axis, not a channel"
    );
}

#[test]
fn test_generic_csv_with_unit_row() {
    // A non-numeric second row is a unit row.
    let csv = "Time,RPM\ns,rpm\n0.0,3000\n0.1,3100\n";
    let session = read(csv).expect("import");
    assert_eq!(channel(&session, "RPM").unit(), "rpm");
    assert_eq!(channel(&session, "RPM").samples().len(), 2);
}

#[test]
fn test_empty_cells_become_nan() {
    let csv = "Time,A\n0.0,1.0\n0.1,\n0.2,3.0\n";
    let session = read(csv).expect("import");
    let a = channel(&session, "A");
    assert_eq!(a.samples()[0].1, 1.0);
    assert!(a.samples()[1].1.is_nan(), "blank cell → NaN");
    assert_eq!(a.samples()[2].1, 3.0);
}

#[test]
fn test_unquoted_and_crlf_tolerated() {
    let csv = "Time,A\r\n0.0,1.5\r\n0.05,2.5\r\n";
    let session = read(csv).expect("import unquoted CRLF");
    assert_eq!(channel(&session, "A").samples()[0].1, 1.5);
    assert_eq!(channel(&session, "A").samples()[1].1, 2.5);
}

#[test]
fn test_trailing_blank_lines_tolerated() {
    let csv = "Time,A\n0.0,1.5\n0.05,2.5\n\n\n";
    let session = read(csv).expect("import with trailing blanks");
    assert_eq!(channel(&session, "A").samples().len(), 2);
}

#[test]
fn test_embedded_comma_in_quoted_field() {
    let csv = "\"Time\",\"A, raw\"\n\"0.0\",\"1.5\"\n";
    let session = read(csv).expect("import");
    assert!(
        session.channels().iter().any(|c| c.name() == "A, raw"),
        "a comma inside quotes stays one field"
    );
}

// --------------------------------------------------------------------------- //
// Error paths
// --------------------------------------------------------------------------- //

#[test]
fn test_empty_input_returns_error() {
    assert_eq!(read("").unwrap_err(), ImportError::Empty);
    assert_eq!(
        read("\n\n\n").unwrap_err(),
        ImportError::Empty,
        "only blanks"
    );
}

#[test]
fn test_no_header_returns_error() {
    // An AiM header block with no name/data section.
    let csv = "\"Format\",\"AiM CSV File\"\n";
    assert_eq!(read(csv).unwrap_err(), ImportError::NoHeader);
}

#[test]
fn test_non_monotonic_time_returns_error() {
    let csv = "Time,A\n0.0,1\n0.2,2\n0.1,3\n";
    assert!(matches!(
        read(csv),
        Err(ImportError::NonMonotonicTime { .. })
    ));
}

#[test]
fn test_ragged_row_returns_error() {
    let csv = "Time,A,B\n0.0,1,2\n0.1,3\n";
    assert!(matches!(read(csv), Err(ImportError::RaggedRow { .. })));
}

#[test]
fn test_bad_number_returns_error() {
    let csv = "Time,A\n0.0,1\n0.1,notanumber\n";
    assert!(matches!(read(csv), Err(ImportError::BadNumber { .. })));
}

#[test]
fn test_bad_time_value_returns_error() {
    // A non-numeric cell in the time column is reported too.
    let csv = "Time,A\n0.0,1\nx,2\n";
    assert!(matches!(read(csv), Err(ImportError::BadNumber { .. })));
}

#[test]
fn test_doubled_quote_becomes_literal_quote() {
    // A doubled `""` inside a quoted field is one literal quote.
    let csv = "\"Time\",\"A\"\"B\"\n\"0.0\",\"1.5\"\n";
    let session = read(csv).expect("import");
    assert!(
        session.channels().iter().any(|c| c.name() == "A\"B"),
        "channels: {:?}",
        session
            .channels()
            .iter()
            .map(Channel::name)
            .collect::<Vec<_>>()
    );
}

#[test]
fn test_unterminated_quote_tolerated() {
    // A quoted field with no closing quote takes the rest of the field.
    let csv = "\"Time\",\"A\n\"0.0\",\"1.5\"\n";
    let session = read(csv).expect("import");
    assert_eq!(channel(&session, "A").samples()[0].1, 1.5);
}

#[test]
fn test_junk_after_closing_quote_ignored() {
    // Characters between a closing quote and the comma are dropped.
    let csv = "\"Time\",\"A\" junk\n\"0.0\",\"1.5\"\n";
    let session = read(csv).expect("import");
    assert_eq!(channel(&session, "A").samples()[0].1, 1.5);
}

#[test]
fn test_unknown_dialect_without_time_column() {
    // A header row but no `Time` column and no all-numeric column: the layout is
    // unrecognized (no time axis can be established).
    let csv = "Label,Note\nunit,unit\napple,red\n";
    assert_eq!(read(csv).unwrap_err(), ImportError::UnknownDialect);
}

#[test]
fn test_import_error_displays() {
    // Each variant renders a message (diagnosability).
    assert!(ImportError::Empty.to_string().contains("empty"));
    assert!(ImportError::NoHeader.to_string().contains("header"));
    assert!(ImportError::UnknownDialect.to_string().contains("layout"));
    assert!(ImportError::RaggedRow {
        line: 3,
        expected: 3,
        found: 2
    }
    .to_string()
    .contains("ragged"));
    assert!(ImportError::BadNumber {
        line: 2,
        text: "x".into()
    }
    .to_string()
    .contains("non-numeric"));
    assert!(ImportError::NonMonotonicTime { line: 4 }
        .to_string()
        .contains("decreased"));
}

// --------------------------------------------------------------------------- //
// Corpus conformance (skips when the git-ignored reference CSV is absent)
// --------------------------------------------------------------------------- //

#[test]
fn test_reference_csv_yields_all_columns_and_13_laps() {
    let Some(path) = support::reference_csv_or_skip() else {
        return;
    };
    let file = std::fs::File::open(&path).expect("open reference");
    let session = read_csv(file).expect("import RaceStudio reference");

    assert!(
        session.channels().len() >= 30,
        "expected 30+ channels, got {}",
        session.channels().len()
    );
    assert_eq!(session.laps().len(), 13, "13 laps from Beacon Markers");
    // GPS Speed present and normalized to m/s.
    let speed = channel(&session, "GPS Speed");
    assert_eq!(speed.unit(), "m/s");
    // Every channel shares the 20 Hz sample count (uniform grid).
    let n = session.channels()[0].samples().len();
    assert!(n > 1000, "a full session has many samples, got {n}");
    assert!(
        session.channels().iter().all(|c| c.samples().len() == n),
        "all columns share the uniform timebase"
    );
}

#[test]
fn test_import_reference_matches_session_golden() {
    let Some(path) = support::reference_csv_or_skip() else {
        return;
    };
    let session = read_csv(std::fs::File::open(&path).expect("open")).expect("import");
    let summary = support::session_summary(&session);

    let golden_path = support::fixtures_dir()
        .join("golden")
        .join("fuji_0033.session.json");
    let expected = std::fs::read_to_string(&golden_path).unwrap_or_else(|e| {
        panic!(
            "missing session golden {} ({e}); regenerate with scripts/gen_session_golden.sh",
            golden_path.display()
        )
    });
    assert_eq!(
        summary.trim(),
        expected.trim(),
        "imported session structure must match the golden"
    );
}
