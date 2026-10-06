import Foundation

extension OverlayLayout {

    /// The session channels this layout's readouts name
    /// (``OverlayWidgetKind/channelValue(_:)`` with ``OverlayChannelSource/channel(_:)``),
    /// in layout order, each once (matched like the channel map, ignoring case and
    /// surrounding spaces; the first spelling is kept) — what the telemetry
    /// timeline must also sample for the overlay (issue 9.11). Hidden widgets are
    /// included, so toggling one on needs no reload.
    public var sessionChannelNames: [String] {
        var seen = Set<String>()
        return validated().widgets.compactMap { widget in
            guard case .channelValue(.channel(let name)) = widget.kind,
                  seen.insert(TelemetryChannelMap.key(for: name)).inserted else { return nil }
            return name
        }
    }
}
