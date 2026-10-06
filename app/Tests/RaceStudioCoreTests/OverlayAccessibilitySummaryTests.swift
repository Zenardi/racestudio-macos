import Testing
import Foundation

@testable import RaceStudioCore

/// Tests for the HUD's VoiceOver summary (issue 9.12): one sentence of what the
/// overlay shows at the cursor — "Lap 7, 1:02.3, speed 84 km/h, delta minus
/// 0.21" — in the layout's units and the reader's language, leaving out
/// whatever the session cannot say at that instant.
@Suite struct OverlayAccessibilitySummaryTests {

    private let en = Locale(identifier: "en_US")
    private let ptBR = Locale(identifier: "pt_BR")

    private func lap(number: Int, elapsed: Double) -> LapClockReading {
        LapClockReading(lap: LapID(number - 1), number: number, elapsed: elapsed, last: nil, best: nil,
                        bestSoFar: nil, isOutLap: false, isInLap: false, sector: nil)
    }

    private func frame(speed: Double? = nil, lap: LapClockReading? = nil, delta: Double? = nil) -> TelemetryFrame {
        TelemetryFrame(time: 100, values: speed.map { [.speed: $0] } ?? [:], lap: lap, delta: delta)
    }

    // MARK: - A full frame

    /// Every part present reads as the issue's example sentence.
    @Test func test_a_full_frame_reads_lap_time_speed_and_delta() {
        let full = frame(speed: 84.2, lap: lap(number: 7, elapsed: 62.3), delta: -0.2149)

        #expect(OverlayAccessibilitySummary.text(for: full, locale: en)
                == "Lap 7, 1:02.3, speed 84 km/h, delta minus 0.21")
    }

    /// In Brazilian Portuguese, with the comma decimal mark.
    @Test func test_a_full_frame_reads_in_portuguese() {
        let full = frame(speed: 84.2, lap: lap(number: 7, elapsed: 62.3), delta: 0.4)

        #expect(OverlayAccessibilitySummary.text(for: full, locale: ptBR)
                == "Volta 7, 1:02,3, velocidade 84 km/h, delta mais 0,40")
    }

    /// The speed is spoken in the overlay's units.
    @Test func test_speed_follows_the_layout_units() {
        let full = frame(speed: 84.2)

        #expect(OverlayAccessibilitySummary.text(for: full, units: .imperial, locale: en) == "speed 52 mph")
    }

    // MARK: - Gaps

    /// A missing value is left out, never read as zero.
    @Test func test_missing_values_are_left_out() {
        #expect(OverlayAccessibilitySummary.text(for: frame(delta: 0.05), locale: en) == "delta plus 0.05")
        #expect(OverlayAccessibilitySummary.text(for: frame(lap: lap(number: 1, elapsed: 0)), locale: en)
                == "Lap 1, 0:00.0")
        #expect(OverlayAccessibilitySummary.text(for: frame(speed: 12, delta: -1.5), locale: en)
                == "speed 12 km/h, delta minus 1.50")
    }

    /// With nothing to say — no frame, or a frame of gaps — it says so.
    @Test func test_no_telemetry_is_said_plainly() {
        #expect(OverlayAccessibilitySummary.text(for: nil, locale: en) == "No telemetry here")
        #expect(OverlayAccessibilitySummary.text(for: frame(), locale: ptBR) == "Sem telemetria aqui")
    }

    /// A delta that rounds to zero is neither plus nor minus.
    @Test func test_a_delta_rounding_to_zero_is_unsigned() {
        #expect(OverlayAccessibilitySummary.text(for: frame(delta: -0.004), locale: en) == "delta 0.00")
    }

    /// The lap time is read to the tenth, carrying into the minute.
    @Test func test_the_lap_time_rounds_to_the_tenth() {
        let carried = frame(lap: lap(number: 3, elapsed: 59.96))

        #expect(OverlayAccessibilitySummary.text(for: carried, locale: en) == "Lap 3, 1:00.0")
    }

    /// A value that is not a reading (an impossible lap time, a non-finite
    /// speed) is left out rather than spoken as garbage.
    @Test func test_unusable_values_are_left_out() {
        let broken = frame(speed: .infinity, lap: lap(number: 2, elapsed: -3), delta: .nan)

        #expect(OverlayAccessibilitySummary.text(for: broken, locale: en) == "Lap 2")
    }
}
