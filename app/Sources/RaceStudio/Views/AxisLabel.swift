import SwiftUI

/// The shared tick-label style for the Core-driven plot axes (issue 4.5): a
/// compact, secondary `%g`-formatted number. Kept in one place so the histogram
/// and scatter axes stay visually consistent.
enum AxisLabel {
    static func text(_ value: Double) -> Text {
        Text(String(format: "%g", value)).font(.caption2).foregroundColor(.secondary)
    }
}
