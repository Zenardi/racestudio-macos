//! CSV import (issue 5.2) — parse a generic or AiM RS2Analysis CSV back into the
//! typed [`Session`] model, the inverse of the 5.1 writer.
//!
//! [`read_csv`] recognizes two layouts:
//!
//! - the **AiM "AiM CSV File"** block — a `Format`…`Segment Times` key/value
//!   header, a blank line, a name row, a unit row, a blank line, then quoted data
//!   rows — from which session metadata and `Beacon Markers` laps are recovered;
//! - a **generic** CSV — a name row, an optional unit row, then data.
//!
//! Channels are reconstructed with names/units/samples; a `GPS Speed` column in
//! km/h is normalized to m/s so downstream analysis matches decoded `.xrk`. Blank
//! cells become `NaN`. Every failure is a typed [`ImportError`]; no input panics.

use std::io::Read;

use racestudio_decode::{Channel, ChannelMeta, LapData, Metadata, Session};

use crate::error::ImportError;
use crate::laps_from_beacons::laps_from_beacons;
use crate::units::{normalize_unit, normalized_unit};

/// Import a CSV into a [`Session`].
///
/// # Errors
/// Returns a typed [`ImportError`] for empty input, a missing header, a ragged
/// row, a non-numeric cell, a non-monotonic time column, or an unrecognized
/// layout. Never panics on any input.
pub fn read_csv<R: Read>(mut reader: R) -> Result<Session, ImportError> {
    let mut bytes = Vec::new();
    reader
        .read_to_end(&mut bytes)
        .map_err(|_| ImportError::Empty)?;
    let text = String::from_utf8_lossy(&bytes);
    parse(&text)
}

/// Parse the whole document: split into rows, detect the dialect, and dispatch.
fn parse(text: &str) -> Result<Session, ImportError> {
    let rows: Vec<Vec<String>> = text
        .split('\n')
        .map(|line| line.strip_suffix('\r').unwrap_or(line))
        .map(parse_row)
        .collect();

    let first = rows
        .iter()
        .position(|row| !row.is_empty())
        .ok_or(ImportError::Empty)?;

    if is_aim_header(&rows[first]) {
        parse_aim(&rows, first)
    } else {
        build_session(&rows, first, Metadata::default(), &[])
    }
}

/// Whether `row` is the AiM `"Format","AiM CSV File"` marker.
fn is_aim_header(row: &[String]) -> bool {
    row.first().map(String::as_str) == Some("Format")
        && row.get(1).map(String::as_str) == Some("AiM CSV File")
}

/// Parse the AiM key/value header block (metadata + beacons), then hand the
/// name/unit/data tail to [`build_session`].
fn parse_aim(rows: &[Vec<String>], start: usize) -> Result<Session, ImportError> {
    let mut meta = Metadata::default();
    let mut beacons = Vec::new();

    let mut i = start;
    while i < rows.len() && !rows[i].is_empty() {
        let row = &rows[i];
        let key = row.first().map(String::as_str).unwrap_or("");
        let value = row.get(1).map(String::as_str).unwrap_or("");
        match key {
            "Session" => meta.track = value.to_string(),
            "Vehicle" => meta.vehicle = value.to_string(),
            "Racer" => meta.driver = value.to_string(),
            "Championship" => meta.series = value.to_string(),
            "Date" => meta.log_date = value.to_string(),
            "Time" => meta.log_time = value.to_string(),
            "Beacon Markers" => {
                beacons = row[1..]
                    .iter()
                    .filter_map(|s| s.parse::<f64>().ok())
                    .collect();
            }
            _ => {}
        }
        i += 1;
    }

    // Skip the blank separator(s) to the name row.
    while i < rows.len() && rows[i].is_empty() {
        i += 1;
    }
    if i >= rows.len() {
        return Err(ImportError::NoHeader);
    }
    build_session(rows, i, meta, &beacons)
}

/// Build a `Session` from the name row at `names_idx`, an optional unit row, and
/// the data rows that follow (skipping blank separators). Shared by both dialects.
fn build_session(
    rows: &[Vec<String>],
    names_idx: usize,
    meta: Metadata,
    beacons: &[f64],
) -> Result<Session, ImportError> {
    // The non-blank rows from the names row onward, tagged with 1-based line no.
    let body: Vec<(usize, &Vec<String>)> = rows
        .iter()
        .enumerate()
        .skip(names_idx)
        .filter(|(_, row)| !row.is_empty())
        .map(|(idx, row)| (idx + 1, row))
        .collect();
    let names = body.first().ok_or(ImportError::NoHeader)?.1;
    let ncols = names.len();

    // A unit row is a row whose first cell is non-numeric (AiM's "s"); otherwise
    // the row after the names is already data (a generic CSV without units).
    let has_units = body
        .get(1)
        .is_some_and(|(_, row)| row.first().is_some_and(|f| f.parse::<f64>().is_err()));
    let units: Option<&Vec<String>> = if has_units { Some(body[1].1) } else { None };
    let data = &body[if has_units { 2 } else { 1 }..];

    // A header with no `Time` column and no all-numeric column is an
    // unrecognized layout (we cannot establish a time axis).
    let time_col = find_time_column(names, data).ok_or(ImportError::UnknownDialect)?;

    // Time axis (seconds → ms), validated ragged/numeric/monotonic.
    let mut times_ms = Vec::with_capacity(data.len());
    let mut prev = f64::NEG_INFINITY;
    for &(line, row) in data {
        if row.len() != ncols {
            return Err(ImportError::RaggedRow {
                line,
                expected: ncols,
                found: row.len(),
            });
        }
        let cell = &row[time_col];
        let t = cell.parse::<f64>().map_err(|_| ImportError::BadNumber {
            line,
            text: cell.clone(),
        })?;
        if t < prev {
            return Err(ImportError::NonMonotonicTime { line });
        }
        prev = t;
        times_ms.push(t * 1000.0);
    }

    let sample_rate_hz = derive_sample_rate(&times_ms);

    let mut channels = Vec::with_capacity(ncols.saturating_sub(1));
    for col in 0..ncols {
        if col == time_col {
            continue;
        }
        let name = names[col].clone();
        let raw_unit = units
            .and_then(|u| u.get(col))
            .map(String::as_str)
            .unwrap_or("");

        let mut samples = Vec::with_capacity(data.len());
        let mut decimals = 0u8;
        for (k, &(line, row)) in data.iter().enumerate() {
            let cell = &row[col];
            let value = if cell.is_empty() {
                f64::NAN
            } else {
                let raw = cell.parse::<f64>().map_err(|_| ImportError::BadNumber {
                    line,
                    text: cell.clone(),
                })?;
                decimals = decimals.max(cell_decimals(cell));
                normalize_unit(&name, raw_unit, raw)
            };
            samples.push((times_ms[k], value));
        }

        let unit = normalized_unit(&name, raw_unit);
        let meta = ChannelMeta::new(name, unit, sample_rate_hz, decimals, true);
        channels.push(Channel::new(meta, samples));
    }

    let laps = LapData::new(laps_from_beacons(beacons));
    Ok(Session::new(meta, channels, None, laps, None))
}

/// The time column: a column literally named `Time` (case-insensitive), else the
/// first column whose every data cell is numeric (per the 5.2 generic rule).
fn find_time_column(names: &[String], data: &[(usize, &Vec<String>)]) -> Option<usize> {
    if let Some(idx) = names.iter().position(|n| n.eq_ignore_ascii_case("Time")) {
        return Some(idx);
    }
    (0..names.len()).find(|&col| {
        !data.is_empty()
            && data
                .iter()
                .all(|(_, row)| row.get(col).is_some_and(|c| c.parse::<f64>().is_ok()))
    })
}

/// Sample rate (Hz) from the first grid interval; `0` when under two samples.
fn derive_sample_rate(times_ms: &[f64]) -> f64 {
    match times_ms {
        [a, b, ..] if b > a => 1000.0 / (b - a),
        _ => 0.0,
    }
}

/// Decimal places in a numeric cell's text (`"36.0000"` → 4, `"3000"` → 0).
fn cell_decimals(cell: &str) -> u8 {
    match cell.rsplit_once('.') {
        Some((_, frac)) => u8::try_from(frac.len()).unwrap_or(u8::MAX),
        None => 0,
    }
}

/// Split one CSV line into fields, tolerating quoted (`QUOTE_ALL`) and unquoted
/// fields, doubled `""` escapes, and embedded commas inside quotes. A blank line
/// yields no fields (a separator row).
fn parse_row(line: &str) -> Vec<String> {
    if line.is_empty() {
        return Vec::new();
    }
    let mut fields = Vec::new();
    let mut chars = line.chars().peekable();
    loop {
        let mut field = String::new();
        if chars.peek() == Some(&'"') {
            chars.next(); // opening quote
            loop {
                match chars.next() {
                    Some('"') => {
                        if chars.peek() == Some(&'"') {
                            field.push('"'); // doubled quote → literal quote
                            chars.next();
                        } else {
                            break; // closing quote
                        }
                    }
                    Some(c) => field.push(c),
                    None => break, // unterminated quote: take what we have
                }
            }
            // Consume any junk up to the next comma (or end of line).
            loop {
                match chars.next() {
                    Some(',') => break,
                    Some(_) => {}
                    None => {
                        fields.push(field);
                        return fields;
                    }
                }
            }
            fields.push(field);
        } else {
            loop {
                match chars.next() {
                    Some(',') => break,
                    Some(c) => field.push(c),
                    None => {
                        fields.push(field);
                        return fields;
                    }
                }
            }
            fields.push(field);
        }
    }
}
