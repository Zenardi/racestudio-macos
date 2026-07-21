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
    cumulative_distance, delta_t, resample_uniform, segment_laps,
    segment_times as lap_segment_times, spectrum, stats_over_range, to_distance_grid,
    AnalysisError as CoreAnalysisError, Lap, Stats, Window as FftWindow,
};
use racestudio_decode::{decode_session, DecodeError, Session};
use racestudio_device::{
    ap_mode_fallback as core_ap_mode_fallback,
    build_session_list_request as core_build_session_list_request,
    download_session as core_download_session, parse_discovery as core_parse_discovery,
    parse_session_list as core_parse_session_list, Device as CoreDevice,
    DeviceError as CoreDeviceError, DownloadPlan as CoreDownloadPlan,
    ProgressSink as CoreProgressSink, SessionDate as CoreSessionDate,
    SessionInfo as CoreSessionInfo, Transport as CoreTransport,
};

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

/// One lap's per-segment split times for the Split Times report (issue 8.11):
/// the lap divided into `N` equal-distance segments, and the seconds spent in
/// each (in track order).
#[derive(Debug, Clone, uniffi::Record)]
pub struct LapSegmentTimes {
    /// Zero-based lap index (matches [`LapInfo::index`]).
    pub lap_index: u32,
    /// Seconds spent in each of the `N` segments, in track order. Always sums to
    /// the lap duration.
    pub segment_times: Vec<f64>,
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
    /// Lazily-computed session distance axis (8.2), shared by the distance-domain
    /// accessors so a paged caller does not re-integrate the whole session on
    /// every windowed call.
    distance_axis: OnceLock<DistanceAxis>,
}

/// The session's cumulative distance axis, derived once from `GPS Speed` and
/// cached: `series` is `(timecode, distance)` samples and `times` is the bare
/// timecode column [`to_distance_grid`] interpolates over. Both vecs are empty
/// when the session has no `GPS Speed` channel — then every queried distance is
/// `0`.
#[derive(Debug)]
struct DistanceAxis {
    times: Vec<f64>,
    series: Vec<(f64, f64)>,
}

/// The clamped `[start, start + count)` slice of `items` — an empty slice when
/// `start` is at or past the end, truncated when `count` overruns it (never an
/// over-read). Shared by every windowed index accessor.
fn window<T>(items: &[T], start: u32, count: u32) -> &[T] {
    let start = start as usize;
    if start >= items.len() {
        return &[];
    }
    let end = start.saturating_add(count as usize).min(items.len());
    &items[start..end]
}

impl SessionHandle {
    /// The per-lap segmentation, computed once and cached.
    fn segmented(&self) -> &[Lap] {
        self.segmented_laps
            .get_or_init(|| segment_laps(&self.session))
    }

    /// The session distance axis (`GPS Speed` integrated into cumulative distance
    /// via [`cumulative_distance`]), computed once and cached — mirroring
    /// [`Self::segmented`] so a paged caller does not re-integrate the whole
    /// session on every windowed distance query. Empty when there is no (or an
    /// empty) `GPS Speed` channel.
    fn distance_axis(&self) -> &DistanceAxis {
        self.distance_axis.get_or_init(|| {
            let Some(speed) =
                channel_samples(&self.session, SPEED_CHANNEL).filter(|s| !s.is_empty())
            else {
                return DistanceAxis {
                    times: Vec::new(),
                    series: Vec::new(),
                };
            };
            let times: Vec<f64> = speed.iter().map(|&(t, _)| t).collect();
            let series = times
                .iter()
                .copied()
                .zip(cumulative_distance(speed))
                .collect();
            DistanceAxis { times, series }
        })
    }

    /// The clamped `[start, start + count)` sample window of channel
    /// `channel_index`. Shared by [`Self::samples`] and
    /// [`Self::samples_with_distance`].
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
        Ok(window(channel.samples(), start, count))
    }

    /// The cumulative track distance (m) at each of `timecodes`, by interpolating
    /// the cached session distance axis ([`Self::distance_axis`]) onto that
    /// timebase (reusing [`to_distance_grid`]).
    ///
    /// Total by construction: a session with no `GPS Speed` channel has no
    /// odometer, so every distance is `0`; a non-monotonic speed timebase — which
    /// the decoder does not produce — likewise falls back to zeros rather than
    /// surfacing an error across this boundary.
    fn distance_at(&self, timecodes: &[f64]) -> Vec<f64> {
        let axis = self.distance_axis();
        if axis.series.is_empty() {
            return vec![0.0; timecodes.len()];
        }
        to_distance_grid(&axis.series, &axis.times, timecodes)
            .unwrap_or_else(|_| vec![0.0; timecodes.len()])
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
        let fixes = window(gps.fixes(), start, count);
        let timecodes: Vec<f64> = fixes.iter().map(|fix| fix.timecode_ms).collect();
        let distances = self.distance_at(&timecodes);
        fixes
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

    /// Split every lap into `splits` equal-distance segments and report the time
    /// (seconds) spent in each, lap by lap (issue 8.11) — the raw grid the Split
    /// Times report groups, times, and derives the best theoretical/rolling laps
    /// from.
    ///
    /// One [`LapSegmentTimes`] per session lap, indexed by lap number, each holding
    /// `splits.max(1)` segment times that sum to the lap duration (see
    /// [`racestudio_analysis::segment_times`] for the distance-cut construction and
    /// the GPS-less equal-time fallback). A session with no lap markers returns an
    /// empty vec. Never panics.
    #[must_use]
    pub fn segment_times(&self, splits: u32) -> Vec<LapSegmentTimes> {
        let n = splits.max(1) as usize;
        self.segmented()
            .iter()
            .map(|lap| LapSegmentTimes {
                lap_index: lap.number(),
                segment_times: lap_segment_times(lap, n),
            })
            .collect()
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
        distance_axis: OnceLock::new(),
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

/// A discovered MyChron device carried across the FFI boundary (issue 6.3).
///
/// Mirrors the device crate's [`Device`](racestudio_device::Device); `address` is
/// a string because UniFFI has no `IpAddr` type. Swift receives it as a `struct
/// Device` value.
#[derive(Debug, Clone, uniffi::Record)]
pub struct Device {
    /// Human-readable display name.
    pub name: String,
    /// The device's IP address (e.g. `10.0.0.1`).
    pub address: String,
    /// The TCP port to connect to for control + transfer.
    pub port: u16,
    /// The device family/model (e.g. `MyChron`).
    pub model: String,
}

impl From<CoreDevice> for Device {
    fn from(d: CoreDevice) -> Self {
        Device {
            name: d.name,
            address: d.address.to_string(),
            port: d.port,
            model: d.model,
        }
    }
}

/// The device-discovery failure surface across the FFI boundary — the device
/// crate's [`DeviceError`](racestudio_device::DeviceError).
///
/// Declared `#[uniffi(flat_error)]`: Swift receives a plain `enum DiscoveryError:
/// Error`, so a malformed announcement is a **thrown** typed error, never a trap.
#[derive(Debug, uniffi::Error)]
#[uniffi(flat_error)]
pub enum DiscoveryError {
    /// A discovery record was malformed or truncated.
    MalformedRecord,
    /// No discovery responder was found on the network.
    NoService,
    /// A response frame failed checksum verification (issue 6.4).
    BadChecksum,
    /// A session-list response was truncated or incomplete (issue 6.4).
    TruncatedList,
    /// A session download failed integrity verification — a chunk stayed corrupt
    /// past the retry budget, or the reassembled file failed its whole-file
    /// checksum. No partial file is surfaced as success (issue 6.5).
    ChecksumMismatch,
    /// A session download ended with a gap: the transport signalled end-of-stream
    /// before every byte of the declared size was covered (issue 6.5).
    MissingChunk,
}

impl std::fmt::Display for DiscoveryError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            DiscoveryError::MalformedRecord => write!(f, "malformed discovery record"),
            DiscoveryError::NoService => write!(f, "no discovery responder found"),
            DiscoveryError::BadChecksum => write!(f, "response frame failed checksum verification"),
            DiscoveryError::TruncatedList => write!(f, "truncated or incomplete session list"),
            DiscoveryError::ChecksumMismatch => write!(
                f,
                "download failed whole-file or unrecoverable chunk checksum verification"
            ),
            DiscoveryError::MissingChunk => {
                write!(f, "the session download is missing one or more chunks")
            }
        }
    }
}

impl std::error::Error for DiscoveryError {}

impl From<CoreDeviceError> for DiscoveryError {
    fn from(err: CoreDeviceError) -> Self {
        match err {
            CoreDeviceError::MalformedRecord => DiscoveryError::MalformedRecord,
            CoreDeviceError::NoService => DiscoveryError::NoService,
            CoreDeviceError::BadChecksum => DiscoveryError::BadChecksum,
            CoreDeviceError::TruncatedList => DiscoveryError::TruncatedList,
            CoreDeviceError::ChecksumMismatch => DiscoveryError::ChecksumMismatch,
            CoreDeviceError::MissingChunk => DiscoveryError::MissingChunk,
        }
    }
}

/// Parse recorded/observed AiM discovery-response bytes into typed devices
/// (issue 6.3).
///
/// The AP-mode/replayed discovery path hands the observed response bytes here;
/// the live mDNS/Bonjour browser (Swift `NWBrowser`) maps its results into
/// [`Device`] directly. Returns the de-duplicated devices, or a thrown
/// [`DiscoveryError`] for a malformed announcement — never a trap.
///
/// # Errors
/// [`DiscoveryError::MalformedRecord`] when a record is malformed or truncated.
#[uniffi::export]
pub fn parse_device_discovery(bytes: Vec<u8>) -> Result<Vec<Device>, DiscoveryError> {
    let devices = core_parse_discovery(&bytes)?;
    Ok(devices.into_iter().map(Device::from).collect())
}

/// The AP-mode fallback device: the well-known gateway the MyChron serves on when
/// the Mac has joined its own access point and no mDNS responder is present
/// (issue 6.3).
#[uniffi::export]
#[must_use]
pub fn ap_mode_fallback_device() -> Device {
    core_ap_mode_fallback().into()
}

/// A device-local session timestamp carried across the FFI boundary (issue 6.4).
///
/// A **typed** date (mirrors the device crate's
/// [`SessionDate`](racestudio_device::SessionDate)), not a raw string — Swift
/// receives a `struct SessionDate` value.
#[derive(Debug, Clone, Copy, uniffi::Record)]
pub struct SessionDate {
    /// Four-digit year (e.g. 2026).
    pub year: u16,
    /// Month, 1–12.
    pub month: u8,
    /// Day of month, 1–31.
    pub day: u8,
    /// Hour, 0–23.
    pub hour: u8,
    /// Minute, 0–59.
    pub minute: u8,
    /// Second, 0–59.
    pub second: u8,
}

impl From<CoreSessionDate> for SessionDate {
    fn from(d: CoreSessionDate) -> Self {
        SessionDate {
            year: d.year,
            month: d.month,
            day: d.day,
            hour: d.hour,
            minute: d.minute,
            second: d.second,
        }
    }
}

/// One enumerated on-device session carried across the FFI boundary (issue 6.4).
///
/// Mirrors the device crate's [`SessionInfo`](racestudio_device::SessionInfo);
/// `date` is a typed [`SessionDate`]. Swift receives it as a `struct SessionInfo`.
#[derive(Debug, Clone, uniffi::Record)]
pub struct SessionInfo {
    /// The device-local session id / index.
    pub id: u32,
    /// The session's display name.
    pub name: String,
    /// The session start timestamp (device-local).
    pub date: SessionDate,
    /// Number of recorded laps.
    pub lap_count: u16,
    /// On-device size of the session's data, in bytes.
    pub size_bytes: u32,
}

impl From<CoreSessionInfo> for SessionInfo {
    fn from(s: CoreSessionInfo) -> Self {
        SessionInfo {
            id: s.id,
            name: s.name,
            date: s.date.into(),
            lap_count: s.lap_count,
            size_bytes: s.size_bytes,
        }
    }
}

/// Build the catalog/session-list request bytes the MyChron answers with its
/// session catalog (issue 6.4) — the observed request frame (`command_info.bin`).
///
/// Swift receives it as `Data` and writes it to the control connection (6.5).
#[uniffi::export]
#[must_use]
pub fn build_session_list_request() -> Vec<u8> {
    core_build_session_list_request()
}

/// Parse a recorded/observed catalog/session-list response into typed sessions
/// (issue 6.4).
///
/// The response frame's checksum is verified before parsing; an empty on-device
/// store yields an empty list. Returns a thrown [`DiscoveryError`] for a bad
/// checksum, a truncated list, or a malformed record — never a trap.
///
/// # Errors
/// [`DiscoveryError::BadChecksum`], [`DiscoveryError::TruncatedList`], or
/// [`DiscoveryError::MalformedRecord`] mapped from the device crate.
#[uniffi::export]
pub fn parse_session_list(bytes: Vec<u8>) -> Result<Vec<SessionInfo>, DiscoveryError> {
    let sessions = core_parse_session_list(&bytes)?;
    Ok(sessions.into_iter().map(SessionInfo::from).collect())
}

/// What to download, carried across the FFI boundary (issue 6.5).
///
/// Mirrors the device crate's [`DownloadPlan`](racestudio_device::DownloadPlan):
/// the `session_id` and `total_len` come from the 6.4 catalog
/// ([`SessionInfo`]), and `whole_file_checksum` is verified after reassembly.
#[derive(Debug, Clone, Copy, uniffi::Record)]
pub struct DownloadPlan {
    /// The device-local id of the session to download.
    pub session_id: u32,
    /// The session's total size in bytes; the reassembled output must cover
    /// exactly this many bytes.
    pub total_len: u64,
    /// The expected whole-file STCP checksum, verified after reassembly.
    pub whole_file_checksum: u16,
}

/// A foreign-implemented source of download chunk frames (issue 6.5).
///
/// Swift's live TCP transport (`NWConnection`) implements this: it sends the read
/// commands and returns each raw STCP chunk frame the device replies with, or
/// `nil` at end-of-stream. A recorded implementation replays fixture bytes so a
/// download can be driven with no live device.
#[uniffi::export(callback_interface)]
pub trait ChunkSource: Send + Sync {
    /// Return the next raw STCP chunk frame, or `None` at end-of-stream.
    fn next_chunk(&self) -> Option<Vec<u8>>;
}

/// A foreign-implemented sink for download progress (issue 6.5).
///
/// The 6.7 device panel implements this to drive a progress bar: it is called
/// with a leading `(0, total)` sample and then after each chunk that covers new
/// bytes, with `bytes_done` monotonically reaching `total` on completion.
#[uniffi::export(callback_interface)]
pub trait DownloadProgress: Send + Sync {
    /// Report that `bytes_done` of `total` bytes have been reassembled.
    fn on_progress(&self, bytes_done: u64, total: u64);
}

/// Bridges a foreign [`ChunkSource`] to the device crate's [`CoreTransport`].
struct ChunkSourceAdapter(Box<dyn ChunkSource>);

impl CoreTransport for ChunkSourceAdapter {
    fn next_chunk(&mut self) -> Result<Option<Vec<u8>>, CoreDeviceError> {
        // A foreign source signals both "no more data" and transport failure as
        // `None`; an incomplete transfer then surfaces as `MissingChunk`.
        Ok(self.0.next_chunk())
    }
}

/// Bridges a foreign [`DownloadProgress`] to the device crate's [`CoreProgressSink`].
struct ProgressAdapter(Box<dyn DownloadProgress>);

impl CoreProgressSink for ProgressAdapter {
    fn on_progress(&mut self, bytes_done: u64, total: u64) {
        self.0.on_progress(bytes_done, total);
    }
}

/// Download a session by reassembling its chunk stream, verifying integrity
/// (issue 6.5).
///
/// Pulls raw chunk frames from `source` (the injected transport), verifies each
/// chunk's checksum (retrying a corrupt chunk), reassembles by offset, and gates
/// the result on the whole-file checksum before returning it — so a corrupt or
/// incomplete transfer never masquerades as a good file. Progress is reported to
/// `progress` so a UI can render a progress bar.
///
/// # Errors
/// A thrown [`DiscoveryError`] — `ChecksumMismatch` (unrecoverable corruption),
/// `MissingChunk` (the stream ended with a gap, or only non-progressing chunks
/// arrived), `TruncatedList` (a chunk frame was incomplete/unverifiable), or
/// `MalformedRecord` (a chunk overran the declared size). Never traps.
#[uniffi::export]
pub fn download_session(
    plan: DownloadPlan,
    source: Box<dyn ChunkSource>,
    progress: Box<dyn DownloadProgress>,
) -> Result<Vec<u8>, DiscoveryError> {
    let core_plan = CoreDownloadPlan {
        session_id: plan.session_id,
        total_len: plan.total_len,
        whole_file_checksum: plan.whole_file_checksum,
    };
    let mut adapted_source = ChunkSourceAdapter(source);
    let mut adapted_progress = ProgressAdapter(progress);
    core_download_session(&core_plan, &mut adapted_source, &mut adapted_progress)
        .map_err(DiscoveryError::from)
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
            distance_axis: OnceLock::new(),
        }
    }

    /// A GPS-less handle over the given CHS channels **and** lap markers — enough
    /// to exercise the lap-based accessors (segment times, 8.11) deterministically,
    /// with `GPS Speed` synthesised as a plain channel so the per-lap distance axis
    /// is fully under the test's control.
    fn handle_with_laps(
        channels: Vec<Channel>,
        laps: Vec<racestudio_decode::Lap>,
    ) -> SessionHandle {
        SessionHandle {
            session: Session::new(
                Metadata::default(),
                channels,
                None,
                LapData::new(laps),
                None,
            ),
            segmented_laps: OnceLock::new(),
            distance_axis: OnceLock::new(),
        }
    }

    #[test]
    fn test_segment_times_partitions_each_lap_and_conserves_duration() {
        // Two 5 s laps over a 10 m/s `GPS Speed` stream. Each lap is cut into 4
        // equal-distance segments; whatever the exact cuts, every lap yields one row
        // (indexed by lap number) of 4 segment times that sum to the 5 s duration.
        let speed = channel(
            SPEED_CHANNEL,
            &(0..20)
                .map(|i| (i as f64 * 500.0, 10.0))
                .collect::<Vec<_>>(),
        );
        let laps = vec![
            racestudio_decode::Lap::new(0, 0.0, 5.0),
            racestudio_decode::Lap::new(1, 5.0, 5.0),
        ];
        let handle = handle_with_laps(vec![speed], laps);

        let rows = handle.segment_times(4);

        assert_eq!(rows.len(), 2, "one row per lap");
        assert_eq!(rows[0].lap_index, 0);
        assert_eq!(rows[1].lap_index, 1);
        for row in &rows {
            assert_eq!(row.segment_times.len(), 4, "4 segments per lap");
            assert!(row.segment_times.iter().all(|&t| t >= 0.0));
            let total: f64 = row.segment_times.iter().sum();
            assert!(
                (total - 5.0).abs() < 1e-9,
                "segments sum to the 5 s duration, got {total}"
            );
        }
    }

    #[test]
    fn test_segment_times_clamps_zero_splits_and_is_empty_without_laps() {
        // A 0 request collapses to a single whole-lap segment (never an empty inner
        // vec); a session with no lap markers yields no rows at all.
        let speed = channel(
            SPEED_CHANNEL,
            &[(0.0, 10.0), (1000.0, 10.0), (2000.0, 10.0)],
        );
        let one_lap = handle_with_laps(vec![speed], vec![racestudio_decode::Lap::new(0, 0.0, 2.0)]);
        let rows = one_lap.segment_times(0);
        assert_eq!(rows.len(), 1);
        assert_eq!(
            rows[0].segment_times.len(),
            1,
            "0 splits → one whole-lap segment"
        );
        assert!((rows[0].segment_times[0] - 2.0).abs() < 1e-9);

        let no_laps = handle_with_channels(vec![channel("AX", &[(0.0, 1.0)])]);
        assert!(no_laps.segment_times(4).is_empty());
    }

    #[test]
    fn test_segment_times_on_real_session_conserves_each_lap_duration() {
        let Some(path) = xrk_or_skip("aim_official_test.xrk") else {
            return;
        };
        let handle = open_session(path.to_string_lossy().into_owned()).expect("decode");
        let laps = handle.laps();

        let rows = handle.segment_times(6);

        assert_eq!(rows.len(), laps.len(), "one row per decoded lap");
        for (row, lap) in rows.iter().zip(&laps) {
            assert_eq!(row.lap_index, lap.index);
            assert_eq!(row.segment_times.len(), 6);
            let total: f64 = row.segment_times.iter().sum();
            assert!(
                (total - lap.duration_s).abs() < 1e-6,
                "lap {} segments sum to its {} s duration, got {total}",
                lap.index,
                lap.duration_s
            );
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

    /// The recorded, de-identified discovery response fixture (issue 6.2/6.3).
    fn recorded_discovery_response() -> Vec<u8> {
        let path = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
            .join("../../fixtures/device/discovery/response.bin");
        std::fs::read(path).expect("discovery response fixture must exist")
    }

    #[test]
    fn test_parse_device_discovery_maps_core_device_across_boundary() {
        // The recorded response crosses the boundary as a typed Device with the
        // IpAddr rendered to a string.
        let devices =
            parse_device_discovery(recorded_discovery_response()).expect("fixture parses");
        assert_eq!(devices.len(), 1);
        let device = &devices[0];
        assert_eq!(device.address, "10.0.0.1");
        assert_eq!(device.port, 2000);
        assert_eq!(device.model, "MyChron");
        assert!(!device.name.is_empty());
    }

    #[test]
    fn test_parse_device_discovery_throws_on_malformed() {
        // A truncated buffer is a thrown DiscoveryError, never a trap.
        let err = parse_device_discovery(vec![0x01, 0x02, 0x03]).unwrap_err();
        assert!(matches!(err, DiscoveryError::MalformedRecord));
    }

    #[test]
    fn test_ap_mode_fallback_device_is_the_gateway() {
        let device = ap_mode_fallback_device();
        assert_eq!(device.address, "10.0.0.1");
        assert_eq!(device.port, 2000);
        assert_eq!(device.model, "MyChron");
    }

    #[test]
    fn test_discovery_error_maps_and_renders() {
        // Both core variants map to the FFI enum and render a distinct message.
        assert!(matches!(
            DiscoveryError::from(CoreDeviceError::MalformedRecord),
            DiscoveryError::MalformedRecord
        ));
        assert!(matches!(
            DiscoveryError::from(CoreDeviceError::NoService),
            DiscoveryError::NoService
        ));
        assert_ne!(
            DiscoveryError::MalformedRecord.to_string(),
            DiscoveryError::NoService.to_string()
        );
        assert!(!DiscoveryError::NoService.to_string().is_empty());
    }

    /// The recorded, de-identified catalog/session-list response (issue 6.2/6.4).
    fn recorded_session_list() -> Vec<u8> {
        let path = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
            .join("../../fixtures/device/sessions/list_response.bin");
        std::fs::read(path).expect("session-list fixture must exist")
    }

    #[test]
    fn test_build_session_list_request_matches_captured_request() {
        // The FFI-built request equals the captured catalog request byte-for-byte.
        let path = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
            .join("../../fixtures/device/control/command_info.bin");
        let captured = std::fs::read(path).expect("command fixture must exist");
        assert_eq!(build_session_list_request(), captured);
    }

    #[test]
    fn test_parse_session_list_over_recorded_fixture_is_empty() {
        // The recorded store was empty at capture time → an empty list, not an error.
        let sessions = parse_session_list(recorded_session_list()).expect("fixture parses");
        assert!(sessions.is_empty());
    }

    #[test]
    fn test_parse_session_list_maps_dated_sessions_across_boundary() {
        // A synthetic dated session frame crosses the boundary as a typed
        // SessionInfo with a typed SessionDate (see racestudio-device session_test
        // for the layout). Built here so the FFI mapping is exercised end-to-end.
        let mut record = [0u8; 56];
        record[0..3].copy_from_slice(b"ses");
        record[3] = 0x01;
        record[4..8].copy_from_slice(&42u32.to_le_bytes());
        record[8..10].copy_from_slice(&2026u16.to_le_bytes());
        record[10] = 7; // month
        record[11] = 21; // day
        record[12] = 8; // hour
        record[13] = 15; // minute
        record[14] = 30; // second
        record[16..18].copy_from_slice(&9u16.to_le_bytes()); // laps
        record[18..22].copy_from_slice(&1_234_567u32.to_le_bytes()); // size
        record[24..29].copy_from_slice(b"Karts");

        let mut payload = Vec::new();
        payload.extend_from_slice(&1u32.to_le_bytes()); // count
        payload.extend_from_slice(&record);
        let mut frame = Vec::new();
        frame.extend_from_slice(b"<hSTCP");
        frame.extend_from_slice(&(payload.len() as u32).to_le_bytes());
        frame.push(0);
        frame.push(b'>');
        frame.extend_from_slice(&payload);
        frame.extend_from_slice(b"<STCP");
        frame.extend_from_slice(&racestudio_device::stcp_checksum(&payload).to_le_bytes());
        frame.push(b'>');

        let sessions = parse_session_list(frame).expect("synthetic frame parses");
        assert_eq!(sessions.len(), 1);
        let s = &sessions[0];
        assert_eq!(s.id, 42);
        assert_eq!(s.name, "Karts");
        assert_eq!(s.lap_count, 9);
        assert_eq!(s.size_bytes, 1_234_567);
        assert_eq!(s.date.year, 2026);
        assert_eq!(s.date.month, 7);
        assert_eq!(s.date.day, 21);
        assert_eq!(s.date.second, 30);
    }

    #[test]
    fn test_parse_session_list_throws_on_bad_checksum() {
        // A corrupt frame is a thrown DiscoveryError, never a trap.
        let mut frame = recorded_session_list();
        let payload_start = b"<hSTCP".len() + 6;
        frame[payload_start + 8] ^= 0xFF;
        let err = parse_session_list(frame).unwrap_err();
        assert!(matches!(err, DiscoveryError::BadChecksum));
    }

    #[test]
    fn test_session_error_variants_map_and_render() {
        // The two 6.4 variants map from the core error and render distinct messages.
        assert!(matches!(
            DiscoveryError::from(CoreDeviceError::BadChecksum),
            DiscoveryError::BadChecksum
        ));
        assert!(matches!(
            DiscoveryError::from(CoreDeviceError::TruncatedList),
            DiscoveryError::TruncatedList
        ));
        assert_ne!(
            DiscoveryError::BadChecksum.to_string(),
            DiscoveryError::TruncatedList.to_string()
        );
        assert!(!DiscoveryError::TruncatedList.to_string().is_empty());
    }

    // ---- 6.5 chunked download over the FFI boundary ------------------------

    /// Frame one download chunk: payload = `offset(u32 LE) || data`, wrapped in a
    /// checksum-valid STCP frame (mirrors the device crate's chunk framing).
    fn download_chunk_frame(offset: u32, data: &[u8]) -> Vec<u8> {
        let mut payload = Vec::new();
        payload.extend_from_slice(&offset.to_le_bytes());
        payload.extend_from_slice(data);
        let mut frame = Vec::new();
        frame.extend_from_slice(b"<hSTCP");
        frame.extend_from_slice(&(payload.len() as u32).to_le_bytes());
        frame.push(0);
        frame.push(b'>');
        frame.extend_from_slice(&payload);
        frame.extend_from_slice(b"<STCP");
        frame.extend_from_slice(&racestudio_device::stcp_checksum(&payload).to_le_bytes());
        frame.push(b'>');
        frame
    }

    /// A `ChunkSource` that replays a queue of pre-framed chunks.
    struct FakeSource {
        queue: std::sync::Mutex<std::collections::VecDeque<Vec<u8>>>,
    }
    impl FakeSource {
        fn new(frames: Vec<Vec<u8>>) -> Self {
            Self {
                queue: std::sync::Mutex::new(frames.into()),
            }
        }
    }
    impl ChunkSource for FakeSource {
        fn next_chunk(&self) -> Option<Vec<u8>> {
            self.queue.lock().expect("queue lock").pop_front()
        }
    }

    /// A `DownloadProgress` that records every `(bytes_done, total)` sample.
    #[derive(Default)]
    struct FakeProgress {
        events: std::sync::Mutex<Vec<(u64, u64)>>,
    }
    impl DownloadProgress for std::sync::Arc<FakeProgress> {
        fn on_progress(&self, bytes_done: u64, total: u64) {
            self.events
                .lock()
                .expect("events lock")
                .push((bytes_done, total));
        }
    }

    #[test]
    fn test_ffi_download_reassembles_and_reports_progress() {
        // A three-chunk transfer reassembles through the real core and the
        // foreign progress sink sees monotonic bytes reaching 100%.
        let payload: Vec<u8> = (0..250u32).map(|i| i as u8).collect();
        let frames = vec![
            download_chunk_frame(0, &payload[0..100]),
            download_chunk_frame(100, &payload[100..200]),
            download_chunk_frame(200, &payload[200..]),
        ];
        let progress = std::sync::Arc::new(FakeProgress::default());
        let plan = DownloadPlan {
            session_id: 5,
            total_len: payload.len() as u64,
            whole_file_checksum: racestudio_device::stcp_checksum(&payload),
        };

        let out = download_session(
            plan,
            Box::new(FakeSource::new(frames)),
            Box::new(std::sync::Arc::clone(&progress)),
        )
        .expect("download reassembles across the boundary");

        assert_eq!(out, payload);
        let events = progress.events.lock().expect("events");
        assert_eq!(
            events.last().copied(),
            Some((payload.len() as u64, payload.len() as u64)),
            "progress reaches 100%"
        );
    }

    #[test]
    fn test_ffi_download_unrecoverable_checksum_maps() {
        // A chunk that stays corrupt past the retry budget maps to ChecksumMismatch.
        let payload: Vec<u8> = (0..64u8).collect();
        let mut corrupt = download_chunk_frame(0, &payload);
        let n = corrupt.len();
        corrupt[n - 2] ^= 0xFF;
        let frames = vec![corrupt.clone(); 5]; // > MAX_CHUNK_RETRIES deliveries
        let progress = std::sync::Arc::new(FakeProgress::default());
        let plan = DownloadPlan {
            session_id: 1,
            total_len: 64,
            whole_file_checksum: 0,
        };

        let err = download_session(
            plan,
            Box::new(FakeSource::new(frames)),
            Box::new(std::sync::Arc::clone(&progress)),
        )
        .unwrap_err();

        assert!(matches!(err, DiscoveryError::ChecksumMismatch));
    }

    #[test]
    fn test_ffi_download_missing_chunk_maps() {
        // A stream that ends before full coverage maps to MissingChunk.
        let payload: Vec<u8> = (0..200u8).collect();
        let frames = vec![download_chunk_frame(0, &payload[0..100])]; // only the first half
        let progress = std::sync::Arc::new(FakeProgress::default());
        let plan = DownloadPlan {
            session_id: 1,
            total_len: 200,
            whole_file_checksum: 0,
        };

        let err = download_session(
            plan,
            Box::new(FakeSource::new(frames)),
            Box::new(std::sync::Arc::clone(&progress)),
        )
        .unwrap_err();

        assert!(matches!(err, DiscoveryError::MissingChunk));
    }

    #[test]
    fn test_download_error_variants_map_and_render() {
        assert!(matches!(
            DiscoveryError::from(CoreDeviceError::ChecksumMismatch),
            DiscoveryError::ChecksumMismatch
        ));
        assert!(matches!(
            DiscoveryError::from(CoreDeviceError::MissingChunk),
            DiscoveryError::MissingChunk
        ));
        assert_ne!(
            DiscoveryError::ChecksumMismatch.to_string(),
            DiscoveryError::MissingChunk.to_string()
        );
        assert!(!DiscoveryError::MissingChunk.to_string().is_empty());
    }
}
