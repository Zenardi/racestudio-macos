import Testing
import Foundation
@testable import RaceStudioCore

/// Tests for the accessibility surface (issue 7.3): the `AccessibilitySummary`
/// VoiceOver string a chart exposes for its plotted channel, the `ControlLabel`
/// catalogue of interactive controls, and the `ChannelViewModel` accessibility
/// hooks. Logic lives in `RaceStudioCore` (the 95% target); the thin shell only
/// applies the strings these produce.
@Suite struct AccessibilityTests {

    private let en = Locale(identifier: "en_US")
    private let ptBR = Locale(identifier: "pt_BR")

    // MARK: - Channel summary

    @Test func test_channel_accessibility_summary_includes_name_unit_range() {
        // A VoiceOver user gets the plotted channel's identity and data range
        // without sight: name, unit, and the min → max span.
        let summary = AccessibilitySummary.channel(
            name: "Speed", unit: "km/h", minimum: 10.0, maximum: 200.0, locale: en)

        #expect(summary.contains("Speed"), "the channel name is spoken")
        #expect(summary.contains("km/h"), "the unit is spoken")
        #expect(summary.contains("10"), "the minimum is spoken")
        #expect(summary.contains("200"), "the maximum is spoken")
        #expect(!L10n.isFlagged(summary), "the summary must be fully localized, never a raw key")
    }

    @Test func test_channel_summary_is_localized_ptBR() {
        let enSummary = AccessibilitySummary.channel(
            name: "Speed", unit: "km/h", minimum: 10.0, maximum: 200.0, locale: en)
        let ptSummary = AccessibilitySummary.channel(
            name: "Speed", unit: "km/h", minimum: 10.0, maximum: 200.0, locale: ptBR)
        #expect(enSummary != ptSummary, "the summary phrasing follows the locale")
        #expect(ptSummary.contains("Speed") && ptSummary.contains("km/h"))
    }

    @Test func test_channel_summary_dimensionless_omits_unit() {
        // A dimensionless channel (empty unit) must read cleanly, never "in ,".
        let summary = AccessibilitySummary.channel(
            name: "Gear", unit: "", minimum: 1, maximum: 6, locale: en)
        #expect(summary.contains("Gear"))
        #expect(!summary.contains("  "), "no doubled spaces from an empty unit")
        #expect(!summary.contains(" in ,"))
    }

    @Test func test_channel_summary_from_values_computes_range() {
        let summary = AccessibilitySummary.channel(
            name: "RPM", unit: "rpm", values: [1200, 8500, 3000, .nan, 500], locale: en)
        #expect(summary.contains("500"), "min over finite values")
        #expect(summary.contains("8,500") || summary.contains("8500"), "max over finite values")
    }

    @Test func test_channel_summary_no_data_is_localized() {
        // A channel with no finite samples reads as an explicit "no data", not a
        // blank or a NaN.
        let enSummary = AccessibilitySummary.channel(name: "Brake", unit: "bar", values: [.nan, .infinity], locale: en)
        let ptSummary = AccessibilitySummary.channel(name: "Brake", unit: "bar", values: [], locale: ptBR)
        #expect(enSummary.contains("Brake"))
        #expect(!enSummary.contains("nan") && !enSummary.lowercased().contains("inf"))
        #expect(enSummary != ptSummary, "the no-data phrasing is localized")
    }

    // MARK: - Control labels

    @Test func test_every_control_has_nonempty_label() {
        // Given any interactive control, VoiceOver must expose a non-empty, localized
        // label — in both shipped languages, and never a raw catalog key.
        #expect(!ControlLabel.allCases.isEmpty)
        for control in ControlLabel.allCases {
            #expect(!control.id.isEmpty, "control \(control) has an empty identity")
            for locale in [en, ptBR] {
                let label = control.label(locale: locale)
                #expect(!label.isEmpty, "control \(control) has an empty label for \(locale.identifier)")
                #expect(!L10n.isFlagged(label), "control \(control) resolves to a flagged key for \(locale.identifier)")
                // The accessibility label is the same localized text the control shows.
                #expect(control.accessibilityLabel(locale: locale) == label)
            }
        }
    }

    @Test func test_control_labels_are_localized_ptBR() {
        // At least the primary actions differ between languages (a smoke test that
        // pt-BR is genuinely wired, not an en copy).
        let differing = ControlLabel.allCases.filter {
            $0.label(locale: en) != $0.label(locale: ptBR)
        }
        #expect(!differing.isEmpty, "pt-BR control labels must not all mirror en")
    }

    // MARK: - ChannelViewModel wiring

    @MainActor
    @Test func test_channel_view_model_exposes_accessibility_label_and_value() {
        let trace = ChannelTrace(
            name: "Speed",
            times: [0, 1, 2, 3],
            distances: [0, 1, 2, 3],
            values: [10, 50, 200, 30])
        let model = ChannelViewModel(trace: trace)

        let label = model.accessibilityLabel(locale: en)
        #expect(label.contains("Speed"))
        #expect(!L10n.isFlagged(label))

        let value = model.accessibilityValue(unit: "km/h", locale: en)
        #expect(value.contains("km/h"))
        #expect(value.contains("10") && value.contains("200"), "spans the trace's min and max")
    }

    @MainActor
    @Test func test_channel_view_model_value_handles_empty_trace() {
        let model = ChannelViewModel(trace: ChannelTrace(name: "Empty", samples: []))
        let value = model.accessibilityValue(unit: "km/h", locale: en)
        #expect(value.contains("Empty"))
        #expect(!value.lowercased().contains("nan"))
    }
}
