import Foundation

/// The search every telemetry read shares (issue 9.9): the index of the last
/// element of the strictly increasing `times` at or before `t`, or `-1` when
/// `t` precedes them all (or is not finite).
///
/// `hint` carries the previous answer between calls. When it still lies at or
/// before `t`, the search gallops forward from it (1, 2, 4, … elements) and then
/// bisects the last stride, so advancing `k` elements costs O(log k) — O(1) for
/// a frame step on a channel logged at or below the frame rate, and still cheap
/// for a 1 kHz channel swept at 30 fps. Anything else (a backwards seek, a stale
/// or out-of-range hint) falls back to a binary search over everything,
/// O(log n). Either way the answer is the same; the hint is then updated to it.
func lastIndex(atOrBefore t: Double, in times: [Double], hint: inout Int) -> Int {
    guard t.isFinite, let first = times.first, t >= first else {
        hint = -1
        return -1
    }
    var low = 0, high = times.count
    if hint >= 0, hint < times.count, times[hint] <= t {
        // Gallop: grow the stride until it overshoots `t` (or the end).
        low = hint
        var stride = 1
        while low + stride < times.count, times[low + stride] <= t {
            low += stride
            stride *= 2
        }
        high = Swift.min(low + stride, times.count)
    }
    // Invariant: times[low] <= t (or low == 0 when not galloping), and every
    // index at or past `high` is after `t`. Bisect for the first index > t.
    var lower = low, upper = high
    while lower < upper {
        let mid = (lower + upper) / 2
        if times[mid] <= t { lower = mid + 1 } else { upper = mid }
    }
    hint = lower - 1
    return lower - 1
}
