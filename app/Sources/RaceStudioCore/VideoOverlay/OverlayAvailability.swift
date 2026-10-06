import Foundation

/// What a session can feed a video overlay (issue 9.10) — what widget
/// availability is decided against: the session's channels, as the overlay's
/// ``TelemetryChannelMap`` resolved them, and the facts beyond the channels.
///
/// The caller states each fact (from the loaded session, its split timeline,
/// its ``TelemetryTimeline`` and the garage), so the layout model depends on
/// none of them.
public struct OverlaySessionContext: Equatable, Sendable {
    /// The session's channels, resolved onto the overlay's roles.
    public var channelMap: TelemetryChannelMap
    /// Whether the session has a lap the lap clock can time.
    public var hasLaps: Bool
    /// Whether its laps are divided into sectors.
    public var hasSectors: Bool
    /// Whether it carries a GPS track (the mini map, the computed delta).
    public var hasTrackPosition: Bool
    /// The garage kart assigned to the session, if any.
    public var kart: Kart?
    /// The session's details (venue, date, driver), if known.
    public var metadata: SessionMetadata?

    public init(channelMap: TelemetryChannelMap, hasLaps: Bool, hasSectors: Bool, hasTrackPosition: Bool,
                kart: Kart? = nil, metadata: SessionMetadata? = nil) {
        self.channelMap = channelMap
        self.hasLaps = hasLaps
        self.hasSectors = hasSectors
        self.hasTrackPosition = hasTrackPosition
        self.kart = kart
        self.metadata = metadata
    }

    /// What the kart badge says: the kart's specification, e.g.
    /// `"F4 · Thunder · RBC Honda · 18 HP"`, or its name when it has none; `nil`
    /// without a kart (the badge is hidden).
    public var kartBadgeText: String? {
        guard let kart else { return nil }
        return kart.specification.isEmpty ? kart.displayName : kart.specification
    }

    /// Whether the session has anything for the session-info widget to show — its
    /// venue, date or session name.
    var hasSessionDetails: Bool {
        guard let metadata else { return false }
        return [metadata.track, metadata.logDate, metadata.session]
            .contains { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    /// Sector times need laps, divided into sectors.
    var sectorAvailability: WidgetAvailability {
        guard hasLaps else { return .unavailable(.noLaps) }
        return hasSectors ? .available : .unavailable(.noSectors)
    }

    /// The delta is read from the logger's own delta channel, or computed from
    /// the laps and the GPS distance — either source will do.
    var deltaAvailability: WidgetAvailability {
        if !channelMap.loggerDeltaChannels.isEmpty { return .available }
        guard hasLaps else { return .unavailable(.noLaps) }
        return hasTrackPosition ? .available : .unavailable(.noTrackPosition)
    }

    /// Whether the session has a sampled channel called `name` (matched like the
    /// channel map: case- and surrounding-whitespace-insensitively).
    func hasChannel(named name: String) -> Bool {
        channelMap.channelIndex(named: name) != nil
    }
}

/// Whether a session can feed a widget (issue 9.10). An unavailable widget is
/// skipped by the renderer — never drawn empty; a degraded one is drawn with
/// what there is, and its reason says what is missing.
public enum WidgetAvailability: Equatable, Sendable {
    case available
    /// Drawn with part of its data.
    case degraded(OverlayAvailabilityReason)
    /// Not drawn.
    case unavailable(OverlayAvailabilityReason)

    /// Whether the renderer draws the widget.
    public var isDrawable: Bool {
        if case .unavailable = self { return false }
        return true
    }

    /// What is missing, or `nil` when nothing is.
    public var reason: OverlayAvailabilityReason? {
        switch self {
        case .available: return nil
        case .degraded(let reason), .unavailable(let reason): return reason
        }
    }
}

/// Why a widget is degraded or unavailable (issue 9.10), worded for the
/// operator by ``label(locale:)``.
public enum OverlayAvailabilityReason: Equatable, Hashable, Sendable {
    /// No channel plays this role.
    case missingRole(TelemetryRole)
    /// Neither role has a channel.
    case missingRoles(TelemetryRole, TelemetryRole)
    /// One role of a pair has no channel; the widget shows the other.
    case partialRoles(missing: TelemetryRole, showing: TelemetryRole)
    /// The session has no sampled channel by this name.
    case missingChannel(String)
    case noLaps
    case noSectors
    /// No GPS track.
    case noTrackPosition
    /// No garage kart is assigned to the session.
    case noKart
    /// The session has no details to show.
    case noSessionInfo

    /// The reason as a sentence — `"No throttle channel; showing brake only"`.
    public func label(locale: Locale = .current) -> String {
        switch self {
        case .missingRole(let role):
            return L10n.format(.overlayReasonMissingRole, locale: locale, role.overlayName(locale: locale))
        case let .missingRoles(first, second):
            return L10n.format(.overlayReasonMissingRoles, locale: locale,
                               first.overlayName(locale: locale), second.overlayName(locale: locale))
        case let .partialRoles(missing, showing):
            return L10n.format(.overlayReasonPartialRoles, locale: locale,
                               missing.overlayName(locale: locale), showing.overlayName(locale: locale))
        case .missingChannel(let name):
            return L10n.format(.overlayReasonMissingChannel, locale: locale, name)
        case .noLaps: return L10n.string(.overlayReasonNoLaps, locale: locale)
        case .noSectors: return L10n.string(.overlayReasonNoSectors, locale: locale)
        case .noTrackPosition: return L10n.string(.overlayReasonNoTrackPosition, locale: locale)
        case .noKart: return L10n.string(.overlayReasonNoKart, locale: locale)
        case .noSessionInfo: return L10n.string(.overlayReasonNoSessionInfo, locale: locale)
        }
    }
}

extension OverlayWidgetKind {

    /// Whether `session` can feed this kind of widget:
    ///
    /// - a channel readout needs its role's channel (or the named channel);
    /// - pedals, temperatures and the G-ball read a *pair* of roles — with one
    ///   of the two they are degraded, with neither unavailable;
    /// - the lap widgets need laps, sector times sectors too, the map a GPS track;
    /// - the delta is computed from laps and GPS distance, or read from the
    ///   logger's own delta channel, so either source makes it available;
    /// - the kart badge needs a kart, session info some session detail.
    public func availability(for session: OverlaySessionContext) -> WidgetAvailability {
        let map = session.channelMap
        switch need {
        case .role(let role): return map.isAvailable(role) ? .available : .unavailable(.missingRole(role))
        case let .rolePair(first, second): return Self.pair(first, second, in: map)
        case .channel(let name):
            return session.hasChannel(named: name) ? .available : .unavailable(.missingChannel(name))
        case .laps: return session.hasLaps ? .available : .unavailable(.noLaps)
        case .sectors: return session.sectorAvailability
        case .trackPosition: return session.hasTrackPosition ? .available : .unavailable(.noTrackPosition)
        case .delta: return session.deltaAvailability
        case .kart: return session.kart != nil ? .available : .unavailable(.noKart)
        case .details: return session.hasSessionDetails ? .available : .unavailable(.noSessionInfo)
        }
    }

    /// What a widget of a kind needs from the session.
    private enum Need {
        /// One role's channel.
        case role(TelemetryRole)
        /// A pair of roles; either alone draws half the widget.
        case rolePair(TelemetryRole, TelemetryRole)
        /// The session channel with this name.
        case channel(String)
        case laps
        /// Laps divided into sectors.
        case sectors
        case trackPosition
        /// A computed or logged delta.
        case delta
        case kart
        /// Some session detail.
        case details
    }

    private var need: Need {
        switch self {
        case .speed: return .role(.speed)
        case .rpm: return .role(.rpm)
        case .gear: return .role(.gear)
        case .channelValue(.role(let role)): return .role(role)
        case .channelValue(.channel(let name)): return .channel(name)
        case .pedals: return .rolePair(.throttle, .brake)
        case .temperature: return .rolePair(.waterTemp, .exhaustTemp)
        case .gForce: return .rolePair(.latG, .lonG)
        case .lapTimer, .lapInfo: return .laps
        case .sectorTimes: return .sectors
        case .trackMap: return .trackPosition
        case .delta: return .delta
        case .kartBadge: return .kart
        case .sessionInfo: return .details
        }
    }

    private static func pair(_ first: TelemetryRole, _ second: TelemetryRole,
                             in map: TelemetryChannelMap) -> WidgetAvailability {
        switch (map.isAvailable(first), map.isAvailable(second)) {
        case (true, true): return .available
        case (true, false): return .degraded(.partialRoles(missing: second, showing: first))
        case (false, true): return .degraded(.partialRoles(missing: first, showing: second))
        case (false, false): return .unavailable(.missingRoles(first, second))
        }
    }
}

extension OverlayLayout {

    /// Whether `session` can feed each widget of the ``validated()`` layout, by
    /// widget id — hidden widgets included, so the editor can say why one would
    /// not draw. The renderer skips every widget that is not
    /// ``WidgetAvailability/isDrawable`` (``drawable(for:session:)``).
    public func availability(for session: OverlaySessionContext) -> [OverlayWidget.ID: WidgetAvailability] {
        Dictionary(uniqueKeysWithValues: validated().widgets.map { ($0.id, $0.kind.availability(for: session)) })
    }

    /// What the renderer draws for `session` in an output of `aspect`: the
    /// ``resolved(for:)`` draw list, back to front, without the widgets the
    /// session cannot feed (degraded ones stay). Like ``resolved(for:)``, it
    /// validates the layout, so compute it once per layout, session and output
    /// size, not per frame.
    public func drawable(for aspect: OverlayAspect, session: OverlaySessionContext) -> [ResolvedOverlayWidget] {
        resolved(for: aspect).filter { $0.widget.kind.availability(for: session).isDrawable }
    }
}

extension TelemetryRole {
    /// The role's name inside an overlay sentence — "No **RPM** channel".
    func overlayName(locale: Locale) -> String {
        switch self {
        case .speed: return L10n.string(.overlayRoleSpeed, locale: locale)
        case .rpm: return L10n.string(.overlayRoleRpm, locale: locale)
        case .gear: return L10n.string(.overlayRoleGear, locale: locale)
        case .throttle: return L10n.string(.overlayRoleThrottle, locale: locale)
        case .brake: return L10n.string(.overlayRoleBrake, locale: locale)
        case .latG: return L10n.string(.overlayRoleLatG, locale: locale)
        case .lonG: return L10n.string(.overlayRoleLonG, locale: locale)
        case .waterTemp: return L10n.string(.overlayRoleWaterTemp, locale: locale)
        case .exhaustTemp: return L10n.string(.overlayRoleExhaustTemp, locale: locale)
        }
    }
}
