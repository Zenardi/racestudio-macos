import Testing
@testable import RaceStudioCore

/// Tests for `SuspensionComposition` (issue 8.17): the pure, view-free description
/// of the RS3 Suspension Analysis layout — the ordered set of sub-panels
/// (shock time/distance + travel histogram + damper FFT + settings) the composite
/// stacks into one view.
@Suite struct SuspensionCompositionTests {

    @Test func test_standard_composition_stacks_time_distance_histogram_fft_and_settings_in_order() {
        #expect(SuspensionComposition.standard.panels
            == [.timeDistance, .histogram, .spectrum, .settings])
    }

    @Test func test_standard_composition_contains_the_three_required_analysis_panels() {
        let composition = SuspensionComposition.standard
        // The acceptance criterion: time/distance + histogram + FFT compose together.
        #expect(composition.contains(.timeDistance))
        #expect(composition.contains(.histogram))
        #expect(composition.contains(.spectrum))
    }

    @Test func test_contains_is_false_for_a_panel_not_in_the_composition() {
        let sparse = SuspensionComposition(panels: [.timeDistance])
        #expect(!sparse.contains(.spectrum))
    }

    @Test func test_panel_kind_exposes_every_case_with_a_title() {
        #expect(SuspensionPanelKind.allCases == [.timeDistance, .histogram, .spectrum, .settings])
        #expect(SuspensionPanelKind.timeDistance.title == "Time / Distance")
        #expect(SuspensionPanelKind.histogram.title == "Histogram")
        #expect(SuspensionPanelKind.spectrum.title == "FFT")
        #expect(SuspensionPanelKind.settings.title == "Settings")
    }

    @Test func test_panel_kind_id_is_the_raw_value() {
        #expect(SuspensionPanelKind.timeDistance.id == "timeDistance")
        #expect(SuspensionPanelKind.spectrum.id == "spectrum")
    }
}
