import Foundation

/// One setting of ``OverlayWidgetOptions`` the overlay editor offers (issue
/// 9.12), bound to its value and named for the editor.
public enum OverlayWidgetOption: String, CaseIterable, Sendable {
    case maxRPM
    case shiftLightRPM
    case deltaRange
    case gForceMax
    case trackMapRotation
    /// The throttle reading at a full bar — the #188 follow-up, for a throttle
    /// logged in mm rather than %.
    case throttleFullScale
    /// The brake reading at a full bar — for a brake logged in bar.
    case brakeFullScale

    /// The setting this option reads and writes.
    public var keyPath: WritableKeyPath<OverlayWidgetOptions, Double> {
        switch self {
        case .maxRPM: return \.maxRPM
        case .shiftLightRPM: return \.shiftLightRPM
        case .deltaRange: return \.deltaRange
        case .gForceMax: return \.gForceMax
        case .trackMapRotation: return \.trackMapRotation
        case .throttleFullScale: return \.throttleFullScale
        case .brakeFullScale: return \.brakeFullScale
        }
    }

    /// The option's name in `locale`, with its unit — `"Shift light at (rpm)"`.
    public func title(locale: Locale = .current) -> String {
        switch self {
        case .maxRPM: return L10n.string(.overlayOptionMaxRPM, locale: locale)
        case .shiftLightRPM: return L10n.string(.overlayOptionShiftLight, locale: locale)
        case .deltaRange: return L10n.string(.overlayOptionDeltaRange, locale: locale)
        case .gForceMax: return L10n.string(.overlayOptionGForceMax, locale: locale)
        case .trackMapRotation: return L10n.string(.overlayOptionMapRotation, locale: locale)
        case .throttleFullScale: return L10n.string(.overlayOptionThrottleFullScale, locale: locale)
        case .brakeFullScale: return L10n.string(.overlayOptionBrakeFullScale, locale: locale)
        }
    }
}

public extension OverlayWidgetKind {

    /// The settings a widget of this kind draws with, in the editor's order —
    /// none for a kind with nothing to set.
    var editableOptions: [OverlayWidgetOption] {
        switch self {
        case .rpm: return [.maxRPM, .shiftLightRPM]
        case .delta: return [.deltaRange]
        case .gForce: return [.gForceMax]
        case .trackMap: return [.trackMapRotation]
        case .pedals: return [.throttleFullScale, .brakeFullScale]
        default: return []
        }
    }
}

public extension OverlayEditorModel {

    /// Set widget `id`'s `option` to `value`, validated with the rest of its
    /// options, as one undoable step.
    func setOption(_ option: OverlayWidgetOption, to value: Double, for id: OverlayWidget.ID) {
        guard var options = layout.widgets.first(where: { $0.id == id })?.options else { return }
        options[keyPath: option.keyPath] = value
        setOptions(options, for: id)
    }
}
