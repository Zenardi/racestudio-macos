//! UniFFI boundary exposing the RaceStudio Rust core to the SwiftUI frontend.
//!
//! Milestone M0 (issue 0.4) proved the Rust→Swift pipeline end-to-end with a
//! single exported `core_version()`. Milestone M1 (issue 1.7) adds the decode
//! interface: [`open_session`] returns an opaque, `Arc`-backed [`SessionHandle`]
//! over the decoded [`Session`](racestudio_decode::Session) (1.6), and Swift
//! reads channel data through the **windowed** [`SessionHandle::samples`]
//! accessor — a bounded slice per call — rather than copying whole channels
//! across the boundary. Every entry point returns a UniFFI-mapped
//! [`FfiDecodeError`]; malformed input never panics or traps.

// The FFI boundary faces untrusted input and must never panic/trap (mirrors the
// decode and analysis crates): forbid unwrap/expect/panic on shipped code; test
// code is exempt.
#![cfg_attr(
    not(test),
    deny(clippy::unwrap_used, clippy::expect_used, clippy::panic)
)]

use std::collections::HashMap;
use std::sync::{Arc, OnceLock};

use racestudio_analysis::expr::{channels_referenced, eval_series, parse_str};
use racestudio_analysis::{
    cumulative_distance, delta_t, resample_uniform, segment_laps, spectrum, stats_over_range,
    to_distance_grid, AnalysisError as CoreAnalysisError, Lap, Stats, Window as FftWindow,
};
use racestudio_decode::{decode_session, DecodeError, Session};

uniffi::setup_scaffolding!();

/// The GPS ground-speed channel integrated into the cumulative track distance
/// axis — the same channel the analysis crate's `distance_axis` uses for the
/// distance-domain accessors (issues 3.1 / 8.2).
const SPEED_CHANNEL: &str = "GPS Speed";

/// The RaceStudio Rust core version, exported across the UniFFI boundary.
///
/// Returns the `racestudio-ffi` crate version (`CARGO_PKG_VERSION`). Swift calls
/// this as `coreVersion()`; a round-trip test asserts the string crosses the
/// boundary unchanged, proving the FFI pipeline works.
#[uniffi::export]
#[must_use]
pub fn core_version() -> String {
    env!("CARGO_PKG_VERSION").to_string()
}

/// Session metadata carried across the boundary (mirrors the decode
/// [`Metadata`](racestudio_decode::Metadata)).
#[derive(Debug, Clone, uniffi::Record)]
pub struct SessionMetadata {
    /// Vehicle name.
    pub vehicle: String,
    /// Track / venue name.
    pub track: String,
    /// Driver / racer name.
    pub driver: String,
    /// Session name.
    pub session: String,
    /// Championship / series name.
    pub series: String,
    /// Raw log date as stored (`MM/DD/YYYY`).
    pub log_date: String,
    /// Raw log time as stored (`HH:MM:SS`).
    pub log_time: String,
    /// Session start as epoch seconds (UTC; 0 when absent/unparseable).
    pub datetime_utc: i64,
}

/// A channel's listing entry: metadata only — **no** bulk samples. Sample data
/// is fetched separately and in windows via [`SessionHandle::samples`].
#[derive(Debug, Clone, uniffi::Record)]
pub struct ChannelInfo {
    /// Channel name (e.g. `RPM`, `AccelerometerX`).
    pub name: String,
    /// Physical unit (e.g. `g`, `V`); empty when dimensionless.
    pub unit: String,
    /// Native sample rate in hertz (0 when unknown).
    pub sample_rate_hz: f64,
    /// Display precision (decimal places) hint.
    pub decimals: u8,
    /// Number of samples in the channel (reported without copying them).
    pub sample_count: u32,
}

/// One decoded lap's timing.
#[derive(Debug, Clone, uniffi::Record)]
pub struct LapInfo {
    /// Zero-based lap index within the session.
    pub index: u32,
    /// Session-relative start time in seconds (cumulative).
    pub start_time_s: f64,
    /// Lap duration in seconds.
    pub duration_s: f64,
    /// Session-relative end time in seconds (`start + duration`).
    pub end_time_s: f64,
}

/// A summary of the session's GPS stream — counts and time span, without the
/// per-fix bulk data.
#[derive(Debug, Clone, uniffi::Record)]
pub struct GpsSummary {
    /// Number of GPS fixes.
    pub fix_count: u32,
    /// Number of GPS channels (raw + computed).
    pub channel_count: u32,
    /// Timecode (ms) of the first fix (0 when there are none).
    pub first_timecode_ms: f64,
    /// Timecode (ms) of the last fix (0 when there are none).
    pub last_timecode_ms: f64,
}

/// One channel sample: a `(timecode, value)` pair.
#[derive(Debug, Clone, Copy, uniffi::Record)]
pub struct Sample {
    /// Logger timecode (milliseconds for most channels).
    pub timecode: f64,
    /// The sample's physical value.
    pub value: f64,
}

/// One distance-paired channel sample: a `(timecode, distance, value)` triple —
/// the same `(timecode, value)` as [`Sample`] plus the cumulative track distance
/// (metres) at that timecode. [`SessionHandle::samples_with_distance`] returns
/// these so the UI can plot a channel against distance without a second round
/// trip and without shipping the distance axis separately.
#[derive(Debug, Clone, Copy, uniffi::Record)]
pub struct DistanceSample {
    /// Logger timecode (milliseconds for most channels).
    pub timecode: f64,
    /// Cumulative track distance (metres) at `timecode`, `0` when the session
    /// carries no `GPS Speed` channel to integrate.
    pub distance: f64,
    /// The sample's physical value.
    pub value: f64,
}

/// One point of the GPS track: a fix's position, the cumulative track distance
/// (metres) at it, and its timecode — the row [`SessionHandle::gps_track`]
/// returns for the track map and the distance axis.
#[derive(Debug, Clone, Copy, uniffi::Record)]
pub struct GpsTrackPoint {
    /// Latitude in degrees (WGS84).
    pub latitude: f64,
    /// Longitude in degrees (WGS84).
    pub longitude: f64,
    /// Cumulative track distance (metres) at this fix, `0` when there is no
    /// `GPS Speed` channel to integrate.
    pub distance: f64,
    /// Logger timecode (milliseconds).
    pub timecode: f64,
}

/// A half-open analysis window `[start, end)` on an accessor's natural axis —
/// seconds for laps, channel timecode (ms) for channel accessors, cumulative
/// distance (m) for delta-t. Every windowed accessor takes one so the UI can
/// request just the visible range without marshalling whole channels (3.8).
#[derive(Debug, Clone, Copy, uniffi::Record)]
pub struct FfiWindow {
    /// Inclusive lower bound.
    pub start: f64,
    /// Exclusive (for channel windows) / inclusive (for laps, delta-t) upper bound.
    pub end: f64,
}

impl FfiWindow {
    /// Reject a `NaN` or inverted (`start > end`) window. Infinite bounds are
    /// allowed and mean "unbounded" — `[-∞, ∞)` is the whole session.
    fn validate(self) -> Result<(), AnalysisError> {
        if self.start.is_nan() || self.end.is_nan() || self.start > self.end {
            return Err(AnalysisError::WindowOutOfBounds {
                start: self.start,
                end: self.end,
            });
        }
        Ok(())
    }
}

/// One point of a delta-t series: cumulative time gained/lost versus a reference
/// lap, as a function of cumulative distance (issue 3.2).
#[derive(Debug, Clone, Copy, uniffi::Record)]
pub struct DeltaPoint {
    /// Cumulative distance from the lap start (metres).
    pub distance: f64,
    /// Delta-t in seconds (positive ⇒ the comparison lap is slower).
    pub dt: f64,
}

/// Summary statistics for a channel window (issue 3.4).
#[derive(Debug, Clone, Copy, uniffi::Record)]
pub struct StatsDto {
    /// Number of finite samples in the window.
    pub count: u32,
    /// Minimum sample value.
    pub min: f64,
    /// Maximum sample value.
    pub max: f64,
    /// Arithmetic mean.
    pub mean: f64,
    /// Population standard deviation (÷ n).
    pub std_pop: f64,
    /// Sample standard deviation (÷ n−1; 0 for a single sample).
    pub std_sample: f64,
    /// Root mean square.
    pub rms: f64,
    /// Peak-to-peak range (`max − min`).
    pub range: f64,
}

impl From<Stats> for StatsDto {
    fn from(s: Stats) -> Self {
        StatsDto {
            count: u32::try_from(s.count()).unwrap_or(u32::MAX),
            min: s.min(),
            max: s.max(),
            mean: s.mean(),
            std_pop: s.std_pop(),
            std_sample: s.std_sample(),
            rms: s.rms(),
            range: s.range(),
        }
    }
}

/// A single-sided amplitude spectrum and its frequency axis (issue 3.7).
#[derive(Debug, Clone, uniffi::Record)]
pub struct SpectrumDto {
    /// Frequencies (Hz): `k·fs/N` for `k` in `0..=N/2`.
    pub freqs: Vec<f64>,
    /// Single-sided amplitudes, aligned with `freqs`.
    pub amps: Vec<f64>,
}

/// The window function applied before an [`SessionHandle::fft_spectrum`] transform.
#[derive(Debug, Clone, Copy, uniffi::Enum)]
pub enum SpectrumWindow {
    /// No taper.
    Rectangular,
    /// Hann.
    Hann,
    /// Hamming.
    Hamming,
    /// Blackman.
    Blackman,
}

impl From<SpectrumWindow> for FftWindow {
    fn from(w: SpectrumWindow) -> Self {
        match w {
            SpectrumWindow::Rectangular => FftWindow::Rectangular,
            SpectrumWindow::Hann => FftWindow::Hann,
            SpectrumWindow::Hamming => FftWindow::Hamming,
            SpectrumWindow::Blackman => FftWindow::Blackman,
        }
    }
}

/// The analysis failure surface across the FFI boundary — the analysis crate's
/// [`AnalysisError`](racestudio_analysis::AnalysisError) plus the FFI-specific
/// invalid-expression, out-of-range-lap, and out-of-bounds-window cases.
///
/// Declared `#[uniffi(flat_error)]`: Swift receives a plain `enum AnalysisError:
/// Error` with these cases (the human-readable message comes from [`Display`]),
/// so an invalid expression or an out-of-bounds window is a **thrown** typed
/// error, never a trap.
#[derive(Debug, uniffi::Error)]
#[uniffi(flat_error)]
pub enum AnalysisError {
    /// A named channel is not present in the session.
    MissingChannel {
        /// The requested channel name.
        name: String,
    },
    /// A lap carries no samples to align (delta-t).
    EmptyLap,
    /// A lap's distance axis is not monotonic, so time cannot be inverted.
    DistanceNotMonotonic,
    /// The window selected no finite samples.
    EmptyRange,
    /// A math-channel expression failed to lex, parse, or evaluate.
    InvalidExpression {
        /// The underlying expression error message.
        message: String,
    },
    /// A delta-t lap index is outside `0..lap_count`.
    LapOutOfRange {
        /// The requested (invalid) lap index.
        index: u32,
        /// The number of laps in the session.
        count: u32,
    },
    /// The window is non-finite or inverted (`start > end`).
    WindowOutOfBounds {
        /// The window start.
        start: f64,
        /// The window end.
        end: f64,
    },
}

impl std::fmt::Display for AnalysisError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            AnalysisError::MissingChannel { name } => write!(f, "channel not found: {name}"),
            AnalysisError::EmptyLap => write!(f, "lap has no samples to align"),
            AnalysisError::DistanceNotMonotonic => {
                write!(f, "a channel axis (distance or timecode) is not monotonic")
            }
            AnalysisError::EmptyRange => write!(f, "window selected no finite samples"),
            AnalysisError::InvalidExpression { message } => {
                write!(f, "invalid math-channel expression: {message}")
            }
            AnalysisError::LapOutOfRange { index, count } => {
                write!(
                    f,
                    "lap index {index} out of range (session has {count} laps)"
                )
            }
            AnalysisError::WindowOutOfBounds { start, end } => {
                write!(f, "window out of bounds: [{start}, {end})")
            }
        }
    }
}

impl std::error::Error for AnalysisError {}

impl From<CoreAnalysisError> for AnalysisError {
    fn from(err: CoreAnalysisError) -> Self {
        match err {
            CoreAnalysisError::MissingChannel { name } => AnalysisError::MissingChannel { name },
            CoreAnalysisError::EmptyLap => AnalysisError::EmptyLap,
            CoreAnalysisError::DistanceNotMonotonic => AnalysisError::DistanceNotMonotonic,
            CoreAnalysisError::EmptyRange => AnalysisError::EmptyRange,
        }
    }
}

/// The decode failure surface across the FFI boundary, mapped from the decode
/// crate's [`DecodeError`], plus the FFI-specific out-of-range channel index.
#[derive(Debug, uniffi::Error)]
pub enum FfiDecodeError {
    /// The file could not be read from disk.
    Io { message: String },
    /// The file does not begin with the `.xrk` header magic.
    BadMagic,
    /// The first header message is cut short.
    TruncatedHeader,
    /// A channel data message's samples run past end-of-file.
    TruncatedChannel,
    /// A multi-sample burst declared an invalid sample count.
    BadSampleCount,
    /// The GPS stream is not a whole number of records.
    TruncatedGps,
    /// A lap marker is too short for its timing fields.
    TruncatedLaps,
    /// A `samples(...)` call named a channel index outside `0..channel_count`.
    ChannelOutOfRange {
        /// The requested (invalid) index.
        index: u32,
        /// The number of channels in the session.
        channel_count: u32,
    },
    /// Any decode error the FFI layer does not distinguish — the reserved
    /// `UnknownUnit` (which the tolerant decoder never emits) and any variant
    /// added to the `#[non_exhaustive]` `DecodeError` after this mapping. Carries
    /// the underlying human-readable message so the boundary stays total.
    Other { message: String },
}

impl std::fmt::Display for FfiDecodeError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            FfiDecodeError::Io { message } => write!(f, "failed to read .xrk file: {message}"),
            FfiDecodeError::BadMagic => write!(f, "not an .xrk file: missing '<h' header magic"),
            FfiDecodeError::TruncatedHeader => write!(f, "truncated .xrk header"),
            FfiDecodeError::TruncatedChannel => write!(f, "truncated channel data"),
            FfiDecodeError::BadSampleCount => write!(f, "invalid channel sample count"),
            FfiDecodeError::TruncatedGps => write!(f, "truncated GPS data"),
            FfiDecodeError::TruncatedLaps => write!(f, "truncated lap marker"),
            FfiDecodeError::ChannelOutOfRange {
                index,
                channel_count,
            } => write!(
                f,
                "channel index {index} out of range (session has {channel_count} channels)"
            ),
            FfiDecodeError::Other { message } => write!(f, "{message}"),
        }
    }
}

impl std::error::Error for FfiDecodeError {}

impl From<DecodeError> for FfiDecodeError {
    fn from(err: DecodeError) -> Self {
        match err {
            DecodeError::Io(e) => FfiDecodeError::Io {
                message: e.to_string(),
            },
            DecodeError::BadMagic => FfiDecodeError::BadMagic,
            DecodeError::TruncatedHeader => FfiDecodeError::TruncatedHeader,
            DecodeError::TruncatedChannel => FfiDecodeError::TruncatedChannel,
            DecodeError::BadSampleCount => FfiDecodeError::BadSampleCount,
            DecodeError::TruncatedGps => FfiDecodeError::TruncatedGps,
            DecodeError::TruncatedLaps => FfiDecodeError::TruncatedLaps,
            // `DecodeError` is `#[non_exhaustive]`; the reserved `UnknownUnit`
            // and any future variant map to a message-bearing catch-all so the
            // boundary stays total.
            other => FfiDecodeError::Other {
                message: other.to_string(),
            },
        }
    }
}

/// An opened decode session, exposed to Swift as an opaque, `Arc`-backed handle.
///
/// The whole [`Session`](racestudio_decode::Session) is decoded once when the
/// handle is created ([`open_session`]); the accessors then read from it in
/// place. Channel samples are read in bounded windows via [`Self::samples`], so
/// Swift never has to copy an entire channel to display part of it.
#[derive(Debug, uniffi::Object)]
pub struct SessionHandle {
    session: Session,
    /// Lazily-computed per-lap segmentation (3.1), shared by the lap-based
    /// accessors so an interactive caller does not re-slice the whole session on
    /// every windowed call.
    segmented_laps: OnceLock<Vec<Lap>>,
}

impl SessionHandle {
    /// The per-lap segmentation, computed once and cached.
    fn segmented(&self) -> &[Lap] {
        self.segmented_laps
            .get_or_init(|| segment_laps(&self.session))
    }

    /// The clamped `[start, start + count)` sample window of channel
    /// `channel_index` — an empty slice when `start` is at or past the end, and
    /// truncated when `count` overruns it (never an over-read). Shared by
    /// [`Self::samples`] and [`Self::samples_with_distance`].
    ///
    /// # Errors
    /// [`FfiDecodeError::ChannelOutOfRange`] when `channel_index` is not a valid
    /// channel.
    fn channel_window(
        &self,
        channel_index: u32,
        start: u32,
        count: u32,
    ) -> Result<&[(f64, f64)], FfiDecodeError> {
        let channels = self.session.channels();
        let channel = channels.get(channel_index as usize).ok_or_else(|| {
            FfiDecodeError::ChannelOutOfRange {
                index: channel_index,
                channel_count: u32::try_from(channels.len()).unwrap_or(u32::MAX),
            }
        })?;
        let samples = channel.samples();
        let start = start as usize;
        if start >= samples.len() {
            return Ok(&[]);
        }
        let end = start.saturating_add(count as usize).min(samples.len());
        Ok(&samples[start..end])
    }

    /// The cumulative track distance (m) at each of `timecodes`, by integrating
    /// the session's `GPS Speed` channel into a distance axis
    /// ([`cumulative_distance`]) and linearly interpolating it onto that timebase
    /// (reusing [`to_distance_grid`]).
    ///
    /// Total by construction: a session with no (or an empty) `GPS Speed` channel
    /// has no odometer, so every distance is `0`; a non-monotonic speed timebase —
    /// which the decoder does not produce — likewise falls back to zeros rather
    /// than surfacing an error across this boundary.
    fn distance_at(&self, timecodes: &[f64]) -> Vec<f64> {
        let zeros = || vec![0.0; timecodes.len()];
        let Some(speed) = channel_samples(&self.session, SPEED_CHANNEL).filter(|s| !s.is_empty())
        else {
            return zeros();
        };
        let speed_times: Vec<f64> = speed.iter().map(|&(t, _)| t).collect();
        let axis = cumulative_distance(speed);
        let series: Vec<(f64, f64)> = speed_times.iter().copied().zip(axis).collect();
        to_distance_grid(&series, &speed_times, timecodes).unwrap_or_else(|_| zeros())
    }
}

#[uniffi::export]
impl SessionHandle {
    /// The session metadata (driver, vehicle, venue, date/time).
    #[must_use]
    pub fn metadata(&self) -> SessionMetadata {
        let m = self.session.metadata();
        SessionMetadata {
            vehicle: m.vehicle.clone(),
            track: m.track.clone(),
            driver: m.driver.clone(),
            session: m.session.clone(),
            series: m.series.clone(),
            log_date: m.log_date.clone(),
            log_time: m.log_time.clone(),
            datetime_utc: m.datetime_utc,
        }
    }

    /// The channel listing: one [`ChannelInfo`] per channel, metadata only. Use
    /// [`Self::samples`] to read a channel's sample window.
    #[must_use]
    pub fn channels(&self) -> Vec<ChannelInfo> {
        self.session
            .channels()
            .iter()
            .map(|c| ChannelInfo {
                name: c.name().to_string(),
                unit: c.unit().to_string(),
                sample_rate_hz: c.sample_rate_hz(),
                decimals: c.decimals(),
                sample_count: u32::try_from(c.samples().len()).unwrap_or(u32::MAX),
            })
            .collect()
    }

    /// The lap timing as a listing.
    #[must_use]
    pub fn laps(&self) -> Vec<LapInfo> {
        self.session
            .laps()
            .laps()
            .iter()
            .map(|l| LapInfo {
                index: l.index(),
                start_time_s: l.start_time_s(),
                duration_s: l.duration_s(),
                end_time_s: l.end_time_s(),
            })
            .collect()
    }

    /// A summary of the GPS stream, or `None` when the session carries no GPS.
    #[must_use]
    pub fn gps_summary(&self) -> Option<GpsSummary> {
        let gps = self.session.gps()?;
        let fixes = gps.fixes();
        Some(GpsSummary {
            fix_count: u32::try_from(fixes.len()).unwrap_or(u32::MAX),
            channel_count: u32::try_from(gps.channels().len()).unwrap_or(u32::MAX),
            first_timecode_ms: fixes.first().map_or(0.0, |fix| fix.timecode_ms),
            last_timecode_ms: fixes.last().map_or(0.0, |fix| fix.timecode_ms),
        })
    }

    /// Read at most `count` samples of channel `channel_index`, starting at
    /// sample `start`.
    ///
    /// The window is **clamped** to the channel: a `start` at or past the end
    /// yields an empty vec, and a `count` that overruns the end returns only the
    /// samples that remain — never an over-read.
    ///
    /// # Errors
    /// [`FfiDecodeError::ChannelOutOfRange`] when `channel_index` is not a valid
    /// channel. Never panics.
    pub fn samples(
        &self,
        channel_index: u32,
        start: u32,
        count: u32,
    ) -> Result<Vec<Sample>, FfiDecodeError> {
        Ok(self
            .channel_window(channel_index, start, count)?
            .iter()
            .map(|&(timecode, value)| Sample { timecode, value })
            .collect())
    }

    /// Like [`Self::samples`], but each sample is paired with the cumulative
    /// track distance (metres) at its timecode — a `(timecode, distance, value)`
    /// triple on the channel's own timebase — so the UI can plot the channel
    /// against distance directly.
    ///
    /// The distance axis is the session's `GPS Speed` channel integrated with
    /// [`cumulative_distance`] and interpolated onto each sample's timecode; a
    /// session without `GPS Speed` reports `0` for every distance. The window is
    /// clamped exactly as [`Self::samples`].
    ///
    /// # Errors
    /// [`FfiDecodeError::ChannelOutOfRange`] when `channel_index` is not a valid
    /// channel. Never panics.
    pub fn samples_with_distance(
        &self,
        channel_index: u32,
        start: u32,
        count: u32,
    ) -> Result<Vec<DistanceSample>, FfiDecodeError> {
        let window = self.channel_window(channel_index, start, count)?;
        let timecodes: Vec<f64> = window.iter().map(|&(t, _)| t).collect();
        let distances = self.distance_at(&timecodes);
        Ok(window
            .iter()
            .zip(distances)
            .map(|(&(timecode, value), distance)| DistanceSample {
                timecode,
                distance,
                value,
            })
            .collect())
    }

    /// The GPS track as `(latitude, longitude, distance, timecode)` points, one
    /// per fix, over the clamped `[start, start + count)` fix window.
    ///
    /// `distance` is the cumulative track distance (metres) at each fix, from
    /// integrating `GPS Speed` ([`cumulative_distance`]). A session with **no**
    /// GPS returns an empty vec — never an error or panic — and a `start` at or
    /// past the last fix likewise yields an empty vec.
    #[must_use]
    pub fn gps_track(&self, start: u32, count: u32) -> Vec<GpsTrackPoint> {
        let Some(gps) = self.session.gps() else {
            return Vec::new();
        };
        let fixes = gps.fixes();
        let start = start as usize;
        if start >= fixes.len() {
            return Vec::new();
        }
        let end = start.saturating_add(count as usize).min(fixes.len());
        let window = &fixes[start..end];
        let timecodes: Vec<f64> = window.iter().map(|fix| fix.timecode_ms).collect();
        let distances = self.distance_at(&timecodes);
        window
            .iter()
            .zip(distances)
            .map(|(fix, distance)| GpsTrackPoint {
                latitude: fix.latitude,
                longitude: fix.longitude,
                distance,
                timecode: fix.timecode_ms,
            })
            .collect()
    }

    /// The laps whose time span intersects `window` (seconds) — a windowed view
    /// of the lap listing (issue 3.1).
    ///
    /// # Errors
    /// [`AnalysisError::WindowOutOfBounds`] for a non-finite or inverted window.
    pub fn list_laps(&self, window: FfiWindow) -> Result<Vec<LapInfo>, AnalysisError> {
        window.validate()?;
        Ok(self
            .session
            .laps()
            .laps()
            .iter()
            .filter(|l| l.end_time_s() >= window.start && l.start_time_s() <= window.end)
            .map(|l| LapInfo {
                index: l.index(),
                start_time_s: l.start_time_s(),
                duration_s: l.duration_s(),
                end_time_s: l.end_time_s(),
            })
            .collect())
    }

    /// The delta-t of the `comparison` lap versus the `reference` lap, as
    /// `(distance, dt)` points restricted to the distance `window` (metres,
    /// issue 3.2).
    ///
    /// # Errors
    /// - [`AnalysisError::LapOutOfRange`] if either index is not a valid lap.
    /// - [`AnalysisError::EmptyLap`] / [`AnalysisError::DistanceNotMonotonic`]
    ///   from the delta-t computation.
    /// - [`AnalysisError::WindowOutOfBounds`] for an inverted window.
    pub fn delta_t_series(
        &self,
        reference: u32,
        comparison: u32,
        window: FfiWindow,
    ) -> Result<Vec<DeltaPoint>, AnalysisError> {
        window.validate()?;
        let laps = self.segmented();
        let count = u32::try_from(laps.len()).unwrap_or(u32::MAX);
        let lap = |index: u32| {
            laps.get(index as usize)
                .ok_or(AnalysisError::LapOutOfRange { index, count })
        };
        let series = delta_t(lap(reference)?, lap(comparison)?)?;
        Ok(series
            .into_iter()
            .filter(|&(distance, _)| distance >= window.start && distance <= window.end)
            .map(|(distance, dt)| DeltaPoint { distance, dt })
            .collect())
    }

    /// Summary statistics of `channel` over the timecode `window` (ms, issue 3.4).
    ///
    /// # Errors
    /// - [`AnalysisError::MissingChannel`] if `channel` is not in the session.
    /// - [`AnalysisError::EmptyRange`] if the window selects no finite samples.
    /// - [`AnalysisError::WindowOutOfBounds`] for an inverted window.
    pub fn channel_stats(
        &self,
        channel: String,
        window: FfiWindow,
    ) -> Result<StatsDto, AnalysisError> {
        window.validate()?;
        let samples = channel_samples(&self.session, &channel)
            .ok_or(AnalysisError::MissingChannel { name: channel })?;
        Ok(stats_over_range(samples, window.start, window.end)?.into())
    }

    /// Evaluate the math-channel `expr` over the timecode `window` (ms), one
    /// [`Sample`] per point on the first referenced channel's in-window timebase;
    /// other referenced channels are linearly resampled onto it (issues 3.3/3.5).
    /// A constant expression (no channel references) yields no samples.
    ///
    /// # Errors
    /// - [`AnalysisError::InvalidExpression`] if `expr` fails to parse or evaluate.
    /// - [`AnalysisError::MissingChannel`] if it references an absent channel.
    /// - [`AnalysisError::DistanceNotMonotonic`] if a referenced channel's
    ///   timecodes are not monotonic (so it cannot be resampled onto the grid).
    /// - [`AnalysisError::WindowOutOfBounds`] for an inverted window.
    pub fn eval_math_channel(
        &self,
        expr: String,
        window: FfiWindow,
    ) -> Result<Vec<Sample>, AnalysisError> {
        window.validate()?;
        let ast = parse_str(&expr).map_err(|e| AnalysisError::InvalidExpression {
            message: e.to_string(),
        })?;
        let references = channels_referenced(&ast);
        if references.is_empty() {
            return Ok(Vec::new()); // constant expression: no timebase.
        }
        // Resolve every referenced channel up front (fail fast on a missing one).
        let mut resolved: Vec<&[(f64, f64)]> = Vec::with_capacity(references.len());
        for name in &references {
            resolved.push(
                channel_samples(&self.session, name)
                    .ok_or_else(|| AnalysisError::MissingChannel { name: name.clone() })?,
            );
        }

        // Anchor the shared timebase on the referenced channel with the most
        // in-window samples — the highest resolution, and independent of the
        // operand order (so `a*b` and `b*a` agree).
        let in_window = |s: &[(f64, f64)]| {
            s.iter()
                .filter(|&&(t, _)| t >= window.start && t < window.end)
                .count()
        };
        let anchor = (0..resolved.len())
            .max_by_key(|&i| in_window(resolved[i]))
            .unwrap_or(0);
        let grid: Vec<f64> = resolved[anchor]
            .iter()
            .map(|&(t, _)| t)
            .filter(|&t| t >= window.start && t < window.end)
            .collect();
        if grid.is_empty() {
            return Ok(Vec::new());
        }

        // The anchor's in-window values already sit on the grid; the others are
        // linearly resampled onto it (issue 3.3).
        let mut resolver: HashMap<String, Vec<f64>> = HashMap::new();
        for (i, (name, series)) in references.iter().zip(&resolved).enumerate() {
            let values = if i == anchor {
                series
                    .iter()
                    .filter(|&&(t, _)| t >= window.start && t < window.end)
                    .map(|&(_, v)| v)
                    .collect()
            } else {
                let times: Vec<f64> = series.iter().map(|&(t, _)| t).collect();
                to_distance_grid(series, &times, &grid)?
            };
            resolver.insert(name.clone(), values);
        }

        let values =
            eval_series(&ast, &resolver).map_err(|e| AnalysisError::InvalidExpression {
                message: e.to_string(),
            })?;
        Ok(grid
            .into_iter()
            .zip(values)
            .map(|(timecode, value)| Sample { timecode, value })
            .collect())
    }

    /// The single-sided amplitude spectrum of `channel` over the timecode
    /// `window` (ms): the in-window samples are resampled to a uniform rate
    /// (issue 3.3), then windowed and transformed (issue 3.7).
    ///
    /// # Errors
    /// - [`AnalysisError::MissingChannel`] if `channel` is not in the session.
    /// - [`AnalysisError::EmptyRange`] if the window holds fewer than two samples.
    /// - [`AnalysisError::WindowOutOfBounds`] for an inverted window.
    pub fn fft_spectrum(
        &self,
        channel: String,
        window_fn: SpectrumWindow,
        window: FfiWindow,
    ) -> Result<SpectrumDto, AnalysisError> {
        window.validate()?;
        let samples = channel_samples(&self.session, &channel)
            .ok_or(AnalysisError::MissingChannel { name: channel })?;
        let windowed: Vec<(f64, f64)> = samples
            .iter()
            .copied()
            .filter(|&(t, _)| t >= window.start && t < window.end)
            .collect();
        let fs = average_rate_hz(&windowed);
        if fs <= 0.0 {
            return Err(AnalysisError::EmptyRange);
        }
        // `resample_uniform`'s rate is in samples per unit of the series' own time
        // axis. The timecodes are milliseconds, so resample at `fs/1000` (samples
        // per ms) to place the grid at the physical `fs` Hz; `spectrum` is then
        // given `fs` so the `k·fs/N` axis comes out in Hz.
        let uniform = resample_uniform(&windowed, fs / 1000.0);
        let values: Vec<f64> = uniform.iter().map(|&(_, v)| v).collect();
        let spec = spectrum(&values, fs, window_fn.into())?;
        Ok(SpectrumDto {
            freqs: spec.freqs().to_vec(),
            amps: spec.amps().to_vec(),
        })
    }
}

/// A channel's `(timecode, value)` samples by name, across CHS-backed and GPS
/// channels (`None` when the name is not present).
fn channel_samples<'a>(session: &'a Session, name: &str) -> Option<&'a [(f64, f64)]> {
    if let Some(channel) = session.channels().iter().find(|c| c.name() == name) {
        return Some(channel.samples());
    }
    session
        .gps()
        .and_then(|gps| gps.channel(name))
        .map(|channel| channel.samples())
}

/// The average sample rate (Hz) of a millisecond-timecoded series, or `0` when
/// it has fewer than two samples or a non-positive span.
fn average_rate_hz(samples: &[(f64, f64)]) -> f64 {
    let (Some(&(first, _)), Some(&(last, _))) = (samples.first(), samples.last()) else {
        return 0.0;
    };
    let span_ms = last - first;
    if span_ms <= 0.0 {
        return 0.0;
    }
    1000.0 * (samples.len() as f64 - 1.0) / span_ms
}

/// Open and decode the `.xrk` file at `path` into an opaque [`SessionHandle`].
///
/// The whole session (metadata + channels + GPS + laps) is decoded up front via
/// [`decode_session`]; the returned handle is `Arc`-backed and immutable.
///
/// # Errors
/// An [`FfiDecodeError`] mapped from the decode failure — I/O, bad magic, or a
/// truncated/malformed stream. Never panics or traps.
#[uniffi::export]
pub fn open_session(path: String) -> Result<Arc<SessionHandle>, FfiDecodeError> {
    let session = decode_session(path)?;
    Ok(Arc::new(SessionHandle {
        session,
        segmented_laps: OnceLock::new(),
    }))
}

/// Parse-validate a math-channel expression against the M2 grammar (issue 5.4).
///
/// Runs `expr` through the same lexer/parser [`SessionHandle::eval_math_channel`]
/// uses, but **does not evaluate** — no session or channel data is required, so a
/// stored math channel can be re-validated when a project/workspace file is
/// loaded. Returns `Ok(())` for syntactically valid input; otherwise a thrown
/// [`AnalysisError::InvalidExpression`] carrying the parser's `(line, col)`
/// message. Never panics.
#[uniffi::export]
pub fn validate_math_expression(expr: String) -> Result<(), AnalysisError> {
    parse_str(&expr)
        .map(|_| ())
        .map_err(|e| AnalysisError::InvalidExpression {
            message: e.to_string(),
        })
}

#[cfg(test)]
mod tests {
    use super::*;

    use std::path::PathBuf;

    use racestudio_decode::{Channel, ChannelMeta, LapData, Metadata};

    /// A CHS channel with the given `(timecode, value)` samples (unit/precision
    /// are irrelevant to the distance accessors).
    fn channel(name: &str, samples: &[(f64, f64)]) -> Channel {
        Channel::new(
            ChannelMeta::new(name.to_string(), String::new(), 0.0, 2, true),
            samples.to_vec(),
        )
    }

    /// A GPS-less handle over the given CHS channels — enough to exercise the
    /// windowed sample accessors deterministically, with `GPS Speed` synthesised
    /// as a plain channel so the distance axis is fully under the test's control.
    fn handle_with_channels(channels: Vec<Channel>) -> SessionHandle {
        SessionHandle {
            session: Session::new(
                Metadata::default(),
                channels,
                None,
                LapData::new(Vec::new()),
                None,
            ),
            segmented_laps: OnceLock::new(),
        }
    }

    /// The repo-root path to a fixture, and whether it is a genuine `.xrk`.
    fn xrk_or_skip(name: &str) -> Option<PathBuf> {
        let path = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
            .parent()
            .and_then(|core| core.parent())
            .map(|root| root.join("fixtures").join(name))?;
        match std::fs::read(&path) {
            Ok(bytes) if bytes.starts_with(b"<h") => Some(path),
            _ => {
                eprintln!(
                    "skipping: {} is not a real .xrk — run `make fixtures`",
                    path.display()
                );
                None
            }
        }
    }

    #[test]
    fn test_samples_with_distance_pairs_each_sample_with_interpolated_distance() {
        // GPS Speed held at 10 m/s over two 1 s steps → distance axis [0, 10, 20]
        // at t = [0, 1000, 2000]. A value channel is interpolated onto that axis.
        let speed = channel(
            SPEED_CHANNEL,
            &[(0.0, 10.0), (1000.0, 10.0), (2000.0, 10.0)],
        );
        let ax = channel(
            "AX",
            &[(0.0, 1.0), (500.0, 2.0), (1000.0, 3.0), (2000.0, 4.0)],
        );
        let handle = handle_with_channels(vec![speed, ax]);

        let out = handle
            .samples_with_distance(1, 0, 10)
            .expect("valid channel index");

        let got: Vec<(f64, f64, f64)> = out
            .iter()
            .map(|s| (s.timecode, s.distance, s.value))
            .collect();
        assert_eq!(
            got,
            vec![
                (0.0, 0.0, 1.0),   // t=0    → distance 0
                (500.0, 5.0, 2.0), // t=500  → half-way to 10 m
                (1000.0, 10.0, 3.0),
                (2000.0, 20.0, 4.0),
            ]
        );
    }

    #[test]
    fn test_samples_with_distance_clamps_window_and_rejects_bad_index() {
        let speed = channel(
            SPEED_CHANNEL,
            &[(0.0, 10.0), (1000.0, 10.0), (2000.0, 10.0)],
        );
        let ax = channel("AX", &[(0.0, 1.0), (1000.0, 3.0), (2000.0, 4.0)]);
        let handle = handle_with_channels(vec![speed, ax]);

        // A mid-channel window returns only the requested slice, distance intact.
        let mid = handle.samples_with_distance(1, 1, 1).expect("in range");
        assert_eq!(mid.len(), 1);
        assert_eq!(
            (mid[0].timecode, mid[0].distance, mid[0].value),
            (1000.0, 10.0, 3.0)
        );

        // A start at/past the end is an empty vec, never an over-read.
        assert!(handle
            .samples_with_distance(1, 9, 5)
            .expect("in range")
            .is_empty());

        // An out-of-range channel index is a thrown ChannelOutOfRange, not a panic.
        let err = handle
            .samples_with_distance(7, 0, 1)
            .expect_err("bad index");
        assert!(matches!(
            err,
            FfiDecodeError::ChannelOutOfRange {
                index: 7,
                channel_count: 2
            }
        ));
    }

    #[test]
    fn test_samples_with_distance_without_speed_reports_zero_distance() {
        // No GPS Speed channel → no odometer → distance 0 for every sample, but
        // the timecodes and values still cross intact.
        let handle = handle_with_channels(vec![channel("AX", &[(0.0, 1.0), (100.0, 2.0)])]);

        let out = handle.samples_with_distance(0, 0, 10).expect("valid index");

        assert_eq!(out.len(), 2);
        assert!(out.iter().all(|s| s.distance == 0.0));
        assert_eq!((out[1].timecode, out[1].value), (100.0, 2.0));
    }

    #[test]
    fn test_samples_with_distance_non_monotonic_speed_falls_back_to_zero() {
        // A non-monotonic speed timebase (which the decoder never emits) makes the
        // distance axis unusable; the boundary stays total by reporting 0, not by
        // throwing or panicking.
        let speed = channel(SPEED_CHANNEL, &[(0.0, 10.0), (500.0, 10.0), (200.0, 10.0)]);
        let ax = channel("AX", &[(0.0, 1.0), (100.0, 2.0)]);
        let handle = handle_with_channels(vec![speed, ax]);

        let out = handle
            .samples_with_distance(1, 0, 10)
            .expect("no error across boundary");

        assert_eq!(out.len(), 2);
        assert!(out.iter().all(|s| s.distance == 0.0));
        assert_eq!(out[1].value, 2.0);
    }

    #[test]
    fn test_gps_track_without_gps_is_empty() {
        // A session with no GPS yields an empty typed result — never an error.
        let handle = handle_with_channels(vec![channel("AX", &[(0.0, 1.0)])]);
        assert!(handle.gps_track(0, 100).is_empty());
    }

    #[test]
    fn test_gps_track_matches_decoded_fixes_and_distance() {
        let Some(path) = xrk_or_skip("aim_official_test.xrk") else {
            return;
        };
        let handle = open_session(path.to_string_lossy().into_owned()).expect("decode");
        let gps = handle.session.gps().expect("fixture has GPS");
        let fixes = gps.fixes();

        let track = handle.gps_track(0, u32::MAX);

        assert_eq!(track.len(), fixes.len(), "one point per fix");
        // Position and timecode are the decoded fix verbatim.
        for (point, fix) in track.iter().zip(fixes) {
            assert_eq!(point.latitude, fix.latitude);
            assert_eq!(point.longitude, fix.longitude);
            assert_eq!(point.timecode, fix.timecode_ms);
        }
        // Distance is the clamped cumulative integral of GPS Speed, index-aligned
        // with the fixes and monotonically non-decreasing.
        let axis = cumulative_distance(gps.channel(SPEED_CHANNEL).expect("GPS Speed").samples());
        for (point, &distance) in track.iter().zip(&axis) {
            assert!((point.distance - distance).abs() < 1e-9);
        }
        assert!(track
            .windows(2)
            .all(|w| w[1].distance >= w[0].distance - 1e-9));
        assert!(track.last().expect("non-empty").distance > 0.0);

        // A start past the last fix is an empty vec.
        assert!(handle
            .gps_track(u32::try_from(fixes.len()).unwrap_or(u32::MAX), 10)
            .is_empty());
    }

    #[test]
    fn test_samples_with_distance_on_real_session_augments_samples() {
        let Some(path) = xrk_or_skip("aim_official_test.xrk") else {
            return;
        };
        let handle = open_session(path.to_string_lossy().into_owned()).expect("decode");

        let with = handle
            .samples_with_distance(0, 0, 100)
            .expect("samples_with_distance");
        let plain = handle.samples(0, 0, 100).expect("samples");

        assert_eq!(with.len(), plain.len());
        // The timecode/value pair is exactly `samples`; distance is finite added on.
        for (a, b) in with.iter().zip(&plain) {
            assert_eq!(a.timecode, b.timecode);
            assert_eq!(a.value, b.value);
            assert!(a.distance.is_finite());
        }
    }

    #[test]
    fn test_validate_math_expression_accepts_valid_and_rejects_invalid() {
        // A syntactically valid expression parses (no session needed).
        assert!(validate_math_expression("sqrt(Ax*Ax + Ay*Ay)".to_string()).is_ok());
        // A malformed expression is a thrown InvalidExpression, never a panic.
        let err = validate_math_expression("Ax +* 2".to_string()).unwrap_err();
        assert!(matches!(err, AnalysisError::InvalidExpression { .. }));
    }

    #[test]
    fn test_core_version_returns_crate_version() {
        assert_eq!(core_version(), env!("CARGO_PKG_VERSION"));
    }

    #[test]
    fn test_error_display_and_mapping_is_total() {
        // Every mapped DecodeError renders a message; the Io mapping carries the
        // OS message; the FFI-only variants render too.
        let io = FfiDecodeError::from(DecodeError::from(std::io::Error::new(
            std::io::ErrorKind::NotFound,
            "gone",
        )));
        assert!(io.to_string().contains("gone"));

        for err in [
            FfiDecodeError::from(DecodeError::BadMagic),
            FfiDecodeError::from(DecodeError::TruncatedHeader),
            FfiDecodeError::from(DecodeError::TruncatedChannel),
            FfiDecodeError::from(DecodeError::BadSampleCount),
            FfiDecodeError::from(DecodeError::TruncatedGps),
            FfiDecodeError::from(DecodeError::TruncatedLaps),
            FfiDecodeError::ChannelOutOfRange {
                index: 3,
                channel_count: 1,
            },
        ] {
            assert!(!err.to_string().is_empty(), "{err:?} has a message");
        }
        assert!(FfiDecodeError::BadMagic.to_string().contains("magic"));
        assert!(FfiDecodeError::ChannelOutOfRange {
            index: 3,
            channel_count: 1
        }
        .to_string()
        .contains("out of range"));

        // The reserved `UnknownUnit` flows through the message-bearing catch-all,
        // preserving the underlying decode message across the boundary (Display
        // renders that message verbatim).
        let mapped = FfiDecodeError::from(DecodeError::UnknownUnit);
        assert!(
            matches!(&mapped, FfiDecodeError::Other { message } if message.contains("unit")),
            "UnknownUnit maps to Other, got {mapped:?}"
        );
        assert!(
            mapped.to_string().contains("unit"),
            "Other renders its message"
        );
    }
}
