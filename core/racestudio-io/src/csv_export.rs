//! The RaceChrono-compatible AiM CSV writer (issue 5.1).
//!
//! [`write_aim_csv`] takes a decoded [`Session`] and reproduces, in Rust, the
//! exact "AiM CSV File" that the sibling `xrk2csv.py` writes and RaceChrono's
//! AiM RS2Analysis importer consumes:
//!
//! - every channel is resampled onto a uniform 20 Hz grid (reusing the 3.3
//!   resampler — never re-implemented here);
//! - GPS speed and velocity-accuracy are converted m/s → km/h (×3.6);
//! - latitude/longitude carry 8 decimals;
//! - a `GPS Heading` column (great-circle bearing) is synthesized right after
//!   `GPS Speed`;
//! - every field is double-quoted (`QUOTE_ALL`) with no trailing comma.

use std::io::Write;

use racestudio_analysis::to_distance_grid;
use racestudio_decode::Session;

use crate::error::IoError;
use crate::grid::uniform_grid_ms;
use crate::heading::compute_heading;
use crate::quoting::{fmt_seg_time, quote_all};

/// m/s → km/h, for GPS speed and velocity-accuracy.
const MS_TO_KMH: f64 = 3.6;

/// The GPS columns to emit, in order: `(source channel, output name, unit,
/// scale, decimals)` — ported verbatim from `xrk2csv.GPS_COLUMN_MAP`. A
/// `GPS Heading` column is synthesized separately, right after `GPS Speed`.
const GPS_COLUMN_MAP: &[(&str, &str, &str, f64, usize)] = &[
    ("GPS Speed", "GPS Speed", "km/h", MS_TO_KMH, 4),
    ("GPS Latitude", "GPS Latitude", "deg", 1.0, 8),
    ("GPS Longitude", "GPS Longitude", "deg", 1.0, 8),
    ("GPS Altitude", "GPS Altitude", "m", 1.0, 2),
    ("GPS_Satellites", "GPS Nsat", " ", 1.0, 0),
    ("GPS_Position_Accuracy", "GPS PosAccuracy", "m", 1.0, 2),
    (
        "GPS_Velocity_Accuracy",
        "GPS SpdAccuracy",
        "km/h",
        MS_TO_KMH,
        2,
    ),
    ("GPS_LateralAcc", "GPS LatAcc", "g", 1.0, 2),
    ("GPS_InlineAcc", "GPS InlineAcc", "g", 1.0, 2),
    ("GPS_Yaw_Rate", "GPS Yaw Rate", "deg/s", 1.0, 1),
];

/// One assembled output column: values are aligned to the export grid.
struct Column {
    name: String,
    unit: String,
    values: Vec<f64>,
    decimals: usize,
}

/// Options controlling the export.
#[derive(Debug, Clone, Copy)]
pub struct ExportOptions {
    /// Uniform resample rate, in Hz (RaceStudio's AiM CSV uses 20 Hz).
    pub rate_hz: f64,
}

impl Default for ExportOptions {
    fn default() -> Self {
        ExportOptions { rate_hz: 20.0 }
    }
}

/// A summary of what was written, mirroring `xrk2csv`'s result record.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct ExportReport {
    /// Number of data rows written (grid samples).
    pub samples: usize,
    /// Number of laps emitted as beacon markers / segment times.
    pub laps: usize,
    /// Number of data columns (excluding the leading `Time` column).
    pub channels: usize,
    /// Whether GPS latitude/longitude were present (and a heading synthesized).
    pub has_gps: bool,
    /// Recording duration in seconds.
    pub duration_s: f64,
}

/// Write `session` to `w` as a RaceChrono-compatible AiM CSV.
///
/// # Errors
/// - [`IoError::InvalidRate`] if `opts.rate_hz` is not positive and finite.
/// - [`IoError::NoChannels`] if the session has no channels to export.
/// - [`IoError::Write`] if the underlying writer fails.
pub fn write_aim_csv<W: Write>(
    session: &Session,
    w: &mut W,
    opts: &ExportOptions,
) -> Result<ExportReport, IoError> {
    let rate = opts.rate_hz;
    if !rate.is_finite() || rate <= 0.0 {
        return Err(IoError::InvalidRate(rate));
    }

    let analog = session.channels();
    let gps = session.gps();
    if analog.is_empty() && gps.map_or(true, |g| g.channels().is_empty()) {
        return Err(IoError::NoChannels);
    }

    // Sample timecodes are stored raw. The recording origin (libxrk's
    // `time_offset`) is the earliest of the first lap's start and any sample
    // timecode; the grid is zeroed there. `latest` gives the recording length.
    let mut earliest = f64::INFINITY;
    let mut latest = f64::NEG_INFINITY;
    for channel in analog {
        if let Some(&(t, _)) = channel.samples().first() {
            earliest = earliest.min(t);
        }
        if let Some(&(t, _)) = channel.samples().last() {
            latest = latest.max(t);
        }
    }
    if let Some(g) = gps {
        for channel in g.channels() {
            if let Some(&(t, _)) = channel.samples().first() {
                earliest = earliest.min(t);
            }
            if let Some(&(t, _)) = channel.samples().last() {
                latest = latest.max(t);
            }
        }
    }
    let earliest = if earliest.is_finite() { earliest } else { 0.0 };
    let first_lap_origin = session.first_lap_origin_ms().map(|o| o as f64);
    // Raw timecodes are non-negative, so the origin is too; clamping at 0 also
    // stops a corrupt lap marker (duration > end_time → negative origin) from
    // exploding the grid into a multi-gigabyte allocation.
    let origin = first_lap_origin
        .map_or(earliest, |o| o.min(earliest))
        .max(0.0);
    // Laps are cumulative from the first lap's start; when a sample predates the
    // first lap the data axis starts earlier, so beacons carry that extra offset.
    let beacon_offset_ms = first_lap_origin.map_or(0.0, |o| o - origin);
    let duration_ms = if latest.is_finite() {
        (latest - origin).floor()
    } else {
        0.0
    };

    let grid_f: Vec<f64> = uniform_grid_ms(duration_ms, rate)
        .into_iter()
        .map(|t| t as f64)
        .collect();
    let n = grid_f.len();

    // Resample a channel onto the grid, in origin-normalized time. Interpolated
    // channels use linear interpolation (reusing the 3.3 resampler, clamped at the
    // ends); step channels (integer counters, satellite count) are sample-held
    // (zero-order hold) — matching libxrk's `resample_to_timecodes`. Decoded
    // timecodes are strictly increasing; a (never-expected) non-monotonic series
    // yields NaN holes rather than a panic.
    let resample = |samples: &[(f64, f64)], interpolate: bool| -> Vec<f64> {
        if samples.is_empty() {
            return vec![f64::NAN; n];
        }
        if interpolate {
            let times: Vec<f64> = samples.iter().map(|&(t, _)| t - origin).collect();
            to_distance_grid(samples, &times, &grid_f).unwrap_or_else(|_| vec![f64::NAN; n])
        } else {
            grid_f
                .iter()
                .map(|&g| {
                    // The last sample at or before g; leading grid points hold the
                    // first sample.
                    let i = samples.partition_point(|&(t, _)| t - origin <= g);
                    samples[i.saturating_sub(1)].1
                })
                .collect()
        }
    };

    // GPS latitude/longitude are resampled once (interpolated) and reused for both
    // their own columns and the synthesized heading.
    let mut lat = gps
        .and_then(|g| g.channel("GPS Latitude"))
        .map(|c| resample(c.samples(), c.interpolate()));
    let mut lon = gps
        .and_then(|g| g.channel("GPS Longitude"))
        .map(|c| resample(c.samples(), c.interpolate()));
    let has_gps = lat.is_some() && lon.is_some();
    let mut heading = match (&lat, &lon) {
        (Some(la), Some(lo)) => Some(compute_heading(la, lo)),
        _ => None,
    };

    let mut columns: Vec<Column> = Vec::new();
    if let Some(g) = gps {
        // Each mapped source is present whenever the session has GPS (the decoder
        // emits the full channel set), so a lookup miss simply contributes no
        // column.
        for &(src, out, unit, scale, decimals) in GPS_COLUMN_MAP {
            if let Some(channel) = g.channel(src) {
                // Move the already-resampled lat/lon into their columns (scale 1.0);
                // every other channel resamples here, honoring its hold/interpolate
                // policy, and is scaled.
                let values = match src {
                    "GPS Latitude" => lat.take().unwrap_or_default(),
                    "GPS Longitude" => lon.take().unwrap_or_default(),
                    _ => resample(channel.samples(), channel.interpolate())
                        .into_iter()
                        .map(|v| v * scale)
                        .collect(),
                };
                columns.push(Column {
                    name: out.to_string(),
                    unit: unit.to_string(),
                    values,
                    decimals,
                });
                // Insert the synthesized heading directly after GPS Speed.
                if out == "GPS Speed" {
                    if let Some(values) = heading.take() {
                        columns.push(Column {
                            name: "GPS Heading".to_string(),
                            unit: "deg".to_string(),
                            values,
                            decimals: 4,
                        });
                    }
                }
            }
        }
    }

    // Remaining (non-GPS) telemetry, native name + unit + display precision.
    for channel in analog {
        let unit = if channel.unit().is_empty() {
            " ".to_string()
        } else {
            channel.unit().to_string()
        };
        columns.push(Column {
            name: channel.name().to_string(),
            unit,
            values: resample(channel.samples(), channel.interpolate()),
            decimals: channel.decimals() as usize,
        });
    }

    let report = ExportReport {
        samples: n,
        laps: session.laps().len(),
        channels: columns.len(),
        has_gps,
        duration_s: duration_ms / 1000.0,
    };

    write_csv(
        session,
        w,
        rate,
        duration_ms,
        beacon_offset_ms,
        &grid_f,
        &columns,
    )?;
    Ok(report)
}

/// Serialize the header block, the name/unit rows, and the data rows.
fn write_csv<W: Write>(
    session: &Session,
    w: &mut W,
    rate: f64,
    duration_ms: f64,
    beacon_offset_ms: f64,
    grid_f: &[f64],
    columns: &[Column],
) -> Result<(), IoError> {
    let meta = session.metadata();
    write_row(w, &["Format", "AiM CSV File"])?;
    write_row(w, &["Session", &meta.track])?;
    write_row(w, &["Vehicle", &meta.vehicle])?;
    write_row(w, &["Racer", &meta.driver])?;
    write_row(w, &["Championship", &meta.series])?;
    // The decoded model carries no "Long Comment"; the field stays empty.
    write_row(w, &["Comment", ""])?;
    write_row(w, &["Date", &meta.log_date])?;
    write_row(w, &["Time", &meta.log_time])?;
    write_row(w, &["Sample Rate", &fmt_g(rate)])?;
    write_row(w, &["Duration", &fmt_g(duration_ms / 1000.0)])?;
    write_row(w, &["Segment", "Session"])?;

    let laps = session.laps().laps();
    // Beacons live on the data axis (zeroed at the recording origin); lap end
    // times are cumulative from the first lap's start, so add the offset between.
    let beacons: Vec<String> = laps
        .iter()
        .map(|l| fmt_g(l.end_time_s() + beacon_offset_ms / 1000.0))
        .collect();
    write_row(w, &prepend("Beacon Markers", &beacons))?;
    let seg_times: Vec<String> = laps
        .iter()
        .map(|l| fmt_seg_time(l.duration_s() * 1000.0))
        .collect();
    write_row(w, &prepend("Segment Times", &seg_times))?;
    write_row(w, &[])?; // blank separator

    let names: Vec<&str> = std::iter::once("Time")
        .chain(columns.iter().map(|c| c.name.as_str()))
        .collect();
    let units: Vec<&str> = std::iter::once("s")
        .chain(columns.iter().map(|c| c.unit.as_str()))
        .collect();
    write_row(w, &names)?;
    write_row(w, &units)?;
    write_row(w, &[])?; // blank separator

    for (i, &t_ms) in grid_f.iter().enumerate() {
        let mut fields: Vec<String> = Vec::with_capacity(columns.len() + 1);
        fields.push(format!("{:.3}", t_ms / 1000.0));
        for column in columns {
            let value = column.values.get(i).copied().unwrap_or(f64::NAN);
            if value.is_nan() {
                fields.push(String::new());
            } else {
                fields.push(format!("{:.*}", column.decimals, value));
            }
        }
        let refs: Vec<&str> = fields.iter().map(String::as_str).collect();
        write_row(w, &refs)?;
    }
    Ok(())
}

/// Write one `QUOTE_ALL` CSV record followed by a CRLF terminator.
fn write_row<W: Write>(w: &mut W, fields: &[&str]) -> Result<(), IoError> {
    w.write_all(quote_all(fields).as_bytes())?;
    w.write_all(b"\r\n")?;
    Ok(())
}

/// `[label, values…]` — a header row's label followed by its stringified values.
fn prepend<'a>(label: &'a str, values: &'a [String]) -> Vec<&'a str> {
    std::iter::once(label)
        .chain(values.iter().map(String::as_str))
        .collect()
}

/// Format `x` like Python's `%g` (6 significant digits, trailing zeros stripped)
/// — the format `xrk2csv` uses for `Sample Rate`, `Duration`, and beacon times.
fn fmt_g(x: f64) -> String {
    if x == 0.0 {
        return if x.is_sign_negative() { "-0" } else { "0" }.to_string();
    }
    if !x.is_finite() {
        return if x.is_nan() {
            "nan"
        } else if x > 0.0 {
            "inf"
        } else {
            "-inf"
        }
        .to_string();
    }
    const PRECISION: i32 = 6;
    let exponent = x.abs().log10().floor() as i32;
    if !(-4..PRECISION).contains(&exponent) {
        // Scientific with (P-1) mantissa digits; strip trailing mantissa zeros.
        let s = format!("{:.*e}", (PRECISION - 1) as usize, x);
        strip_scientific(&s)
    } else {
        let decimals = (PRECISION - 1 - exponent).max(0) as usize;
        strip_fixed(&format!("{:.*}", decimals, x))
    }
}

/// Drop trailing zeros (and a bare trailing point) from a fixed-notation number.
fn strip_fixed(s: &str) -> String {
    if s.contains('.') {
        s.trim_end_matches('0').trim_end_matches('.').to_string()
    } else {
        s.to_string()
    }
}

/// Strip trailing zeros from a scientific-notation mantissa (`1.20000e-5` →
/// `1.2e-5`).
fn strip_scientific(s: &str) -> String {
    let Some((mantissa, exp)) = s.split_once('e') else {
        return s.to_string();
    };
    format!("{}e{exp}", strip_fixed(mantissa))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_fmt_g_fixed_range() {
        assert_eq!(fmt_g(20.0), "20");
        assert_eq!(fmt_g(1698.0), "1698");
        assert_eq!(fmt_g(193.611), "193.611");
        assert_eq!(fmt_g(1079.43), "1079.43");
        assert_eq!(fmt_g(0.5), "0.5");
        assert_eq!(fmt_g(0.05), "0.05");
    }

    #[test]
    fn test_fmt_g_zero_and_non_finite() {
        assert_eq!(fmt_g(0.0), "0");
        assert_eq!(fmt_g(-0.0), "-0");
        assert_eq!(fmt_g(f64::NAN), "nan");
        assert_eq!(fmt_g(f64::INFINITY), "inf");
        assert_eq!(fmt_g(f64::NEG_INFINITY), "-inf");
    }

    #[test]
    fn test_fmt_g_scientific_range() {
        // Very small / very large magnitudes fall into the %e branch.
        assert_eq!(fmt_g(0.000_012_5), "1.25e-5");
        assert_eq!(fmt_g(1_500_000.0), "1.5e6");
    }

    #[test]
    fn test_fmt_g_integer_no_decimal_point() {
        // A six-digit integer stays in the fixed branch with zero decimals, so
        // there is no decimal point to strip.
        assert_eq!(fmt_g(150_000.0), "150000");
    }

    #[test]
    fn test_strip_helpers_edge_cases() {
        assert_eq!(strip_fixed("42"), "42"); // no decimal point → unchanged
        assert_eq!(strip_fixed("1.2300"), "1.23");
        assert_eq!(strip_scientific("1.2000e-5"), "1.2e-5");
        assert_eq!(strip_scientific("42"), "42"); // no 'e' → returned unchanged
    }
}
