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
    /// The speed dial's full scale, km/h (issue 9.15).
    case maxSpeed

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
        case .maxSpeed: return \.maxSpeed
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
        case .maxSpeed: return L10n.string(.overlayOptionMaxSpeed, locale: locale)
        }
    }
}

public extension OverlayWidgetKind {

    /// The settings a widget of this kind can draw with, in the editor's order —
    /// none for a kind with nothing to set. ``OverlayWidget/editableOptions``
    /// narrows them to the widget's gauge style.
    var editableOptions: [OverlayWidgetOption] {
        switch self {
        case .rpm: return [.maxRPM, .shiftLightRPM]
        case .speed: return [.maxSpeed]
        case .delta: return [.deltaRange]
        case .gForce: return [.gForceMax]
        case .trackMap: return [.trackMapRotation]
        case .pedals: return [.throttleFullScale, .brakeFullScale]
        default: return []
        }
    }

    /// Whether a widget of this kind can be drawn as a needle dial (issue 9.15).
    var offersGaugeStyle: Bool {
        self == .rpm || self == .speed
    }
}

public extension OverlayWidget {

    /// The settings this widget draws with, in the editor's order: its kind's,
    /// less the speed dial's full scale while the speed shows as digits.
    var editableOptions: [OverlayWidgetOption] {
        kind.editableOptions.filter { $0 != .maxSpeed || options.gaugeStyle == .needle }
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

    /// Draw widget `id` in `style` — a needle dial or the classic bar and
    /// digits — as one undoable step (issue 9.15).
    func setGaugeStyle(_ style: OverlayGaugeStyle, for id: OverlayWidget.ID) {
        guard var options = layout.widgets.first(where: { $0.id == id })?.options else { return }
        options.gaugeStyle = style
        setOptions(options, for: id)
    }
}
