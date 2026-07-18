//! Lap segmentation & alignment (issue 3.1).
//!
//! [`segment_laps`] turns a decoded [`Session`] into per-lap [`Lap`] views: each
//! lap carries its number, its half-open `[start, end)` time window (ms), and
//! every channel (CHS-backed and GPS) sliced to that window. On top of those:
//!
//! - [`distance_axis`] integrates a speed channel with the trapezoidal rule into
//!   a cumulative, monotonically non-decreasing distance axis.
//! - [`align_by_time`] pairs two laps' samples on a common time-from-lap-start
//!   axis (lap `a` is the reference; lap `b` is linearly interpolated onto it).
//! - [`align_by_distance`] pairs them on a common distance axis, truncated to the
//!   shorter lap.
//!
//! The interpolation here is a small local `lerp`; the general resampler (issue
//! 3.3) and the delta-t metric (3.2) are out of scope. Nothing panics on caller
//! input — missing/empty channels surface as [`AnalysisError`].

use racestudio_decode::Session;

use crate::error::AnalysisError;
use crate::math::{cumulative_trapezoid, interp};

/// The channel integrated to distance for distance-domain work. AiM's GPS-derived
/// ground speed (m/s); see [`align_by_distance`]. Held constant because the
/// align API takes only the *value* channel to compare, not the speed source.
/// Shared with delta-t (3.2).
pub(crate) const SPEED_CHANNEL: &str = "GPS Speed";

/// The domain a pair of laps is aligned on.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum LapAxis {
    /// Time measured from each lap's start (milliseconds).
    Time,
    /// Cumulative distance from each lap's start.
    Distance,
}

/// One channel's samples within a single lap: `(timecode_ms, value)`, in
/// chronological order.
#[derive(Debug, Clone, PartialEq)]
pub struct LapChannel {
    name: String,
    samples: Vec<(f64, f64)>,
}

impl LapChannel {
    /// Build a lap channel from its name and `(timecode_ms, value)` samples.
    #[must_use]
    pub fn new(name: impl Into<String>, samples: Vec<(f64, f64)>) -> Self {
        Self {
            name: name.into(),
            samples,
        }
    }

    /// The channel name.
    #[must_use]
    pub fn name(&self) -> &str {
        &self.name
    }

    /// The `(timecode_ms, value)` samples.
    #[must_use]
    pub fn samples(&self) -> &[(f64, f64)] {
        &self.samples
    }
}

/// A per-lap view: the lap number, its half-open `[start, end)` time window (ms),
/// and every channel sliced to that window.
#[derive(Debug, Clone, PartialEq)]
pub struct Lap {
    number: u32,
    start_time_ms: f64,
    end_time_ms: f64,
    channels: Vec<LapChannel>,
}

impl Lap {
    /// Build a lap view from its number, half-open `[start, end)` ms window, and
    /// sliced channels.
    #[must_use]
    pub fn new(
        number: u32,
        start_time_ms: f64,
        end_time_ms: f64,
        channels: Vec<LapChannel>,
    ) -> Self {
        Self {
            number,
            start_time_ms,
            end_time_ms,
            channels,
        }
    }

    /// Zero-based lap number within the session.
    #[must_use]
    pub fn number(&self) -> u32 {
        self.number
    }

    /// Session-relative lap start in milliseconds (inclusive).
    #[must_use]
    pub fn start_time_ms(&self) -> f64 {
        self.start_time_ms
    }

    /// Session-relative lap end in milliseconds (exclusive).
    #[must_use]
    pub fn end_time_ms(&self) -> f64 {
        self.end_time_ms
    }

    /// Lap duration in milliseconds (`end - start`).
    #[must_use]
    pub fn duration_ms(&self) -> f64 {
        self.end_time_ms - self.start_time_ms
    }

    /// The lap's channels, in session order.
    #[must_use]
    pub fn channels(&self) -> &[LapChannel] {
        &self.channels
    }

    /// The channel with the given name, if present in this lap.
    #[must_use]
    pub fn channel(&self, name: &str) -> Option<&LapChannel> {
        self.channels.iter().find(|c| c.name == name)
    }
}

/// Two laps' channel samples paired on a shared axis (time or distance).
#[derive(Debug, Clone, PartialEq)]
pub struct Alignment {
    axis_kind: LapAxis,
    axis: Vec<f64>,
    a: Vec<f64>,
    b: Vec<f64>,
}

impl Alignment {
    /// Whether the shared axis is time-from-lap-start or cumulative distance.
    #[must_use]
    pub fn axis_kind(&self) -> LapAxis {
        self.axis_kind
    }

    /// The shared axis values (time-from-start ms, or cumulative distance).
    #[must_use]
    pub fn axis(&self) -> &[f64] {
        &self.axis
    }

    /// Lap `a`'s channel values, one per axis point.
    #[must_use]
    pub fn a(&self) -> &[f64] {
        &self.a
    }

    /// Lap `b`'s channel values, one per axis point.
    #[must_use]
    pub fn b(&self) -> &[f64] {
        &self.b
    }

    /// Number of paired samples (axis length).
    #[must_use]
    pub fn len(&self) -> usize {
        self.axis.len()
    }

    /// Whether there are no paired samples.
    #[must_use]
    pub fn is_empty(&self) -> bool {
        self.axis.is_empty()
    }
}

/// Segment a decoded [`Session`] into per-lap views.
///
/// One [`Lap`] is produced per beacon lap marker (1.5), in order. Each carries
/// every channel — CHS-backed ([`Session::channels`]) and GPS
/// ([`Session::gps`]) — sliced to the lap's half-open `[start, end)` millisecond
/// window. A session with no lap markers returns an empty vector (not an error).
#[must_use]
pub fn segment_laps(session: &Session) -> Vec<Lap> {
    let sources = channel_sources(session);
    session
        .laps()
        .laps()
        .iter()
        .map(|lap| {
            let start_ms = lap.start_time_s() * 1000.0;
            let end_ms = lap.end_time_s() * 1000.0;
            let channels = sources
                .iter()
                .map(|(name, samples)| {
                    LapChannel::new(*name, slice_samples(samples, start_ms, end_ms))
                })
                .collect();
            Lap::new(lap.index(), start_ms, end_ms, channels)
        })
        .collect()
}

/// The cumulative distance (m) at each sample of a `(timecode_ms, value)` speed
/// series (m/s), by the trapezoidal rule with each step's area floored at `0`, so
/// the axis is guaranteed monotonically non-decreasing (one value per sample,
/// starting at `0`). This is the session-wide odometer the distance-mode plots
/// and the track map (8.2) read; an empty series yields an empty axis.
///
/// Clamping matches [`distance_axis`]: a spurious negative speed cannot make the
/// distance dip, keeping the axis usable as the monotonic grid
/// [`to_distance_grid`](crate::to_distance_grid) requires.
#[must_use]
pub fn cumulative_distance(speed: &[(f64, f64)]) -> Vec<f64> {
    cumulative_trapezoid(speed, true)
}

/// The cumulative distance axis for `lap`, integrating `speed_channel` over time
/// with the trapezoidal rule (one distance value per speed sample, starting at
/// `0`). A non-negative speed channel yields a monotonically non-decreasing axis.
///
/// Returns an empty axis when the lap has no such channel — callers that require
/// the channel (e.g. [`align_by_distance`]) surface a typed error instead.
#[must_use]
pub fn distance_axis(lap: &Lap, speed_channel: &str) -> Vec<f64> {
    lap.channel(speed_channel)
        .map(|channel| cumulative_distance(channel.samples()))
        .unwrap_or_default()
}

/// Pair two laps' `channel` samples on a common time-from-lap-start axis.
///
/// Lap `a` is the reference: the axis is its `channel` sample times re-based to
/// its own start, `a`'s values sit on it directly, and `b`'s values are linearly
/// interpolated onto it.
///
/// # Errors
/// - [`AnalysisError::MissingChannel`] if `channel` is absent from either lap.
/// - [`AnalysisError::EmptyLap`] if either lap has no samples for `channel`.
pub fn align_by_time(a: &Lap, b: &Lap, channel: &str) -> Result<Alignment, AnalysisError> {
    let channel_a = require_channel(a, channel)?;
    let channel_b = require_channel(b, channel)?;
    if channel_a.samples().is_empty() || channel_b.samples().is_empty() {
        return Err(AnalysisError::EmptyLap);
    }
    let (axis, a_values) = rebased(channel_a.samples(), a.start_time_ms());
    let (b_times, b_values) = rebased(channel_b.samples(), b.start_time_ms());
    let b_on_axis = axis
        .iter()
        .map(|&t| interp(&b_times, &b_values, t))
        .collect();
    Ok(Alignment {
        axis_kind: LapAxis::Time,
        axis,
        a: a_values,
        b: b_on_axis,
    })
}

/// Pair two laps' `channel` samples on a common distance axis.
///
/// Each lap's samples are placed on a distance axis derived by integrating its
/// [`SPEED_CHANNEL`] (see [`distance_axis`]). The **shorter** lap (fewer samples)
/// defines the shared grid, so the result spans `0..min(len_a, len_b)` and is
/// truncated to it; both laps' values are interpolated onto that grid.
///
/// # Errors
/// - [`AnalysisError::MissingChannel`] if `channel` — or the speed channel — is
///   absent from either lap.
/// - [`AnalysisError::EmptyLap`] if either lap has no samples for `channel`.
pub fn align_by_distance(a: &Lap, b: &Lap, channel: &str) -> Result<Alignment, AnalysisError> {
    let (distances_a, values_a) = value_vs_distance(a, channel)?;
    let (distances_b, values_b) = value_vs_distance(b, channel)?;
    if distances_a.is_empty() || distances_b.is_empty() {
        return Err(AnalysisError::EmptyLap);
    }
    // The shorter lap defines the shared distance grid (truncating to it).
    let axis = if distances_a.len() <= distances_b.len() {
        distances_a.clone()
    } else {
        distances_b.clone()
    };
    let a_on_axis = axis
        .iter()
        .map(|&d| interp(&distances_a, &values_a, d))
        .collect();
    let b_on_axis = axis
        .iter()
        .map(|&d| interp(&distances_b, &values_b, d))
        .collect();
    Ok(Alignment {
        axis_kind: LapAxis::Distance,
        axis,
        a: a_on_axis,
        b: b_on_axis,
    })
}

// --------------------------------------------------------------------------- //
// Internals
// --------------------------------------------------------------------------- //

/// Every channel of a session as `(name, samples)` — CHS-backed channels first,
/// then GPS channels (which carry the speed used for distance).
fn channel_sources(session: &Session) -> Vec<(&str, &[(f64, f64)])> {
    let mut sources: Vec<(&str, &[(f64, f64)])> = session
        .channels()
        .iter()
        .map(|channel| (channel.name(), channel.samples()))
        .collect();
    if let Some(gps) = session.gps() {
        sources.extend(gps.channels().iter().map(|c| (c.name(), c.samples())));
    }
    sources
}

/// The samples whose timecode falls in the half-open window `[start_ms, end_ms)`.
fn slice_samples(samples: &[(f64, f64)], start_ms: f64, end_ms: f64) -> Vec<(f64, f64)> {
    samples
        .iter()
        .copied()
        .filter(|&(t, _)| t >= start_ms && t < end_ms)
        .collect()
}

/// A channel's samples split into re-based times (`t - start_ms`) and values.
fn rebased(samples: &[(f64, f64)], start_ms: f64) -> (Vec<f64>, Vec<f64>) {
    let times = samples.iter().map(|&(t, _)| t - start_ms).collect();
    let values = samples.iter().map(|&(_, v)| v).collect();
    (times, values)
}

/// A lap's `channel` placed on its own distance axis: `(distances, values)`,
/// where each value sample's distance is read from the speed-integrated axis at
/// that sample's time.
fn value_vs_distance(lap: &Lap, channel: &str) -> Result<(Vec<f64>, Vec<f64>), AnalysisError> {
    let speed = require_channel(lap, SPEED_CHANNEL)?;
    let value = require_channel(lap, channel)?;
    let cumulative = cumulative_trapezoid(speed.samples(), true);
    let speed_times: Vec<f64> = speed.samples().iter().map(|&(t, _)| t).collect();
    let distances = value
        .samples()
        .iter()
        .map(|&(t, _)| interp(&speed_times, &cumulative, t))
        .collect();
    let values = value.samples().iter().map(|&(_, v)| v).collect();
    Ok((distances, values))
}

/// Look up a channel by name, or fail with [`AnalysisError::MissingChannel`].
fn require_channel<'a>(lap: &'a Lap, name: &str) -> Result<&'a LapChannel, AnalysisError> {
    lap.channel(name)
        .ok_or_else(|| AnalysisError::MissingChannel {
            name: name.to_string(),
        })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_slice_samples_is_half_open() {
        let samples = [(0.0, 1.0), (10.0, 2.0), (20.0, 3.0), (30.0, 4.0)];
        // [10, 30): includes 10 and 20, excludes 30.
        let sliced = slice_samples(&samples, 10.0, 30.0);
        assert_eq!(sliced, vec![(10.0, 2.0), (20.0, 3.0)]);
    }

    #[test]
    fn test_rebased_subtracts_start() {
        let (times, values) = rebased(&[(1000.0, 1.0), (1100.0, 2.0)], 1000.0);
        assert_eq!(times, vec![0.0, 100.0]);
        assert_eq!(values, vec![1.0, 2.0]);
    }
}
