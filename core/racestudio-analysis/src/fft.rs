//! Windowed FFT (issue 3.7): the single-sided amplitude spectrum of a channel.
//!
//! The intended pipeline builds on resampling (3.3): resample an irregular
//! channel to a uniform rate `fs` with [`resample_uniform`](crate::resample_uniform),
//! then pass the values to [`spectrum`]. A window ([`Window`]) tapers the block
//! to cut spectral leakage; its **coherent gain** (the mean coefficient) is
//! divided back out so the returned amplitudes are physical.
//!
//! **Scaling.** For a length-`N` block sampled at `fs`, bin `k` has frequency
//! `k·fs/N` for `k` in `0..=N/2`. The amplitude is `|X_k| / (N · coherent_gain)`,
//! **doubled** for the interior bins to fold the negative frequencies into a
//! single-sided spectrum — but **not** doubled for DC (`k = 0`) or, when `N` is
//! even, the Nyquist bin (`k = N/2`), which have no negative-frequency twin. A
//! tone of amplitude `A` on an exact bin therefore reads back as `A`.
//!
//! **Length policy.** Any length is transformed directly by `rustfft`'s
//! mixed-radix algorithm — no zero-padding — so `N` need not be a power of two.
//! Empty input is [`AnalysisError::EmptyRange`].

use std::f64::consts::PI;

use rustfft::num_complex::Complex;
use rustfft::FftPlanner;

use crate::error::AnalysisError;

/// A window function applied to a block before the transform, trading main-lobe
/// width against side-lobe leakage. Coefficients are the standard symmetric
/// forms over `N` points (`i` in `0..N`, denominator `N − 1`).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Window {
    /// No taper (all-ones); narrowest main lobe, highest leakage.
    Rectangular,
    /// Hann: `0.5 − 0.5·cos(2πi/(N−1))`.
    Hann,
    /// Hamming: `0.54 − 0.46·cos(2πi/(N−1))`.
    Hamming,
    /// Blackman: `0.42 − 0.5·cos(2πi/(N−1)) + 0.08·cos(4πi/(N−1))`.
    Blackman,
}

impl Window {
    /// The window coefficient at index `i` of `n` points. A degenerate length
    /// (`n ≤ 1`) has the trivial coefficient `1`.
    fn coefficient(self, i: usize, n: usize) -> f64 {
        if n <= 1 {
            return 1.0;
        }
        let x = 2.0 * PI * i as f64 / (n - 1) as f64;
        match self {
            Self::Rectangular => 1.0,
            Self::Hann => 0.5 - 0.5 * x.cos(),
            Self::Hamming => 0.54 - 0.46 * x.cos(),
            Self::Blackman => 0.42 - 0.5 * x.cos() + 0.08 * (2.0 * x).cos(),
        }
    }
}

/// A single-sided amplitude spectrum and its frequency axis.
#[derive(Debug, Clone, PartialEq)]
pub struct Spectrum {
    freqs: Vec<f64>,
    amps: Vec<f64>,
}

impl Spectrum {
    /// The frequency axis (Hz): `k·fs/N` for `k` in `0..=N/2`.
    #[must_use]
    pub fn freqs(&self) -> &[f64] {
        &self.freqs
    }

    /// The single-sided amplitudes, aligned one-to-one with [`freqs`](Self::freqs).
    #[must_use]
    pub fn amps(&self) -> &[f64] {
        &self.amps
    }

    /// The number of bins (`N/2 + 1`).
    #[must_use]
    pub fn len(&self) -> usize {
        self.freqs.len()
    }

    /// Whether there are no bins.
    #[must_use]
    pub fn is_empty(&self) -> bool {
        self.freqs.is_empty()
    }
}

/// Multiply `samples` in place by `window`'s coefficients, returning the
/// **coherent gain** — the mean coefficient — used to keep spectral amplitudes
/// physical. An empty slice returns a gain of `1.0`.
pub fn apply_window(samples: &mut [f64], window: Window) -> f64 {
    let n = samples.len();
    if n == 0 {
        return 1.0;
    }
    let mut sum = 0.0;
    for (i, sample) in samples.iter_mut().enumerate() {
        let coefficient = window.coefficient(i, n);
        *sample *= coefficient;
        sum += coefficient;
    }
    sum / n as f64
}

/// The single-sided amplitude [`Spectrum`] of `samples` (assumed uniformly
/// sampled at `fs` Hz) after applying `window`.
///
/// See the module docs for the `k·fs/N` axis, the single-sided ×2 scaling (DC
/// and Nyquist excepted), and the coherent-gain correction. Any length is
/// handled directly (mixed-radix).
///
/// # Errors
/// [`AnalysisError::EmptyRange`] when `samples` is empty.
pub fn spectrum(samples: &[f64], fs: f64, window: Window) -> Result<Spectrum, AnalysisError> {
    if samples.is_empty() {
        return Err(AnalysisError::EmptyRange);
    }
    let n = samples.len();

    let mut windowed = samples.to_vec();
    let coherent_gain = apply_window(&mut windowed, window);

    let mut buffer: Vec<Complex<f64>> =
        windowed.into_iter().map(|x| Complex::new(x, 0.0)).collect();
    FftPlanner::new().plan_fft_forward(n).process(&mut buffer);

    // rustfft is unnormalised (X_k = Σ x_n e^…), so divide by N; the window's
    // coherent gain divides back out its attenuation. A window that collapses the
    // block to (near-)zero — e.g. the symmetric Hann/Blackman at N = 2, whose
    // coefficients are all 0 — has no recoverable amplitude, so those bins are 0
    // rather than a `0/0` NaN.
    let scale = n as f64 * coherent_gain;
    let recoverable = scale.is_finite() && scale > f64::EPSILON;
    let half = n / 2;
    let mut freqs = Vec::with_capacity(half + 1);
    let mut amps = Vec::with_capacity(half + 1);
    for (k, bin) in buffer.iter().take(half + 1).enumerate() {
        freqs.push(k as f64 * fs / n as f64);
        let magnitude = if recoverable { bin.norm() / scale } else { 0.0 };
        // Fold negative frequencies in by doubling the interior bins; DC and (for
        // even N) Nyquist have no twin and are left as-is.
        let is_edge = k == 0 || (n % 2 == 0 && k == half);
        amps.push(if is_edge { magnitude } else { 2.0 * magnitude });
    }
    Ok(Spectrum { freqs, amps })
}
