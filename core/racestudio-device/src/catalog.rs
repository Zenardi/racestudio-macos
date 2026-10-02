//! The device's session catalog (issue #179): the download-summary CSV the
//! MyChron serves for opcode `0x0224` (stored on the device as `1:/mem/dwnsm`).
//!
//! The #133 capture showed the catalog is plain text, one header row then one
//! row per stored session, `\r\n`-separated, each row ending in a comma:
//!
//! ```text
//! name,size,date,hour,nlap,nbest,best,pilota,track_name,veicolo,campionato,…,track_lat,track_lon,test_dur,…
//! a_0061.xrz,3866208,11/07/2025,17:45:28,23,2,53951,,<track>,,,…,-227767969,-471201413,1294498,…
//! ```
//!
//! Columns are looked up **by name**, so a firmware that adds or reorders
//! columns still parses. A row that lacks a required field (name, size, date,
//! time) or has the wrong column count is skipped and counted, never fatal; the
//! parser never panics. This replaces the binary-record hypothesis of
//! [`crate::parse_session_list`], which no capture ever showed. Clean-room,
//! interoperability-only (DMCA §1201(f); EU 2009/24/EC Art. 6).

use std::collections::HashMap;

use crate::command::MAX_PATH_LEN;
use crate::error::DeviceError;
use crate::session::SessionDate;

/// The on-device directory holding recorded sessions (the path table's
/// `recorded=1:/mem` entry).
pub const RECORDED_DIR: &str = "1:/mem/";

/// One session stored on the device, as the catalog lists it.
#[derive(Debug, Clone, PartialEq)]
pub struct SessionEntry {
    /// The on-device file name (`a_0061.xrz`), downloaded from [`RECORDED_DIR`].
    pub file_name: String,
    /// The stored (compressed) size in bytes — the length the download declares.
    pub size_bytes: u32,
    /// When the session started (device-local time).
    pub date: SessionDate,
    /// Number of recorded laps.
    pub lap_count: u16,
    /// The best lap's number, when the logger timed one.
    pub best_lap_number: Option<u16>,
    /// The best lap's time in milliseconds, when the logger timed one.
    pub best_lap_ms: Option<u32>,
    /// The driver name configured on the logger (often empty).
    pub driver: String,
    /// The track the logger matched.
    pub track_name: String,
    /// The vehicle name configured on the logger.
    pub vehicle: String,
    /// The championship name configured on the logger.
    pub championship: String,
    /// The session's duration in milliseconds.
    pub duration_ms: Option<u32>,
    /// The track's latitude in degrees.
    pub track_latitude: Option<f64>,
    /// The track's longitude in degrees.
    pub track_longitude: Option<f64>,
}

/// The parsed catalog: the sessions, plus how many rows had to be skipped.
#[derive(Debug, Clone, PartialEq, Default)]
pub struct Catalog {
    /// The sessions, in the device's order (newest first in the capture).
    pub sessions: Vec<SessionEntry>,
    /// Rows that could not be read and were left out.
    pub skipped_rows: usize,
}

/// Coordinates are stored as integer degrees × 10⁷.
const COORDINATE_SCALE: f64 = 1e7;

/// Parse the catalog CSV.
///
/// Empty input is an empty catalog (the device stores no sessions). Text that
/// is not valid UTF-8 is read lossily.
///
/// # Errors
/// [`DeviceError::MalformedRecord`] when the header lacks one of the required
/// `name`, `size`, `date` or `hour` columns.
pub fn parse_catalog(bytes: &[u8]) -> Result<Catalog, DeviceError> {
    let text = String::from_utf8_lossy(bytes);
    let mut lines = text
        .split('\n')
        .map(|line| line.trim_end_matches('\r'))
        .filter(|line| !line.trim().is_empty());
    let Some(header) = lines.next() else {
        return Ok(Catalog::default());
    };
    let columns = Columns::new(header)?;

    let mut catalog = Catalog::default();
    for line in lines {
        match columns.entry(line) {
            Some(entry) => catalog.sessions.push(entry),
            None => catalog.skipped_rows += 1,
        }
    }
    Ok(catalog)
}

/// The on-device path of a catalog file name, validated so a hostile catalog
/// can never steer the read anywhere but the recorded-sessions directory.
///
/// # Errors
/// [`DeviceError::InvalidPath`] when `file_name` is not a plain session file
/// name (see [`is_valid_file_name`]).
pub fn session_path(file_name: &str) -> Result<String, DeviceError> {
    if !is_valid_file_name(file_name) {
        return Err(DeviceError::InvalidPath);
    }
    Ok(format!("{RECORDED_DIR}{file_name}"))
}

/// Is `name` a plain session file name: `[A-Za-z0-9_-]` stem, an `.xrz`/`.xrk`
/// extension, and short enough that the full path fits a read command?
#[must_use]
pub fn is_valid_file_name(name: &str) -> bool {
    let lower = name.to_ascii_lowercase();
    let Some(stem) = lower
        .strip_suffix(".xrz")
        .or_else(|| lower.strip_suffix(".xrk"))
    else {
        return false;
    };
    !stem.is_empty()
        && RECORDED_DIR.len() + name.len() <= MAX_PATH_LEN
        && stem
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b == b'_' || b == b'-')
}

/// The header's column positions.
struct Columns {
    count: usize,
    index: HashMap<String, usize>,
}

impl Columns {
    const REQUIRED: [&'static str; 4] = ["name", "size", "date", "hour"];

    fn new(header: &str) -> Result<Self, DeviceError> {
        let names: Vec<&str> = header.split(',').map(str::trim).collect();
        let index: HashMap<String, usize> = names
            .iter()
            .enumerate()
            .filter(|(_, name)| !name.is_empty())
            .map(|(i, name)| (name.to_ascii_lowercase(), i))
            .collect();
        if Self::REQUIRED.iter().any(|c| !index.contains_key(*c)) {
            return Err(DeviceError::MalformedRecord);
        }
        Ok(Columns {
            count: names.len(),
            index,
        })
    }

    /// Decode one row, or `None` when it cannot be read.
    fn entry(&self, line: &str) -> Option<SessionEntry> {
        let fields: Vec<&str> = line.split(',').map(str::trim).collect();
        if fields.len() != self.count {
            return None;
        }
        let field = |name: &str| self.index.get(name).and_then(|&i| fields.get(i)).copied();
        let text = |name: &str| field(name).unwrap_or_default().to_string();

        let file_name = field("name")?;
        if !is_valid_file_name(file_name) {
            return None;
        }
        Some(SessionEntry {
            file_name: file_name.to_string(),
            size_bytes: field("size")?.parse().ok()?,
            date: parse_date_time(field("date")?, field("hour")?)?,
            lap_count: optional(field("nlap")).unwrap_or(0),
            best_lap_number: optional(field("nbest")),
            best_lap_ms: optional(field("best")),
            driver: text("pilota"),
            track_name: text("track_name"),
            vehicle: text("veicolo"),
            championship: text("campionato"),
            duration_ms: optional(field("test_dur")),
            track_latitude: coordinate(field("track_lat"), 90.0),
            track_longitude: coordinate(field("track_lon"), 180.0),
        })
    }
}

/// An optional number: empty, missing or unreadable is `None`.
fn optional<T: std::str::FromStr>(value: Option<&str>) -> Option<T> {
    value.filter(|v| !v.is_empty())?.parse().ok()
}

/// A coordinate stored as degrees × 10⁷, rejected outside ±`limit` degrees.
fn coordinate(value: Option<&str>, limit: f64) -> Option<f64> {
    let raw: i64 = optional(value)?;
    #[allow(clippy::cast_precision_loss)] // ±1.8e9 is exact in an f64
    let degrees = raw as f64 / COORDINATE_SCALE;
    (degrees.abs() <= limit).then_some(degrees)
}

/// `dd/mm/yyyy` + `hh:mm:ss`, range-checked.
fn parse_date_time(date: &str, time: &str) -> Option<SessionDate> {
    let mut d = date.split('/');
    let day: u8 = d.next()?.parse().ok()?;
    let month: u8 = d.next()?.parse().ok()?;
    let year: u16 = d.next()?.parse().ok()?;
    let mut t = time.split(':');
    let hour: u8 = t.next()?.parse().ok()?;
    let minute: u8 = t.next()?.parse().ok()?;
    let second: u8 = t.next()?.parse().ok()?;
    if d.next().is_some() || t.next().is_some() {
        return None;
    }
    let valid = (1..=days_in_month(month, year)).contains(&day)
        && (1..=12).contains(&month)
        && (1900..=2999).contains(&year)
        && hour < 24
        && minute < 60
        && second < 60;
    valid.then_some(SessionDate {
        year,
        month,
        day,
        hour,
        minute,
        second,
    })
}

/// Days in `month` of `year` (Gregorian); 0 for a month outside 1–12.
fn days_in_month(month: u8, year: u16) -> u8 {
    match month {
        1 | 3 | 5 | 7 | 8 | 10 | 12 => 31,
        4 | 6 | 9 | 11 => 30,
        2 if year % 4 == 0 && (year % 100 != 0 || year % 400 == 0) => 29,
        2 => 28,
        _ => 0,
    }
}
