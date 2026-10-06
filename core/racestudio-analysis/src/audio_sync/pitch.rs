//! The engine pitch track (issue 9.8): one fundamental-frequency estimate per
//! frame from the harmonic salience, with a voicing confidence.

use super::salience::{FrameAnalyzer, Harmonics, LogGrid};
use super::PitchConfig;

/// Candidate spacing of the pitch track: 0.5 % in `ln f`, refined between
/// candidates by parabolic interpolation.
const PITCH_DU: f64 = 0.005;

/// A frame is voiced when its best candidate's raw salience — nats of whitened
/// log magnitude at its harmonics — exceeds this. The strongest of ~650
/// candidates on broadband noise stays below one nat; a lone clean sine (the
/// weakest harmonic signal: one partial, no overtones) reads about two.
const VOICED_SALIENCE: f64 = 1.4;

/// The raw salience at which a frame's confidence saturates at `1`.
const CLEAR_SALIENCE: f64 = 2.8;

/// One frame of a pitch track.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct PitchPoint {
    /// The frame's centre, in seconds from the first sample.
    pub t: f64,
    /// The estimated fundamental (Hz); `0` when the frame is unvoiced.
    pub f0: f64,
    /// Voicing confidence in `[0, 1]`: `0` for a silent or noise-only frame,
    /// rising with how far the pitch stands out of the frame's salience.
    pub confidence: f64,
}

/// The pitch track of mono `pcm` sampled at `sample_rate` Hz: Hann-windowed
/// frames of [`PitchConfig::frame_s`] (rounded to a power of two) every
/// [`PitchConfig::hop_s`], each scored by subharmonic summation over
/// [`PitchConfig::harmonics`] harmonics in the `min_hz..max_hz` band.
///
/// The caller decimates to ~8 kHz first; any rate whose Nyquist clears the band
/// works. Never panics: audio shorter than one frame, a zero rate or an
/// unworkable configuration yields an empty track, and a silent or noise-only
/// frame is reported with `f0 = 0` and `confidence = 0`.
#[must_use]
pub fn pitch_track(pcm: &[f32], sample_rate: u32, cfg: &PitchConfig) -> Vec<PitchPoint> {
    let fs = f64::from(sample_rate);
    let grid = LogGrid::new(cfg.min_hz, cfg.max_hz, PITCH_DU);
    let Some(mut analyzer) = FrameAnalyzer::new(fs, cfg) else {
        return Vec::new();
    };
    let taps = analyzer.taps(grid, Harmonics::Decaying);
    let n = analyzer.frame_len();
    if pcm.len() < n || !(cfg.hop_s.is_finite() && cfg.hop_s > 0.0) {
        return Vec::new();
    }
    let hop = (cfg.hop_s * fs).round().max(1.0) as usize;
    let mut row = vec![0.0_f32; grid.len];
    (0..=pcm.len() - n)
        .step_by(hop)
        .map(|start| {
            let t = (start as f64 + n as f64 / 2.0) / fs;
            if !analyzer.load(pcm, start) {
                return PitchPoint {
                    t,
                    f0: 0.0,
                    confidence: 0.0,
                };
            }
            analyzer.score(&taps, &mut row);
            let (best, peak) = argmax(&row);
            let confidence =
                ((peak - VOICED_SALIENCE) / (CLEAR_SALIENCE - VOICED_SALIENCE)).clamp(0.0, 1.0);
            if confidence <= 0.0 {
                return PitchPoint {
                    t,
                    f0: 0.0,
                    confidence: 0.0,
                };
            }
            let f0 = grid.hz(best as f64 + parabolic_offset(&row, best));
            PitchPoint { t, f0, confidence }
        })
        .collect()
}

/// The index and value of the largest element (the first on a tie).
fn argmax(row: &[f32]) -> (usize, f64) {
    let mut best = 0;
    for (i, &v) in row.iter().enumerate() {
        if v > row[best] {
            best = i;
        }
    }
    (best, f64::from(row[best]))
}

/// The sub-sample offset of the vertex of the parabola through `row[i-1..=i+1]`
/// — `0` at an edge or on a flat top.
pub(crate) fn parabolic_offset(row: &[f32], i: usize) -> f64 {
    if i == 0 || i + 1 >= row.len() {
        return 0.0;
    }
    let (y0, y1, y2) = (
        f64::from(row[i - 1]),
        f64::from(row[i]),
        f64::from(row[i + 1]),
    );
    let den = y0 - 2.0 * y1 + y2;
    if den.abs() < f64::EPSILON {
        return 0.0;
    }
    (0.5 * (y0 - y2) / den).clamp(-0.5, 0.5)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parabolic_offset_finds_the_vertex() {
        // y = −(x − 0.25)² sampled at −1, 0, 1 → vertex 0.25 right of the middle.
        let row = [-(1.25_f32 * 1.25), -(0.25 * 0.25), -(0.75 * 0.75)];
        assert!((parabolic_offset(&row, 1) - 0.25).abs() < 1e-6);
    }

    #[test]
    fn parabolic_offset_is_zero_at_edges_and_flat_tops() {
        assert_eq!(parabolic_offset(&[1.0, 2.0], 0), 0.0);
        assert_eq!(parabolic_offset(&[1.0, 2.0], 1), 0.0);
        assert_eq!(parabolic_offset(&[1.0, 1.0, 1.0], 1), 0.0);
    }

    #[test]
    fn argmax_takes_the_first_of_a_tie() {
        assert_eq!(argmax(&[1.0, 3.0, 3.0]), (1, 3.0));
    }
}
