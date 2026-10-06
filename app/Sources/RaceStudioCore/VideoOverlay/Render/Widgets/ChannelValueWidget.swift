import CoreGraphics
import Foundation

/// One channel's value (issue 9.11), under the channel's name: a role's value in
/// the frame's units (speed and temperatures converted to the widget's units),
/// or a session channel sampled by name in its own unit at its own precision.
struct ChannelValueWidget: OverlayWidgetDrawer {

    struct Layout: Sendable {
        let label: CGRect
        let value: CGRect
        let labelStyle: OverlayTextStyle
        let valueStyle: OverlayTextStyle
    }

    /// The decimals a role's readout is written with.
    static func decimals(for role: TelemetryRole) -> Int {
        switch role {
        case .speed, .rpm, .gear, .throttle, .waterTemp, .exhaustTemp: return 0
        case .brake: return 1
        case .latG, .lonG: return 2
        }
    }

    /// The label: the channel's name, or the role's in the export language — in capitals.
    static func label(_ context: OverlayWidgetContext) -> String {
        let locale = context.formatter.locale
        switch source(context) {
        case .role(let role): return role.overlayName(locale: locale).uppercased(with: locale)
        case .channel(let name): return name.uppercased(with: locale)
        case nil: return ""
        }
    }

    func layout(in context: OverlayWidgetContext) -> Layout {
        let content = context.content
        let (label, value) = content.divided(atDistance: (content.height * 0.35).rounded(), from: .maxYEdge)
        return Layout(label: label, value: value, labelStyle: context.style(for: label, fitting: Self.label(context)),
                      valueStyle: context.style(for: value, fitting: "88888.8 " + Self.unit(context)))
    }

    func drawStatic(_ layout: Layout, in graphics: CGContext, context: OverlayWidgetContext) {
        context.drawPlate(in: graphics)
        context.draw(Self.label(context), layout.labelStyle, in: layout.label, color: context.palette.secondary,
                     in: graphics)
    }

    func readouts(_ frame: TelemetryFrame, context: OverlayWidgetContext) -> [String] {
        let formatter = context.formatter
        let text: String
        switch Self.source(context) {
        case .role(.gear):
            text = formatter.gear(frame.gear)
        case .role(let role):
            text = formatter.number(Self.value(of: role, in: frame, units: context.units),
                                    decimals: Self.decimals(for: role))
        case .channel(let name):
            text = formatter.number(frame.value(ofChannelKey: TelemetryChannelMap.key(for: name)),
                                    decimals: Int(Self.channel(named: name, in: context)?.decimals ?? 2))
        case nil:
            text = OverlayFormatter.missing
        }
        let unit = Self.unit(context)
        return [text == OverlayFormatter.missing || unit.isEmpty ? text : text + " " + unit]
    }

    func drawDynamic(_ frame: TelemetryFrame, _ layout: Layout, in graphics: CGContext,
                     context: OverlayWidgetContext) {
        for text in readouts(frame, context: context) {
            context.draw(text, layout.valueStyle, in: layout.value, in: graphics)
        }
    }

    // MARK: - Internals

    private static func source(_ context: OverlayWidgetContext) -> OverlayChannelSource? {
        guard case .channelValue(let source) = context.widget.kind else { return nil }
        return source
    }

    /// The unit written after the value.
    private static func unit(_ context: OverlayWidgetContext) -> String {
        switch source(context) {
        case .role(.speed): return context.units.speedUnit
        case .role(.waterTemp), .role(.exhaustTemp): return context.units.temperatureUnit
        case .role(.gear), nil: return ""
        case .role(let role):
            return context.session.channelMap.binding(for: role)?.unit ?? role.canonicalUnit ?? ""
        case .channel(let name): return channel(named: name, in: context)?.unit ?? ""
        }
    }

    /// `role`'s value, speed and temperatures in `units`.
    private static func value(of role: TelemetryRole, in frame: TelemetryFrame, units: UnitSystem) -> Double? {
        guard let value = frame[role] else { return nil }
        switch role {
        case .speed: return units.speed(fromKilometresPerHour: value)
        case .waterTemp, .exhaustTemp: return units.temperature(fromCelsius: value)
        default: return value
        }
    }

    private static func channel(named name: String, in context: OverlayWidgetContext) -> Channel? {
        context.session.channelMap.channelIndex(named: name).map { context.session.channelMap.channels[$0] }
    }
}
