import Testing
import Foundation

@testable import RaceStudioCore

/// Tests for the overlay widgets' names (issue 9.12) — what the editor's widget
/// list shows beside each toggle, in English and Brazilian Portuguese.
@Suite struct OverlayWidgetTitleTests {

    private let en = Locale(identifier: "en_US")
    private let ptBR = Locale(identifier: "pt_BR")

    private static let plainKinds: [OverlayWidgetKind] = [
        .speed, .rpm, .gear, .lapTimer, .lapInfo, .delta, .gForce, .trackMap, .pedals, .temperature,
        .sectorTimes, .kartBadge, .sessionInfo
    ]

    /// Every kind has a real name in both languages, and no two share one.
    @Test func test_every_kind_is_named_in_both_languages() {
        for locale in [en, ptBR] {
            let titles = Self.plainKinds.map { $0.title(locale: locale) }
            #expect(titles.allSatisfy { !$0.isEmpty && !L10n.isFlagged($0) })
            #expect(Set(titles).count == titles.count, "\(locale.identifier): names must be distinct")
        }
    }

    /// A few names, as the operator reads them.
    @Test func test_names_read_as_the_operator_knows_them() {
        #expect(OverlayWidgetKind.trackMap.title(locale: en) == "Track map")
        #expect(OverlayWidgetKind.gForce.title(locale: en) == "G-ball")
        #expect(OverlayWidgetKind.pedals.title(locale: ptBR) == "Pedais")
    }

    /// A channel readout is named for what it reads.
    @Test func test_a_channel_readout_is_named_for_its_channel() {
        #expect(OverlayWidgetKind.channelValue(.role(.waterTemp)).title(locale: en) == "Water temperature")
        #expect(OverlayWidgetKind.channelValue(.channel("Oil Temp")).title(locale: ptBR) == "Oil Temp")
    }
}
