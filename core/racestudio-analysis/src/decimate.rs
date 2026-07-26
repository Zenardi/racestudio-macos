//! Min/max decimation (issue 7.2): reduce a dense channel to a per-pixel-column
//! min/max envelope so a multi-million-sample channel renders in a screen's worth
//! of points with no visual loss.
//!
//! A logged endurance channel can hold millions of `(time, value)` samples;
//! drawing them all stalls the UI and paints far more points than a display has
//! pixels. [`min_max_decimate`] buckets the samples into (at most) one bucket per
//! pixel column and keeps only each bucket's minimum and maximum — the two points
//! that bound what that column must show — so every peak and trough survives while
//! the point count collapses to twice the column count.

/// Reduce `samples` (`(time, value)` pairs in time order) to a min/max envelope
/// of `2 * buckets` points — one vertical min/max pair per bucket (≈ pixel
/// column).
///
/// Each bucket spans the even index range `[b * n / buckets, (b + 1) * n /
/// buckets)`; its minimum-value and maximum-value samples are emitted **in time
/// order**, so the resulting polyline stays monotonic in time. When a bucket's min
/// and max are the same sample it is emitted twice (a zero-height column), keeping
/// the output a regular two points per bucket. The scan visits every sample
/// exactly once — a single O(n) pass — and every emitted point is a real source
/// sample, so injected spikes are preserved exactly at any zoom level whose bucket
/// contains them. Non-finite (`NaN`) samples never mask a bucket's real min/max (a
/// `Channel` may carry `NaN` for a blank cell); a bucket that is entirely `NaN`
/// yields a `NaN` point.
///
/// Degenerate inputs are returned unchanged (a copy) rather than decimated — an
/// empty channel, a zero `buckets`, or a `buckets` at or above the sample count
/// (there is nothing to reduce) — so the function never panics or divides by zero.
#[must_use]
pub fn min_max_decimate(samples: &[(f64, f64)], buckets: usize) -> Vec<(f64, f64)> {
    if buckets == 0 || buckets >= samples.len() {
        return samples.to_vec();
    }

    let n = samples.len();
    let mut envelope = Vec::with_capacity(buckets * 2);
    for bucket in 0..buckets {
        let start = bucket * n / buckets;
        let end = (bucket + 1) * n / buckets;
        // `buckets < n` guarantees `start < end`, so the bucket is never empty.
        let mut min_index = start;
        let mut max_index = start;
        for i in (start + 1)..end {
            let value = samples[i].1;
            // NaN-safe: `<`/`>` are always false for `NaN`, so a `NaN` never
            // displaces a real extreme; the `is_nan()` fallback lets any real value
            // replace a `NaN` a bucket happened to start on, so genuine peaks and
            // troughs are never masked by a `NaN` (e.g. a blank CSV cell — see
            // `Channel::new`). A bucket that is entirely `NaN` yields a `NaN` point.
            if value < samples[min_index].1 || samples[min_index].1.is_nan() {
                min_index = i;
            }
            if value > samples[max_index].1 || samples[max_index].1.is_nan() {
                max_index = i;
            }
        }
        // Emit the two extremes in time order (index order is time order).
        let first = min_index.min(max_index);
        let second = min_index.max(max_index);
        envelope.push(samples[first]);
        envelope.push(samples[second]);
    }
    envelope
}
