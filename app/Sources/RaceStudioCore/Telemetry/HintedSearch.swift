import Foundation

/// The search every telemetry read shares (issue 9.9): the index of the last
/// element of the strictly increasing `times` at or before `t`, or `-1` when
/// `t` precedes them all (or is not finite).
///
/// `hint` carries the previous answer between calls. When it still lies at or
/// before `t`, the search walks forward from it a few steps — a frame-to-frame
/// advance at any channel rate — so a monotone sweep is amortized O(1); anything
/// else (a backwards seek, a far jump, a stale or out-of-range hint) falls back
/// to a binary search, O(log n). Either way the answer is the same; the hint is
/// then updated to it.
func lastIndex(atOrBefore t: Double, in times: [Double], hint: inout Int) -> Int {
    guard t.isFinite, let first = times.first, t >= first else {
        hint = -1
        return -1
    }
    if hint >= 0, hint < times.count, times[hint] <= t {
        var index = hint
        var steps = 0
        while index + 1 < times.count, times[index + 1] <= t, steps < hintWalk {
            index += 1
            steps += 1
        }
        if index + 1 == times.count || times[index + 1] > t {
            hint = index
            return index
        }
    }
    // First index whose time is > t, minus one.
    var low = 0, high = times.count
    while low < high {
        let mid = (low + high) / 2
        if times[mid] <= t { low = mid + 1 } else { high = mid }
    }
    hint = low - 1
    return low - 1
}

/// How many elements a forward hint walks before the binary search takes over.
private let hintWalk = 8
