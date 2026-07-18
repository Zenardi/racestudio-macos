//! Tests for CSV field quoting and segment-time formatting (issue 5.1).

use racestudio_io::{fmt_seg_time, quote_all};

#[test]
fn test_quote_all_wraps_every_field() {
    assert_eq!(
        quote_all(&["Format", "AiM CSV File"]),
        "\"Format\",\"AiM CSV File\""
    );
}

#[test]
fn test_quote_all_single_field_has_no_trailing_comma() {
    let row = quote_all(&["Beacon Markers"]);
    assert_eq!(row, "\"Beacon Markers\"");
    assert!(!row.ends_with(','), "no trailing comma");
}

#[test]
fn test_quote_all_empty_is_blank_row() {
    assert_eq!(quote_all(&[]), "");
}

#[test]
fn test_quote_all_escapes_embedded_quotes() {
    // RFC-4180: an embedded double-quote is doubled.
    assert_eq!(quote_all(&["a\"b"]), "\"a\"\"b\"");
}

#[test]
fn test_quote_all_quotes_empty_field() {
    // A missing/NaN value is written as an empty *quoted* field, not bare.
    assert_eq!(quote_all(&["Time", ""]), "\"Time\",\"\"");
}

#[test]
fn test_fmt_seg_time_minutes_seconds_millis() {
    // 3:13.611 — the AiM CSV `Segment Times` format.
    assert_eq!(fmt_seg_time(193_611.0), "3:13.611");
}

#[test]
fn test_fmt_seg_time_pads_seconds_to_two_digits() {
    // Seconds below ten are zero-padded (M:SS.mmm, not M:S.mmm).
    assert_eq!(fmt_seg_time(63_050.0), "1:03.050");
}

#[test]
fn test_fmt_seg_time_zero() {
    assert_eq!(fmt_seg_time(0.0), "0:00.000");
}

#[test]
fn test_fmt_seg_time_whole_minutes() {
    assert_eq!(fmt_seg_time(120_000.0), "2:00.000");
}
