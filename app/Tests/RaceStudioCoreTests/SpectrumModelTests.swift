import Testing
import Foundation
@testable import RaceStudioCore

/// Tests for `SpectrumModel` (issue 8.16) — the pure feed adapter that turns a
/// channel's single-sided amplitude spectrum (the engine's `fft_spectrum`) into
/// the reused ``SpectrumView``'s frequency-vs-amplitude points, and computes the
/// dominant-frequency peak. The RS3 Frequency Analysis panel for damper /
/// vibration work. Covered without SwiftUI, and — through a fake seam — without
/// the FFI.
@Suite struct SpectrumModelTests {

    // MARK: - Builders (no logic)

    private func channel(_ name: String, count: UInt32 = 8) -> Channel {
        Channel(name: name, unit: "", sampleRateHz: 10, decimals: 0, sampleCount: count)
    }

    private func session(_ channels: [Channel]) -> Session {
        Session(
            metadata: SessionMetadata(
                vehicle: "", track: "", driver: "", session: "",
                series: "", logDate: "", logTime: "", datetimeUtc: 0),
            channels: channels, laps: [])
    }

    // MARK: - Pure assembly (criterion 1: amplitude-vs-frequency)

    @Test func test_points_pair_frequencies_with_amplitudes_in_order() {
        let model = SpectrumModel(channel: "RPM", windowFunction: .hann,
                                  spectrum: ChannelSpectrum(freqs: [0, 10, 20], amps: [1, 5, 2]))
        #expect(model.points == [
            SpectrumPoint(frequency: 0, amplitude: 1),
            SpectrumPoint(frequency: 10, amplitude: 5),
            SpectrumPoint(frequency: 20, amplitude: 2)
        ])
    }

    @Test func test_channel_and_window_function_are_carried() {
        let model = SpectrumModel(channel: "Damper_FL", windowFunction: .blackman,
                                  spectrum: ChannelSpectrum(freqs: [0], amps: [1]))
        #expect(model.channel == "Damper_FL")
        #expect(model.windowFunction == .blackman)
    }

    @Test func test_peak_is_the_dominant_frequency() throws {
        let model = SpectrumModel(channel: "RPM", windowFunction: .hann,
                                  spectrum: ChannelSpectrum(freqs: [0, 10, 20], amps: [1, 5, 2]))
        let peak = try #require(model.peak)
        #expect(peak == SpectrumPoint(frequency: 10, amplitude: 5))
    }

    @Test func test_empty_spectrum_has_no_points_and_no_peak() {
        let model = SpectrumModel(channel: "RPM", windowFunction: .hann, spectrum: .empty)
        #expect(model.isEmpty)
        #expect(model.points.isEmpty)
        #expect(model.peak == nil)
    }

    @Test func test_mismatched_axis_lengths_degrade_to_the_common_prefix_without_trapping() {
        // A malformed spectrum (more freqs than amps) pairs only where both exist.
        let model = SpectrumModel(channel: "RPM", windowFunction: .hann,
                                  spectrum: ChannelSpectrum(freqs: [0, 10, 20], amps: [1, 5]))
        #expect(model.points == [
            SpectrumPoint(frequency: 0, amplitude: 1),
            SpectrumPoint(frequency: 10, amplitude: 5)
        ])
    }

    @Test func test_more_amps_than_freqs_also_degrades_to_the_common_prefix() {
        // The reverse malformed case (more amps than freqs) is symmetric.
        let model = SpectrumModel(channel: "RPM", windowFunction: .hann,
                                  spectrum: ChannelSpectrum(freqs: [0, 10], amps: [1, 5, 2]))
        #expect(model.points == [
            SpectrumPoint(frequency: 0, amplitude: 1),
            SpectrumPoint(frequency: 10, amplitude: 5)
        ])
    }

    @Test func test_peak_ties_resolve_to_the_lowest_frequency() {
        // Two bins share the max amplitude; `max(by:)` keeps the first (lowest freq).
        let model = SpectrumModel(channel: "RPM", windowFunction: .hann,
                                  spectrum: ChannelSpectrum(freqs: [0, 10, 20], amps: [5, 3, 5]))
        #expect(model.peak == SpectrumPoint(frequency: 0, amplitude: 5))
    }

    @Test func test_peak_ignores_nan_amplitudes() {
        // A stray NaN must not capture the peak (defensive; the engine emits 0, not NaN).
        let model = SpectrumModel(channel: "RPM", windowFunction: .hann,
                                  spectrum: ChannelSpectrum(freqs: [0, 10, 20], amps: [.nan, 4, 2]))
        #expect(model.peak == SpectrumPoint(frequency: 10, amplitude: 4))
    }

    @Test func test_peak_is_nil_when_every_amplitude_is_non_finite() {
        let model = SpectrumModel(channel: "RPM", windowFunction: .hann,
                                  spectrum: ChannelSpectrum(freqs: [0, 10], amps: [.nan, .nan]))
        #expect(model.peak == nil)
    }

    // MARK: - compute(from:) over the live session (criterion 1)

    @MainActor
    @Test func test_compute_reads_the_spectrum_from_the_session() {
        let spectrum = ChannelSpectrum(freqs: [0, 10, 20], amps: [3, 7, 1])
        let source = FakeSessionDataSource(
            banks: [[]],
            spectra: [.init(channel: "RPM", windowFunction: .hann): spectrum])
        let sut = AnalysisSession(session: session([channel("RPM")]), dataSource: source)

        let model = SpectrumModel.compute(from: sut, channel: "RPM", windowFunction: .hann)

        #expect(!model.isEmpty)
        #expect(model.points.map(\.frequency) == [0, 10, 20])
        #expect(model.points.map(\.amplitude) == [3, 7, 1])
    }

    // MARK: - Window-function choice (criterion 2: changing it updates the spectrum)

    @MainActor
    @Test func test_changing_the_window_function_changes_the_spectrum() {
        // The engine returns a different spectrum per taper; the model reflects it.
        let source = FakeSessionDataSource(
            banks: [[]],
            spectra: [
                .init(channel: "RPM", windowFunction: .hann): ChannelSpectrum(freqs: [0, 10], amps: [1, 9]),
                .init(channel: "RPM", windowFunction: .hamming): ChannelSpectrum(freqs: [0, 10], amps: [2, 4])
            ])
        let sut = AnalysisSession(session: session([channel("RPM")]), dataSource: source)

        let hann = SpectrumModel.compute(from: sut, channel: "RPM", windowFunction: .hann)
        let hamming = SpectrumModel.compute(from: sut, channel: "RPM", windowFunction: .hamming)

        #expect(hann.points != hamming.points, "a different taper yields a different spectrum")
        #expect(hann.windowFunction == .hann)
        #expect(hamming.windowFunction == .hamming)
    }

    @MainActor
    @Test func test_compute_forwards_the_selected_window_function_and_bounds_to_the_engine() {
        let source = FakeSessionDataSource(
            banks: [[]],
            spectra: [.init(channel: "RPM", windowFunction: .blackman): ChannelSpectrum(freqs: [0], amps: [1])])
        let sut = AnalysisSession(session: session([channel("RPM")]), dataSource: source)

        _ = SpectrumModel.compute(from: sut, channel: "RPM", windowFunction: .blackman,
                                  window: TimeWindow(start: 1, end: 4))

        #expect(source.lastSpectrumRequest == .init(channel: "RPM", windowFunction: .blackman, start: 1, end: 4))
    }

    // MARK: - Error / edge paths (criterion 3: no crash)

    @MainActor
    @Test func test_compute_degrades_to_empty_when_the_engine_throws() {
        // An engine error (e.g. too-few-samples window) degrades to a blank panel.
        let source = FakeSessionDataSource(banks: [[]], spectrumError: FakeSessionDataSource.UnknownChannel())
        let sut = AnalysisSession(session: session([channel("RPM")]), dataSource: source)

        let model = SpectrumModel.compute(from: sut, channel: "RPM", windowFunction: .hann)

        #expect(model.isEmpty)
    }

    @MainActor
    @Test func test_compute_degrades_to_empty_for_an_unknown_channel() {
        let source = FakeSessionDataSource(banks: [[]]) // no spectra seeded
        let sut = AnalysisSession(session: session([channel("RPM")]), dataSource: source)

        let model = SpectrumModel.compute(from: sut, channel: "NoSuchChannel", windowFunction: .hann)

        #expect(model.isEmpty)
    }

    @MainActor
    @Test func test_non_uniform_channel_transforms_via_the_engine_without_crashing() {
        // The engine resamples a non-uniformly-sampled channel to a uniform rate
        // before the FFT (issue 3.3); at the Swift seam that is just "a spectrum
        // comes back and compute never throws". The resampling itself is covered
        // in the Rust engine + the real-.xrk adapter test.
        let source = FakeSessionDataSource(
            banks: [[]],
            spectra: [.init(channel: "Steer", windowFunction: .hann): ChannelSpectrum(freqs: [0, 5], amps: [4, 2])])
        let sut = AnalysisSession(session: session([channel("Steer")]), dataSource: source)

        let model = SpectrumModel.compute(from: sut, channel: "Steer", windowFunction: .hann)

        #expect(model.points.count == 2)
    }
}

/// Tests for `SpectrumWindowKind` (issue 8.16) — Core's mirror of the FFI window
/// functions and the picker labels the thin panel binds to.
@Suite struct SpectrumWindowKindTests {

    @Test func test_all_four_tapers_are_offered() {
        #expect(SpectrumWindowKind.allCases == [.rectangular, .hann, .hamming, .blackman])
    }

    @Test func test_titles_label_the_picker() {
        #expect(SpectrumWindowKind.rectangular.title == "Rectangular")
        #expect(SpectrumWindowKind.hann.title == "Hann")
        #expect(SpectrumWindowKind.hamming.title == "Hamming")
        #expect(SpectrumWindowKind.blackman.title == "Blackman")
    }

    @Test func test_id_is_the_raw_value() {
        #expect(SpectrumWindowKind.hann.id == "hann")
    }
}

/// Tests for `ChannelSpectrum` (issue 8.16) — Core's mirror of the FFI `SpectrumDto`.
@Suite struct ChannelSpectrumTests {

    @Test func test_empty_spectrum_is_two_empty_axes() {
        #expect(ChannelSpectrum.empty == ChannelSpectrum(freqs: [], amps: []))
    }
}

/// Tests for `SpectrumPanelModel` (issue 8.16) — the window-level taper knob the
/// Spectrum panel binds to, held apart from the window model so it survives layout
/// switches.
@Suite struct SpectrumPanelModelTests {

    @MainActor @Test func test_default_window_function_is_hann() {
        #expect(SpectrumPanelModel().windowFunction == .hann)
    }

    @MainActor @Test func test_set_window_function_updates_the_choice() {
        let model = SpectrumPanelModel()
        model.setWindowFunction(.blackman)
        #expect(model.windowFunction == .blackman)
    }
}
