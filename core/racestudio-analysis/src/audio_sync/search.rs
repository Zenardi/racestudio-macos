//! The coarse, global half of the offset search (issue 9.8): every lag and
//! every pitch/RPM ratio at once, by FFT.
//!
//! The audio's salience map `Z(t, u)` (frames × log-frequency candidates) is
//! matched against an image of the session's log-RPM curve, `I(t, u) = w(t)`
//! where `u = ln rpm(t)` (zero elsewhere; `w` is the RPM-slope timing weight,
//! see [`LogRpm::weight_at`]). The engine is heard where `ln f0 = c + ln rpm(t −
//! τ)` — `c = ln k` the unknown pitch/RPM ratio, `τ` the offset — so the
//! weighted mean salience along that curve,
//!
//! ```text
//! score(τ, c) = Σ_t w(t)·Z(t + τ, c + ln rpm(t)) / W(τ),
//! ```
//!
//! is a **2-D cross-correlation** of `Z` and `I` (`W(τ)` is the weight of the
//! frames both sides cover, shrunk for short overlaps). In log frequency `k` is
//! a pure shift, so the search finds it instead of being told it — and matching
//! another harmonic just moves the peak along `c`, never along `τ`. The
//! correlation over `τ` is done by FFT for every shift `c`, `O(N log N)` rather
//! than `O(N · lags)`.

use rustfft::num_complex::Complex;
use rustfft::FftPlanner;

use super::rpm::LogRpm;
use super::salience::SalienceMap;
use super::AudioSyncError;

/// The best coarse alignment and the evidence for it.
#[derive(Debug, Clone, Copy, PartialEq)]
pub(crate) struct Coarse {
    /// The offset (seconds), parabolically refined between lags.
    pub offset_s: f64,
    /// `ln k` at the peak.
    pub log_k: f64,
    /// The peak's mean salience.
    pub peak: f64,
    /// The best score at least `exclusion_s` away from the peak, if any lag is.
    pub rival: Option<f64>,
}

/// What the search may consider.
#[derive(Debug, Clone, Copy)]
pub(crate) struct Bounds {
    /// Inclusive offset window (seconds).
    pub window: (f64, f64),
    /// Least frames both sides must share for a lag to count.
    pub min_overlap: usize,
    /// How far (seconds) a rival peak must sit from the best one.
    pub exclusion_s: f64,
    /// Pseudo-count (seconds of zero-score frames) a lag's mean is shrunk by.
    pub shrink_s: f64,
}

/// Search `map` against `rpm` (on the same hop, binned on the same `du`) for the
/// best `(τ, c)`.
///
/// # Errors
/// [`AudioSyncError::TooShort`] when no lag inside the window shares
/// `min_overlap` frames.
pub(crate) fn coarse_search(
    map: &SalienceMap,
    rpm: &LogRpm,
    bounds: Bounds,
) -> Result<Coarse, AudioSyncError> {
    let du = map.grid.du;
    let (bins, lr_min) = bin_rpm(rpm, du);
    let n_a = map.frames();
    let n_b = bins.len();
    let nfft = (n_a + n_b).next_power_of_two();
    let mut fft = Spectra::new(nfft);

    // Per lag: how many voiced frames meet a valid RPM sample (admissibility),
    // and the total slope weight they carry (the score's denominator).
    let voiced: Vec<f32> = map.voiced.iter().map(|&v| f32::from(u8::from(v))).collect();
    let valid: Vec<f32> = bins
        .iter()
        .map(|b| f32::from(u8::from(b.is_some())))
        .collect();
    let weights: Vec<f32> = (0..n_b)
        .map(|j| rpm.weight_at(rpm.t0 + j as f64 * rpm.step).unwrap_or(0.0) as f32)
        .collect();
    let overlap = Overlap {
        frames: fft.correlate(&voiced, &valid),
        weight: fft.correlate(&voiced, &weights),
    };
    let lags = admissible_lags(map, rpm, n_b, &overlap, bounds);
    if !lags.iter().any(|lag| lag.in_window) {
        return Err(AudioSyncError::TooShort);
    }

    let u_len = map.grid.len;
    let columns_a: Vec<Half> = (0..u_len)
        .map(|u| {
            let column: Vec<f32> = (0..n_a).map(|j| map.rows[j * u_len + u]).collect();
            fft.forward(&column)
        })
        .collect();
    let rpm_bins = bins.iter().flatten().max().map_or(0, |&b| b + 1);
    let columns_b: Vec<Option<Half>> = (0..rpm_bins)
        .map(|b| {
            let column: Vec<f32> = bins
                .iter()
                .zip(&weights)
                .map(|(&x, &w)| if x == Some(b) { w } else { 0.0 })
                .collect();
            column
                .iter()
                .any(|&v| v > 0.0)
                .then(|| fft.forward(&column))
        })
        .collect();

    // For each shift d (column u = b + d), correlate over time; keep, per lag,
    // the best score over d.
    let mut best = vec![(f64::NEG_INFINITY, 0_i64); lags.len()];
    let mut product = Half::zeros(nfft / 2 + 1);
    for d in -(rpm_bins as i64 - 1)..u_len as i64 {
        product.clear();
        let mut any = false;
        for (b, column_b) in columns_b.iter().enumerate() {
            let u = b as i64 + d;
            let (Some(column_b), true) = (column_b, (0..u_len as i64).contains(&u)) else {
                continue;
            };
            any = true;
            product.add_cross(&columns_a[u as usize], column_b);
        }
        if !any {
            continue;
        }
        let sums = fft.inverse_half(&product);
        for (slot, lag) in best.iter_mut().zip(&lags) {
            let score = f64::from(sums[lag.lag.rem_euclid(nfft as i64) as usize]) / lag.denominator;
            if score > slot.0 {
                *slot = (score, d);
            }
        }
    }

    // The winner must lie in the window; the rival may lie anywhere. A window
    // that excludes the true alignment then finds it as a rival stronger than
    // its own best, instead of crowning a lap-shifted look-alike.
    let profile: Vec<f64> = best.iter().map(|&(s, _)| s).collect();
    let peak_index = argmax_where(&profile, |i| lags[i].in_window);
    let (peak, d) = best[peak_index];
    let lag = lags[peak_index].lag as f64 + vertex(&profile, &lags, peak_index);
    let exclusion = bounds.exclusion_s / map.hop;
    let rival = lags
        .iter()
        .zip(&profile)
        .filter(|(l, _)| ((l.lag - lags[peak_index].lag) as f64).abs() >= exclusion)
        .map(|(_, &s)| s)
        .fold(None, |acc: Option<f64>, s| {
            Some(acc.map_or(s, |a| a.max(s)))
        });
    Ok(Coarse {
        offset_s: map.t0 - rpm.t0 + lag * map.hop,
        log_k: map.grid.u0 - lr_min + d as f64 * du,
        peak,
        rival,
    })
}

/// A lag `ℓ` (audio frame `j + ℓ` against RPM sample `j`) with enough overlap
/// to score.
#[derive(Debug, Clone, Copy, PartialEq)]
struct Lag {
    lag: i64,
    /// What its weighted salience sum is divided by (see [`admissible_lags`]).
    denominator: f64,
    /// Whether its offset lies in the search window — only those may win.
    in_window: bool,
}

/// Quantise `ln rpm` onto `du` bins above its minimum: `(bins, ln rpm_min)`,
/// `None` where the grid has a gap.
fn bin_rpm(rpm: &LogRpm, du: f64) -> (Vec<Option<usize>>, f64) {
    let lr_min = rpm
        .values
        .iter()
        .copied()
        .filter(|v| v.is_finite())
        .fold(f64::INFINITY, f64::min);
    let bins = rpm
        .values
        .iter()
        .map(|&v| v.is_finite().then(|| ((v - lr_min) / du).round() as usize))
        .collect();
    (bins, lr_min)
}

/// Per-lag overlap between the audio and the RPM, as circular correlations
/// (lag `ℓ` at index `ℓ mod nfft`).
struct Overlap {
    /// Voiced frames meeting a valid RPM sample.
    frames: Vec<f32>,
    /// The slope weight those frames carry.
    weight: Vec<f32>,
}

/// Every lag whose overlap reaches the minimum, with the denominator its
/// weighted salience sum is divided by and whether it lies in the window.
///
/// The denominator is the overlap's weight inflated by `(n + n₀)/n` — a
/// pseudo-count of `shrink_s` seconds of zero-score frames. That shrinks the
/// mean of a short overlap towards zero: averaged over few frames, a chance
/// alignment can score as high as the real one, and it would otherwise pose as
/// a rival (or a winner) on noise alone.
fn admissible_lags(
    map: &SalienceMap,
    rpm: &LogRpm,
    n_b: usize,
    overlap: &Overlap,
    bounds: Bounds,
) -> Vec<Lag> {
    let nfft = overlap.frames.len() as i64;
    let (lo, hi) = bounds.window;
    let pseudo = bounds.shrink_s / map.hop;
    (-(n_b as i64 - 1)..map.frames() as i64)
        .filter_map(|lag| {
            let offset = map.t0 - rpm.t0 + lag as f64 * map.hop;
            let index = lag.rem_euclid(nfft) as usize;
            let frames = f64::from(overlap.frames[index]).round();
            let weight = f64::from(overlap.weight[index]).max(f64::EPSILON);
            (frames >= bounds.min_overlap as f64).then(|| Lag {
                lag,
                denominator: weight * (frames + pseudo) / frames,
                in_window: offset >= lo && offset <= hi,
            })
        })
        .collect()
}

/// The index of the largest value among those `allowed` (the first on a tie;
/// `0` when none is allowed).
fn argmax_where(values: &[f64], allowed: impl Fn(usize) -> bool) -> usize {
    let mut best: Option<usize> = None;
    for (i, &v) in values.iter().enumerate() {
        if allowed(i) && best.map_or(true, |b| v > values[b]) {
            best = Some(i);
        }
    }
    best.unwrap_or(0)
}

/// The parabolic vertex offset at `i`, when both neighbours are the adjacent
/// lags; `0` otherwise.
fn vertex(profile: &[f64], lags: &[Lag], i: usize) -> f64 {
    if i == 0 || i + 1 >= profile.len() || lags[i + 1].lag - lags[i - 1].lag != 2 {
        return 0.0;
    }
    let (y0, y1, y2) = (profile[i - 1], profile[i], profile[i + 1]);
    let den = y0 - 2.0 * y1 + y2;
    if den.abs() < f64::EPSILON {
        return 0.0;
    }
    (0.5 * (y0 - y2) / den).clamp(-0.5, 0.5)
}

/// Forward / inverse transforms of one length, with reusable buffers.
struct Spectra {
    nfft: usize,
    forward: std::sync::Arc<dyn rustfft::Fft<f32>>,
    inverse: std::sync::Arc<dyn rustfft::Fft<f32>>,
    buf: Vec<Complex<f32>>,
    scratch: Vec<Complex<f32>>,
}

impl Spectra {
    fn new(nfft: usize) -> Self {
        let mut planner = FftPlanner::new();
        let forward = planner.plan_fft_forward(nfft);
        let inverse = planner.plan_fft_inverse(nfft);
        let scratch_len = forward
            .get_inplace_scratch_len()
            .max(inverse.get_inplace_scratch_len());
        Self {
            nfft,
            forward,
            inverse,
            buf: vec![Complex::new(0.0, 0.0); nfft],
            scratch: vec![Complex::new(0.0, 0.0); scratch_len],
        }
    }

    /// The first `nfft/2 + 1` bins of the zero-padded transform of `x` — all a
    /// real signal needs.
    fn forward(&mut self, x: &[f32]) -> Half {
        self.buf.fill(Complex::new(0.0, 0.0));
        for (slot, &v) in self.buf.iter_mut().zip(x) {
            *slot = Complex::new(v, 0.0);
        }
        self.forward
            .process_with_scratch(&mut self.buf, &mut self.scratch);
        let bins = &self.buf[..self.nfft / 2 + 1];
        Half {
            re: bins.iter().map(|c| c.re).collect(),
            im: bins.iter().map(|c| c.im).collect(),
        }
    }

    /// The real inverse of a Hermitian spectrum given by its first half,
    /// normalised (`1/nfft`).
    fn inverse_half(&mut self, half: &Half) -> Vec<f32> {
        let n = self.nfft;
        let len = half.re.len();
        for (k, slot) in self.buf[..len].iter_mut().enumerate() {
            *slot = Complex::new(half.re[k], half.im[k]);
        }
        for k in 1..n - len + 1 {
            self.buf[n - k] = Complex::new(half.re[k], -half.im[k]);
        }
        self.inverse
            .process_with_scratch(&mut self.buf, &mut self.scratch);
        let scale = 1.0 / n as f32;
        self.buf.iter().map(|c| c.re * scale).collect()
    }

    /// The circular cross-correlation `r[k] = Σ_j a[j + k]·b[j]` (lags `k < 0`
    /// at `nfft + k`).
    fn correlate(&mut self, a: &[f32], b: &[f32]) -> Vec<f32> {
        let fa = self.forward(a);
        let fb = self.forward(b);
        let mut product = Half::zeros(fa.re.len());
        product.add_cross(&fa, &fb);
        self.inverse_half(&product)
    }
}

/// The first half of a real signal's spectrum, real and imaginary parts apart
/// so the cross-spectrum accumulates in plain, vectorisable `f32` arithmetic —
/// the search's inner loop.
struct Half {
    re: Vec<f32>,
    im: Vec<f32>,
}

impl Half {
    fn zeros(len: usize) -> Self {
        Self {
            re: vec![0.0; len],
            im: vec![0.0; len],
        }
    }

    fn clear(&mut self) {
        self.re.fill(0.0);
        self.im.fill(0.0);
    }

    /// `self += a · conj(b)`, bin by bin.
    #[allow(clippy::needless_range_loop)] // index form: one bounds check per slice, vectorises
    fn add_cross(&mut self, a: &Half, b: &Half) {
        let n = self.re.len();
        let (re, im) = (&mut self.re[..n], &mut self.im[..n]);
        let (ar, ai, br, bi) = (&a.re[..n], &a.im[..n], &b.re[..n], &b.im[..n]);
        for i in 0..n {
            re[i] += ar[i] * br[i] + ai[i] * bi[i];
            im[i] += ai[i] * br[i] - ar[i] * bi[i];
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn correlate_matches_the_direct_sum() {
        let a = [1.0_f32, 2.0, 3.0, 0.5];
        let b = [0.5_f32, -1.0, 2.0];
        let mut spectra = Spectra::new(8);
        let r = spectra.correlate(&a, &b);
        for lag in -2_i64..4 {
            let direct: f32 = (0..b.len() as i64)
                .filter(|&j| (0..a.len() as i64).contains(&(j + lag)))
                .map(|j| a[(j + lag) as usize] * b[j as usize])
                .sum();
            let got = r[lag.rem_euclid(8) as usize];
            assert!((got - direct).abs() < 1e-5, "lag {lag}: {got} vs {direct}");
        }
    }

    fn lags(at: [i64; 3]) -> [Lag; 3] {
        at.map(|lag| Lag {
            lag,
            denominator: 1.0,
            in_window: true,
        })
    }

    #[test]
    fn vertex_needs_adjacent_neighbours() {
        let profile = [1.0, 3.0, 2.0];
        let adjacent = lags([4, 5, 6]);
        let gapped = lags([4, 5, 9]);
        assert!(vertex(&profile, &adjacent, 1) > 0.0);
        assert_eq!(vertex(&profile, &gapped, 1), 0.0);
        assert_eq!(vertex(&profile, &adjacent, 0), 0.0);
        assert_eq!(vertex(&[1.0, 1.0, 1.0], &adjacent, 1), 0.0);
    }

    #[test]
    fn argmax_where_only_considers_allowed_indices() {
        let values = [5.0, 1.0, 3.0, 3.0];
        assert_eq!(argmax_where(&values, |_| true), 0);
        assert_eq!(argmax_where(&values, |i| i > 0), 2, "first of the tie");
        assert_eq!(argmax_where(&values, |_| false), 0);
    }
}
