//! Automatic video sync from engine sound (issue 9.8).
//!
//! Onboard kart footage rarely carries usable sync metadata, but it always
//! records the engine, whose sound has a fundamental proportional to RPM —
//! `f0 = k·RPM` with `k = 1/120` for a four-stroke single's firing rate, `1/60`
//! for its crank, other ratios for other engines and harmonics. This module
//! estimates the **video↔session offset** by matching the camera audio's pitch
//! against the session's `RPM` channel, without ever being told `k`.
//!
//! - [`pitch_track`] — one fundamental per audio frame from a harmonic-salience
//!   front end (whitened log spectrum, subharmonic summation).
//! - [`estimate_offset`] — the offset, as a two-stage search of the **mean
//!   salience along the RPM-predicted pitch curve** `ln f0 = ln k + ln rpm(t −
//!   τ)`: a coarse FFT cross-correlation over every lag `τ` and every ratio `k`
//!   (`ln k` is a shift in log frequency, so `k` is found, not configured), then
//!   a dense local refinement with parabolic interpolation.
//!
//! The estimate carries its evidence — the peak's score and its ratio to the
//! best rival at least [`RIVAL_EXCLUSION_S`] away — and
//! [`SyncEstimate::is_confident`] applies the thresholds chosen by the fixture
//! study ([`MIN_CONFIDENT_SCORE`], [`MIN_CONFIDENT_PEAK_RATIO`]; see
//! `docs/adr/0007-audio-engine-sync.md`). A proposal is never applied silently:
//! the caller shows it and the operator confirms.
//!
//! Every entry point is total: bad input is an empty result or a typed error,
//! never a panic.

use std::fmt;

mod pitch;
mod refine;
mod rpm;
mod salience;
mod search;

pub use pitch::{pitch_track, PitchPoint};

use salience::SalienceMap;
use search::{coarse_search, Bounds};

/// The least audio, RPM, and audio∩RPM overlap (seconds) an alignment is
/// attempted on: a lap or two of a kart session, enough for its RPM curve to
/// have a shape.
pub const MIN_OVERLAP_S: f64 = 20.0;

/// How far (seconds) the best rival peak must sit from the winner to count as a
/// different alignment rather than the winner's own shoulder.
pub const RIVAL_EXCLUSION_S: f64 = 2.0;

/// The least weighted mean salience (in frame standard deviations) along the
/// matched curve for a confident proposal. Pure noise stays below ~0.3; real
/// footage scores 2–3.
pub const MIN_CONFIDENT_SCORE: f64 = 0.5;

/// The least ratio of the winning peak to the best rival for a confident
/// proposal. Kart laps repeat, so the usual rival is the same RPM curve a lap
/// off. In the fixture study every true match cleared 1.75 and no false one
/// reached 1.2 (real footage: ≈ 3.5 against ≤ 1.07); 1.4 sits between.
pub const MIN_CONFIDENT_PEAK_RATIO: f64 = 1.4;

/// Hop (seconds) of the coarse search's frames.
const COARSE_HOP_S: f64 = 0.1;

/// Pitch-candidate spacing of the coarse search (2 % in `ln f`).
const COARSE_DU: f64 = 0.02;

/// Harmonics summed per candidate by the search (flat-weighted, see
/// `salience::Harmonics::Flat`): six reach the 2–4 % log-frequency sharpness
/// that tells a lap-shifted RPM curve from the true one.
const SEARCH_HARMONICS: usize = 6;

/// Pseudo-count (seconds of zero-score frames) every lag's mean is shrunk by,
/// so a short overlap cannot score high on chance alone.
const SHRINK_S: f64 = 40.0;

/// A rival weaker than this is read as this, so the ratio stays finite.
const RIVAL_FLOOR: f64 = 0.1;

/// Why no offset could be estimated.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum AudioSyncError {
    /// The audio, the RPM trace, or every overlap the search window allows is
    /// shorter than [`MIN_OVERLAP_S`].
    TooShort,
    /// The audio is silent throughout.
    NoPitch,
    /// The RPM channel has no usable (finite, running-engine) samples.
    NoRpm,
    /// The RPM never changes, so there is no shape to align.
    FlatSignal,
    /// A zero (or too low) sample rate, or a non-finite / inverted window.
    InvalidInput,
}

impl fmt::Display for AudioSyncError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(match self {
            Self::TooShort => "too little overlapping audio and RPM to align",
            Self::NoPitch => "no engine pitch found in the audio",
            Self::NoRpm => "the RPM channel has no usable samples",
            Self::FlatSignal => "the RPM never changes, so there is nothing to align",
            Self::InvalidInput => "invalid sample rate or search window",
        })
    }
}

impl std::error::Error for AudioSyncError {}

/// A proposed alignment and the evidence for it.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct SyncEstimate {
    /// `video time = session time + offset_s` — the app's `VideoSyncModel`
    /// convention: positive when the footage leads the logger.
    pub offset_s: f64,
    /// Mean z-scored salience along the matched pitch curve — how loudly the
    /// audio agrees with the RPM there (≈ 0 for chance, 2–3 on clean footage).
    pub score: f64,
    /// The winning coarse peak over the best rival at least
    /// [`RIVAL_EXCLUSION_S`] away; `1` when the window holds no rival to
    /// compare against.
    pub peak_ratio: f64,
    /// The fitted `k` of `f0 = k·RPM` (e.g. `1/120` for a four-stroke single's
    /// firing rate) — diagnostic, and a sanity check on the match.
    pub pitch_per_rpm: f64,
}

impl SyncEstimate {
    /// Whether the estimate clears both confidence thresholds — only then may a
    /// caller offer it for one-click apply.
    #[must_use]
    pub fn is_confident(&self) -> bool {
        self.score >= MIN_CONFIDENT_SCORE && self.peak_ratio >= MIN_CONFIDENT_PEAK_RATIO
    }
}

/// Estimate the offset between mono camera audio `pcm` (sampled at
/// `sample_rate` Hz, ideally decimated to ~8 kHz) and the session's `rpm`
/// trace (`(seconds, rpm)` on the session clock), searching offsets in the
/// inclusive `search` window.
///
/// # Errors
/// - [`AudioSyncError::InvalidInput`] for a sample rate whose Nyquist does not
///   clear the 400 Hz pitch band, or a non-finite / inverted window.
/// - [`AudioSyncError::TooShort`] when the audio, the RPM trace, or every
///   overlap the window allows is under [`MIN_OVERLAP_S`].
/// - [`AudioSyncError::NoRpm`] when no RPM sample is usable.
/// - [`AudioSyncError::FlatSignal`] when the RPM is constant.
/// - [`AudioSyncError::NoPitch`] when the audio is silent throughout.
///
/// Noise or a mismatched session is **not** an error: it yields an estimate
/// that [`SyncEstimate::is_confident`] rejects.
pub fn estimate_offset(
    pcm: &[f32],
    sample_rate: u32,
    rpm: &[(f64, f64)],
    search: (f64, f64),
) -> Result<SyncEstimate, AudioSyncError> {
    let cfg = PitchConfig {
        harmonics: SEARCH_HARMONICS,
        ..PitchConfig::default()
    };
    let fs = f64::from(sample_rate);
    let (lo, hi) = search;
    if !(lo.is_finite() && hi.is_finite() && lo <= hi) || cfg.max_hz >= fs / 2.0 {
        return Err(AudioSyncError::InvalidInput);
    }
    if (pcm.len() as f64) < MIN_OVERLAP_S * fs {
        return Err(AudioSyncError::TooShort);
    }
    let points = rpm::usable(rpm);
    if points.is_empty() {
        return Err(AudioSyncError::NoRpm);
    }
    if rpm::span(&points) < MIN_OVERLAP_S {
        return Err(AudioSyncError::TooShort);
    }
    if rpm::is_flat(&points) {
        return Err(AudioSyncError::FlatSignal);
    }
    let map = SalienceMap::compute(pcm, fs, &cfg, COARSE_DU, COARSE_HOP_S)
        .ok_or(AudioSyncError::InvalidInput)?;
    if !map.voiced.iter().any(|&v| v) {
        return Err(AudioSyncError::NoPitch);
    }
    let coarse_rpm = rpm::LogRpm::new(&points, map.hop);
    let bounds = Bounds {
        window: search,
        min_overlap: (MIN_OVERLAP_S / map.hop).ceil() as usize,
        exclusion_s: RIVAL_EXCLUSION_S,
        shrink_s: SHRINK_S,
    };
    let coarse = coarse_search(&map, &coarse_rpm, bounds)?;
    let fine = refine::refine(pcm, fs, &cfg, &points, &coarse, MIN_OVERLAP_S, COARSE_DU);
    let peak_ratio = coarse
        .rival
        .map_or(1.0, |rival| coarse.peak / rival.max(RIVAL_FLOOR));
    Ok(SyncEstimate {
        offset_s: fine.offset_s,
        score: fine.score,
        peak_ratio,
        pitch_per_rpm: fine.log_k.exp(),
    })
}

/// The pitch front end's framing and search band.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct PitchConfig {
    /// Frame length in seconds, rounded to the nearest power-of-two sample count
    /// (0.5 s → 4096 samples at 8 kHz, ~2 Hz bins).
    pub frame_s: f64,
    /// Hop between frame starts, in seconds.
    pub hop_s: f64,
    /// Lowest candidate fundamental (Hz).
    pub min_hz: f64,
    /// Highest candidate fundamental (Hz); must sit below Nyquist.
    pub max_hz: f64,
    /// Harmonics summed per candidate.
    pub harmonics: usize,
}

impl Default for PitchConfig {
    /// 0.5 s frames every 20 ms, fundamentals 15–400 Hz (a four-stroke single
    /// idling at 1 800 rpm fires at 15 Hz; a two-stroke at 24 000 rpm turns at
    /// 400 Hz), four harmonics.
    fn default() -> Self {
        Self {
            frame_s: 0.5,
            hop_s: 0.02,
            min_hz: 15.0,
            max_hz: 400.0,
            harmonics: 4,
        }
    }
}
