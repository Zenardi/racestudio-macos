import CoreGraphics
import Foundation
import Testing
@testable import RaceStudioCore

/// Tests for the text size on the needle speedometer and tachometer (issue
/// 9.21): their scale numbers, their readout and their caption grow with the
/// text size as far as the dial allows — never into each other, the tick
/// marks, the needle's hub or out of the widget.
@Suite struct DialTextSizeTests {

    // MARK: - Fixture (no logic — fixed contexts)

    private func tachometer(_ rect: CGRect = CGRect(x: 0, y: 0, width: 280, height: 280), textSize: Double,
                            maxRPM: Double = 16_000) -> OverlayWidgetContext {
        OverlayRenderFixture.context(.rpm, rect: rect, plate: .none, textSize: textSize,
                                     options: OverlayWidgetOptions(maxRPM: maxRPM, shiftLightRPM: maxRPM * 0.9,
                                                                   gaugeStyle: .needle))
    }

    private func speedometer(_ rect: CGRect = CGRect(x: 0, y: 0, width: 280, height: 280), textSize: Double,
                             maxSpeed: Double = 160, units: UnitSystem = .metric) -> OverlayWidgetContext {
        OverlayRenderFixture.context(.speed, rect: rect, plate: .none, textSize: textSize, units: units,
                                     options: OverlayWidgetOptions(gaugeStyle: .needle, maxSpeed: maxSpeed))
    }

    /// The boxes a dial's texts are drawn in: each scale number, the readout's
    /// widest digits, and the caption.
    private struct Boxes {
        let labels: [CGRect]
        let value: CGRect
        let caption: CGRect
    }

    private func boxes(_ dial: DialLayout, template: String, caption: String) -> Boxes {
        Boxes(labels: dial.labels.map { Dial.textBox($0.text, dial.labelStyle, in: $0.slot) },
              value: Dial.textBox(template, dial.valueStyle, in: dial.value),
              caption: Dial.textBox(caption, dial.captionStyle, in: dial.caption))
    }

    /// A dial as drawn: its layout, its readout's widest digits, its caption and
    /// the widget's content.
    private struct Drawn {
        let dial: DialLayout
        let template: String
        let caption: String
        let content: CGRect
    }

    /// Whether two boxes share any area — touching edges do not count.
    private func overlap(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
        let shared = lhs.intersection(rhs)
        return !shared.isNull && shared.width * shared.height > 1e-9
    }

    private func corners(_ box: CGRect) -> [CGPoint] {
        [CGPoint(x: box.minX, y: box.minY), CGPoint(x: box.maxX, y: box.minY),
         CGPoint(x: box.minX, y: box.maxY), CGPoint(x: box.maxX, y: box.maxY)]
    }

    private func distance(_ point: CGPoint, from centre: CGPoint) -> CGFloat {
        hypot(point.x - centre.x, point.y - centre.y)
    }

    // MARK: - Growing

    /// At 150 % the speedometer's scale numbers and readout are half as big
    /// again.
    @Test func test_the_speedometer_numbers_grow_with_the_text_size() {
        let base = SpeedometerWidget().layout(in: speedometer(textSize: 1)).dial
        let sized = SpeedometerWidget().layout(in: speedometer(textSize: 1.5)).dial

        #expect(abs(sized.labelStyle.capHeight / base.labelStyle.capHeight - 1.5) < 0.01)
        #expect(abs(sized.valueStyle.capHeight / base.valueStyle.capHeight - 1.5) < 0.01)
        #expect(sized.captionStyle.capHeight > base.captionStyle.capHeight)
    }

    /// The tachometer's numbers grow too.
    @Test func test_the_tachometer_numbers_grow_with_the_text_size() {
        let base = TachometerWidget().layout(in: tachometer(textSize: 1)).dial
        let sized = TachometerWidget().layout(in: tachometer(textSize: 1.5)).dial

        #expect(abs(sized.labelStyle.capHeight / base.labelStyle.capHeight - 1.5) < 0.01)
        #expect(sized.valueStyle.capHeight > base.valueStyle.capHeight * 1.3)
    }

    /// At 200 % the numbers are as big as the dial allows: bigger than at
    /// 150 %, or held where they would collide.
    @Test func test_at_200_percent_the_numbers_are_as_big_as_the_dial_allows() {
        let middle = TachometerWidget().layout(in: tachometer(textSize: 1.5)).dial
        let largest = TachometerWidget().layout(in: tachometer(textSize: 2)).dial

        #expect(largest.labelStyle.capHeight >= middle.labelStyle.capHeight)
        #expect(largest.valueStyle.capHeight >= middle.valueStyle.capHeight)
    }

    /// Smaller text shrinks by the text size.
    @Test func test_the_dial_numbers_shrink_with_a_smaller_text_size() {
        let base = SpeedometerWidget().layout(in: speedometer(textSize: 1)).dial
        let sized = SpeedometerWidget().layout(in: speedometer(textSize: 0.5)).dial

        #expect(abs(sized.labelStyle.capHeight / base.labelStyle.capHeight - 0.5) < 0.01)
        #expect(abs(sized.valueStyle.capHeight / base.valueStyle.capHeight - 0.5) < 0.01)
    }

    // MARK: - Never colliding

    /// At every text size, in every box, no text of a dial runs into another;
    /// all of them stay inside the widget; the readout stays under the hub.
    @Test(arguments: [0.5, 1, 1.5, 2], [CGSize(width: 280, height: 280), CGSize(width: 120, height: 120),
                                        CGSize(width: 400, height: 260), CGSize(width: 200, height: 320),
                                        CGSize(width: 60, height: 60)])
    func test_no_text_of_a_dial_collides(textSize: Double, size: CGSize) {
        let rect = CGRect(origin: .zero, size: size)
        let dials: [Drawn] = [16_000, 9_000, 30_000].map { rpm in
            let context = tachometer(rect, textSize: textSize, maxRPM: rpm)
            return Drawn(dial: TachometerWidget().layout(in: context).dial, template: "88888",
                         caption: TachometerWidget.caption, content: context.content)
        } + [(160, UnitSystem.metric), (400, .metric), (160, .imperial)].map { speed, units in
            let context = speedometer(rect, textSize: textSize, maxSpeed: speed, units: units)
            return Drawn(dial: SpeedometerWidget().layout(in: context).dial, template: "888",
                         caption: units.speedUnit, content: context.content)
        }

        for drawnDial in dials {
            let dial = drawnDial.dial, content = drawnDial.content
            let drawn = boxes(dial, template: drawnDial.template, caption: drawnDial.caption)
            for (box, next) in zip(drawn.labels, drawn.labels.dropFirst()) {
                #expect(!overlap(box, next), "labels \(box) and \(next) at \(textSize) in \(size)")
            }
            for box in drawn.labels {
                #expect(!overlap(box, drawn.value) && !overlap(box, drawn.caption), "\(box) at \(textSize)")
            }
            #expect(!overlap(drawn.value, drawn.caption), "readout and caption at \(textSize) in \(size)")
            for box in drawn.labels + [drawn.value, drawn.caption] {
                #expect(content.insetBy(dx: -0.5, dy: -0.5).contains(box), "\(box) at \(textSize)")
            }
            #expect(drawn.value.maxY <= dial.centre.y - dial.radius * 0.06, "the readout under the hub")
        }
    }

    /// Grown, the scale numbers stay inside the tick marks.
    @Test(arguments: [1.5, 2], [CGSize(width: 280, height: 280), CGSize(width: 120, height: 120)])
    func test_grown_numbers_stay_inside_the_ticks(textSize: Double, size: CGSize) {
        let dial = SpeedometerWidget().layout(in: speedometer(CGRect(origin: .zero, size: size), textSize: textSize,
                                                              maxSpeed: 400)).dial

        for label in dial.labels {
            let box = Dial.textBox(label.text, dial.labelStyle, in: label.slot)
            #expect(corners(box).allSatisfy { distance($0, from: dial.centre) <= dial.radius * 0.86 },
                    "\(label.text) at \(textSize)")
        }
    }
}
