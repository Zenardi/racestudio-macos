import Testing
@testable import RaceStudioCore

/// Tests for `PlotArrangement` (issue 8.12): the RaceStudio-3 display modes that
/// map N channels onto graphs — overlapped, mixed (≤ 6 graphs), tiled, smart, and
/// smart-tiled — plus the shared-vs-per-graph Y decision and the smart-mode
/// corner-bound family grouping.
@Suite struct PlotArrangementTests {

    private let channels = ["Speed", "RPM", "Throttle", "Brake", "Gear", "Steering", "Lat Acc", "Lon Acc"]

    // MARK: - Overlapped

    @Test func test_overlapped_puts_every_channel_in_one_shared_y_graph() {
        let arrangement = PlotArrangement.arrange(mode: .overlapped, channels: channels)
        #expect(arrangement.graphs.count == 1)
        #expect(arrangement.graphs[0].channelNames == channels)
        #expect(arrangement.sharedY, "one graph → a single shared Y axis")
    }

    // MARK: - Tiled

    @Test func test_tiled_gives_each_channel_its_own_per_graph_y() {
        let arrangement = PlotArrangement.arrange(mode: .tiled, channels: channels)
        #expect(arrangement.graphs.count == channels.count)
        #expect(arrangement.graphs.map(\.channelNames) == channels.map { [$0] })
        #expect(!arrangement.sharedY, "each channel on its own Y axis is per-graph Y")
    }

    // MARK: - Mixed

    @Test func test_mixed_caps_the_graph_count_at_six() {
        let arrangement = PlotArrangement.arrange(mode: .mixed, channels: channels)
        #expect(arrangement.graphs.count == PlotArrangement.maxMixedGraphs)
        #expect(arrangement.graphs.count == 6)
        #expect(!arrangement.sharedY)
    }

    @Test func test_mixed_partitions_all_channels_in_order_without_loss() {
        let arrangement = PlotArrangement.arrange(mode: .mixed, channels: channels)
        // 8 channels into 6 graphs: 2, 2, 1, 1, 1, 1 — the leading graphs take the remainder.
        #expect(arrangement.graphs.map(\.channelNames.count) == [2, 2, 1, 1, 1, 1])
        #expect(arrangement.graphs.flatMap(\.channelNames) == channels, "no channel dropped, order kept")
    }

    @Test func test_mixed_with_few_channels_makes_one_graph_each() {
        let arrangement = PlotArrangement.arrange(mode: .mixed, channels: ["Speed", "RPM", "Gear"])
        #expect(arrangement.graphs.map(\.channelNames) == [["Speed"], ["RPM"], ["Gear"]])
    }

    // MARK: - Smart

    private let cornerChannels = [
        "Damper Pos FL", "Damper Pos FR", "Damper Pos RL", "Damper Pos RR",
        "Wheel Speed FL", "Wheel Speed FR",
        "Brake Press Front", "Brake Press Rear",
        "GPS Speed", "RPM"
    ]

    @Test func test_smart_auto_groups_each_corner_bound_family() {
        let arrangement = PlotArrangement.arrange(mode: .smart, channels: cornerChannels)
        let groups = arrangement.graphs.map(\.channelNames)
        #expect(groups.contains(["Damper Pos FL", "Damper Pos FR", "Damper Pos RL", "Damper Pos RR"]),
                "the four dampers form one graph")
        #expect(groups.contains(["Wheel Speed FL", "Wheel Speed FR"]), "the wheel speeds form one graph")
        #expect(groups.contains(["Brake Press Front", "Brake Press Rear"]), "the brakes form one graph")
    }

    @Test func test_smart_overlays_all_non_family_channels_in_one_graph() {
        let arrangement = PlotArrangement.arrange(mode: .smart, channels: cornerChannels)
        let groups = arrangement.graphs.map(\.channelNames)
        // GPS Speed + RPM are not corner-bound → overlaid together as the trailing graph.
        #expect(groups.last == ["GPS Speed", "RPM"])
        #expect(arrangement.graphs.count == 4, "3 families + 1 leftover graph")
    }

    @Test func test_smart_does_not_mistake_gps_speed_for_a_wheel_speed() {
        let arrangement = PlotArrangement.arrange(mode: .smart, channels: ["GPS Speed", "Wheel Speed FL"])
        let groups = arrangement.graphs.map(\.channelNames)
        #expect(groups.contains(["Wheel Speed FL"]), "only the wheel channel is a wheel-speed family member")
        #expect(groups.contains(["GPS Speed"]), "GPS Speed stays a leftover, not a wheel speed")
    }

    // MARK: - Smart tiled

    @Test func test_smart_tiled_keeps_families_but_tiles_each_leftover() {
        let arrangement = PlotArrangement.arrange(mode: .smartTiled, channels: cornerChannels)
        let groups = arrangement.graphs.map(\.channelNames)
        #expect(groups.contains(["Damper Pos FL", "Damper Pos FR", "Damper Pos RL", "Damper Pos RR"]),
                "families are still grouped")
        #expect(groups.contains(["GPS Speed"]), "each leftover is tiled on its own")
        #expect(groups.contains(["RPM"]))
        #expect(arrangement.graphs.count == 5, "3 families + 2 tiled leftovers")
    }

    // MARK: - Empty / edge

    @Test func test_every_mode_yields_no_graphs_for_no_channels() {
        for mode in PlotArrangementMode.allCases {
            #expect(PlotArrangement.arrange(mode: mode, channels: []).graphs.isEmpty,
                    "\(mode) with no channels has no graphs")
        }
    }

    @Test func test_a_single_channel_is_one_graph_in_every_mode() {
        for mode in PlotArrangementMode.allCases {
            let arrangement = PlotArrangement.arrange(mode: mode, channels: ["Speed"])
            #expect(arrangement.graphs.map(\.channelNames) == [["Speed"]], "\(mode) with one channel")
            #expect(arrangement.sharedY, "\(mode): a single graph is shared-Y")
        }
    }

    // MARK: - Mode metadata

    @Test func test_modes_expose_stable_titles_and_ids() {
        #expect(PlotArrangementMode.allCases == [.overlapped, .mixed, .tiled, .smart, .smartTiled])
        #expect(PlotArrangementMode.overlapped.id == "overlapped")
        #expect(!PlotArrangementMode.smartTiled.title.isEmpty)
        #expect(!PlotArrangementMode.overlapped.systemImageName.isEmpty)
    }

    @Test func test_graph_ids_are_distinct_so_the_view_can_foreach_them() {
        let arrangement = PlotArrangement.arrange(mode: .tiled, channels: channels)
        #expect(Set(arrangement.graphs.map(\.id)).count == arrangement.graphs.count)
    }

    @Test func test_graph_count_reports_the_number_of_stacked_graphs() {
        #expect(PlotArrangement.arrange(mode: .overlapped, channels: channels).graphCount == 1)
        #expect(PlotArrangement.arrange(mode: .mixed, channels: channels).graphCount == 6)
        #expect(PlotArrangement.arrange(mode: .tiled, channels: channels).graphCount == channels.count)
    }

    @Test func test_all_modes_expose_non_empty_titles_and_images() {
        for mode in PlotArrangementMode.allCases {
            #expect(!mode.title.isEmpty, "\(mode) has a picker title")
            #expect(!mode.systemImageName.isEmpty, "\(mode) has an SF Symbol")
        }
    }

    @Test func test_channel_families_expose_stable_ids_and_titles() {
        #expect(PlotChannelFamily.allCases == [.damper, .wheelSpeed, .brake, .tyre])
        for family in PlotChannelFamily.allCases {
            #expect(family.id == family.rawValue)
            #expect(!family.title.isEmpty, "\(family) has a legend title")
        }
    }
}
