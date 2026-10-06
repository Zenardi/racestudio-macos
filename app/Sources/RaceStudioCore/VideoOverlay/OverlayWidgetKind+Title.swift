import Foundation

public extension OverlayWidgetKind {

    /// The widget's name in `locale`, as the overlay editor's widget list shows
    /// it (issue 9.12) — `"Track map"`, `"Pedais"`. A channel readout is named
    /// for what it reads: its role (`"Water temperature"`) or its channel's own
    /// name.
    func title(locale: Locale = .current) -> String {
        switch self {
        case .channelValue(.role(let role)):
            let name = role.overlayName(locale: locale)
            return name.prefix(1).uppercased(with: locale) + name.dropFirst()
        case .channelValue(.channel(let name)):
            return name
        default:
            return L10n.string(titleKey, locale: locale)
        }
    }

    /// The catalog key naming a kind without a parameter.
    private var titleKey: L10n.Key {
        switch self {
        case .speed: return .overlayWidgetSpeed
        case .rpm: return .overlayWidgetRpm
        case .gear: return .overlayWidgetGear
        case .lapTimer: return .overlayWidgetLapTimer
        case .lapInfo: return .overlayWidgetLapInfo
        case .delta: return .overlayWidgetDelta
        case .gForce: return .overlayWidgetGForce
        case .trackMap: return .overlayWidgetTrackMap
        case .pedals: return .overlayWidgetPedals
        case .temperature: return .overlayWidgetTemperature
        case .sectorTimes: return .overlayWidgetSectorTimes
        case .kartBadge: return .overlayWidgetKartBadge
        case .sessionInfo, .channelValue: return .overlayWidgetSessionInfo
        }
    }
}
