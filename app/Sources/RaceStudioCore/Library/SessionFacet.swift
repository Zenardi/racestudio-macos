import Foundation

/// The six RaceStudio 3 search facets (issue 8.15).
///
/// A single place the browser model and the filter both agree on: how each facet
/// reads a ``SessionSummary`` (for building the list of distinct choices) and how
/// it is applied to a ``FilterSpec`` (for filtering). Keeping the mapping here
/// means adding a facet is one enum case, not scattered `switch`es.
public enum SessionFacet: String, CaseIterable, Identifiable, Sendable {
    case racer, vehicle, track, championship, comment, logger

    public var id: String { rawValue }

    /// Human-facing label for the facet control.
    public var title: String {
        switch self {
        case .racer: return "Racer"
        case .vehicle: return "Vehicle"
        case .track: return "Track"
        case .championship: return "Championship"
        case .comment: return "Comment"
        case .logger: return "Logger"
        }
    }

    /// This facet's value on a summary (for building the distinct-choices list).
    public func value(in summary: SessionSummary) -> String {
        switch self {
        case .racer: return summary.driver
        case .vehicle: return summary.vehicle
        case .track: return summary.venue
        case .championship: return summary.championship
        case .comment: return summary.comment
        case .logger: return summary.logger
        }
    }

    /// This facet's current constraint on a spec (`nil` when unconstrained).
    public func value(in spec: FilterSpec) -> String? {
        switch self {
        case .racer: return spec.racer
        case .vehicle: return spec.vehicle
        case .track: return spec.track
        case .championship: return spec.championship
        case .comment: return spec.comment
        case .logger: return spec.logger
        }
    }

    /// Set this facet's constraint on `spec` (pass `nil` to clear it).
    public func apply(_ value: String?, to spec: inout FilterSpec) {
        switch self {
        case .racer: spec.racer = value
        case .vehicle: spec.vehicle = value
        case .track: spec.track = value
        case .championship: spec.championship = value
        case .comment: spec.comment = value
        case .logger: spec.logger = value
        }
    }
}
