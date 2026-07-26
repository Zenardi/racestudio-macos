//! Criterion benches for min/max decimation (issue 7.2).
//!
//! Two tracked benchmarks, matched by `scripts/bench_thresholds.json`:
//! - `decimate/single_channel` — one dense channel (1M samples) reduced to a
//!   1920-column envelope (the per-channel plot cost);
//! - `decimate/full_session` — a whole session's worth of channels decimated in
//!   one pass (the cost of laying out an analysis window).
//!
//! Data is generated in-memory so the bench is self-contained and runs in CI
//! without the git-ignored `synthetic_5m.xrk` fixture.

use criterion::{black_box, criterion_group, criterion_main, Criterion};
use racestudio_analysis::min_max_decimate;

/// A deterministic, well-spread waveform on a 100 Hz (ms) time axis — the same
/// shape the decimation tests use, so bench and test exercise identical inputs.
fn synthetic(n: usize) -> Vec<(f64, f64)> {
    (0..n)
        .map(|i| {
            let t = i as f64 * 10.0;
            let v = (i as f64 * 0.017).sin() * 100.0 + ((i % 251) as f64) * 0.3;
            (t, v)
        })
        .collect()
}

fn bench_decimation(c: &mut Criterion) {
    // A 1080p-ish target column count — the realistic upper bound of a plot width.
    let buckets = 1_920;

    let mut group = c.benchmark_group("decimate");

    let single = synthetic(1_000_000);
    group.bench_function("single_channel", |b| {
        b.iter(|| min_max_decimate(black_box(&single), black_box(buckets)));
    });

    // A full session: many channels decimated back-to-back for one layout pass.
    let channels: Vec<Vec<(f64, f64)>> = (0..24).map(|_| synthetic(250_000)).collect();
    group.bench_function("full_session", |b| {
        b.iter(|| {
            let mut total = 0usize;
            for channel in &channels {
                total += min_max_decimate(black_box(channel), black_box(buckets)).len();
            }
            total
        });
    });

    group.finish();
}

criterion_group!(benches, bench_decimation);
criterion_main!(benches);
