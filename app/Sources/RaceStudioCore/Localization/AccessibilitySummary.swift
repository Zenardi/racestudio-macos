import Foundation

/// Builds the VoiceOver value a chart exposes for its plotted channel (issue 7.3),
/// so a VoiceOver user gets the channel's identity and data range without sight:
/// its name, unit, and min → max span, fully localized.
///
/// Numbers are formatted for the locale (pt-BR `,` decimal; en `.`), integral
/// values drop their fraction for a cleaner read, and a channel with no finite
/// samples reads as an explicit "no data" rather than a blank or a `NaN`.
public enum AccessibilitySummary {

    /// The VoiceOver value for a channel with a known `minimum`/`maximum`.
    /// A dimensionless channel (empty `unit`) omits the unit clause entirely.
    public static func channel(
        name: String,
        unit: String,
        minimum: Double,
        maximum: Double,
        locale: Locale = .current
    ) -> String {
        let minText = measure(minimum, locale: locale)
        let maxText = measure(maximum, locale: locale)
        if unit.isEmpty {
            return L10n.format(.accessibilityChannelSummaryNoUnit, locale: locale, name, minText, maxText)
        }
        return L10n.format(.accessibilityChannelSummary, locale: locale, name, unit, minText, maxText)
    }

    /// The VoiceOver value for a channel derived from its raw `values`. Non-finite
    /// samples are dropped before computing the range; a channel with no finite
    /// value reads as a localized "no data".
    public static func channel(
        name: String,
        unit: String,
        values: [Double],
        locale: Locale = .current
    ) -> String {
        guard let range = finiteRange(values) else {
            return L10n.format(.accessibilityChannelNoData, locale: locale, name)
        }
        return channel(
            name: name,
            unit: unit,
            minimum: range.minimum,
            maximum: range.maximum,
            locale: locale)
    }

    /// The min/max over the finite `values` in a single `O(n)` pass — a chart's
    /// channel can hold millions of samples, and a VoiceOver value must not sort or
    /// allocate on the main thread (that would undo issue 7.2's decimation work).
    /// Returns `nil` when no finite value remains.
    static func finiteRange(_ values: [Double]) -> (minimum: Double, maximum: Double)? {
        var minimum = Double.infinity
        var maximum = -Double.infinity
        var sawFinite = false
        for value in values where value.isFinite {
            sawFinite = true
            if value < minimum { minimum = value }
            if value > maximum { maximum = value }
        }
        return sawFinite ? (minimum, maximum) : nil
    }

    /// Formats a range endpoint for speech: integral values drop the fraction,
    /// others keep two digits; a non-finite value renders the em-dash placeholder.
    private static func measure(_ value: Double, locale: Locale) -> String {
        guard value.isFinite else { return ChannelFormatting.emDash }
        let fractionDigits = (value == value.rounded()) ? 0 : 2
        return L10n.formattedNumber(value, fractionDigits: fractionDigits, locale: locale)
    }
}

/// The catalogue of interactive controls whose accessibility labels are localized
/// (issue 7.3). Enumerable so a test asserts *every* control exposes a non-empty,
/// localized label in every shipped language — the thin shell binds each control's
/// ``label(locale:)`` to its `accessibilityLabel`.
public enum ControlLabel: String, CaseIterable, Sendable, Identifiable {
    case importSession
    case exportCSV
    case openSession
    case deleteSession
    case downloadSession
    case connectDevice
    case addMathChannel
    case zoomIn
    case zoomOut
    case resetZoom
    case toggleLapOverlay
    case addChannel
    case removeChannel
    case addPlot
    case removePlot
    case selectLap

    public var id: String { rawValue }

    /// The localization key backing this control's label.
    public var key: L10n.Key {
        switch self {
        case .importSession: return .controlImport
        case .exportCSV: return .controlExportCSV
        case .openSession: return .controlOpen
        case .deleteSession: return .controlDelete
        case .downloadSession: return .controlDownload
        case .connectDevice: return .controlConnectDevice
        case .addMathChannel: return .controlAddMathChannel
        case .zoomIn: return .controlZoomIn
        case .zoomOut: return .controlZoomOut
        case .resetZoom: return .controlResetZoom
        case .toggleLapOverlay: return .controlToggleLapOverlay
        case .addChannel: return .controlAddChannel
        case .removeChannel: return .controlRemoveChannel
        case .addPlot: return .controlAddPlot
        case .removePlot: return .controlRemovePlot
        case .selectLap: return .controlSelectLap
        }
    }

    /// The localized label for `locale` (default: the current locale).
    public func label(locale: Locale = .current) -> String {
        L10n.string(key, locale: locale)
    }

    /// The VoiceOver accessibility label — the same localized text as ``label(locale:)``.
    public func accessibilityLabel(locale: Locale = .current) -> String {
        label(locale: locale)
    }
}
