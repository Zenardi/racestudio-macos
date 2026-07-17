import Foundation

/// Generates "nice" axis tick values — multiples of 1, 2, or 5 × 10ⁿ — for a
/// given domain and an approximate desired tick count (issue 4.1).
public enum TickGenerator {
    /// Ascending nice ticks that all fall inside `domain`, with a count within
    /// ±1 of `targetCount` for typical axes. Returns `[]` for a degenerate
    /// (zero- or negative-span, or non-finite) domain or a non-positive
    /// `targetCount`.
    public static func ticks(for domain: ClosedRange<Double>, targetCount: Int) -> [Double] {
        let span = domain.upperBound - domain.lowerBound
        guard span > 0, span.isFinite, targetCount > 0 else { return [] }

        var step = niceNumber(span / Double(targetCount), rounding: true)
        // Guarantee at least one interior tick: a nice step no wider than the
        // span always has a multiple inside a window that wide.
        if step > span { step = niceNumber(span, rounding: false) }
        guard step > 0, step.isFinite else { return [] }

        let lower = domain.lowerBound, upper = domain.upperBound
        let epsilon = step * 1e-9
        let firstIndex = (lower / step).rounded(.up)
        let lastIndex = (upper / step).rounded(.down)

        var ticks: [Double] = []
        ticks.reserveCapacity(Int((lastIndex - firstIndex).magnitude) + 2)
        // Scan one index beyond each end so a boundary tick lost to float drift
        // is still recovered by the ±epsilon domain check.
        var index = firstIndex - 1
        while index <= lastIndex + 1 {
            let value = index * step
            if value >= lower - epsilon && value <= upper + epsilon {
                ticks.append(value)
            }
            index += 1
        }
        return ticks
    }

    /// The nearest "nice" number (mantissa 1, 2, 5, or 10) to `value`. With
    /// `rounding` the mantissa rounds to the closest nice value; without it, it
    /// rounds down (the largest nice number ≤ `value`).
    private static func niceNumber(_ value: Double, rounding: Bool) -> Double {
        guard value > 0 else { return 0 }
        let exponent = floor(log10(value))
        let mantissa = value / pow(10, exponent) // in [1, 10)
        let niceMantissa: Double
        if rounding {
            switch mantissa {
            case ..<1.5: niceMantissa = 1
            case ..<3: niceMantissa = 2
            case ..<7: niceMantissa = 5
            default: niceMantissa = 10
            }
        } else {
            switch mantissa {
            case ..<2: niceMantissa = 1
            case ..<5: niceMantissa = 2
            default: niceMantissa = 5
            }
        }
        return niceMantissa * pow(10, exponent)
    }
}
