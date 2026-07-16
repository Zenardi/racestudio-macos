//! Channel statistics (issue 3.4): summary statistics for a channel over the
//! whole session, a single lap, or an arbitrary windowed `[t0, t1)` range.
//!
//! [`channel_stats`] reduces a value slice to a [`Stats`] — min, max, mean,
//! standard deviation (population *and* sample), RMS, count, and range.
//! [`stats_over_range`] restricts to a half-open time window (left edge
//! included, right edge excluded — the slicing convention shared with lap
//! segmentation, 3.1). [`stats_per_lap`] applies that per lap.
//!
//! **Numerical stability.** Mean and variance use Welford's online algorithm, so
//! a large constant offset does not cause the catastrophic cancellation a
//! single-pass `Σx² − (Σx)²/n` would. RMS is recovered from the same moments as
//! `√(var_pop + mean²)` rather than a separate large accumulator.
//!
//! **`NaN` policy.** Non-finite samples — the hole markers resampling (3.3) can
//! introduce — are ignored, never propagated: they are excluded from the count
//! and every statistic. A range with no finite samples (empty slice, empty
//! window, or all-`NaN`) is [`AnalysisError::EmptyRange`], never a `NaN` result.
//!
//! **Population vs sample.** [`Stats::std_pop`] divides the variance by `n`;
//! [`Stats::std_sample`] by `n − 1` and is defined as `0.0` for a single sample
//! (never `NaN`).

use racestudio_decode::Session;

use crate::error::AnalysisError;
use crate::laps::segment_laps;

/// Summary statistics over a set of finite samples (issue 3.4).
///
/// Every field is derived from the finite samples only; see the module docs for
/// the `NaN` policy and the population-vs-sample standard-deviation convention.
#[derive(Debug, Clone, PartialEq)]
pub struct Stats {
    count: usize,
    min: f64,
    max: f64,
    mean: f64,
    std_pop: f64,
    std_sample: f64,
    rms: f64,
    range: f64,
}

impl Stats {
    /// Number of finite samples the statistics were computed over.
    #[must_use]
    pub fn count(&self) -> usize {
        self.count
    }

    /// Smallest sample value.
    #[must_use]
    pub fn min(&self) -> f64 {
        self.min
    }

    /// Largest sample value.
    #[must_use]
    pub fn max(&self) -> f64 {
        self.max
    }

    /// Arithmetic mean.
    #[must_use]
    pub fn mean(&self) -> f64 {
        self.mean
    }

    /// Population standard deviation (variance divided by `n`).
    #[must_use]
    pub fn std_pop(&self) -> f64 {
        self.std_pop
    }

    /// Sample standard deviation (variance divided by `n − 1`); `0.0` for a
    /// single sample, never `NaN`.
    #[must_use]
    pub fn std_sample(&self) -> f64 {
        self.std_sample
    }

    /// Root mean square (quadratic mean) of the samples.
    #[must_use]
    pub fn rms(&self) -> f64 {
        self.rms
    }

    /// Peak-to-peak span, `max − min`.
    #[must_use]
    pub fn range(&self) -> f64 {
        self.range
    }
}

/// Summary statistics for a channel's `values`, ignoring non-finite samples.
///
/// # Errors
/// [`AnalysisError::EmptyRange`] when there are no finite samples (an empty
/// slice or an all-`NaN` slice).
pub fn channel_stats(values: &[f64]) -> Result<Stats, AnalysisError> {
    accumulate(values.iter().copied())
}

/// Summary statistics for the samples of `series` whose timecode falls in the
/// half-open window `[t0, t1)` — left edge included, right edge excluded
/// (matching lap segmentation, 3.1, and libxrk's `filter_by_time_range`).
///
/// # Errors
/// [`AnalysisError::EmptyRange`] when the window selects no finite samples.
pub fn stats_over_range(series: &[(f64, f64)], t0: f64, t1: f64) -> Result<Stats, AnalysisError> {
    accumulate(
        series
            .iter()
            .filter(|&&(t, _)| t >= t0 && t < t1)
            .map(|&(_, v)| v),
    )
}

/// Summary statistics of `channel` within each lap of `session`, one [`Stats`]
/// per lap in lap order. Each lap restricts to its own half-open `[start, end)`
/// window (issue 3.1), so a lap's statistics exclude every other lap's samples.
///
/// A session with no lap markers yields an empty vector.
///
/// # Errors
/// - [`AnalysisError::MissingChannel`] if `channel` is absent from the session.
/// - [`AnalysisError::EmptyRange`] if a lap has no finite samples for `channel`.
pub fn stats_per_lap(session: &Session, channel: &str) -> Result<Vec<Stats>, AnalysisError> {
    segment_laps(session)
        .iter()
        .map(|lap| {
            let lap_channel =
                lap.channel(channel)
                    .ok_or_else(|| AnalysisError::MissingChannel {
                        name: channel.to_string(),
                    })?;
            accumulate(lap_channel.samples().iter().map(|&(_, v)| v))
        })
        .collect()
}

/// Fold an iterator of samples into [`Stats`] with Welford's online moments,
/// skipping non-finite values. Empty (after skipping) → [`AnalysisError::EmptyRange`].
fn accumulate(values: impl Iterator<Item = f64>) -> Result<Stats, AnalysisError> {
    let mut count: usize = 0;
    let mut mean = 0.0;
    let mut m2 = 0.0; // Σ (x − mean)², accumulated online.
    let mut min = f64::INFINITY;
    let mut max = f64::NEG_INFINITY;

    for x in values.filter(|v| v.is_finite()) {
        count += 1;
        let delta = x - mean;
        mean += delta / count as f64;
        m2 += delta * (x - mean);
        min = min.min(x);
        max = max.max(x);
    }

    if count == 0 {
        return Err(AnalysisError::EmptyRange);
    }

    let variance_pop = m2 / count as f64;
    let std_sample = if count > 1 {
        (m2 / (count as f64 - 1.0)).sqrt()
    } else {
        0.0
    };

    Ok(Stats {
        count,
        min,
        max,
        mean,
        std_pop: variance_pop.sqrt(),
        std_sample,
        // RMS = √E[x²] = √(var_pop + mean²): stable, no second large accumulator.
        rms: (variance_pop + mean * mean).sqrt(),
        range: max - min,
    })
}
