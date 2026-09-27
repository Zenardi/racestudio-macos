import Foundation

/// The map shown underneath the racing line on the track map.
///
/// The plot is readable on its own, and drawing it over imagery costs network
/// requests and contrast — so there is no backdrop unless the user asks for one.
/// Satellite is the useful case for a circuit: it shows the kerbs and run-off the
/// line actually relates to, which a road map of a kart track does not have.
public enum TrackMapBackdrop: String, Equatable, Sendable, Codable, CaseIterable {
    /// No map — the racing line on the plot background (the default).
    case none
    /// The standard road map.
    case standard
    /// Satellite imagery.
    case satellite
    /// Satellite imagery with road and place labels.
    case hybrid

    /// The startup choice: no imagery, so the app stays readable and offline until
    /// the user opts in.
    public static let `default` = TrackMapBackdrop.none

    /// The label shown in the map-style picker.
    public var title: String {
        switch self {
        case .none: return "No Map"
        case .standard: return "Map"
        case .satellite: return "Satellite"
        case .hybrid: return "Hybrid"
        }
    }

    /// Whether choosing this style makes the app fetch map tiles. Imagery needs the
    /// `com.apple.security.network.client` entitlement and an internet connection;
    /// ``none`` needs neither, which is why it is the default.
    public var needsNetwork: Bool { self != .none }
}
