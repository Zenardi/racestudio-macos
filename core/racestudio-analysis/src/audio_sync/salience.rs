//! The harmonic-salience front end shared by [`pitch_track`](super::pitch_track)
//! and the offset search (issue 9.8).
//!
//! Each audio frame is Hann-windowed (the [`Window`] of the 3.7 FFT layer) and
//! transformed; its log-magnitude spectrum is **whitened** by subtracting a
//! moving average across frequency (so wind, road noise and a camera's AGC — all
//! broadband — flatten to zero and only narrow spectral lines stand out) and
//! clipped at zero. The salience of a candidate fundamental `f` is then the
//! weighted mean of that whitened spectrum at its first few harmonics `h·f`
//! ([`Harmonics`]), and — for the search — the row is z-scored across
//! candidates so frames of any loudness weigh alike.
//!
//! Candidates sit on a [`LogGrid`] — evenly spaced in `ln f` — because there a
//! change of the unknown pitch/RPM ratio `k` is a pure **shift**, which is what
//! lets the search find `k` instead of being told it.

use std::ops::Range;
use std::sync::Arc;

use rustfft::num_complex::Complex;
use rustfft::{Fft, FftPlanner};

use super::PitchConfig;
use crate::fft::{apply_window, Window};

/// Frames quieter than this RMS (−80 dBFS) are silence: unvoiced, no salience.
const SILENCE_RMS: f64 = 1e-4;

/// Width (Hz) of the moving average a frame's log spectrum is whitened against —
/// several bins wider than a Hann main lobe, so a harmonic stands proud of it.
const WHITENING_HZ: f64 = 60.0;

/// The harmonic weight decay of subharmonic summation (Hermes, 1988): the
/// fundamental outweighs its subharmonics, which also sum the same partials.
const HARMONIC_DECAY: f64 = 0.84;

/// Floor added to a magnitude before its logarithm.
const MAGNITUDE_FLOOR: f32 = 1e-12;

/// How a candidate's harmonics are weighted.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum Harmonics {
    /// Subharmonic summation, weights `0.84^(h−1)`: a lone partial at `f`
    /// scores highest at `f` itself, not at `f/2` or `f/3` (which sum it too) —
    /// what a pitch *tracker* needs.
    Decaying,
    /// Equal weights. In log frequency a harmonic's peak narrows as `1/h`, so
    /// letting the high harmonics count as much as the broad fundamental
    /// sharpens the match — what the *alignment* needs to tell the true offset
    /// from the same RPM curve a lap later. Which candidate is "the" pitch does
    /// not matter there: the search absorbs it into `k`.
    Flat,
}

impl Harmonics {
    fn weight(self, h: usize) -> f64 {
        match self {
            Self::Decaying => HARMONIC_DECAY.powi(h as i32 - 1),
            Self::Flat => 1.0,
        }
    }
}

/// Candidate fundamentals evenly spaced in `ln f`: `u_i = u0 + i·du`.
#[derive(Debug, Clone, Copy, PartialEq)]
pub(crate) struct LogGrid {
    /// `ln` of the lowest candidate (Hz).
    pub u0: f64,
    /// Spacing in `ln f` (`0.01` ≈ 1 %).
    pub du: f64,
    /// Number of candidates.
    pub len: usize,
}

impl LogGrid {
    /// Candidates from `min_hz` up to (at most) `max_hz`, `du` apart in `ln f`.
    pub fn new(min_hz: f64, max_hz: f64, du: f64) -> Self {
        let u0 = min_hz.ln();
        let len = ((max_hz / min_hz).ln() / du).floor() as usize + 1;
        Self { u0, du, len }
    }

    /// The frequency (Hz) at fractional candidate index `i`.
    pub fn hz(&self, i: f64) -> f64 {
        (self.u0 + i * self.du).exp()
    }

    /// The fractional candidate index of log-frequency `u`.
    pub fn position(&self, u: f64) -> f64 {
        (u - self.u0) / self.du
    }
}

/// One harmonic's contribution to a candidate: four Catmull-Rom weights over
/// bins `k..k+4` (centred on the fractional bin between `k+1` and `k+2`), with
/// the harmonic's own weight folded in.
#[derive(Debug, Clone, Copy)]
struct Tap {
    k: usize,
    w: [f32; 4],
}

/// The harmonic taps of every candidate on one [`LogGrid`] — built once per
/// analyzer and grid, applied to every frame.
pub(crate) struct TapSet {
    pub grid: LogGrid,
    taps: Vec<Tap>,
    tap_start: Vec<usize>,
}

/// The frame length (samples) for `frame_s` seconds at `fs`: the nearest power
/// of two, for a fast transform. At 8 kHz a 0.5 s frame is 4096 samples.
pub(crate) fn frame_len(frame_s: f64, fs: f64) -> usize {
    let target = (frame_s * fs).max(2.0);
    let exponent = target.log2().round().clamp(1.0, 30.0) as u32;
    1usize << exponent
}

/// A reusable per-frame analyzer: FFT plan, window and scratch buffers, and the
/// whitened spectrum of the frame last [`load`](Self::load)ed, which any number
/// of [`TapSet`]s then score.
pub(crate) struct FrameAnalyzer {
    n: usize,
    bin_hz: f64,
    kmax: usize,
    harmonics: usize,
    window: Vec<f32>,
    fft: Arc<dyn Fft<f32>>,
    buf: Vec<Complex<f32>>,
    scratch: Vec<Complex<f32>>,
    logmag: Vec<f32>,
    prefix: Vec<f64>,
    white: Vec<f32>,
    half_width: usize,
}

impl FrameAnalyzer {
    /// An analyzer for `fs` Hz audio with `cfg`'s frame length, band and
    /// harmonic count. `None` when the configuration cannot work: a
    /// non-positive rate or frame, an empty or inverted band, no harmonics, or a
    /// band reaching Nyquist.
    pub fn new(fs: f64, cfg: &PitchConfig) -> Option<Self> {
        let valid = fs.is_finite()
            && fs > 0.0
            && cfg.frame_s.is_finite()
            && cfg.frame_s > 0.0
            && cfg.min_hz.is_finite()
            && cfg.min_hz > 0.0
            && cfg.max_hz > cfg.min_hz
            && cfg.max_hz < fs / 2.0
            && cfg.harmonics > 0;
        if !valid {
            return None;
        }
        let n = frame_len(cfg.frame_s, fs);
        let bin_hz = fs / n as f64;
        let half_width = ((WHITENING_HZ / 2.0) / bin_hz).round().max(1.0) as usize;
        let top = ((cfg.max_hz * cfg.harmonics as f64) / bin_hz).ceil() as usize + 3 + half_width;
        let kmax = top.min(n / 2);

        let mut coefficients = vec![1.0; n];
        apply_window(&mut coefficients, Window::Hann);
        let window = coefficients.iter().map(|&c| c as f32).collect();

        let fft = FftPlanner::new().plan_fft_forward(n);
        let scratch = vec![Complex::new(0.0, 0.0); fft.get_inplace_scratch_len()];
        Some(Self {
            n,
            bin_hz,
            kmax,
            harmonics: cfg.harmonics,
            window,
            fft,
            buf: vec![Complex::new(0.0, 0.0); n],
            scratch,
            logmag: vec![0.0; kmax + 1],
            prefix: vec![0.0; kmax + 2],
            white: vec![0.0; kmax + 1],
            half_width,
        })
    }

    /// The frame length in samples.
    pub fn frame_len(&self) -> usize {
        self.n
    }

    /// The taps that score every candidate of `grid` with `weighting` against
    /// this analyzer's spectra. A harmonic whose four-bin support runs past the
    /// analysed bins is dropped, and each candidate's weights sum to one.
    pub fn taps(&self, grid: LogGrid, weighting: Harmonics) -> TapSet {
        let mut taps = Vec::with_capacity(grid.len * self.harmonics);
        let mut tap_start = Vec::with_capacity(grid.len + 1);
        for i in 0..grid.len {
            tap_start.push(taps.len());
            let f = grid.hz(i as f64);
            let first = taps.len();
            let mut total = 0.0;
            for h in 1..=self.harmonics {
                let pos = h as f64 * f / self.bin_hz;
                let k = pos.floor() as usize;
                if k < 1 || k + 2 > self.kmax {
                    continue;
                }
                let weight = weighting.weight(h);
                total += weight;
                let cr = catmull_rom(pos - k as f64);
                taps.push(Tap {
                    k: k - 1,
                    w: cr.map(|c| (c * weight) as f32),
                });
            }
            for tap in &mut taps[first..] {
                for w in &mut tap.w {
                    *w = (f64::from(*w) / total) as f32;
                }
            }
        }
        tap_start.push(taps.len());
        TapSet {
            grid,
            taps,
            tap_start,
        }
    }

    /// Transform and whiten the frame starting at `pcm[start]`. Returns whether
    /// it is loud enough to score at all (a silent frame has no salience).
    pub fn load(&mut self, pcm: &[f32], start: usize) -> bool {
        let frame = &pcm[start..start + self.n];
        let mut energy = 0.0_f64;
        for ((slot, &sample), &w) in self.buf.iter_mut().zip(frame).zip(&self.window) {
            let x = if sample.is_finite() { sample } else { 0.0 };
            energy += f64::from(x) * f64::from(x);
            *slot = Complex::new(x * w, 0.0);
        }
        if (energy / self.n as f64).sqrt() < SILENCE_RMS {
            return false;
        }
        self.fft
            .process_with_scratch(&mut self.buf, &mut self.scratch);
        self.whiten();
        true
    }

    /// Score every candidate of `taps` against the loaded frame into `out`: one
    /// raw salience per candidate, in nats of whitened log magnitude (a clean
    /// harmonic reads several nats; broadband noise peaks near one).
    pub fn score(&self, taps: &TapSet, out: &mut [f32]) {
        self.score_band(taps, 0..taps.grid.len, out);
    }

    /// Score candidates `band` of `taps` into `out[..band.len()]` — the cheap
    /// path when only a few candidates can matter.
    pub fn score_band(&self, taps: &TapSet, band: Range<usize>, out: &mut [f32]) {
        for (slot, i) in out.iter_mut().zip(band) {
            let mut s = 0.0_f32;
            for tap in &taps.taps[taps.tap_start[i]..taps.tap_start[i + 1]] {
                let v = &self.white[tap.k..tap.k + 4];
                s += tap.w[0] * v[0] + tap.w[1] * v[1] + tap.w[2] * v[2] + tap.w[3] * v[3];
            }
            *slot = s;
        }
    }

    /// `white[k] = max(0, ln|X_k| − mean of ln|X| over k ± half_width)`.
    fn whiten(&mut self) {
        let kmax = self.kmax;
        for (k, slot) in self.logmag.iter_mut().enumerate() {
            *slot = (self.buf[k].norm() + MAGNITUDE_FLOOR).ln();
        }
        self.prefix[0] = 0.0;
        for k in 0..=kmax {
            self.prefix[k + 1] = self.prefix[k] + f64::from(self.logmag[k]);
        }
        for k in 0..=kmax {
            let lo = k.saturating_sub(self.half_width);
            let hi = (k + self.half_width).min(kmax);
            let mean = (self.prefix[hi + 1] - self.prefix[lo]) / (hi + 1 - lo) as f64;
            self.white[k] = (f64::from(self.logmag[k]) - mean).max(0.0) as f32;
        }
    }
}

/// The z-scored salience of every frame of a clip — the audio side of the
/// coarse search. Row `i` scores the frame centred at `t0 + i·hop` seconds; an
/// unvoiced frame's row is all zero.
pub(crate) struct SalienceMap {
    /// Centre of the first frame (seconds).
    pub t0: f64,
    /// Exact hop between frame centres (seconds) — a whole number of samples.
    pub hop: f64,
    /// The candidate grid every row is scored on.
    pub grid: LogGrid,
    /// `frames × grid.len` z-scored saliences, row-major.
    pub rows: Vec<f32>,
    /// Whether each frame was voiced.
    pub voiced: Vec<bool>,
}

impl SalienceMap {
    /// Score every `hop_s` frame of `pcm` on a `du` grid over `cfg`'s band with
    /// flat harmonic weights, or `None` when `cfg` cannot work at `fs` or the
    /// clip is shorter than a frame.
    pub fn compute(pcm: &[f32], fs: f64, cfg: &PitchConfig, du: f64, hop_s: f64) -> Option<Self> {
        let grid = LogGrid::new(cfg.min_hz, cfg.max_hz, du);
        let mut analyzer = FrameAnalyzer::new(fs, cfg)?;
        let taps = analyzer.taps(grid, Harmonics::Flat);
        let n = analyzer.frame_len();
        if pcm.len() < n {
            return None;
        }
        let hop = (hop_s * fs).round().max(1.0) as usize;
        let frames = (pcm.len() - n) / hop + 1;
        let mut rows = vec![0.0_f32; frames * grid.len];
        let mut voiced = Vec::with_capacity(frames);
        for (i, row) in rows.chunks_exact_mut(grid.len).enumerate() {
            let loud = analyzer.load(pcm, i * hop);
            if loud {
                analyzer.score(&taps, row);
            }
            voiced.push(loud && standardize(row));
        }
        Some(Self {
            t0: n as f64 / 2.0 / fs,
            hop: hop as f64 / fs,
            grid,
            rows,
            voiced,
        })
    }

    /// The number of frames.
    pub fn frames(&self) -> usize {
        self.voiced.len()
    }
}

/// A salience row's mean and standard deviation across candidates, or `None`
/// for an empty or flat row (which carries no pitch information).
pub(crate) fn row_stats(row: &[f32]) -> Option<(f64, f64)> {
    if row.is_empty() {
        return None;
    }
    let len = row.len() as f64;
    let mean = row.iter().map(|&s| f64::from(s)).sum::<f64>() / len;
    let var = row
        .iter()
        .map(|&s| (f64::from(s) - mean).powi(2))
        .sum::<f64>()
        / len;
    (var > f64::EPSILON).then(|| (mean, var.sqrt()))
}

/// Z-score a salience row in place (zero mean, unit variance across
/// candidates), so loud and quiet frames weigh alike in the search. A flat row
/// is zeroed and `false` returned.
pub(crate) fn standardize(row: &mut [f32]) -> bool {
    let Some((mean, std)) = row_stats(row) else {
        row.fill(0.0);
        return false;
    };
    for slot in row.iter_mut() {
        *slot = ((f64::from(*slot) - mean) / std) as f32;
    }
    true
}

/// Catmull-Rom weights for the points at `−1, 0, 1, 2` evaluated at `t ∈ [0, 1)`.
fn catmull_rom(t: f64) -> [f64; 4] {
    let t2 = t * t;
    let t3 = t2 * t;
    [
        (-t3 + 2.0 * t2 - t) / 2.0,
        (3.0 * t3 - 5.0 * t2 + 2.0) / 2.0,
        (-3.0 * t3 + 4.0 * t2 + t) / 2.0,
        (t3 - t2) / 2.0,
    ]
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn frame_len_rounds_to_the_nearest_power_of_two() {
        assert_eq!(frame_len(0.5, 8000.0), 4096);
        assert_eq!(frame_len(0.5, 7350.0), 4096);
        assert_eq!(frame_len(0.5, 4000.0), 2048);
        assert_eq!(frame_len(0.0, 8000.0), 2);
    }

    #[test]
    fn catmull_rom_interpolates_its_knots() {
        assert_eq!(catmull_rom(0.0), [0.0, 1.0, 0.0, 0.0]);
        let mid: f64 = catmull_rom(0.5).iter().sum();
        assert!((mid - 1.0).abs() < 1e-12, "weights sum to one");
    }

    #[test]
    fn standardize_zero_means_and_unit_scales_a_row() {
        let mut row = [1.0_f32, 2.0, 3.0, 4.0];
        assert!(standardize(&mut row));
        let mean: f32 = row.iter().sum::<f32>() / 4.0;
        let var: f32 = row.iter().map(|v| (v - mean).powi(2)).sum::<f32>() / 4.0;
        assert!(mean.abs() < 1e-6 && (var - 1.0).abs() < 1e-5);
    }

    #[test]
    fn standardize_rejects_a_flat_or_empty_row() {
        let mut flat = [2.0_f32; 5];
        assert!(!standardize(&mut flat));
        assert_eq!(flat, [0.0; 5]);
        assert!(!standardize(&mut []));
        assert_eq!(row_stats(&[]), None);
    }

    #[test]
    fn analyzer_rejects_unworkable_configurations() {
        let ok = PitchConfig::default();
        assert!(FrameAnalyzer::new(8000.0, &ok).is_some());
        assert!(FrameAnalyzer::new(0.0, &ok).is_none());
        assert!(
            FrameAnalyzer::new(600.0, &ok).is_none(),
            "band past Nyquist"
        );
        let no_harmonics = PitchConfig { harmonics: 0, ..ok };
        assert!(FrameAnalyzer::new(8000.0, &no_harmonics).is_none());
        let inverted = PitchConfig {
            min_hz: 500.0,
            max_hz: 400.0,
            ..ok
        };
        assert!(FrameAnalyzer::new(8000.0, &inverted).is_none());
    }

    #[test]
    fn a_band_scores_exactly_like_the_full_row() {
        let cfg = PitchConfig::default();
        let mut analyzer = FrameAnalyzer::new(8000.0, &cfg).unwrap();
        let taps = analyzer.taps(LogGrid::new(15.0, 400.0, 0.01), Harmonics::Flat);
        let pcm: Vec<f32> = (0..4096)
            .map(|i| (2.0 * std::f32::consts::PI * 90.0 * i as f32 / 8000.0).sin())
            .collect();
        assert!(analyzer.load(&pcm, 0));
        let mut full = vec![0.0; taps.grid.len];
        analyzer.score(&taps, &mut full);
        let mut band = vec![0.0; 10];
        analyzer.score_band(&taps, 100..110, &mut band);
        assert_eq!(&full[100..110], &band[..]);
        assert!((taps.grid.position(taps.grid.u0 + 2.5 * 0.01) - 2.5).abs() < 1e-9);
    }
}
