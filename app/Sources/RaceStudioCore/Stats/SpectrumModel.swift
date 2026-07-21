import Foundation

/// One point of an amplitude spectrum (issue 8.16): a frequency (Hz) and the
/// single-sided amplitude at it — the reused ``SpectrumView``'s `(x, y)`.
public struct SpectrumPoint: Equatable, Sendable {
    /// Frequency in Hz.
    public let frequency: Double
    /// Single-sided amplitude at ``frequency``.
    public let amplitude: Double

    public init(frequency: Double, amplitude: Double) {
        self.frequency = frequency
        self.amplitude = amplitude
    }
}

/// Assembles the ``SpectrumView``'s inputs from a channel's amplitude spectrum
/// (issue 8.16 — the RaceStudio 3 **Frequency Analysis** panel for damper /
/// vibration work): the frequency-vs-amplitude ``points`` and the
/// dominant-frequency ``peak``, computed once from a ``ChannelSpectrum``.
///
/// Pure: the FFT, the pre-transform resampling, and the window taper are the
/// engine's (`fft_spectrum`, tested Rust); this only pairs the aligned
/// `freqs`/`amps` and finds the peak, so the view stays a thin points-to-pixels
/// renderer. A spectrum with empty or mismatched axes yields no points (an empty,
/// peak-less panel) rather than trapping.
public struct SpectrumModel: Sendable {

    /// The transformed channel's name (empty when none is selected).
    public let channel: String

    /// The window function the amplitudes were computed with — surfaced so the
    /// panel can label which taper produced this spectrum.
    public let windowFunction: SpectrumWindowKind

    /// The frequency-vs-amplitude points, ascending in frequency.
    public let points: [SpectrumPoint]

    /// - Parameters:
    ///   - channel: the transformed channel's display name (for the panel title).
    ///   - windowFunction: the taper the amplitudes were computed with.
    ///   - spectrum: the engine's single-sided amplitude spectrum.
    public init(channel: String, windowFunction: SpectrumWindowKind, spectrum: ChannelSpectrum) {
        self.channel = channel
        self.windowFunction = windowFunction
        // Pair only where both axes carry a value; a malformed spectrum with
        // mismatched lengths degrades to the common prefix rather than trapping.
        let count = min(spectrum.freqs.count, spectrum.amps.count)
        self.points = (0..<count).map {
            SpectrumPoint(frequency: spectrum.freqs[$0], amplitude: spectrum.amps[$0])
        }
    }

    /// Whether the spectrum is empty (nothing to plot).
    public var isEmpty: Bool { points.isEmpty }

    /// The dominant frequency: the finite-amplitude point of greatest amplitude, or
    /// `nil` when the spectrum has no finite amplitudes — the headline number for a
    /// vibration / damper read. NaN amplitudes are ignored (the engine emits `0` for
    /// unrecoverable bins, so this is defensive), keeping the peak stable regardless
    /// of where a stray NaN would fall.
    public var peak: SpectrumPoint? {
        points.filter { $0.amplitude.isFinite }.max { $0.amplitude < $1.amplitude }
    }
}

public extension SpectrumModel {
    /// Compute the amplitude spectrum of `channel` from the live `session`, tapered
    /// by `windowFunction`, over `window` (issue 8.16). On any engine error — an
    /// unknown channel, or a window with too few samples to transform — it degrades
    /// to an **empty** model rather than throwing, so the panel shows "no data"
    /// instead of surfacing the error. The engine resamples a non-uniformly-sampled
    /// channel to a uniform rate first, so this never needs to.
    @MainActor
    static func compute(from session: AnalysisSession, channel: String,
                        windowFunction: SpectrumWindowKind,
                        window: TimeWindow = .all) -> SpectrumModel {
        let spectrum = (try? session.spectrum(channel: channel, windowFunction: windowFunction,
                                              window: window)) ?? .empty
        return SpectrumModel(channel: channel, windowFunction: windowFunction, spectrum: spectrum)
    }
}

/// The Spectrum panel's window-level knob (issue 8.16): the chosen window function,
/// held apart from ``AnalysisWindowModel`` so it survives layout switches — the same
/// reason ``StatsPanelsModel`` holds the histogram bin count. The taper choice is the
/// only state here; the spectrum itself is computed by ``SpectrumModel/compute(from:channel:windowFunction:window:)``
/// and cached in the view (so a re-render never re-marshals the FFT across the FFI).
/// `@MainActor` because the SwiftUI panel reads it on the main actor.
@MainActor
public final class SpectrumPanelModel: ObservableObject {

    /// The window function applied before the transform; Hann (the general-purpose
    /// default) until the user picks another.
    @Published public private(set) var windowFunction: SpectrumWindowKind = .hann

    public init() {}

    /// Choose the window function — the RS3 taper selector.
    public func setWindowFunction(_ function: SpectrumWindowKind) {
        windowFunction = function
    }
}
