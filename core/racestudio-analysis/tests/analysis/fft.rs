//! Windowed-FFT tests (issue 3.7).
//!
//! - **Spectrum** (`test_single_tone_peak_bin_and_amplitude`,
//!   `test_frequency_axis_scaling`, `test_dc_and_nyquist_not_doubled`,
//!   `test_non_power_of_two_length`): a synthetic tone lands in the right bin at
//!   the right physical amplitude; the `k·fs/N` axis and single-sided ×2 scaling
//!   (DC/Nyquist excepted) are correct; any length works.
//! - **Windows** (`test_hann_window_coefficients`, `test_coherent_gain_correction`):
//!   coefficients match the reference formulas and `apply_window` returns the
//!   coherent gain used to keep amplitudes physical.
//! - **Property** (`prop_peak_matches_input_frequency`): random single tones peak
//!   within one bin of their frequency — swept deterministically (an in-test LCG)
//!   rather than with `proptest`, which perturbs this repo's CI coverage
//!   instrumentation (see issue 3.3); the coverage-gate intent is unchanged.
//! - **Law / error** (`test_parseval_energy_conserved`,
//!   `test_empty_input_returns_error`): Parseval holds; empty input is typed.

use std::f64::consts::PI;

use racestudio_analysis::{apply_window, spectrum, AnalysisError, Spectrum, Window};

/// A sine `a·sin(2π f t)` sampled at `fs` for `n` points.
fn sine(a: f64, f: f64, fs: f64, n: usize) -> Vec<f64> {
    (0..n)
        .map(|i| a * (2.0 * PI * f * i as f64 / fs).sin())
        .collect()
}

/// The `(frequency, amplitude)` of the largest spectrum bin.
fn peak(spec: &Spectrum) -> (f64, f64) {
    let mut best = 0;
    for (i, &amp) in spec.amps().iter().enumerate() {
        if amp > spec.amps()[best] {
            best = i;
        }
    }
    (spec.freqs()[best], spec.amps()[best])
}

/// A tiny deterministic LCG for the reproducible sweeps.
fn lcg(state: &mut u64) -> u64 {
    *state = state
        .wrapping_mul(6_364_136_223_846_793_005)
        .wrapping_add(1_442_695_040_888_963_407);
    *state >> 16
}

// --------------------------------------------------------------------------- //
// Single tone: bin & amplitude
// --------------------------------------------------------------------------- //

#[test]
fn test_single_tone_peak_bin_and_amplitude() {
    let (fs, n, a) = (1000.0, 1024, 2.0);
    let f = 64.0 * fs / n as f64; // an exact bin (62.5 Hz)
    let samples = sine(a, f, fs, n);

    let spec = spectrum(&samples, fs, Window::Hann).expect("spectrum");
    let (peak_f, peak_a) = peak(&spec);

    assert!(
        (peak_f - f).abs() <= fs / n as f64,
        "peak bin {peak_f} vs {f}"
    );
    assert!(
        ((peak_a - a) / a).abs() < 0.01,
        "peak amplitude {peak_a} within 1% of {a}"
    );
}

// --------------------------------------------------------------------------- //
// Frequency axis & single-sided scaling
// --------------------------------------------------------------------------- //

#[test]
fn test_frequency_axis_scaling() {
    let (fs, n) = (2000.0, 16);
    let spec = spectrum(&sine(1.0, 250.0, fs, n), fs, Window::Rectangular).expect("spectrum");

    assert_eq!(spec.freqs().len(), n / 2 + 1, "single-sided length N/2+1");
    assert_eq!(spec.amps().len(), n / 2 + 1);
    for k in 0..=n / 2 {
        assert!(
            (spec.freqs()[k] - k as f64 * fs / n as f64).abs() < 1e-12,
            "freq[{k}] = k·fs/N"
        );
    }
    assert_eq!(spec.freqs()[0], 0.0, "DC bin");
    assert!(
        (spec.freqs()[n / 2] - fs / 2.0).abs() < 1e-12,
        "Nyquist = fs/2"
    );
}

#[test]
fn test_dc_and_nyquist_not_doubled() {
    let (fs, n, a) = (100.0, 32, 3.0);

    // Pure DC → amp[0] = A (not doubled).
    let spec = spectrum(&vec![a; n], fs, Window::Rectangular).expect("spectrum");
    assert!(
        (spec.amps()[0] - a).abs() < 1e-9,
        "DC amp {}",
        spec.amps()[0]
    );

    // Pure Nyquist a·(−1)^n → amp[N/2] = A (not doubled).
    let nyquist: Vec<f64> = (0..n).map(|i| if i % 2 == 0 { a } else { -a }).collect();
    let spec = spectrum(&nyquist, fs, Window::Rectangular).expect("spectrum");
    assert!(
        (spec.amps()[n / 2] - a).abs() < 1e-9,
        "Nyquist amp {}",
        spec.amps()[n / 2]
    );

    // An interior tone a·cos(2π·4·n/N) IS doubled → amp[4] = A.
    let tone: Vec<f64> = (0..n)
        .map(|i| a * (2.0 * PI * 4.0 * i as f64 / n as f64).cos())
        .collect();
    let spec = spectrum(&tone, fs, Window::Rectangular).expect("spectrum");
    assert!(
        (spec.amps()[4] - a).abs() < 1e-9,
        "interior amp {}",
        spec.amps()[4]
    );
}

#[test]
fn test_non_power_of_two_length() {
    // 150 = 2·3·5² — rustfft's mixed-radix transform handles it directly.
    let (fs, n, a) = (300.0, 150, 2.0);
    let f = 10.0 * fs / n as f64; // exact bin
    let spec = spectrum(&sine(a, f, fs, n), fs, Window::Hann).expect("spectrum");

    assert_eq!(spec.freqs().len(), n / 2 + 1);
    let (peak_f, peak_a) = peak(&spec);
    assert!(
        (peak_f - f).abs() <= fs / n as f64,
        "peak bin {peak_f} vs {f}"
    );
    assert!(((peak_a - a) / a).abs() < 0.01, "amp {peak_a} vs {a}");
}

// --------------------------------------------------------------------------- //
// Windows
// --------------------------------------------------------------------------- //

#[test]
fn test_hann_window_coefficients() {
    // Symmetric Hann over N=5: 0.5·(1 − cos(2πn/(N−1))) = [0, 0.5, 1, 0.5, 0].
    let mut buffer = vec![1.0; 5];
    let gain = apply_window(&mut buffer, Window::Hann);

    let expected = [0.0, 0.5, 1.0, 0.5, 0.0];
    for (got, want) in buffer.iter().zip(expected) {
        assert!((got - want).abs() < 1e-12, "coeff {got} vs {want}");
    }
    assert!((gain - 0.4).abs() < 1e-12, "coherent gain (mean) = 0.4");
}

#[test]
fn test_apply_window_empty_is_unit_gain() {
    // `apply_window` is public and total: an empty block returns unit gain.
    let mut empty: [f64; 0] = [];
    assert_eq!(apply_window(&mut empty, Window::Hann), 1.0);
}

#[test]
fn test_coherent_gain_correction() {
    let n = 100;

    // Rectangular gain is 1.
    let mut rect = vec![1.0; n];
    assert!((apply_window(&mut rect, Window::Rectangular) - 1.0).abs() < 1e-12);

    // Hann coherent gain is exactly (N−1)/(2N).
    let mut hann = vec![1.0; n];
    let gain = apply_window(&mut hann, Window::Hann);
    assert!((gain - (n as f64 - 1.0) / (2.0 * n as f64)).abs() < 1e-12);

    // Hamming ≈ 0.54, Blackman ≈ 0.42 (the DC coefficient of each).
    let mut hamming = vec![1.0; n];
    assert!((apply_window(&mut hamming, Window::Hamming) - 0.54).abs() < 0.01);
    let mut blackman = vec![1.0; n];
    assert!((apply_window(&mut blackman, Window::Blackman) - 0.42).abs() < 0.01);

    // The correction makes amplitudes physical: the same tone read through a
    // Hann window recovers its amplitude (not attenuated by the gain).
    let (fs, len, a) = (500.0, 512, 1.7);
    let f = 40.0 * fs / len as f64;
    let hann_amp = peak(&spectrum(&sine(a, f, fs, len), fs, Window::Hann).expect("spec")).1;
    assert!(
        ((hann_amp - a) / a).abs() < 0.01,
        "Hann amp {hann_amp} vs {a}"
    );
}

// --------------------------------------------------------------------------- //
// Property: peak tracks input frequency
// --------------------------------------------------------------------------- //

#[test]
fn prop_peak_matches_input_frequency() {
    let windows = [
        Window::Rectangular,
        Window::Hann,
        Window::Hamming,
        Window::Blackman,
    ];
    let mut state = 0xF17_5EED_u64;
    for _ in 0..400 {
        let fs = 500.0 + (lcg(&mut state) % 3500) as f64;
        let n = 128 + (lcg(&mut state) % 1024) as usize;
        let bin = fs / n as f64;
        // An interior tone near a bin (sub-bin offset in [−0.3, 0.3]·bin) so the
        // nearest bin is unambiguous.
        let k0 = 4 + (lcg(&mut state) % (n as u64 / 2 - 8)) as usize;
        let offset = ((lcg(&mut state) % 601) as f64 / 1000.0 - 0.3) * bin;
        let f = k0 as f64 * bin + offset;
        let a = 0.5 + (lcg(&mut state) % 400) as f64 / 100.0;
        let window = windows[(lcg(&mut state) % 4) as usize];

        let spec = spectrum(&sine(a, f, fs, n), fs, window).expect("spectrum");
        let (peak_f, _) = peak(&spec);

        assert!(
            (peak_f - f).abs() <= bin,
            "peak {peak_f} within one bin ({bin}) of {f} (n={n}, fs={fs})"
        );
    }
}

// --------------------------------------------------------------------------- //
// Parseval & empty input
// --------------------------------------------------------------------------- //

#[test]
fn test_parseval_energy_conserved() {
    // Single-sided Parseval (rectangular window): the time-domain energy equals
    // N·A₀² + N·A_Nyq² + (N/2)·Σ interior Aₖ².  Tones sit on exact bins so the
    // identity is exact to floating point.
    let (fs, n) = (1000.0, 64);
    let samples: Vec<f64> = (0..n)
        .map(|i| {
            let t = i as f64 / fs;
            1.5 * (2.0 * PI * 125.0 * t).sin() + 0.7 * (2.0 * PI * 250.0 * t).cos() + 0.3
        })
        .collect();

    let spec = spectrum(&samples, fs, Window::Rectangular).expect("spectrum");
    let amps = spec.amps();
    let nf = n as f64;

    let time_energy: f64 = samples.iter().map(|x| x * x).sum();
    let interior: f64 = amps[1..n / 2].iter().map(|x| x * x).sum();
    let freq_energy =
        nf * amps[0] * amps[0] + nf * amps[n / 2] * amps[n / 2] + (nf / 2.0) * interior;

    assert!(
        (time_energy - freq_energy).abs() / time_energy < 1e-9,
        "Parseval: time {time_energy} vs freq {freq_energy}"
    );
}

#[test]
fn test_empty_input_returns_error() {
    assert_eq!(
        spectrum(&[], 1000.0, Window::Hann).expect_err("empty input"),
        AnalysisError::EmptyRange
    );
}

#[test]
fn test_degenerate_window_at_length_two_is_finite() {
    // The symmetric Hann/Blackman windows collapse to all-zero coefficients at
    // N=2; the spectrum must stay finite and non-negative (all bins 0), never a
    // NaN or a negative "amplitude".
    for window in [
        Window::Rectangular,
        Window::Hann,
        Window::Hamming,
        Window::Blackman,
    ] {
        let spec = spectrum(&[1.0, 2.0], 100.0, window).expect("spectrum");
        assert_eq!(spec.len(), 2, "N/2+1 bins for N=2");
        for &amp in spec.amps() {
            assert!(
                amp.is_finite() && amp >= 0.0,
                "{window:?} amplitude {amp} must be finite and non-negative"
            );
        }
    }
}

#[test]
fn test_single_sample_spectrum_is_dc() {
    // One sample → only the DC bin, equal to that sample (rectangular).
    let spec = spectrum(&[4.0], 100.0, Window::Rectangular).expect("spectrum");
    assert_eq!(spec.freqs(), &[0.0]);
    assert!((spec.amps()[0] - 4.0).abs() < 1e-12);
    assert_eq!(spec.len(), 1);
    assert!(!spec.is_empty());
}
