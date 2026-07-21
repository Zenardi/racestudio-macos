import Testing
@testable import RaceStudioCore

/// Tests for `WindowLayout` (issues 8.3 / 8.9): the analysis window rail's panel
/// set and each layout's stable title, SF Symbol, and identity — the labels the
/// thin rail view binds to.
@Suite struct WindowLayoutTests {

    @Test func test_layout_titles_label_the_rail() {
        #expect(WindowLayout.timeDistance.title == "Time / Distance")
        #expect(WindowLayout.channelTable.title == "Channels")
        #expect(WindowLayout.trackMap.title == "Track Map")
        #expect(WindowLayout.lapOverlay.title == "Lap Overlay")
        #expect(WindowLayout.histogram.title == "Histogram")
        #expect(WindowLayout.scatter.title == "Scatter")
        #expect(WindowLayout.spectrum.title == "Spectrum")
        #expect(WindowLayout.suspension.title == "Suspension")
        #expect(WindowLayout.channelsReport.title == "Report")
        #expect(WindowLayout.splitTimes.title == "Splits")
        #expect(WindowLayout.mathChannels.title == "Math")
        #expect(WindowLayout.summary.title == "Summary")
        #expect(WindowLayout.logSheet.title == "Log Sheet")
    }

    @Test func test_layout_system_image_names_are_stable() {
        #expect(WindowLayout.timeDistance.systemImageName == "chart.xyaxis.line")
        #expect(WindowLayout.channelTable.systemImageName == "tablecells")
        #expect(WindowLayout.trackMap.systemImageName == "map")
        #expect(WindowLayout.lapOverlay.systemImageName == "point.3.connected.trianglepath.dotted")
        #expect(WindowLayout.histogram.systemImageName == "chart.bar.xaxis")
        #expect(WindowLayout.scatter.systemImageName == "chart.dots.scatter")
        #expect(WindowLayout.spectrum.systemImageName == "waveform")
        #expect(WindowLayout.suspension.systemImageName == "arrow.up.and.down")
        #expect(WindowLayout.channelsReport.systemImageName == "chart.bar.doc.horizontal")
        #expect(WindowLayout.splitTimes.systemImageName == "stopwatch")
        #expect(WindowLayout.mathChannels.systemImageName == "function")
        #expect(WindowLayout.summary.systemImageName == "list.bullet.rectangle")
        #expect(WindowLayout.logSheet.systemImageName == "doc.text")
    }

    @Test func test_window_layout_id_is_the_raw_value() {
        #expect(WindowLayout.timeDistance.id == "timeDistance")
        #expect(WindowLayout.channelTable.id == "channelTable")
        #expect(WindowLayout.trackMap.id == "trackMap")
        #expect(WindowLayout.lapOverlay.id == "lapOverlay")
        #expect(WindowLayout.histogram.id == "histogram")
        #expect(WindowLayout.scatter.id == "scatter")
        #expect(WindowLayout.spectrum.id == "spectrum")
        #expect(WindowLayout.suspension.id == "suspension")
        #expect(WindowLayout.channelsReport.id == "channelsReport")
        #expect(WindowLayout.splitTimes.id == "splitTimes")
        #expect(WindowLayout.mathChannels.id == "mathChannels")
        #expect(WindowLayout.summary.id == "summary")
        #expect(WindowLayout.logSheet.id == "logSheet")
    }
}
