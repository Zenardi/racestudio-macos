//! The fine, local half of the offset search (issue 9.8): around the coarse
//! peak, the same weighted mean-salience score evaluated directly on a dense
//! grid of offsets and pitch/RPM ratios, from frames every 20 ms on a 0.5 %
//! pitch grid, then parabolically interpolated — sub-frame precision for the
//! cost of one more pass over the audio.
//!
//! The pass is streamed frame by frame, so no fine salience map is held, and
//! each frame scores only the **band** of pitch candidates the examined
//! offsets and ratios can reach — a few dozen of ~650 — z-scored with the
//! whole row's statistics taken on the coarse grid.

use std::ops::Range;

use super::rpm::LogRpm;
use super::salience::{row_stats, FrameAnalyzer, Harmonics, LogGrid};
use super::search::Coarse;
use super::PitchConfig;
use crate::audio_sync::pitch::parabolic_offset;

/// Hop between refinement frames (seconds).
const FINE_HOP_S: f64 = 0.02;
/// Pitch-candidate spacing of the refinement (0.5 % in `ln f`).
const FINE_DU: f64 = 0.005;
/// Offsets examined either side of the coarse peak (seconds).
const OFFSET_SPAN_S: f64 = 0.2;
/// Spacing of the examined offsets (seconds).
const OFFSET_STEP_S: f64 = 0.005;
/// `ln k` values examined either side of the coarse ratio — 1½ coarse bins.
const LOG_K_SPAN: f64 = 0.02;
/// Step of the RPM lookup grid (seconds): the offset step, so every examined
/// offset lands on it.
const RPM_STEP_S: f64 = 0.005;

/// The refined alignment.
#[derive(Debug, Clone, Copy, PartialEq)]
pub(crate) struct Fine {
    pub offset_s: f64,
    pub score: f64,
    pub log_k: f64,
}

/// Refine `coarse` against the usable RPM `points`, or keep it (with its own
/// score) when no examined offset gathers `min_overlap_s` seconds of voiced
/// frames. `stats_du` is the coarse grid spacing the per-frame z-score
/// statistics are taken on.
pub(crate) fn refine(
    pcm: &[f32],
    fs: f64,
    cfg: &PitchConfig,
    points: &[(f64, f64)],
    coarse: &Coarse,
    min_overlap_s: f64,
    stats_du: f64,
) -> Fine {
    let fallback = Fine {
        offset_s: coarse.offset_s,
        score: coarse.peak,
        log_k: coarse.log_k,
    };
    let Some(mut analyzer) = FrameAnalyzer::new(fs, cfg) else {
        return fallback;
    };
    let fine = analyzer.taps(
        LogGrid::new(cfg.min_hz, cfg.max_hz, FINE_DU),
        Harmonics::Flat,
    );
    let stats = analyzer.taps(
        LogGrid::new(cfg.min_hz, cfg.max_hz, stats_du),
        Harmonics::Flat,
    );
    let rpm = LogRpm::new(points, RPM_STEP_S);
    let n = analyzer.frame_len();
    let hop = (FINE_HOP_S * fs).round().max(1.0) as usize;
    let offsets = around(coarse.offset_s, OFFSET_SPAN_S, OFFSET_STEP_S);
    let log_ks = around(coarse.log_k, LOG_K_SPAN, FINE_DU);
    let (k_lo, k_hi) = (log_ks[0], log_ks[log_ks.len() - 1]);

    let mut tally = Tally::new(offsets.len(), log_ks.len());
    let mut stats_row = vec![0.0_f32; stats.grid.len];
    let mut band_row = vec![0.0_f32; fine.grid.len];
    let mut looked: Vec<Option<(f64, f64)>> = vec![None; offsets.len()];
    let Some(last_start) = pcm.len().checked_sub(n) else {
        return fallback;
    };
    for start in (0..=last_start).step_by(hop) {
        let t = (start as f64 + n as f64 / 2.0) / fs;
        if !in_reach(&rpm, t, &offsets) || !analyzer.load(pcm, start) {
            continue;
        }
        analyzer.score(&stats, &mut stats_row);
        let Some((mean, std)) = row_stats(&stats_row) else {
            continue;
        };
        // ln rpm (and its timing weight) under every examined offset; the
        // band of fine candidates they can reach.
        let (mut lo, mut hi) = (f64::INFINITY, f64::NEG_INFINITY);
        for (slot, &offset) in looked.iter_mut().zip(&offsets) {
            let session_t = t - offset;
            *slot = rpm.at(session_t).zip(rpm.weight_at(session_t));
            if let Some((lr, _)) = *slot {
                lo = lo.min(lr);
                hi = hi.max(lr);
            }
        }
        let band = band(&fine.grid, k_lo + lo, k_hi + hi);
        if band.is_empty() {
            continue;
        }
        let row = &mut band_row[..band.len()];
        analyzer.score_band(&fine, band.clone(), row);
        for v in row.iter_mut() {
            *v = ((f64::from(*v) - mean) / std) as f32;
        }
        for (i, slot) in looked.iter().enumerate() {
            if let Some((lr, weight)) = *slot {
                let saliences = log_ks
                    .iter()
                    .map(|&log_k| sample(row, fine.grid.position(log_k + lr) - band.start as f64));
                tally.add(i, weight, saliences);
            }
        }
    }
    let min_overlap = (min_overlap_s / FINE_HOP_S).ceil() as usize;
    tally
        .best(&offsets, &log_ks, min_overlap)
        .unwrap_or(fallback)
}

/// `center ± span` in steps of `step`, ascending.
fn around(center: f64, span: f64, step: f64) -> Vec<f64> {
    let steps = (span / step).round() as i64;
    (-steps..=steps).map(|i| center + i as f64 * step).collect()
}

/// The candidates of `grid` needed to interpolate anywhere in `[u_lo, u_hi]`,
/// clipped to the grid (empty when the range misses it, or is not a range).
fn band(grid: &LogGrid, u_lo: f64, u_hi: f64) -> Range<usize> {
    let (lo, hi) = (
        grid.position(u_lo).floor(),
        grid.position(u_hi).ceil() + 2.0,
    );
    if !(lo.is_finite() && hi.is_finite()) || hi <= 0.0 || lo >= grid.len as f64 {
        return 0..0;
    }
    (lo.max(0.0) as usize)..(hi.min(grid.len as f64) as usize)
}

/// The weighted salience sums of every examined `(offset, ln k)`, with each
/// offset's frame count and total weight.
#[derive(Debug, Clone, PartialEq)]
struct Tally {
    width: usize,
    sums: Vec<f64>,
    frames: Vec<usize>,
    weight: Vec<f64>,
}

impl Tally {
    fn new(offsets: usize, log_ks: usize) -> Self {
        Self {
            width: log_ks,
            sums: vec![0.0; offsets * log_ks],
            frames: vec![0; offsets],
            weight: vec![0.0; offsets],
        }
    }

    /// Count one frame at offset `i` with timing weight `weight`, adding its
    /// salience at each examined `ln k`.
    fn add(&mut self, i: usize, weight: f64, saliences: impl Iterator<Item = f64>) {
        self.frames[i] += 1;
        self.weight[i] += weight;
        let sums = &mut self.sums[i * self.width..(i + 1) * self.width];
        for (sum, salience) in sums.iter_mut().zip(saliences) {
            *sum += weight * salience;
        }
    }

    /// The weighted mean salience at `(i, j)`.
    fn score(&self, i: usize, j: usize) -> f64 {
        self.sums[i * self.width + j] / self.weight[i]
    }

    /// The best examined `(offset, ln k)` among offsets with at least
    /// `min_overlap` frames, parabolically refined along the offset axis.
    fn best(&self, offsets: &[f64], log_ks: &[f64], min_overlap: usize) -> Option<Fine> {
        let enough = |i: usize| self.frames[i] >= min_overlap.max(1) && self.weight[i] > 0.0;
        let mut top: Option<(usize, usize, f64)> = None;
        for i in (0..offsets.len()).filter(|&i| enough(i)) {
            for j in 0..self.width {
                let s = self.score(i, j);
                if top.map_or(true, |(_, _, best)| s > best) {
                    top = Some((i, j, s));
                }
            }
        }
        let (i, j, peak) = top?;
        let column: Vec<f32> = (0..offsets.len())
            .map(|r| {
                if enough(r) {
                    self.score(r, j) as f32
                } else {
                    f32::NEG_INFINITY
                }
            })
            .collect();
        let shift = if column.iter().all(|v| v.is_finite()) {
            parabolic_offset(&column, i)
        } else {
            0.0
        };
        Some(Fine {
            offset_s: offsets[i] + shift * OFFSET_STEP_S,
            score: peak,
            log_k: log_ks[j],
        })
    }
}

/// Whether frame time `t` can meet the RPM trace at any examined offset.
fn in_reach(rpm: &LogRpm, t: f64, offsets: &[f64]) -> bool {
    let (Some(&first), Some(&last)) = (offsets.first(), offsets.last()) else {
        return false;
    };
    let end = rpm.t0 + rpm.step * rpm.values.len() as f64;
    t - last >= rpm.t0 && t - first <= end
}

/// The z-scored salience at fractional index `pos` of `row`, linearly
/// interpolated; `0` (the row mean) outside it.
fn sample(row: &[f32], pos: f64) -> f64 {
    if pos.is_nan() || pos < 0.0 {
        return 0.0;
    }
    let i = pos.floor() as usize;
    if i + 1 >= row.len() {
        return 0.0;
    }
    let w = pos - i as f64;
    f64::from(row[i]) * (1.0 - w) + f64::from(row[i + 1]) * w
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn sample_interpolates_inside_the_row_and_is_neutral_outside() {
        let row = [0.0_f32, 2.0, 4.0, 6.0, 8.0, 10.0, 12.0, 14.0];
        assert!((sample(&row, 1.5) - 3.0).abs() < 1e-6);
        assert_eq!(sample(&row, -0.5), 0.0);
        assert_eq!(sample(&row, 7.0), 0.0);
        assert_eq!(sample(&row, f64::NAN), 0.0);
    }

    #[test]
    fn band_covers_the_reachable_candidates_and_clips_to_the_grid() {
        let grid = LogGrid::new(10.0, 100.0, 0.1); // 24 candidates
        let u = |i: f64| grid.u0 + i * grid.du;
        assert_eq!(band(&grid, u(3.2), u(5.5)), 3..8);
        assert_eq!(band(&grid, u(-4.0), u(0.5)), 0..3);
        assert_eq!(band(&grid, u(22.5), u(40.0)), 22..24);
        assert!(band(&grid, u(30.0), u(40.0)).is_empty());
        assert!(band(&grid, u(-9.0), u(-5.0)).is_empty());
        assert!(band(&grid, f64::INFINITY, f64::NEG_INFINITY).is_empty());
    }

    #[test]
    fn around_steps_symmetrically() {
        assert_eq!(around(1.0, 0.5, 0.25), vec![0.5, 0.75, 1.0, 1.25, 1.5]);
    }

    #[test]
    fn tally_takes_the_weighted_mean() {
        let mut tally = Tally::new(1, 2);
        tally.add(0, 1.0, [2.0, 4.0].into_iter());
        tally.add(0, 3.0, [6.0, 0.0].into_iter());
        assert!((tally.score(0, 0) - 5.0).abs() < 1e-12, "(1·2 + 3·6) / 4");
        assert!((tally.score(0, 1) - 1.0).abs() < 1e-12, "(1·4 + 3·0) / 4");
    }

    #[test]
    fn best_skips_offsets_without_enough_frames() {
        let offsets = [0.0, 0.005, 0.01];
        let log_ks = [-4.0];
        let mut tally = Tally::new(3, 1);
        tally.add(0, 1.0, [9.0].into_iter());
        for _ in 0..2 {
            tally.add(1, 1.0, [1.0].into_iter());
        }
        for _ in 0..3 {
            tally.add(2, 1.0, [1.0].into_iter());
        }
        let fine = tally.best(&offsets, &log_ks, 2).unwrap();
        assert_eq!(fine.offset_s, 0.005, "the first offset has too few frames");
        assert!(tally.best(&offsets, &log_ks, 10).is_none());
    }

    #[test]
    fn best_interpolates_between_examined_offsets() {
        let offsets = [0.0, 0.005, 0.01];
        let mut tally = Tally::new(3, 1);
        for (i, s) in [1.0, 3.0, 2.0].into_iter().enumerate() {
            tally.add(i, 1.0, [s].into_iter());
        }
        let fine = tally.best(&offsets, &[-4.0], 1).unwrap();
        assert!(
            fine.offset_s > 0.005 && fine.offset_s < 0.0075,
            "{}",
            fine.offset_s
        );
        assert_eq!(fine.score, 3.0);
    }
}
